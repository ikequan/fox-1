import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart' show StateProvider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../../config/constants.dart';
import '../../main.dart';
import '../../providers/providers.dart';
import '../../services/agent/agent_bridge.dart';
import '../../services/camera/watch_camera_service.dart';
import '../bridge/call_bridge_service.dart';
import '../logging/log_buffer.dart';
import '../notes/note_store.dart' show NoteStatus;
import '../notes/ring_notes.dart';
import '../ring/health_store.dart' show ReportPeriod;
import '../ring/ring_console.dart';
import '../ring/ring_protocol.dart' show parseHex;
import '../../widgets/mascot.dart' show Mascot;
import 'portal_api.dart';
import 'portal_auth.dart';
import 'ring_console_html.dart';
import '../call/auto_answer.dart';

/// Singleton settings server — uses globalContainer for provider access
/// so it works regardless of which screen is active.
class SettingsServer {
  static SettingsServer? _instance;
  HttpServer? _server;
  WatchCameraService? _previewCamera;
  int _streamClientCount = 0;

  SettingsServer._();

  static SettingsServer get instance => _instance ??= SettingsServer._();

  bool get isRunning => _server != null;

  /// Started and stopped by `PortalService` — use that, not this.
  Future<void> start(
    String ip, {
    required PortalAuth auth,
    required PortalApi api,
    void Function()? onVisit,
  }) async {
    if (_server != null) return;

    final router = Router();
    for (final path in _assets.keys) {
      router.get(path, _asset);
    }
    api.register(router);
    router
      ..get('/api/settings', _handleGetSettings)
      ..post('/api/settings', _handlePostSettings)
      ..post('/api/watchface', _handlePostWatchface)
      ..get('/api/camera/stream', _handleCameraStream)
      ..post('/api/camera', _handlePostCamera)
      ..get('/logs', _handleLogsPage)
      ..get('/api/logs', _handleLogsData)
      ..post('/api/logs/clear', _handleLogsClear)
      ..get('/api/bridge/recordings', _handleBridgeRecordings)
      ..get('/api/bridge/recordings/<name>', _handleBridgeRecording)
      ..get('/ring', _handleRingConsole)
      ..get('/api/ring/status', _handleRingStatus)
      ..get('/api/ring/health', _handleRingHealth)
      ..post('/api/ring/send', _handleRingSend)
      ..post('/api/ring/action', _handleRingAction)
      ..get('/api/ring/recordings', _handleRingRecordings)
      ..get('/api/ring/recordings/<name>', _handleRingRecording)
      ..get('/api/logs/files', _handleLogFiles)
      ..get('/api/logs/files/<name>', _handleLogFile);

    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addMiddleware(_gate(auth, onVisit))
        .addHandler(router.call);

    // Before listening, not after. prepareNetwork binds this whole process to
    // cellular so call audio does not fight Wi-Fi, and a server socket opened
    // under that bind cannot be reached over the LAN. The wearer is at a desk
    // when they use this; the bind is restored when they close it.
    await CallBridgeService().unbindNetwork();

    _server = await shelf_io.serve(handler, '0.0.0.0', 8080);
  }

  Future<void> stop() async {
    await _stopCamera();
    await _server?.close(force: true);
    _server = null;
    // Put the call agent's traffic back on cellular if it is still on duty.
    if (globalContainer.read(callOrchestratorProvider).isRunning) {
      await CallBridgeService().prepareNetwork();
    }
  }

  CameraConfig _readCameraConfig() {
    final c = globalContainer;
    return CameraConfig(
      rotation: c.read(cameraRotationProvider),
      quality: c.read(cameraQualityProvider),
      resolution: c.read(cameraResolutionProvider),
      mirror: c.read(cameraMirrorProvider),
      aspectRatio: c.read(cameraAspectRatioProvider),
    );
  }

  Future<void> _startCamera() async {
    if (_previewCamera != null) return;
    _previewCamera = WatchCameraService();
    await _previewCamera!.start(config: _readCameraConfig());
  }

  Future<void> _stopCamera() async {
    _previewCamera?.dispose();
    _previewCamera = null;
  }

