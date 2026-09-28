import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import '../../config/constants.dart';
import '../../main.dart';
import '../../providers/providers.dart';
import '../call/call_history.dart';
import '../memory/memory_store.dart';
import '../notes/note_store.dart';
import '../notes/ring_notes.dart';
import '../ring/health_store.dart';
import '../ring/ring_service.dart';
import '../platform/system_actions_service.dart';
import '../setup/device_setup.dart';
import '../agent/native_tools_bridge.dart';
import '../agent/screen_capture.dart';
import '../platform/screen_automation_service.dart';
import '../session/ai_session_manager.dart';
import 'package:flutter/painting.dart' show Color;

import '../../watch_avatar/watch_avatar.dart'
    show AvatarParams, Character, kPalettes, kParamGroups, kParamSpecs, paramSpec;
import '../../widgets/mascot.dart' show Mascot;
import 'portal_auth.dart';

/// The portal's JSON (docs/HUB_API.md), apart from the settings and
/// camera endpoints `SettingsServer` already had. Built per start with that
/// start's [auth]; reads providers through [globalContainer], like the rest
/// of the server. The shapes are static and pure, and tested.
class PortalApi {
  PortalApi({
    required this.auth,
    required this.address,
    required this.closesAt,
    required this.stop,
  });

  final PortalAuth auth;
  final String address;
  final DateTime? Function() closesAt;
  final Future<void> Function() stop;

  void register(Router r) {
    r
      ..post('/api/auth', _signIn)
      ..get('/api/session', (shelf.Request _) => _ok())
      ..post('/api/logout', _signOut)
      ..get('/api/overview', _overview)
      ..get('/api/notes', _notes)
      ..post('/api/notes/delete-silent', _deleteSilent)
      ..get('/api/notes/<id>', _note)
      ..get('/api/notes/<id>/audio', _noteAudio)
      ..post('/api/notes/<id>/retry', _retry)
      ..delete('/api/notes/<id>', _deleteNote)
      ..get('/api/health/report', _healthReport)
      ..get('/api/conversations/days', _conversationDays)
      ..get('/api/conversations/search', _conversationSearch)
      ..get('/api/conversations', _conversations)
      ..get('/api/calls', _calls)
      ..get('/api/memory', _memory)
      ..post('/api/memory', _remember)
      ..post('/api/memory/<id>/confirm', _confirm)
      ..delete('/api/memory/<id>', _forget)
      ..get('/api/settings/options', _options)
      ..get('/api/avatar', _avatarGet)
      ..post('/api/avatar', _avatarSet)
      ..get('/api/setup', _setup)
      ..post('/api/setup/permission', _setupAsk)
      ..post('/api/setup/ring', _setupRing)
      ..post('/api/setup/done', _setupDone)
      ..get('/api/backup', _backup)
      ..post('/api/restore', _restore)
      ..post('/api/dev/task', _devTask)
      ..get('/api/dev/usage', _devUsage)
      ..get('/api/dev/screen', _devScreen)
      ..post('/api/dev/screen-tool', _devScreenTool)
      ..post('/api/portal/stop', _stop);
  }

  // ------------------------------------------------------------ sign-in

  Future<shelf.Response> _signIn(shelf.Request r) async {
    final String pin;
    try {
      pin = '${(jsonDecode(await r.readAsString()) as Map)['pin'] ?? ''}';
    } catch (_) {
      return _fail(400, 'expected {"pin":"123456"}');
    }
    final s = auth.signIn(pin);
    if (s.ok) {
      debugPrint('[PORTAL] signed in');
      return _ok(const {}, {
        'Set-Cookie':
            '${PortalAuth.cookieName}=${s.token}; Path=/; HttpOnly; SameSite=Strict',
      });
    }
    if (s.locked) {
      debugPrint('[PORTAL] too many wrong PINs — locked for ${s.retryIn} s');
      return _json({'ok': false, 'error': 'Too many tries', 'retryIn': s.retryIn}, status: 429);
    }
    return _json({'ok': false, 'error': 'Wrong PIN', 'retryIn': 0}, status: 401);
  }

