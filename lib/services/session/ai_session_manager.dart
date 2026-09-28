import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../call/call_briefing.dart' show nameLine;
import '../../config/constants.dart';
import '../../providers/providers.dart';
import '../agent/agent_bridge.dart';
import '../agent/agent_relay_bridge.dart';
import '../agent/native_tools_bridge.dart';
import '../audio/audio_manager.dart';
import '../camera/watch_camera_service.dart';
import '../gemini/gemini_live_client.dart';
import '../memory/episodes.dart';
import '../openclaw/openclaw_bridge.dart';
import '../platform/installed_apps_service.dart';
import 'ai_session.dart';
import '../conversation/conversation_store.dart';
import '../platform/phone_service.dart';
import '../notes/note_tools.dart';
import '../ring/ring_tools.dart';
import '../../widgets/mascot.dart' show MascotMood;

/// Owns the one long-lived [AISession].
///
/// The session used to be created and destroyed by the agent screen, so every
/// visit paid for a fresh WebSocket, a fresh Gemini context and an installed-apps
/// scan — and lost the previous conversation. Holding it here means screen
/// changes only move it between power tiers.
class AISessionManager {
  final Ref _ref;

  AISession? _session;
  String? _builtSignature;
  Future<AISession?>? _building;

  AISessionManager(this._ref);

  AISession? get session => _session;

  /// Settings that require a rebuild rather than a reconnect. Voice, model and
  /// prompt are baked into the Gemini setup message, so changing them means a
  /// new session.
  String _currentSignature() {
    final r = _ref;
    return [
      r.read(geminiApiKeyProvider),
      r.read(geminiModelProvider),
      r.read(geminiVoiceProvider),
      r.read(userSystemPromptProvider),
      // Developer mode decides which prompt is sent (see _systemPrompt).
      r.read(developerModeProvider),
      r.read(userProfileProvider),
      r.read(agentProviderTypeProvider).name,
      r.read(openClawHostProvider),
      r.read(openClawPortProvider),
      r.read(openClawTokenProvider),
      r.read(agentRelayHostProvider),
      r.read(agentRelayPortProvider),
      r.read(agentRelayTokenProvider),
      // Pairing or forgetting a ring adds or removes the health tools, and
      // tool declarations are baked into the setup message too.
      r.read(ringServiceProvider).paired,
    ].join('|');
  }

  CameraConfig _currentCameraConfig() => CameraConfig(
        rotation: _ref.read(cameraRotationProvider),
        quality: _ref.read(cameraQualityProvider),
        resolution: _ref.read(cameraResolutionProvider),
        mirror: _ref.read(cameraMirrorProvider),
        aspectRatio: _ref.read(cameraAspectRatioProvider),
      );

  /// Builds the session if needed, or returns the existing one. Rebuilds when
  /// settings that are baked into the Gemini handshake have changed.
  Future<AISession?> ensureSession() {
    return _building ??= _ensureSession().whenComplete(() => _building = null);
  }

