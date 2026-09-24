import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';
import '../models/app_info.dart';
import '../services/agent/agent_bridge.dart';
import '../services/platform/installed_apps_service.dart';
import '../services/platform/notification_service.dart';
import '../services/platform/quick_settings_service.dart';
import '../services/call/call_history.dart';
import '../services/memory/memory_store.dart';
import '../services/call/dialed_numbers.dart';
import '../services/call/auto_answer.dart';
import '../services/call/crash_journal.dart';
import '../services/call/call_orchestrator.dart';
import '../services/call/pending_reports.dart';
import '../services/call/wearer_briefer.dart';
import '../services/ring/ring_service.dart';
import '../services/notes/note_store.dart';
import '../services/conversation/conversation_store.dart';
import '../services/backup/backup.dart';
import '../services/setup/device_setup.dart';
import '../services/web/portal_service.dart';
import '../widgets/mascot.dart';
import '../watch_avatar/watch_avatar.dart' show AvatarParams, Character;
import '../services/notes/notes_pipeline.dart';
import '../services/notes/ring_notes.dart';
import '../services/notes/transcriber.dart';
import '../services/audio/audio_manager.dart';
import '../services/platform/system_actions_service.dart';
import '../services/ring/ring_gestures.dart';
import '../services/ring/ring_input.dart';
import '../services/session/ai_session_manager.dart';

// Current screen (for AI session lifecycle)
enum ActiveScreen { home, aiAgent, apps, notifications, controls }
final activeScreenProvider = StateProvider<ActiveScreen>((_) => ActiveScreen.home);

/// Bumped whenever something asks the launcher to return to the watch face —
/// the agent standing down, press_home, or the physical home button. A counter
/// rather than a bool so repeated requests each fire.
final goHomeSignalProvider = StateProvider<int>((_) => 0);

// Platform services
final installedAppsServiceProvider = Provider((_) => InstalledAppsService());
final notificationServiceProvider = Provider((_) => NotificationService());
final quickSettingsServiceProvider = Provider((_) => QuickSettingsService());

// Cached installed apps — fetched once, not on every swipe
final installedAppsProvider = FutureProvider<List<AppInfo>>((ref) async {
  final service = ref.read(installedAppsServiceProvider);
  return service.getInstalledApps();
});

// Settings
final geminiApiKeyProvider = StateProvider<String>((_) => '');
final geminiModelProvider = StateProvider<String>((_) => AppConstants.geminiModel);
final geminiVoiceProvider = StateProvider<String>((_) => 'Kore');
final agentProviderTypeProvider =
    StateProvider<AgentProviderType>((_) => AgentProviderType.openClaw);
final openClawHostProvider = StateProvider<String>((_) => '');
final openClawPortProvider = StateProvider<int>((_) => 18789);
final openClawTokenProvider = StateProvider<String>((_) => '');
final agentRelayHostProvider = StateProvider<String>((_) => '');
final agentRelayPortProvider = StateProvider<int?>((_) => null);
final agentRelayTokenProvider = StateProvider<String>((_) => '');

// Camera settings
final cameraRotationProvider = StateProvider<int>((_) => 90);
final cameraQualityProvider = StateProvider<int>((_) => 70);
final cameraResolutionProvider = StateProvider<String>((_) => 'medium');
final cameraMirrorProvider = StateProvider<bool>((_) => false);
final cameraAspectRatioProvider = StateProvider<String>((_) => 'landscape');

// Shared stores. One instance each, process-wide.
//
// These MUST NOT be constructed per session. Both agents write to the same two
// files, so two instances mean two divergent in-memory lists: the main agent
// could not see claims the call agent had just filed, and whichever saved last
// silently wiped the other's writes.
final memoryStoreProvider = Provider<MemoryStore>((_) => MemoryStore());
final callHistoryProvider = Provider<CallHistory>((_) => CallHistory());

/// Auto-answer. Off by default, deliberately: the device taking the wearer's
/// calls is something they opt into, never something they discover.
final autoAnswerModeProvider =
    StateProvider<AutoAnswerMode>((_) => AutoAnswerMode.off);