  shelf.Response _signOut(shelf.Request r) {
    auth.signOut(PortalAuth.tokenIn(r.headers['cookie']));
    return _ok(const {}, {
      'Set-Cookie': '${PortalAuth.cookieName}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0',
    });
  }

  // ----------------------------------------------------------- overview

  Future<shelf.Response> _overview(shelf.Request r) async {
    final c = globalContainer;
    final ring = c.read(ringServiceProvider);
    final notes = c.read(noteStoreProvider);
    final memory = c.read(memoryStoreProvider);
    await memory.load();
    final listed = await notes.all();
    final now = DateTime.now();
    final today = await c.read(conversationStoreProvider).on(now);
    int? battery;
    var charging = false;
    try {
      final b = Battery();
      battery = await b.batteryLevel;
      charging = await b.batteryState == BatteryState.charging;
    } catch (_) {}
    return _json({
      'watch': {'battery': battery, 'charging': charging, 'now': now.toIso8601String()},
      'ring': ringJson(ring),
      'today': (await ring.store.summary(now))?.toJson(),
      'notes': {
        'count': listed.length,
        'waiting': listed.where((n) => n.status == NoteStatus.pending).length,
        'failed': listed.where((n) => n.status == NoteStatus.failed).length,
        'silent': await notes.silentCount(),
        'recent': [for (final n in listed.take(3)) noteJson(n)],
      },
      'memory': {'facts': memory.count, 'claims': memory.pendingClaims().length},
      'conversations': {
        'today': today.length,
        'last': today.isEmpty ? null : today.last.end.toIso8601String(),
      },
      'callAgent': {'onDuty': c.read(callAgentOnDutyProvider)},
      'assistant': {
        'name': c.read(assistantNameProvider),
        'model': c.read(geminiModelProvider),
        'voice': c.read(geminiVoiceProvider),
      },
      'portal': {'address': address, 'closesAt': closesAt()?.toIso8601String()},
    });
  }

  static Map<String, Object?> ringJson(RingService ring) => {
        'paired': ring.paired,
        'name': ring.name.isEmpty ? null : ring.name,
        'link': ring.link.name,
        'battery': ring.battery,
        'lastSync': ring.lastSync?.toIso8601String(),
        'lastSyncSummary': ring.lastSyncSummary,
        'liveSteps': ring.liveSteps,
      };

  // -------------------------------------------------------------- notes

  static Map<String, Object?> noteJson(Note n, {bool full = false}) => {
        'id': n.id,
        'recordedAt': n.recordedAt.toIso8601String(),
        'duration': n.duration.inSeconds,
        'status': n.status.name,
        'silent': n.silent,
        'title': n.title,
        'summary': n.summary,
        'language': n.language,
        'actionItems': n.actionItems,
        'people': n.people,
        'dates': n.dates,
        'error': n.error,
        if (full) 'transcript': n.transcript,
      };

  Future<shelf.Response> _notes(shelf.Request r) async {
    final store = globalContainer.read(noteStoreProvider);
    final q = (r.url.queryParameters['q'] ?? '').trim();
    final notes = q.isEmpty
        ? await store.all(withSilent: r.url.queryParameters['all'] == '1')
        : await store.search(q);
    return _json({
      'notes': [for (final n in notes) noteJson(n)],
      'silent': await store.silentCount(),
    });
  }

  Future<shelf.Response> _note(shelf.Request r, String id) async {
    final n = await globalContainer.read(noteStoreProvider).get(id);
    return n == null ? _fail(404, 'no such note') : _json(noteJson(n, full: true));
  }