  Future<AISession?> _ensureSession() async {
    final apiKey = _ref.read(geminiApiKeyProvider);
    if (apiKey.isEmpty) return null;

    final signature = _currentSignature();
    if (_session != null && signature == _builtSignature) {
      // Camera settings are read per-capture, so they never force a rebuild.
      _session!.cameraConfig = _currentCameraConfig();
      return _session;
    }

    if (_session != null) {
      debugPrint('[SESSION_MGR] settings changed — rebuilding session');
      await _disposeSession();
    }

    AgentBridge? agentBridge;
    switch (_ref.read(agentProviderTypeProvider)) {
      case AgentProviderType.openClaw:
        final host = _ref.read(openClawHostProvider);
        final token = _ref.read(openClawTokenProvider);
        if (host.isNotEmpty && token.isNotEmpty) {
          agentBridge = OpenClawBridge(
            host: host,
            port: _ref.read(openClawPortProvider),
            gatewayToken: token,
          );
        }
      case AgentProviderType.agentRelay:
        final host = _ref.read(agentRelayHostProvider);
        final token = _ref.read(agentRelayTokenProvider);
        if (host.isNotEmpty && token.isNotEmpty) {
          agentBridge = AgentRelayBridge(
            host: host,
            port: _ref.read(agentRelayPortProvider),
            token: token,
          );
        }
    }

    // Shared with the call agent — same file, very different doors. Loaded
    // before the bridge so the first recall of a session is not empty.
    // Same instance the call agent uses, not a copy. Building one here broke
    // the review flow outright: this copy was loaded at session start, so
    // claims the call agent filed during a call were invisible to
    // `review_claims` afterwards — and the two lists overwrote each other.
    final memory = _ref.read(memoryStoreProvider);
    await memory.load();
    final ringService = _ref.read(ringServiceProvider);
    final noteStore = _ref.read(noteStoreProvider);
    final episodes = _ref.read(episodeStoreProvider);
    final conversations = _ref.read(conversationStoreProvider);
    // Notes outlive a forgotten ring, so their tools stay while any exist.
    final hasNotes = !await noteStore.isEmpty;
    final nativeBridge = NativeToolsBridge(
      innerBridge: agentBridge,
      // Health tools only while a ring is paired (see _currentSignature).
      ring: ringService.paired ? RingTools.of(ringService) : null,
      notes: ringService.paired || hasNotes ? NoteTools(noteStore) : null,
      episodes: EpisodeTools(episodes, conversations),
      // Screen work goes to the helper, out of the voice conversation.
      helperKey: () => _ref.read(geminiApiKeyProvider),
      onCost: (source, usd) {
        final meter = _session?.gemini.usage;
        if (meter == null) return;
        meter.addExtra(source, usd);
        debugPrint('[COST] $source: \$${usd.toStringAsFixed(4)} · session ${meter.totalLine}');
      },
      portal: (on) => _ref.read(portalServiceProvider).toolCall(on),
      memory: memory,
      dialed: _ref.read(dialedNumbersProvider),
      // Only offered when the call agent is actually on duty — a dispatch to
      // an agent that is not running would place a call nobody is on.
      dispatchCall: (number, task) async {
        final o = _ref.read(callOrchestratorProvider);
        final why = await o.dispatch(number: number, task: task);
        if (why != null) return why;
        final r = await PhoneService().makeCall(number);
        return r['success'] == true ? null : r['error']?.toString();
      },
    );

    // Done once per session rather than on every screen entry.
    final apps = await InstalledAppsService().getAppNames();
    final appNames = apps.map((a) => a.name).join(', ');

    final name = _ref.read(assistantNameProvider);
    final persona = GeminiConfig.withName(_ref.read(aiPersonaProvider).trim(), name);
    // The saved prompt only in developer mode; otherwise the built-in one.
    final saved = _ref.read(userSystemPromptProvider).trim();
    final basePrompt = _ref.read(developerModeProvider) && saved.isNotEmpty ? saved : GeminiConfig.defaultPrompt.trim();
    final userProfile = _ref.read(userProfileProvider).trim();
    final promptParts = <String>[
      // Its name first, whatever the persona says — the wearer may have
      // written their own without {name}. Then who it is, then what it should
      // do. The call agent gets the same first part and none of the last.
      nameLine(name),
      if (persona.isNotEmpty) persona,
      GeminiConfig.withName(basePrompt.isNotEmpty ? basePrompt : GeminiConfig.defaultPrompt, name),
    ];
    if (userProfile.isNotEmpty) {
      promptParts.add('\n[User Profile]\n$userProfile');
    }
    if (appNames.isNotEmpty) {
      promptParts.add('\n[Installed Apps]\n$appNames');
    }

    // Today's earlier conversations, as key points. Not the conversations
    // themselves: an ended one is not resumed (see _conversationEnded).
    await _rememberEnded(within: const Duration(seconds: 4));
    final earlier = episodeBriefing(await episodes.on(DateTime.now()));
    if (earlier.isNotEmpty) promptParts.add('\n$earlier');

    // Anything a call left for the wearer that they have not heard. Told to
    // the agent as an instruction so it leads with the message rather than
    // waiting to be asked — the wearer should not have to know to ask.
    final pending = _ref.read(pendingReportsProvider);
    await pending.load();
    if (!pending.isEmpty) {
      promptParts.add('\n${pending.briefing(wearer: userProfile)}');
    }

    final tools = nativeBridge.toolDeclarations;
    _logSetupSize(promptParts, persona, basePrompt, userProfile, appNames, earlier, tools);

    final selectedModel = _ref.read(geminiModelProvider);
    final modelId = AppConstants.supportedModel(selectedModel);

    final session = AISession(
      audioManager: AudioManager(),
      cameraService: WatchCameraService(),
      gemini: GeminiLiveClient(
        config: GeminiConfig(
          apiKey: apiKey,
          model: modelId,
          voice: _ref.read(geminiVoiceProvider),
          systemPrompt: promptParts.join('\n'),
          toolDeclarations: tools,
        ),
      ),
      agentBridge: nativeBridge,
      cameraConfig: _currentCameraConfig(),
      onRequestHome: () =>
          _ref.read(goHomeSignalProvider.notifier).state++,
      idleLimit: () => Duration(minutes: _ref.read(standDownAfterProvider)),
      onConversationEnded: () => unawaited(_conversationEnded()),
    );

    // The bridge is built first so its declarations reach the setup message;
    // the camera it drives belongs to the session, wired back here.
    nativeBridge.vision = session;

    _session = session;
    // A message is only delivered once somebody actually says something back.
    // Until then it stays queued — announcing into an empty room and calling it
    // done is exactly the failure this avoids.
    final briefer = _ref.read(wearerBrieferProvider);
    briefer.reset();
    final dialed = _ref.read(dialedNumbersProvider);
    session.transcript.listen((e) {
      if (e.role != TranscriptRole.system && e.text.trim().isNotEmpty) {
        _conversationStart ??= e.timestamp;
      }
      // Kept for the portal's conversation history.
      conversations.addTranscript(e.role.name, e.text, e.timestamp);
      if (e.role == TranscriptRole.user && e.text.trim().isNotEmpty) {
        briefer.noteWearerSpoke();
        // New notes count as heard once the wearer has said something after
        // she was told about them — not when she was told.
        if (_toldNotes.isNotEmpty) {
          final told = _toldNotes;
          _toldNotes = const [];
          unawaited(noteStore.markAnnounced(told));
        }
        // And it lifts the block on calling that person again. The runaway
        // loop this guards against is defined by the wearer NOT speaking — the
        // agent read its own finished errand and re-dispatched it, four times,
        // the last 1.6 s after the report landed. A fresh instruction is the
        // signal that the next call is a new errand rather than that one
        // again; without this, "also ask him to bring the GTA disc" was
        // refused as a duplicate of "ask him to bring the controller".
        dialed.allowRedial();
      }
    });

    _wireMascot(session);

    _builtSignature = signature;
    return session;
  }