final autoAnswerDelayProvider = StateProvider<int>((_) => 6);
final autoAnswerBlockedProvider = StateProvider<String>((_) => '');
final autoAnswerAlwaysProvider = StateProvider<String>((_) => '');

/// Written by the main agent when it dials, read by the call agent when the
/// board reports an outgoing call it has no caller ID for.
final dialedNumbersProvider = Provider<DialedNumbers>((_) => DialedNumbers());

/// What was happening when the process last died. FOX-1 is the HOME
/// launcher, so a kill is followed by a restart within seconds — while the
/// call carries on regardless.
final crashJournalProvider = Provider<CrashJournal>((_) => CrashJournal());

/// Messages from finished calls the wearer has not heard yet.
final pendingReportsProvider = Provider<PendingReports>((_) => PendingReports());

/// The ring as a control for the assistant: hold to talk, double-tap to stand
/// down. Started at boot beside the service.
final ringGesturesProvider = Provider<RingGestures>((ref) {
  final g = RingGestures(
    buttons: ref.read(ringServiceProvider).buttons,
    gestures: RingInput.gestures,
    hold: (holding) async {
      final manager = ref.read(aiSessionManagerProvider);
      final live = manager.session;
      if (!holding) {
        live?.audioManager.setHoldOpen(false);
        unawaited(live?.audioManager.playEarcon(Earcon.done) ?? Future.value());
        return;
      }
      // The press is felt before anything slow happens. Waking her takes a
      // second or two, and until the ready sound the wearer has no way to know
      // whether anything is listening.
      unawaited(SystemActionsService.vibrate(ms: 35, amplitude: 150));
      // With the screen off the CPU sleeps between Bluetooth events. The first
      // cold wake on hardware stalled half-built for 69 s — until the release
      // woke the CPU again — so keep it running through the wake.
      unawaited(SystemActionsService.keepCpuAwake(const Duration(seconds: 20)));
      // Drop whatever she has queued before anything else: Gemini's own
      // interruption arrives a beat later, and until then her buffered
      // speech keeps playing over the wearer.
      final audio = live?.audioManager;
      audio?.interruptPlayback();
      audio?.setHoldOpen(true);
      var s = live;
      try {
        // The socket, not the session's own flag: after a silent close the
        // session used to report itself active with nothing behind it.
        if (s == null ||
            !s.isActive ||
            !s.gemini.isConnected ||
            !s.isListening) {
          s = await manager.wake();
        }
      } catch (e) {
        // Thrown, not null: a wake that timed out used to end here with no
        // buzz at all, and the wearer went on talking to nothing.
        debugPrint('[RING] hold-to-talk: could not wake her — $e');
        _holdFailed(manager.session?.audioManager);
        return;
      }
      if (s == null) {
        debugPrint('[RING] hold-to-talk: nothing woke up');
        _holdFailed(null);
        return;
      }
      s.audioManager.setHoldOpen(true);
      unawaited(s.audioManager.playEarcon(Earcon.ready));
      unawaited(SystemActionsService.vibrate(ms: 70, amplitude: 230));
    },
    standDown: () async => ref.read(aiSessionManagerProvider).session?.standDown(),
    block: RingInput.setBlockExternal,
  );
  ref.onDispose(g.stop);
  return g;
});

/// Nothing is listening: a long buzz, and the low tone if a track is left.
void _holdFailed(AudioManager? audio) {
  unawaited(SystemActionsService.vibrate(ms: 350, amplitude: 255));
  unawaited(audio?.playEarcon(Earcon.failed) ?? Future.value());
}

/// The smart ring: one BLE link for the whole app, and its health history.
/// Started at boot; the Smart Ring screen is a view onto it.
final ringServiceProvider = Provider<RingService>((ref) {
  final s = RingService();
  ref.onDispose(s.dispose);
  return s;
});

/// Voice notes from the ring. One store for the app: the pipeline writes it;
/// The assistant's tools and the web page read it.
final noteStoreProvider = Provider<NoteStore>((ref) {
  final s = NoteStore();
  ref.onDispose(s.dispose);
  return s;
});