  Future<shelf.Response> _noteAudio(shelf.Request r, String id) async {
    final store = globalContainer.read(noteStoreProvider);
    if (await store.get(id) == null) return _fail(404, 'no such note');
    final frames = await store.frames(id);
    if (frames == null) return _fail(404, 'the recording is gone');
    try {
      return shelf.Response.ok(await RingNotes.wavOf(frames),
          headers: {'Content-Type': 'audio/wav', 'Cache-Control': 'private, max-age=3600'});
    } catch (e) {
      return _fail(500, 'could not decode: $e');
    }
  }

  Future<shelf.Response> _retry(shelf.Request r, String id) async {
    if (!await globalContainer.read(noteStoreProvider).requeue(id)) {
      return _fail(404, 'nothing to retry');
    }
    unawaited(globalContainer.read(ringNotesProvider).pipeline.run());
    return _ok();
  }

  Future<shelf.Response> _deleteNote(shelf.Request r, String id) async {
    final ok = await globalContainer.read(noteStoreProvider).delete(id);
    if (ok) debugPrint('[PORTAL] deleted note $id');
    return ok ? _ok() : _fail(404, 'no such note');
  }

  Future<shelf.Response> _deleteSilent(shelf.Request r) async {
    final store = globalContainer.read(noteStoreProvider);
    var deleted = 0;
    for (final n in await store.all(withSilent: true)) {
      if (n.silent && await store.delete(n.id)) deleted++;
    }
    debugPrint('[PORTAL] deleted $deleted recording(s) with no speech');
    return _ok({'deleted': deleted});
  }

  // ------------------------------------------------------------- health

  Future<shelf.Response> _healthReport(shelf.Request r) async {
    final q = r.url.queryParameters;
    final period = ReportPeriod.values
        .firstWhere((p) => p.name == q['period'], orElse: () => ReportPeriod.week);
    final anchor = DateTime.tryParse(q['anchor'] ?? '') ?? DateTime.now();
    final store = globalContainer.read(ringServiceProvider).store;
    final report = await store.report(period, anchor);
    final days = period == ReportPeriod.year
        ? const <DaySummary>[]
        : await store.between(report.total.from, report.total.to);
    return _json({
      ...report.toJson(),
      'days': [for (final d in days) d.toJson()],
    });
  }

  // ------------------------------------------------------ conversations

  Future<shelf.Response> _conversationDays(shelf.Request r) async {
    final limit = int.tryParse(r.url.queryParameters['limit'] ?? '') ?? 30;
    final days = await globalContainer.read(conversationStoreProvider).days(limit: limit.clamp(1, 365));
    return _json({
      'days': [
        for (final d in days)
          {'day': d.day, 'conversations': d.conversations, 'turns': d.turns},
      ],
    });
  }

  Future<shelf.Response> _conversations(shelf.Request r) async {
    final day = DateTime.tryParse(r.url.queryParameters['day'] ?? '') ?? DateTime.now();
    final list = await globalContainer.read(conversationStoreProvider).on(day);
    return _json({
      'day': dayKey(dayOf(day)),
      'conversations': [for (final c in list) c.toJson()],
    });
  }

  Future<shelf.Response> _conversationSearch(shelf.Request r) async {
    final hits = await globalContainer
        .read(conversationStoreProvider)
        .search(r.url.queryParameters['q'] ?? '');
    return _json({
      'results': [
        for (final h in hits)
          {
            'day': h.day,
            'conversationId': h.conversation.id,
            't': h.said.at.toIso8601String(),
            'role': h.said.role,
            'text': h.said.text,
          },
      ],
    });
  }

  // -------------------------------------------------------------- calls

  static Map<String, Object?> callerJson(CallerThread t) => {
        'key': t.key,
        'display': t.display,
        'contactName': t.contactName,
        'calls': [
          for (final c in t.calls.reversed)
            {
              'at': c.at.toIso8601String(),
              'seconds': c.seconds,
              'summary': c.summary,
              'commitments': c.commitments,
              'actionItems': c.actionItems,
              'callerAsserted': c.callerAsserted,
              'unresolved': c.unresolved,
              'abrupt': c.abrupt,
              'callbackRequested': c.callbackRequested,
            },
        ],
      };