  /// When the conversation in progress began — its first words.
  DateTime? _conversationStart;

  /// Episodes being written, so a build can wait for today's points.
  Future<void>? _remembering;
  bool _caughtUp = false;

  /// A quiet conversation has ended. It is remembered as key points, and the
  /// session is let go, so the next wake builds a fresh one briefed with
  /// them rather than resuming the whole conversation — which Gemini then
  /// re-bills on every turn.
  Future<void> _conversationEnded() async {
    // Like any stand-down, back to the watch face. Only the launcher's own
    // page moves: an app the agent opened stays in front.
    _ref.read(goHomeSignalProvider.notifier).state++;
    // Kept past the session, so remembering it counts in its total.
    final meter = _session?.gemini.usage;
    final start = _conversationStart;
    _conversationStart = null;
    await _disposeSession();
    if (start != null) {
      final conversations = _ref.read(conversationStoreProvider);
      await conversations.flush();
      final said = await _saidSince(start);
      final asked = [
        for (final s in said)
          if (s.role == 'user') s.text.length > 120 ? '${s.text.substring(0, 120)}…' : s.text,
      ].take(3).toList();
      if (asked.isNotEmpty) {
        await _ref.read(episodeStoreProvider).save(Episode(start: start, end: said.last.at, asked: asked));
      }
    }
    await _rememberEnded();
    final written = start == null ? null : _memoryUsd.remove(start.toIso8601String());
    if (meter != null && start != null) {
      if (written != null) meter.addExtra('key points', written);
      if (meter.totalUsd > 0) {
        final end = DateTime.now();
        String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
        debugPrint('[COST] conversation ${hm(start)}–${hm(end)}: ${meter.totalLine}');
      }
    }
  }