/// What was said with the assistant, for the portal's conversation history. The
/// session manager feeds it every transcript entry.
final conversationStoreProvider = Provider<ConversationStore>((ref) {
  final s = ConversationStore();
  ref.onDispose(s.dispose);
  return s;
});

/// Quadruple-tap recordings → transcribed notes, with nobody asking. Started
/// at boot beside the ring service.
final ringNotesProvider = Provider<RingNotes>((ref) {
  final store = ref.read(noteStoreProvider);
  final transcriber = Transcriber(apiKey: () => ref.read(geminiApiKeyProvider));
  final n = RingNotes(
    ring: ref.read(ringServiceProvider),
    store: store,
    pipeline: NotesPipeline(
      store: store,
      transcribe: transcriber.transcribe,
      toWav: RingNotes.wavOf,
      // Usually with the screen off: keep the CPU up through one request.
      keepAwake: () => SystemActionsService.keepCpuAwake(const Duration(seconds: 60)),
      log: (s) => debugPrint('[NOTES] $s'),
    ),
  );
  ref.onDispose(n.dispose);
  return n;
});

/// Whether the call agent is on duty. Off by default — the bridge holds a wake
/// lock and the HFP slot, so it is the wearer's call, not ours.
final callAgentOnDutyProvider = StateProvider<bool>((_) => false);

/// Which board the call agent uses when it goes on duty.
final callAgentDeviceProvider = StateProvider<String>((_) => '');

/// Shows Settings → Developer: the call-bridge playground and the ring test
/// harness. Off by default; tap "FOX-1" at the bottom of Settings
/// seven times. Device-only on purpose — in the web form it would not be hidden.
final developerModeProvider = StateProvider<bool>((_) => false);

/// Gets a finished call's message to the wearer. Defined before the
/// orchestrator because the orchestrator hands its reports here.
final wearerBrieferProvider = Provider<WearerBriefer>((ref) {
  final b = WearerBriefer(
    pending: ref.read(pendingReportsProvider),
    wakeAgent: () => ref.read(aiSessionManagerProvider).wake(),
    isAgentAwake: () => ref.read(aiSessionManagerProvider).session != null,
    // The agent is told the wearer's name rather than a script; it knows how
    // it usually addresses them.
    wearerName: () => ref.read(userProfileProvider),
  );
  ref.onDispose(b.dispose);
  return b;
});

/// The headless call agent. Owned here rather than by a screen: a session that
/// only exists while somebody is looking at it is no use for answering calls.
final callOrchestratorProvider = Provider<CallOrchestrator>((ref) {
  final o = CallOrchestrator(
    history: ref.read(callHistoryProvider),
    memory: ref.read(memoryStoreProvider),
    dialed: ref.read(dialedNumbersProvider),
    journal: ref.read(crashJournalProvider),
    pending: ref.read(wearerBrieferProvider),
  );
  ref.onDispose(o.dispose);
  return o;
});

// Persona + system prompt + profile
//
// Persona is separate from the system prompt because the call agent must see
// one and not the other: it needs a name to introduce itself with, but the
// system prompt is on-device instructions that would mislead it on a call.
/// What the wearer calls the assistant. `{name}` in the prompts becomes this.
final assistantNameProvider = StateProvider<String>((_) => GeminiConfig.defaultAssistantName);
final aiPersonaProvider = StateProvider<String>((_) => GeminiConfig.defaultPersona.trim());
final userSystemPromptProvider = StateProvider<String>((_) => GeminiConfig.defaultPrompt.trim());
final userProfileProvider = StateProvider<String>((_) => '');

/// The only instruction text a caller's session sees.
final callAgentPromptProvider =
    StateProvider<String>((_) => GeminiConfig.defaultCallPrompt.trim());

// Watchface font settings
final watchFontFamilyProvider = StateProvider<String>((_) => 'Rajdhani');
final watchFontWeightProvider = StateProvider<int>((_) => 600);
final watchFontSizeFactorProvider = StateProvider<double>((_) => 0.35);