  Future<shelf.Response> _calls(shelf.Request r) async {
    final history = globalContainer.read(callHistoryProvider);
    await history.load();
    return _json({
      'callers': [for (final t in history.threads) callerJson(t)],
    });
  }

  // ------------------------------------------------------------- memory

  static Map<String, Object?> factJson(Fact f) => {
        'id': f.id,
        'text': f.text,
        'subject': f.subject,
        'subjectLabel': f.subjectLabel,
        'trust': f.trust.name,
        'source': f.source,
        'at': f.at.toIso8601String(),
      };

  Future<MemoryStore> _loadedMemory() async {
    final m = globalContainer.read(memoryStoreProvider);
    await m.load();
    return m;
  }

  Future<shelf.Response> _memory(shelf.Request r) async =>
      _json({'facts': [for (final f in (await _loadedMemory()).facts) factJson(f)]});

  /// Written as the wearer's own: the portal is signed in as them.
  Future<shelf.Response> _remember(shelf.Request r) async {
    final Map body;
    try {
      body = jsonDecode(await r.readAsString()) as Map;
    } catch (_) {
      return _fail(400, 'expected {"text":"…"}');
    }
    final text = '${body['text'] ?? ''}'.trim();
    if (text.isEmpty) return _fail(400, 'Nothing to remember');
    final f = await (await _loadedMemory()).remember(text, about: '${body['about'] ?? ''}'.trim());
    return _ok({'fact': factJson(f)});
  }

  Future<shelf.Response> _confirm(shelf.Request r, String id) async {
    final m = await _loadedMemory();
    final f = m.facts.where((f) => f.id == id).firstOrNull;
    if (f == null) return _fail(404, 'no such fact');
    // Confirming a fact already known would rewrite its provenance.
    if (f.trust == Trust.claimed) await m.resolve(id, keep: true);
    return _ok();
  }

  Future<shelf.Response> _forget(shelf.Request r, String id) async =>
      await (await _loadedMemory()).resolve(id, keep: false)
          ? _ok()
          : _fail(404, 'no such fact');

  // ------------------------------------------------------------- mascot

  shelf.Response _avatarGet(shelf.Request r) => _json({
        'mascot': globalContainer.read(mascotProvider).name,
        'params': globalContainer.read(liveAvatarParamsProvider).toJson(),
        ...avatarSpecsJson(),
      });

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Every design setting as `watch_avatar` describes it, for the portal to
  /// build its controls from — so the page never has to be kept in step with
  /// the module. The character is the Mascot setting, so it is left out; and
  /// the clock's words are the watch face's, where the app draws the time.
  static Map<String, Object?> avatarSpecsJson() => {
        'groups': [for (final g in kParamGroups) if (g != 'Character' || kParamSpecs.any((s) => s.group == g && s.key != 'character')) g],
        'specs': [
          for (final s in kParamSpecs)
            if (s.key != 'character')
              {
                'key': s.key,
                'label': s.label,
                'group': s.group,
                'kind': s.kind.name,
                'help': switch (s.key) {
                  'clock' => 'Show the time on the watch face. Its font, size and place are under Watch face.',
                  'clock24' => 'Off: 12-hour time with AM/PM on the watch face.',
                  _ => s.help,
                },
                'min': s.min,
                'max': s.max,
                'step': s.step,
                'unit': s.unit,
                'choices': [for (final c in s.choices) {'value': c.value.name, 'label': c.label}],
                'bloub': s.bloub,
                'fox': s.fox,
              },
        ],
        'palettes': [
          for (final p in kPalettes)
            {'name': p.name, 'bg': _hex(p.bg), 'body': _hex(p.body), 'eye': _hex(p.eye), 'muzzle': _hex(p.muzzle)},
        ],
      };