  /// What writing each episode's key points cost, by episode id, until its
  /// conversation's total is logged.
  final Map<String, double> _memoryUsd = {};

  Future<List<Said>> _saidSince(DateTime start, [DateTime? end]) async {
    final conversations = _ref.read(conversationStoreProvider);
    final days = {ConversationStore.dayKey(start), ConversationStore.dayKey(end ?? DateTime.now())};
    final out = <Said>[];
    for (final d in days) {
      out.addAll(await conversations.entriesOn(DateTime.parse(d)));
    }
    return [
      for (final s in out)
        if (!s.at.isBefore(start.subtract(const Duration(seconds: 1))) &&
            (end == null || !s.at.isAfter(end.add(const Duration(seconds: 1)))))
          s,
    ];
  }

  /// Writes every episode still waiting for its points. [within] caps how
  /// long a caller waits; the writing carries on regardless.
  Future<void> _rememberEnded({Duration? within}) async {
    final run = _remembering ??= _writeEpisodes().whenComplete(() => _remembering = null);
    if (within == null) return run;
    try {
      await run.timeout(within);
    } catch (_) {}
  }

  Future<void> _writeEpisodes() async {
    final store = _ref.read(episodeStoreProvider);
    if (!_caughtUp) {
      _caughtUp = true;
      await _catchUp(store);
    }
    final writer = EpisodeWriter(apiKey: () => _ref.read(geminiApiKeyProvider));
    final name = _ref.read(assistantNameProvider);
    for (final e in await store.pending()) {
      final said = await _saidSince(e.start, e.end);
      if (said.isEmpty) continue;
      try {
        final usd = await writer.write(e, said, name: name);
        _memoryUsd[e.id] = usd;
        debugPrint('[MEMORY] remembered ${e.when}: ${e.gist} (${e.points.length} points)');
        debugPrint('[COST] key points for ${e.when}: \$${usd.toStringAsFixed(4)}');
      } on EpisodeWriteError catch (err) {
        if (!err.network) e.strikes++;
        debugPrint('[MEMORY] could not remember ${e.when} yet: $err');
        if (err.network) {
          await store.save(e);
          return; // Offline: the rest would fail the same way.
        }
      }
      await store.save(e);
    }
  }

  /// Conversations from before a restart that ended without being
  /// remembered become episodes too — memory is never lost to a crash.
  Future<void> _catchUp(EpisodeStore store) async {
    final conversations = _ref.read(conversationStoreProvider);
    final known = await store.recent();
    final now = DateTime.now();
    for (final day in [now.subtract(const Duration(days: 1)), now]) {
      for (final c in await conversations.on(day)) {
        if (now.difference(c.end) < const Duration(minutes: 1)) continue;
        if (known.any((e) => !e.start.isAfter(c.end) && !e.end.isBefore(c.start))) continue;
        final asked = [for (final s in c.entries) if (s.role == 'user') s.text].take(3).toList();
        if (asked.isEmpty) continue;
        await store.save(Episode(start: c.start, end: c.end, asked: asked));
      }
    }
  }