/// Where the time sits on a live mascot's watch face (Bloub, the fox): the
/// point it is centred on, as a share of the screen — 0 is the left or top
/// edge, 1 the right or bottom.
final watchTimeXProvider = StateProvider<double>((_) => 0.5);
final watchTimeYProvider = StateProvider<double>((_) => 0.74);

/// Which mascot the wearer sees, everywhere in the launcher.
final mascotProvider = StateProvider<Mascot>((_) => Mascot.fallback);

/// The live avatar's design — every setting from the FOX-1 web design tool —
/// saved as that tool's own JSON under `avatar_params`, so a design exported
/// there loads here and the other way round.
final avatarParamsProvider = StateProvider<AvatarParams>((_) => AvatarParams.fox);

/// What is actually drawn: the saved design, as the chosen character.
/// `switchCharacter` swaps in the character's own colours only while they are
/// still the other one's defaults, so hand-picked colours survive a switch.
final liveAvatarParamsProvider = Provider<AvatarParams>((ref) {
  final p = ref.watch(avatarParamsProvider);
  return switch (ref.watch(mascotProvider)) {
    Mascot.bloub => p.switchCharacter(Character.bloub),
    Mascot.fox => p.switchCharacter(Character.fox),
  };
});

/// A saved design, or the default one if there is none or it will not read.
AvatarParams loadAvatarParams(String? raw) {
  if (raw == null || raw.isEmpty) return AvatarParams.fox;
  try {
    final j = jsonDecode(raw);
    if (j is Map) return AvatarParams.fromJson(Map<String, Object?>.from(j));
  } catch (_) {}
  return AvatarParams.fox;
}

/// What the mascot is doing. One value for the whole app, so the watch face
/// and the AI screen show the same thing — a conversation started by holding
/// the ring is visible without opening the AI screen. `AISessionManager`
/// keeps it up to date.
final mascotStateProvider = StateProvider<MascotMood>((_) => MascotMood.idle);

/// The wearer's web portal. Off by default; Controls, Settings and
/// the assistant's `web_portal` tool all go through this.
final portalServiceProvider = Provider<PortalService>((ref) {
  final p = PortalService(ref);
  ref.onDispose(p.dispose);
  return p;
});

/// Whether first-time setup is finished. Until it is, the device shows only
/// the FOX-1 Hub's QR code and PIN (`OnboardingScreen`), and the wearer sets
/// everything up from their phone. Device state under `setup_done`, like the
/// ring pairing — not a user setting.
final setupDoneProvider = StateProvider<bool>((_) => false);

/// Backup and restore (FOX-1 Hub → System).
final backupServiceProvider = Provider<BackupService>((_) => BackupService(app: 'fox1'));

/// Checks and asks for what setup needs from Android.
final deviceSetupProvider = Provider<DeviceSetup>((_) => DeviceSetup());

/// Mirrors of [portalServiceProvider]'s state, for widgets to watch.
final webServerRunningProvider = StateProvider<bool>((_) => false);
final webServerHotspotInfoProvider = StateProvider<Map<String, String>?>((_) => null);