  /// [changes] — setting key to value, in the web tool's JSON form — applied
  /// to [p]. Unknown keys and empty values are skipped rather than refused, so
  /// an older page never breaks a newer device.
  static AvatarParams applyAvatarChanges(AvatarParams p, Map changes) {
    var q = p;
    for (final e in changes.entries) {
      final key = '${e.key}';
      final value = e.value;
      if (value == null || paramSpec(key) == null) continue;
      if (key == 'character') {
        final c = Character.values.where((c) => c.name == value).firstOrNull;
        if (c != null) q = q.switchCharacter(c);
      } else {
        q = q.withValue(key, value as Object);
      }
    }
    return q;
  }

  /// A design from the web tool's "Settings for the app" export —
  /// `{"params": {…}}` — or `{"reset": true}` for the character's default. A
  /// design names its own character, and a live mascot follows it.
  Future<shelf.Response> _avatarSet(shelf.Request r) async {
    const expected = 'expected {"changes":{…}}, {"palette":n}, {"params":{…}} or {"reset":true}';
    final Map body;
    try {
      body = jsonDecode(await r.readAsString()) as Map;
    } catch (_) {
      return _fail(400, expected);
    }
    final c = globalContainer;
    final mascot = c.read(mascotProvider);
    final AvatarParams p;
    if (body['reset'] == true) {
      p = mascot == Mascot.fox ? AvatarParams.fox : const AvatarParams();
    } else if (body['changes'] is Map) {
      // One or a few settings, as the wearer moves a control: applied to what
      // is on the device now, so it changes there at once.
      p = applyAvatarChanges(c.read(liveAvatarParamsProvider), body['changes'] as Map);
    } else if (body['palette'] is num) {
      final i = (body['palette'] as num).toInt();
      if (i < 0 || i >= kPalettes.length) return _fail(400, 'no such palette');
      p = kPalettes[i].applyTo(c.read(liveAvatarParamsProvider));
    } else if (body['params'] is Map) {
      final j = Map<String, Object?>.from(body['params'] as Map);
      // fromJson takes anything, falling back key by key; a file with none of
      // the tool's keys is not a design at all.
      if (!j.containsKey('body') && !j.containsKey('character')) {
        return _fail(400, 'That file is not an avatar design');
      }
      p = AvatarParams.fromJson(j);
    } else {
      return _fail(400, expected);
    }
    final prefs = await SharedPreferences.getInstance();
    c.read(avatarParamsProvider.notifier).state = p;
    await prefs.setString('avatar_params', jsonEncode(p.toJson()));
    final want = p.character == Character.fox ? Mascot.fox : Mascot.bloub;
    if (want != mascot) {
      c.read(mascotProvider.notifier).state = want;
      await prefs.setString('mascot', want.name);
    }
    if (body['changes'] == null) {
      debugPrint('[PORTAL] mascot design ${body['reset'] == true ? 'reset' : 'loaded'}'
          ' (${p.character.name})');
    }
    return _ok({
      'mascot': c.read(mascotProvider).name,
      'params': c.read(liveAvatarParamsProvider).toJson(),
    });
  }

  // ------------------------------------------------------------- system

  shelf.Response _options(shelf.Request r) => _json({
        'models': [
          for (final m in AppConstants.geminiModels)
            if (m.value != 'other') {'value': m.value, 'label': m.label},
        ],
        'voices': [
          for (final v in AppConstants.geminiVoices) {'name': v.name, 'style': v.style},
        ],
        'mascots': [
          for (final m in Mascot.values) {'value': m.name, 'label': m.label},
        ],
      });

  shelf.Response _stop(shelf.Request r) {
    debugPrint('[PORTAL] turned off from the browser');
    // After the answer is on its way — stopping closes every socket.
    Timer(const Duration(milliseconds: 300), () => unawaited(stop()));
    return _ok();
  }