  /// The device's address on the current Wi-Fi, so the server can be reached
  /// from a PC on the same network without standing up the hotspot.
  /// Interfaces a phone beside the device can reach it on. Pure; tested.
  static bool isLocalInterface(String name) =>
      const ['wlan', 'eth', 'ap', 'swlan', 'softap', 'rndis', 'usb']
          .any(name.startsWith);

  static Future<String?> wifiIp() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      // Only an address a phone next to the device can reach: Wi-Fi, a
      // hotspot, a cable. Never mobile data (rmnet…, seth_lte…, ccmni…) —
      // right after Android restarted, before Wi-Fi reconnected, the Hub
      // once advertised its LTE address, and the phone could not open it.
      for (final ni in interfaces) {
        if (!isLocalInterface(ni.name)) continue;
        for (final addr in ni.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Stage 4 writes a WAV to the app's external files dir. With no ADB on this
  /// device, this is the only way to get it off and listen to it —
  /// which is the entire pass criterion for that stage.
  Future<shelf.Response> _handleBridgeRecordings(shelf.Request request) async {
    final files = await CallBridgeService().recordings();
    final rows = files.map((f) {
      final name = f['name']?.toString() ?? '';
      final bytes = f['bytes'] ?? 0;
      final kb = (bytes is int ? bytes : 0) ~/ 1024;
      return '<li><a href="/api/bridge/recordings/$name">$name</a> '
          '<span>$kb kB</span></li>';
    }).join();
    final body = '<!doctype html><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Bridge recordings</title>'
        '<style>body{background:#0a0a0a;color:#eee;font:14px system-ui;padding:20px}'
        'a{color:#00E5CC}li{margin:6px 0}span{color:#888;font-size:12px}</style>'
        '<h3>Bridge recordings</h3>'
        '${files.isEmpty ? "<p>None yet — run stage 4.</p>" : "<ul>$rows</ul>"}';
    return shelf.Response.ok(body,
        headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  Future<shelf.Response> _handleBridgeRecording(
      shelf.Request request, String name) async {
    final files = await CallBridgeService().recordings();
    // Serve only names the native side listed — never a caller-supplied path.
    final match = files.where((f) => f['name']?.toString() == name).toList();
    if (match.isEmpty) return shelf.Response.notFound('no such recording');
    final file = File(match.first['path']?.toString() ?? '');
    if (!await file.exists()) return shelf.Response.notFound('missing on disk');
    return shelf.Response.ok(
      await file.readAsBytes(),
      headers: {
        'Content-Type': 'audio/wav',
        'Content-Disposition': 'attachment; filename="$name"',
      },
    );
  }

  /// `/ring` — every ring command as a button, for a browser. The device is too
  /// small to type hex on. Works while Settings → Smart Ring is open.
  shelf.Response _handleRingConsole(shelf.Request request) => shelf.Response.ok(
      ringConsoleHtml,
      headers: {'Content-Type': 'text/html; charset=utf-8'});

  shelf.Response _handleRingStatus(shelf.Request request) => _json(
      {'open': RingConsole.attached, 'connected': RingConsole.connected});

  Future<shelf.Response> _handleRingSend(shelf.Request request) async {
    Map body;
    try {
      body = jsonDecode(await request.readAsString()) as Map;
    } catch (_) {
      return _json({'ok': false, 'message': 'expected JSON {op, payload}'});
    }
    final op = int.tryParse(
        '${body['op'] ?? ''}'.trim().replaceFirst(RegExp('^0x', caseSensitive: false), ''),
        radix: 16);
    final payload = parseHex('${body['payload'] ?? ''}');
    if (op == null || payload == null) {
      return _json({'ok': false, 'message': 'opcode and payload must be hex'});
    }
    final msg = await RingConsole.send(op, payload);
    return _json({'ok': msg == RingConsole.sent, 'message': msg});
  }

  Future<shelf.Response> _handleRingAction(shelf.Request request) async {
    String name;
    try {
      name = '${(jsonDecode(await request.readAsString()) as Map)['name']}';
    } catch (_) {
      return _json({'ok': false, 'message': 'expected JSON {name}'});
    }
    final msg = await RingConsole.action(name);
    return _json({'ok': RingConsole.connected && !msg.startsWith('no such'),
        'message': msg});
  }

  /// The device's health history as JSON — today, and this week, month and
  /// year, aggregated LoraFit's way. The portal's health page will read this.
  Future<shelf.Response> _handleRingHealth(shelf.Request request) async {
    final ring = globalContainer.read(ringServiceProvider);
    final store = ring.store;
    final now = DateTime.now();
    return _json({
      'paired': ring.paired,
      'link': ring.link.name,
      'battery': ring.battery,
      'lastSync': ring.lastSync?.toIso8601String(),
      'lastSyncSummary': ring.lastSyncSummary,
      'today': (await store.summary(now))?.toJson(),
      'week': (await store.report(ReportPeriod.week, now)).toJson(),
      'month': (await store.report(ReportPeriod.month, now)).toJson(),
      'year': (await store.report(ReportPeriod.year, now)).toJson(),
    });
  }

  shelf.Response _json(Map<String, Object?> body) => shelf.Response.ok(
      jsonEncode(body),
      headers: {'Content-Type': 'application/json'});

  /// Voice notes from the ring: title, summary, action items, the transcript
  /// and a player. Only the ring's packets are kept; the audio is rebuilt on
  /// each play. The stage-6 portal replaces this page.
  Future<shelf.Response> _handleRingRecordings(shelf.Request request) async {
    final store = globalContainer.read(noteStoreProvider);
    final showSilent = request.url.queryParameters['all'] == '1';
    final notes = await store.all(withSilent: showSilent);
    final silent = await store.silentCount();
    const esc = HtmlEscape();
    String e(String? s) => esc.convert(s ?? '');
    final rows = notes.map((n) {
      final when = n.recordedAt.toString().substring(0, 16);
      final state = switch (n.status) {
        NoteStatus.done => '',
        NoteStatus.pending =>
          ' · <em>transcribing${n.error == null ? '' : ' — ${e(n.error)}'}</em>',
        NoteStatus.failed => ' · <em>not transcribed — ${e(n.error)}</em>',
      };
      final items = n.actionItems.isEmpty
          ? ''
          : '<ul>${n.actionItems.map((a) => '<li>${e(a)}</li>').join()}</ul>';
      final lang = (n.language ?? '').isEmpty ? '' : ' (${e(n.language)})';
      final transcript = (n.transcript ?? '').isEmpty
          ? ''
          : '<details><summary>Transcript$lang</summary><p>${e(n.transcript)}</p></details>';
      return '<li><b>${e(n.title ?? n.id)}</b><br>'
          '<span>$when · ${n.duration.inSeconds} s$state</span>'
          '${(n.summary ?? '').isEmpty ? '' : '<p>${e(n.summary)}</p>'}$items$transcript'
          '<audio controls preload="none" src="/api/ring/recordings/${n.id}.wav"></audio> '
          '<a href="/api/ring/recordings/${n.id}.opus40">packets</a></li>';
    }).join();
    final body = '<!doctype html><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Voice notes</title>'
        '<style>body{background:#0a0a0a;color:#eee;font:14px system-ui;padding:20px}'
        'a{color:#00E5CC}li{margin:16px 0}span{color:#888;font-size:12px}'
        'p{margin:6px 0;color:#ccc}em{color:#FFB74D;font-style:normal}'
        'details{margin:6px 0}audio{margin-top:4px;width:100%;max-width:420px}</style>'
        '<h3>Voice notes</h3>'
        '${silent == 0 ? '' : showSilent ? '<span><a href="?">Hide the $silent with no speech</a></span>' : '<span>$silent with no speech hidden · <a href="?all=1">show</a></span>'}'
        '${notes.isEmpty ? "<p>None yet — quadruple-tap the ring to start recording, and again to stop. It comes over to the device on its own.</p>" : "<ul>$rows</ul>"}';
    return shelf.Response.ok(body,
        headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  Future<shelf.Response> _handleRingRecording(
      shelf.Request request, String name) async {
    // Only ids the store knows — never a caller-supplied path.
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return shelf.Response.notFound('no such recording');
    final id = name.substring(0, dot), ext = name.substring(dot + 1);
    final store = globalContainer.read(noteStoreProvider);
    if (await store.get(id) == null) return shelf.Response.notFound('no such recording');
    final frames = await store.frames(id);
    if (frames == null) return shelf.Response.notFound('the recording is gone');
    switch (ext) {
      case 'wav':
        try {
          return shelf.Response.ok(await RingNotes.wavOf(frames),
              headers: {'Content-Type': 'audio/wav'});
        } catch (err) {
          return shelf.Response.internalServerError(body: 'could not decode: $err');
        }
      case 'opus40':
        return shelf.Response.ok(frames, headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': 'attachment; filename="$name"',
        });
      default:
        return shelf.Response.notFound('no such recording');
    }
  }

  /// Saved log sessions. The in-memory buffer at /logs dies with the process —
  /// and the process dying mid-call, screen off, is the thing worth reading
  /// about. These files survive it.
  shelf.Response _handleLogFiles(shelf.Request request) {
    final files = LogBuffer.instance.sessionFiles();
    final rows = files.map((f) {
      final name = f.uri.pathSegments.last;
      final kb = f.lengthSync() ~/ 1024;
      final when = f.statSync().modified.toString().split('.').first;
      return '<li><a href="/api/logs/files/$name">$name</a> '
          '<span>$kb kB · $when</span></li>';
    }).join();
    final body = '<!doctype html><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Saved logs</title>'
        '<style>body{background:#0a0a0a;color:#eee;font:14px system-ui;padding:20px}'
        'a{color:#00E5CC}li{margin:8px 0}span{color:#888;font-size:12px}</style>'
        '<h3>Saved logs</h3>'
        '<p><a href="/logs">live log</a></p>'
        '${files.isEmpty ? "<p>None yet.</p>" : "<ul>$rows</ul>"}';
    return shelf.Response.ok(body,
        headers: {'Content-Type': 'text/html; charset=utf-8'});
  }

  Future<shelf.Response> _handleLogFile(
      shelf.Request request, String name) async {
    // Serve only names the buffer listed — never a caller-supplied path.
    final match = LogBuffer.instance
        .sessionFiles()
        .where((f) => f.uri.pathSegments.last == name)
        .toList();
    if (match.isEmpty) return shelf.Response.notFound('no such log');
    return shelf.Response.ok(
      await match.first.readAsBytes(),
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Disposition': 'attachment; filename="$name"',
      },
    );
  }

  shelf.Response _handleLogsData(shelf.Request request) {
    final filter = request.url.queryParameters['q'];
    return shelf.Response.ok(
      LogBuffer.instance.render(filter: filter),
      headers: {'Content-Type': 'text/plain; charset=utf-8'},
    );
  }

  shelf.Response _handleLogsClear(shelf.Request request) {
    LogBuffer.instance.clear();
    return shelf.Response.ok('{"ok":true}',
        headers: {'Content-Type': 'application/json'});
  }

  shelf.Response _handleLogsPage(shelf.Request request) {
    return shelf.Response.ok(
      _logsHtml,
      headers: {'Content-Type': 'text/html; charset=utf-8'},
    );
  }

  /// Open without a session: the portal's own files and the sign-in itself.
  static const _public = {'/', '/portal.css', '/portal.js', '/icon.svg', '/api/auth'};

  /// Everything else needs a session. Only a signed-in request keeps the
  /// portal from closing for lack of use — and not a background refresh
  /// (`X-Portal-Poll: 1`), or a tab left open on Home would keep it on for
  /// ever.
  static shelf.Middleware _gate(PortalAuth auth, void Function()? onVisit) =>
      (inner) => (request) {
            final path = '/${request.url.path}';
            if (_public.contains(path)) return inner(request);
            if (auth.valid(PortalAuth.tokenIn(request.headers['cookie']))) {
              if (request.headers['x-portal-poll'] != '1') onVisit?.call();
              return inner(request);
            }
            if (path.startsWith('/api/')) {
              return shelf.Response(401,
                  body: jsonEncode({'ok': false, 'error': 'sign in'}),
                  headers: {'Content-Type': 'application/json'});
            }
            return shelf.Response.found('/#/login');
          };

  /// The portal frontend, bundled as Flutter assets (assets/portal/).
  static const _assets = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/portal.css': ('portal.css', 'text/css; charset=utf-8'),
    '/portal.js': ('portal.js', 'text/javascript; charset=utf-8'),
    '/icon.svg': ('icon.svg', 'image/svg+xml'),
  };

  Future<shelf.Response> _asset(shelf.Request request) async {
    final a = _assets['/${request.url.path}'];
    if (a == null) return shelf.Response.notFound('');
    try {
      final data = await rootBundle.load('assets/portal/${a.$1}');
      return shelf.Response.ok(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        headers: {'Content-Type': a.$2, 'Cache-Control': 'no-cache'},
      );
    } catch (_) {
      return shelf.Response.notFound('FOX-1 Hub is missing from this build');
    }
  }

  shelf.Response _handleGetSettings(shelf.Request request) {
    final c = globalContainer;
    final settings = {
      'gemini_api_key': c.read(geminiApiKeyProvider),
      'gemini_model': c.read(geminiModelProvider),
      'gemini_voice': c.read(geminiVoiceProvider),
      'mascot': c.read(mascotProvider).name,
      'assistant_name': c.read(assistantNameProvider),
      'ai_persona': c.read(aiPersonaProvider).isEmpty
          ? GeminiConfig.defaultPersona.trim()
          : c.read(aiPersonaProvider),
      if (c.read(developerModeProvider)) 'system_prompt': c.read(userSystemPromptProvider).isEmpty
          ? GeminiConfig.defaultPrompt.trim()
          : c.read(userSystemPromptProvider),
      'user_profile': c.read(userProfileProvider),
      'call_agent_on_duty': c.read(callAgentOnDutyProvider),
      'call_agent_device': c.read(callAgentDeviceProvider),
      'auto_answer_mode': c.read(autoAnswerModeProvider).name,
      'auto_answer_delay': c.read(autoAnswerDelayProvider),
      'stand_down_after': c.read(standDownAfterProvider),
      'auto_answer_blocked': c.read(autoAnswerBlockedProvider),
      'auto_answer_always': c.read(autoAnswerAlwaysProvider),
      'call_agent_prompt': c.read(callAgentPromptProvider).isEmpty
          ? GeminiConfig.defaultCallPrompt.trim()
          : c.read(callAgentPromptProvider),
      'agent_provider_type': c.read(agentProviderTypeProvider).name,
      'openclaw_host': c.read(openClawHostProvider),
      'openclaw_port': c.read(openClawPortProvider),
      'openclaw_token': c.read(openClawTokenProvider),
      'agent_relay_host': c.read(agentRelayHostProvider),
      'agent_relay_port': c.read(agentRelayPortProvider),
      'agent_relay_token': c.read(agentRelayTokenProvider),
      'camera_rotation': c.read(cameraRotationProvider),
      'camera_quality': c.read(cameraQualityProvider),
      'camera_resolution': c.read(cameraResolutionProvider),
      'camera_mirror': c.read(cameraMirrorProvider),
      'camera_aspect_ratio': c.read(cameraAspectRatioProvider),
      'watch_font_family': c.read(watchFontFamilyProvider),
      'watch_font_weight': c.read(watchFontWeightProvider),
      'watch_font_size_factor': c.read(watchFontSizeFactorProvider),
      'watch_time_x': c.read(watchTimeXProvider),
      'watch_time_y': c.read(watchTimeYProvider),
    };
    return shelf.Response.ok(
      jsonEncode(settings),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// Partial: only the keys present change. The portal sends what was
  /// edited, and a key left out must never be reset to its default — the old
  /// form sent everything, and anything that did not would have wiped the
  /// API key.
  Future<shelf.Response> _handlePostSettings(shelf.Request request) async {
    final Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(jsonDecode(await request.readAsString()) as Map);
    } catch (_) {
      return shelf.Response(400,
          body: jsonEncode({'ok': false, 'error': 'expected a JSON object'}),
          headers: {'Content-Type': 'application/json'});
    }
    final prefs = await SharedPreferences.getInstance();
    final c = globalContainer;

    Future<void> text(String key, StateProvider<String> p,
        {String? pref, String fallback = ''}) async {
      if (!data.containsKey(key)) return;
      var v = '${data[key] ?? ''}'.trim();
      if (v.isEmpty) v = fallback;
      c.read(p.notifier).state = v;
      await prefs.setString(pref ?? key, v);
    }

    Future<void> whole(String key, StateProvider<int> p, int fallback) async {
      if (!data.containsKey(key)) return;
      final v = (data[key] as num?)?.toInt() ?? fallback;
      c.read(p.notifier).state = v;
      await prefs.setInt(key, v);
    }

    await text('gemini_api_key', geminiApiKeyProvider);
    if (data.containsKey('gemini_model')) {
      // Only a model on offer; anything else falls back to the default.
      final model = AppConstants.supportedModel('${data['gemini_model'] ?? ''}'.trim());
      c.read(geminiModelProvider.notifier).state = model;
      await prefs.setString('gemini_model', model);
    }
    await text('gemini_voice', geminiVoiceProvider, fallback: 'Kore');
    if (data.containsKey('mascot')) {
      final mascot = Mascot.byName('${data['mascot'] ?? ''}'.trim());
      c.read(mascotProvider.notifier).state = mascot;
      await prefs.setString('mascot', mascot.name);
    }
    await text('assistant_name', assistantNameProvider, fallback: GeminiConfig.defaultAssistantName);
    await text('ai_persona', aiPersonaProvider);
    // Only developer mode may change the device instructions.
    if (c.read(developerModeProvider)) {
      await text('system_prompt', userSystemPromptProvider, pref: 'user_system_prompt');
    }
    await text('user_profile', userProfileProvider);

    if (data.containsKey('call_agent_on_duty')) {
      final onDuty = data['call_agent_on_duty'] == true;
      c.read(callAgentOnDutyProvider.notifier).state = onDuty;
      await prefs.setBool('call_agent_on_duty', onDuty);
    }
    await text('call_agent_device', callAgentDeviceProvider);
    if (data.containsKey('auto_answer_mode')) {
      final aaMode = '${data['auto_answer_mode'] ?? 'off'}';
      c.read(autoAnswerModeProvider.notifier).state = AutoAnswerMode.values
          .firstWhere((m) => m.name == aaMode, orElse: () => AutoAnswerMode.off);
      await prefs.setString('auto_answer_mode', aaMode);
    }
    await whole('auto_answer_delay', autoAnswerDelayProvider, 6);
    if (data.containsKey('stand_down_after')) {
      // Only a minute count on offer; anything else is the default.
      final v = (data['stand_down_after'] as num?)?.toInt();
      final m = AppConstants.standDownChoices.contains(v) ? v! : AppConstants.idleBeforeCold.inMinutes;
      c.read(standDownAfterProvider.notifier).state = m;
      await prefs.setInt('stand_down_after', m);
    }
    await text('auto_answer_blocked', autoAnswerBlockedProvider);
    await text('auto_answer_always', autoAnswerAlwaysProvider);
    await text('call_agent_prompt', callAgentPromptProvider);

    if (data.containsKey('agent_provider_type')) {
      final providerType = '${data['agent_provider_type'] ?? 'openClaw'}';
      c.read(agentProviderTypeProvider.notifier).state =
          AgentProviderType.fromString(providerType);
      await prefs.setString('agent_provider_type', providerType);
    }
    await text('openclaw_host', openClawHostProvider);
    await whole('openclaw_port', openClawPortProvider, 18789);
    await text('openclaw_token', openClawTokenProvider);
    await text('agent_relay_host', agentRelayHostProvider);
    if (data.containsKey('agent_relay_port')) {
      final arPort = (data['agent_relay_port'] as num?)?.toInt();
      c.read(agentRelayPortProvider.notifier).state = arPort;
      if (arPort != null) {
        await prefs.setInt('agent_relay_port', arPort);
      } else {
        await prefs.remove('agent_relay_port');
      }
    }
    await text('agent_relay_token', agentRelayTokenProvider);

    await _applyCamera(data, prefs);

    // Watchface — updates providers so watchface rebuilds in real-time
    await text('watch_font_family', watchFontFamilyProvider, fallback: 'Rajdhani');
    await whole('watch_font_weight', watchFontWeightProvider, 600);
    if (data.containsKey('watch_font_size_factor')) {
      final sizeFactor = (data['watch_font_size_factor'] as num?)?.toDouble() ?? 0.35;
      c.read(watchFontSizeFactorProvider.notifier).state = sizeFactor;
      await prefs.setDouble('watch_font_size_factor', sizeFactor);
    }
    await _applyTimePosition(data, prefs);

    return shelf.Response.ok(
      jsonEncode({'ok': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// The time's position on a live mascot's face, when [data] carries it —
  /// clamped to the screen. Shared by the settings save and the live
  /// watch-face push.
  Future<void> _applyTimePosition(Map<String, dynamic> data, SharedPreferences prefs) async {
    final c = globalContainer;
    for (final e in {'watch_time_x': watchTimeXProvider, 'watch_time_y': watchTimeYProvider}.entries) {
      if (!data.containsKey(e.key)) continue;
      final v = ((data[e.key] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
      c.read(e.value.notifier).state = v;
      await prefs.setDouble(e.key, v);
    }
  }

  /// The camera keys present in [data], applied and saved — shared by the
  /// settings save and the live camera push.
  Future<void> _applyCamera(Map<String, dynamic> data, SharedPreferences prefs) async {
    final c = globalContainer;
    if (data.containsKey('camera_rotation')) {
      final v = (data['camera_rotation'] as num).toInt();
      c.read(cameraRotationProvider.notifier).state = v;
      await prefs.setInt('camera_rotation', v);
    }
    if (data.containsKey('camera_quality')) {
      final v = (data['camera_quality'] as num).toInt();
      c.read(cameraQualityProvider.notifier).state = v;
      await prefs.setInt('camera_quality', v);
    }
    if (data.containsKey('camera_resolution')) {
      final v = data['camera_resolution'] as String;
      c.read(cameraResolutionProvider.notifier).state = v;
      await prefs.setString('camera_resolution', v);
    }
    if (data.containsKey('camera_mirror')) {
      final v = data['camera_mirror'] as bool;
      c.read(cameraMirrorProvider.notifier).state = v;
      await prefs.setBool('camera_mirror', v);
    }
    if (data.containsKey('camera_aspect_ratio')) {
      final v = data['camera_aspect_ratio'] as String;
      c.read(cameraAspectRatioProvider.notifier).state = v;
      await prefs.setString('camera_aspect_ratio', v);
    }
  }

  /// Lightweight endpoint for real-time watchface preview.
  /// Only updates font providers + persists — no other settings touched.
  Future<shelf.Response> _handlePostWatchface(shelf.Request request) async {
    final body = await request.readAsString();
    final Map<String, dynamic> data = jsonDecode(body);
    final prefs = await SharedPreferences.getInstance();
    final c = globalContainer;

    if (data.containsKey('watch_font_family')) {
      final v = data['watch_font_family'] as String;
      c.read(watchFontFamilyProvider.notifier).state = v;
      await prefs.setString('watch_font_family', v);
    }
    if (data.containsKey('watch_font_weight')) {
      final v = (data['watch_font_weight'] as num).toInt();
      c.read(watchFontWeightProvider.notifier).state = v;
      await prefs.setInt('watch_font_weight', v);
    }
    if (data.containsKey('watch_font_size_factor')) {
      final v = (data['watch_font_size_factor'] as num).toDouble();
      c.read(watchFontSizeFactorProvider.notifier).state = v;
      await prefs.setDouble('watch_font_size_factor', v);
    }
    await _applyTimePosition(data, prefs);

    return shelf.Response.ok(
      jsonEncode({'ok': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// MJPEG stream: multipart/x-mixed-replace.
  /// Camera starts on first client, stops when all clients disconnect.
  Future<shelf.Response> _handleCameraStream(shelf.Request request) async {
    _streamClientCount++;
    await _startCamera();

    const boundary = 'mjpeg_boundary';

    final frameSub = _previewCamera!.frames.listen(null);

    request.hijack((channel) async {
      final sink = channel.sink;
      final httpHeader = 'HTTP/1.1 200 OK\r\n'
          'Content-Type: multipart/x-mixed-replace; boundary=$boundary\r\n'
          'Cache-Control: no-cache\r\n'
          'Connection: keep-alive\r\n'
          '\r\n';
      sink.add(utf8.encode(httpHeader));

      frameSub.onData((jpeg) {
        try {
          final header = '--$boundary\r\n'
              'Content-Type: image/jpeg\r\n'
              'Content-Length: ${jpeg.length}\r\n'
              '\r\n';
          sink.add(utf8.encode(header));
          sink.add(jpeg);
          sink.add(utf8.encode('\r\n'));
        } catch (_) {}
      });

      void cleanup() {
        frameSub.cancel();
        _streamClientCount--;
        if (_streamClientCount <= 0) {
          _streamClientCount = 0;
          _stopCamera();
        }
      }

      channel.stream.listen((_) {}, onDone: () {
        cleanup();
        sink.close();
      }, onError: (_) {
        cleanup();
        sink.close();
      });
    });

    // ignore: dead_code
    return shelf.Response.ok('');
  }

  /// Live camera config push — updates providers + camera service
  Future<shelf.Response> _handlePostCamera(shelf.Request request) async {
    final body = await request.readAsString();
    final Map<String, dynamic> data = jsonDecode(body);
    await _applyCamera(data, await SharedPreferences.getInstance());

    // Update running camera with new config
    if (_previewCamera != null) {
      await _previewCamera!.updateConfig(_readCameraConfig());
    }

    return shelf.Response.ok(
      jsonEncode({'ok': true}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}

/// Self-contained log viewer: tails the buffer, filters, and follows.
const String _logsHtml = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>FOX-1 logs</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  body{background:#0a0a0f;color:#d8d8e0;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;margin:0;padding:12px}
  header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px}
  h1{font-size:15px;margin:0 8px 0 0;color:#00e5cc;font-weight:600}
  input,button{background:#16161f;color:#d8d8e0;border:1px solid #2a2a38;border-radius:6px;padding:6px 10px;font:inherit}
  button{cursor:pointer}
  button:hover{border-color:#00e5cc}
  label{display:flex;align-items:center;gap:5px;color:#8a8a9a}
  pre{white-space:pre-wrap;word-break:break-word;margin:0;padding:10px;background:#101018;border:1px solid #1e1e2a;border-radius:8px;height:calc(100vh - 90px);overflow:auto}
  .n{color:#5a5a6a}
</style></head><body>
<header>
  <h1>FOX-1 logs</h1><a href="/api/logs/files" style="color:#00E5CC">saved sessions</a>
  <input id="q" placeholder="filter e.g. GEMINI, AUDIO, AI_SESSION" size="34">
  <label><input type="checkbox" id="follow" checked> follow</label>
  <button id="clear">clear</button>
  <span class="n" id="count"></span>
</header>
<pre id="out">loading…</pre>
<script>
const out=document.getElementById('out'),q=document.getElementById('q'),
      follow=document.getElementById('follow'),count=document.getElementById('count');
async function tick(){
  try{
    const r=await fetch('/api/logs?q='+encodeURIComponent(q.value||''));
    const t=await r.text();
    const atBottom=out.scrollTop+out.clientHeight>=out.scrollHeight-40;
    out.textContent=t||'(no matching lines)';
    count.textContent=t?t.split('\\n').length+' lines':'';
    if(follow.checked&&atBottom)out.scrollTop=out.scrollHeight;
  }catch(e){out.textContent='disconnected — '+e;}
}
document.getElementById('clear').onclick=async()=>{await fetch('/api/logs/clear',{method:'POST'});tick();};
q.oninput=tick; tick(); setInterval(tick,1500);
</script></body></html>
''';