// Load settings from SharedPreferences
final settingsInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  ref.read(geminiApiKeyProvider.notifier).state =
      prefs.getString('gemini_api_key') ?? '';
  ref.read(assistantNameProvider.notifier).state =
      prefs.getString('assistant_name') ?? GeminiConfig.defaultAssistantName;
  ref.read(setupDoneProvider.notifier).state = DeviceSetup.isDone(
      saved: prefs.getBool('setup_done'), apiKey: prefs.getString('gemini_api_key') ?? '');
  // Only the current models are offered. One saved by an older build moves
  // onto the default, and is saved that way.
  final savedModel = prefs.getString('gemini_model');
  final model = AppConstants.supportedModel(savedModel);
  if (savedModel != null && savedModel != model) {
    await prefs.setString('gemini_model', model);
  }
  ref.read(geminiModelProvider.notifier).state = model;
  ref.read(geminiVoiceProvider.notifier).state =
      prefs.getString('gemini_voice') ?? 'Kore';
  ref.read(mascotProvider.notifier).state =
      Mascot.byName(prefs.getString('mascot'));
  ref.read(avatarParamsProvider.notifier).state =
      loadAvatarParams(prefs.getString('avatar_params'));
  ref.read(openClawHostProvider.notifier).state =
      prefs.getString('openclaw_host') ?? '';
  ref.read(openClawPortProvider.notifier).state =
      prefs.getInt('openclaw_port') ?? 18789;
  ref.read(openClawTokenProvider.notifier).state =
      prefs.getString('openclaw_token') ?? '';

  // Agent provider type
  final providerStr = prefs.getString('agent_provider_type') ?? 'openClaw';
  ref.read(agentProviderTypeProvider.notifier).state =
      AgentProviderType.fromString(providerStr);

  // Agent Relay settings
  ref.read(agentRelayHostProvider.notifier).state =
      prefs.getString('agent_relay_host') ?? '';
  final arPort = prefs.getInt('agent_relay_port');
  ref.read(agentRelayPortProvider.notifier).state = arPort;
  ref.read(agentRelayTokenProvider.notifier).state =
      prefs.getString('agent_relay_token') ?? '';

  // Camera settings
  ref.read(cameraRotationProvider.notifier).state =
      prefs.getInt('camera_rotation') ?? 90;
  ref.read(cameraQualityProvider.notifier).state =
      prefs.getInt('camera_quality') ?? 70;
  ref.read(cameraResolutionProvider.notifier).state =
      prefs.getString('camera_resolution') ?? 'medium';
  ref.read(cameraMirrorProvider.notifier).state =
      prefs.getBool('camera_mirror') ?? false;
  ref.read(cameraAspectRatioProvider.notifier).state =
      prefs.getString('camera_aspect_ratio') ?? 'landscape';

  // Persona + system prompt + profile
  ref.read(aiPersonaProvider.notifier).state =
      prefs.getString('ai_persona') ?? GeminiConfig.defaultPersona.trim();
  ref.read(userSystemPromptProvider.notifier).state =
      prefs.getString('user_system_prompt') ?? GeminiConfig.defaultPrompt.trim();
  ref.read(userProfileProvider.notifier).state =
      prefs.getString('user_profile') ?? '';
  ref.read(callAgentOnDutyProvider.notifier).state =
      prefs.getBool('call_agent_on_duty') ?? false;
  ref.read(developerModeProvider.notifier).state =
      prefs.getBool('developer_mode') ?? false;
  ref.read(callAgentDeviceProvider.notifier).state =
      prefs.getString('call_agent_device') ?? '';
  ref.read(autoAnswerModeProvider.notifier).state = AutoAnswerMode.values
      .firstWhere((m) => m.name == (prefs.getString('auto_answer_mode') ?? ''),
          orElse: () => AutoAnswerMode.off);
  ref.read(autoAnswerDelayProvider.notifier).state =
      prefs.getInt('auto_answer_delay') ?? 6;
  ref.read(autoAnswerBlockedProvider.notifier).state =
      prefs.getString('auto_answer_blocked') ?? '';
  ref.read(autoAnswerAlwaysProvider.notifier).state =
      prefs.getString('auto_answer_always') ?? '';
  ref.read(callAgentPromptProvider.notifier).state =
      prefs.getString('call_agent_prompt') ??
          GeminiConfig.defaultCallPrompt.trim();

  // Watchface font settings
  ref.read(watchFontFamilyProvider.notifier).state =
      prefs.getString('watch_font_family') ?? 'Rajdhani';
  ref.read(watchFontWeightProvider.notifier).state =
      prefs.getInt('watch_font_weight') ?? 600;
  ref.read(watchFontSizeFactorProvider.notifier).state =
      prefs.getDouble('watch_font_size_factor') ?? 0.35;
  ref.read(watchTimeXProvider.notifier).state = prefs.getDouble('watch_time_x') ?? 0.5;
  ref.read(watchTimeYProvider.notifier).state = prefs.getDouble('watch_time_y') ?? 0.74;
});