  // -------------------------------------------------------------- setup

  /// First-time setup's state: what is filled in and what Android has
  /// granted. The Hub polls it while the wearer answers prompts on the device.
  Future<shelf.Response> _setup(shelf.Request r) async {
    final c = globalContainer;
    final granted = await c.read(deviceSetupProvider).check();
    return _json(DeviceSetup.json(
      done: c.read(setupDoneProvider),
      hasKey: c.read(geminiApiKeyProvider).trim().isNotEmpty,
      profile: c.read(userProfileProvider),
      mascot: c.read(mascotProvider).name,
      name: c.read(assistantNameProvider),
      ringPaired: c.read(ringServiceProvider).paired,
      granted: granted,
      keepsAccessibility: c.read(deviceSetupProvider).keepsAccessibility,
    ));
  }

  /// `{"id":"camera"}` — puts Android's prompt or Settings screen for it on
  /// the device, for the wearer to answer there.
  Future<shelf.Response> _setupAsk(shelf.Request r) async {
    final Map body;
    try {
      body = jsonDecode(await r.readAsString()) as Map;
    } catch (_) {
      return _fail(400, 'expected {"id":"…"}');
    }
    final p = SetupPermission.byName('${body['id']}');
    if (p == null) return _fail(400, 'unknown permission ${body['id']}');
    // Not awaited: a prompt stays open until the wearer answers it on the
    // device, and the Hub finds out by polling.
    unawaited(globalContainer.read(deviceSetupProvider).ask(p));
    return _ok({'askedBy': p.askedBy.name});
  }

  /// Finds and pairs the smart ring, as Settings → Smart Ring does.
  Future<shelf.Response> _setupRing(shelf.Request r) async {
    final ring = globalContainer.read(ringServiceProvider);
    final result = await ring.findAndPair();
    return _ok({'paired': ring.paired, 'result': result});
  }

  /// Setup is finished: the device leaves the QR code for its watch face.
  Future<shelf.Response> _setupDone(shelf.Request r) async {
    final c = globalContainer;
    c.read(setupDoneProvider.notifier).state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_done', true);
    debugPrint('[SETUP] finished from the FOX-1 Hub');
    return _ok();
  }

  // ------------------------------------------------------------- backup

  /// `?keys=1` puts the API keys and tokens in too. Downloads as a zip.
  Future<shelf.Response> _backup(shelf.Request r) async {
    final keys = r.url.queryParameters['keys'] == '1';
    try {
      final b = await globalContainer.read(backupServiceProvider).export(includeKeys: keys);
      return shelf.Response.ok(b.bytes, headers: {
        'Content-Type': 'application/zip',
        'Content-Disposition': 'attachment; filename="${b.name}"',
        'Cache-Control': 'no-store',
      });
    } catch (e) {
      debugPrint('[BACKUP] export failed: $e');
      return _fail(500, 'Could not make the backup: $e');
    }
  }

  static const _maxRestore = 512 * 1024 * 1024;