  /// What the fixed part of every turn is made of — re-sent, and billed, on
  /// every step of every turn. About four characters to a token.
  void _logSetupSize(List<String> prompt, String persona, String system, String profile,
      String apps, String earlier, List<Map<String, dynamic>> tools) {
    int t(int chars) => (chars / 4).round();
    final promptChars = prompt.join('\n').length;
    final toolChars = jsonEncode(tools).length;
    final biggest = [...tools]..sort((a, b) => jsonEncode(b).length.compareTo(jsonEncode(a).length));
    debugPrint('[SESSION_MGR] setup ≈ ${t(promptChars + toolChars)} tokens: '
        'prompt ≈ ${t(promptChars)} (persona ${t(persona.length)} · system ${t(system.length)} · '
        'profile ${t(profile.length)} · apps ${t(apps.length)} · earlier today ${t(earlier.length)}) · '
        '${tools.length} tools ≈ ${t(toolChars)} (largest: '
        '${biggest.take(5).map((d) => '${d['name']} ${t(jsonEncode(d).length)}').join(', ')})');
  }

  /// Keeps [mascotStateProvider] on what the session is actually doing, so
  /// every screen showing the mascot says the same thing. It lives here and
  /// not on the AI screen because the ring starts conversations hands-free,
  /// with the watch face in front of the wearer.
  ///
  /// Nothing is cancelled: these streams close with the session that owns
  /// them, as the transcript listener above does.
  void _wireMascot(AISession session) {
    void mood(MascotMood s) =>
        _ref.read(mascotStateProvider.notifier).state = s;

    session.sessionState.listen((s) => mood(switch (s) {
          AISessionState.starting => MascotMood.thinking,
          AISessionState.active => MascotMood.listening,
          AISessionState.onCall => MascotMood.speaking,
          AISessionState.error => MascotMood.confused,
          AISessionState.warm || AISessionState.stopped => MascotMood.idle,
        }));
    session.gemini.audioResponses.listen((_) => mood(MascotMood.speaking));
    session.gemini.speechStarted.listen((_) => mood(MascotMood.listening));
    // Extended thinking keeps working after it stops talking.
    session.gemini.busyChanges.listen((busy) {
      if (busy) {
        if (_ref.read(mascotStateProvider) != MascotMood.speaking) {
          mood(MascotMood.thinking);
        }
      } else if (session.isListening) {
        mood(MascotMood.listening);
      }
    });
    session.gemini.turnComplete.listen((_) {
      Future.delayed(AppConstants.listeningRestoreDelay, () {
        if (session.isListening && !session.gemini.busy) {
          mood(MascotMood.listening);
        }
      });
    });
  }

  /// Full readiness — socket up, mic live, previous conversation resumed.
  Future<AISession?> wake() async {
    final session = await ensureSession();
    if (session == null) return null;
    await session.wake();
    unawaited(_announceNotes(session));
    return session;
  }

  /// Notes handed to the agent and not yet heard by the wearer.
  List<String> _toldNotes = const [];

  /// Tells the agent about notes transcribed since the wearer last heard of
  /// any. Once per set: a second wake before they have spoken does not tell
  /// it again.
  Future<void> _announceNotes(AISession session) async {
    final fresh = await _ref.read(noteStoreProvider).unannounced();
    if (fresh.isEmpty || fresh.every((n) => _toldNotes.contains(n.id))) return;
    session.tell(NoteTools.announcement(fresh));
    _toldNotes = [for (final n in fresh) n.id];
  }

  /// Left the agent screen: camera off, listening continues until the
  /// conversation actually goes quiet.
  Future<void> goWarm() async => _session?.goWarm();

  /// App backgrounded — display timeout, or the agent opened another app.
  /// Keeps a live conversation running; only reclaims power if it was idle.
  Future<void> onBackgrounded() async => _session?.onBackgrounded();

  /// Release everything. The conversation survives in the resumption handle.
  Future<void> goCold() async => _session?.goCold();

  Future<void> _disposeSession() async {
    final session = _session;
    _session = null;
    _builtSignature = null;
    _ref.read(mascotStateProvider.notifier).state = MascotMood.idle;
    if (session == null) return;
    await session.goCold();
    session.dispose();
  }

  void dispose() {
    _disposeSession();
  }
}

/// App-scoped: survives screen changes by design.
final aiSessionManagerProvider = Provider<AISessionManager>((ref) {
  final manager = AISessionManager(ref);
  ref.onDispose(manager.dispose);
  return manager;
});

/// Whether the camera is currently live, for the UI indicator.
final visionActiveProvider = StateProvider<bool>((_) => false);