  /// The body is the backup zip itself. Answers what came across, then the
  /// app restarts so every store loads it.
  Future<shelf.Response> _restore(shelf.Request r) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in r.read()) {
      buf.add(chunk);
      if (buf.length > _maxRestore) return _fail(413, 'That backup is too big');
    }
    if (buf.isEmpty) return _fail(400, 'Choose a backup file');
    try {
      final summary = await globalContainer.read(backupServiceProvider).restore(buf.takeBytes());
      // After the answer has left.
      Timer(const Duration(seconds: 1), () => unawaited(SystemActionsService.restartApp()));
      return _ok({'restored': summary});
    } on FormatException catch (e) {
      return _fail(400, e.message);
    } catch (e) {
      debugPrint('[BACKUP] restore failed: $e');
      return _fail(500, 'Could not restore: $e');
    }
  }

  // ---------------------------------------------------- developer: cost

  /// Developer mode only. `{"text":"…"}` runs a typed task in a fresh
  /// conversation, mic off, and keeps its screen reads — for measuring what a
  /// task costs (`/api/dev/usage`).
  Future<shelf.Response> _devTask(shelf.Request r) async {
    final c = globalContainer;
    if (!c.read(developerModeProvider)) return _fail(403, 'developer mode is off');
    final Map body;
    try {
      body = jsonDecode(await r.readAsString()) as Map;
    } catch (_) {
      return _fail(400, 'expected {"text":"…"}');
    }
    final text = '${body['text'] ?? ''}'.trim();
    if (text.isEmpty) return _fail(400, 'expected {"text":"…"}');
    final session = await c.read(aiSessionManagerProvider).ensureSession();
    if (session == null) return _fail(409, 'no API key');
    ScreenCapture.start();
    await session.runTypedTask(text);
    return _ok();
  }

  /// Developer mode only: the screen as `get_screen` would give it to the
  /// model — read on the device by the accessibility service, no Gemini call.
  /// For measuring screen sizes without spending anything.
  Future<shelf.Response> _devScreen(shelf.Request r) async {
    if (!globalContainer.read(developerModeProvider)) return _fail(403, 'developer mode is off');
    final svc = ScreenAutomationService();
    if (r.url.queryParameters['format'] == 'compact') {
      return _json({'compact': (await svc.getScreen(keep: false))['screen']});
    }
    // The raw tree the model used to get, for comparison.
    return _json(await svc.getScreenTree());
  }

  /// The screen tools the developer endpoint may run.
  static const _devScreenTools = {
    'get_screen', 'tap', 'scroll', 'type_text', 'press_back', 'press_home', 'launch_app',
  };

  /// Developer mode only: `{"name":"tap","args":{"node_id":3}}` runs one
  /// screen tool exactly as the model would, on the device, with no Gemini
  /// call — for checking screen automation for free.
  Future<shelf.Response> _devScreenTool(shelf.Request r) async {
    if (!globalContainer.read(developerModeProvider)) return _fail(403, 'developer mode is off');
    final Map body;
    try {
      body = jsonDecode(await r.readAsString()) as Map;
    } catch (_) {
      return _fail(400, 'expected {"name":"…","args":{…}}');
    }
    final name = '${body['name'] ?? ''}';
    if (!_devScreenTools.contains(name)) return _fail(400, 'not a screen tool: $name');
    final args = body['args'] is Map ? Map<String, dynamic>.from(body['args'] as Map) : <String, dynamic>{};
    return _json(await NativeToolsBridge().handleToolCall(name, args));
  }

  /// What the current conversation's turns cost, from Google's counts, and
  /// the screen reads kept since the last `/api/dev/task`.
  Future<shelf.Response> _devUsage(shelf.Request r) async {
    final c = globalContainer;
    if (!c.read(developerModeProvider)) return _fail(403, 'developer mode is off');
    final session = c.read(aiSessionManagerProvider).session;
    final u = session?.gemini.usage;
    return _json({
      'turns': [for (final s in u?.samples ?? const []) s.toJson(u!.prices)],
      'totalUsd': u?.totalUsd ?? 0,
      'screens': ScreenCapture.captured,
    });
  }

  // ------------------------------------------------------------ helpers

  static shelf.Response _json(Object body,
          {int status = 200, Map<String, String> headers = const {}}) =>
      shelf.Response(status,
          body: jsonEncode(body),
          headers: {'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers});

  static shelf.Response _ok(
          [Map<String, Object?> extra = const {}, Map<String, String> headers = const {}]) =>
      _json({'ok': true, ...extra}, headers: headers);

  static shelf.Response _fail(int status, String error) =>
      _json({'ok': false, 'error': error}, status: status);
}
