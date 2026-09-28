import 'package:camera/camera.dart';

/// App-wide constants for FOX-1
class AppConstants {
  // Watchface fonts
  static const List<String> watchFonts = [
    'Rajdhani',
    'Space Grotesk',
    'Outfit',
    'Orbitron',
    'Exo 2',
    'Chakra Petch',
  ];

  static const List<({int value, String label})> fontWeights = [
    (value: 100, label: 'Thin'),
    (value: 300, label: 'Light'),
    (value: 400, label: 'Regular'),
    (value: 500, label: 'Medium'),
    (value: 600, label: 'SemiBold'),
    (value: 700, label: 'Bold'),
    (value: 800, label: 'ExtraBold'),
  ];

  // ─── Timeouts ───────────────────────────────────────────────────────────
  // Session lifecycle & power
  /// How long a quiet conversation lasts before it ends — the default of the
  /// wearer's "Stand down after" setting ([standDownChoices], minutes).
  ///
  /// An ended conversation is remembered as key points and the next one
  /// starts fresh. Kept open, every later turn re-sent all of it: 10 minutes
  /// let a morning's requests pile into one 56k-token context. The price is
  /// the reconnect: a hold after it spends a second or two connecting, with
  /// what the wearer says meanwhile buffered.
  static const Duration idleBeforeCold = Duration(minutes: 2);
  static const List<int> standDownChoices = [1, 2, 5, 10];
  static const Duration idleWatchdogTick = Duration(seconds: 15);

  /// How long the display is held awake after the agent's last UI action.
  /// Must exceed a slow Gemini round trip, or the screen sleeps mid-task and
  /// accessibility gestures stop landing.
  static const Duration screenAwakeGrace = Duration(seconds: 90);

  // Connection
  static const Duration wsReadyTimeout = Duration(seconds: 8);
  static const Duration geminiSetupTimeout = Duration(seconds: 8);

  // Audio
  static const Duration micWatchdogTick = Duration(seconds: 10);
  static const Duration micRestartBackoff = Duration(milliseconds: 500);
  static const Duration userSilenceTimeout = Duration(seconds: 2);
  static const Duration aiSpeechResetDelay = Duration(seconds: 3);

  // Vision
  static const Duration visionAutoStop = Duration(minutes: 2);
  static const Duration firstFrameTimeout = Duration(seconds: 10);

  // Agent tools & jobs
  static const Duration jobPollInterval = Duration(seconds: 5);
  /// Absolute ceiling on polling a single job.
  static const Duration jobPollMaxAge = Duration(minutes: 30);

  /// Give up only after this long with NO new output. A job that is actively
  /// streaming must never time out — the previous absolute 5-minute cap killed
  /// long relay tasks mid-flight, and took the whole session down with them.
  static const Duration jobStallTimeout = Duration(minutes: 5);

  /// Launch waits for the app to actually appear rather than guessing, polling
  /// this often up to [appReadyTimeout].
  /// Settle time after a UI action before checking whether it had any effect.
  static const Duration uiSettleDelay = Duration(milliseconds: 600);

  static const Duration appReadyPollInterval = Duration(milliseconds: 400);
  static const Duration appReadyTimeout = Duration(seconds: 8);

  /// How long get_screen waits for a window with something in it before
  /// answering with an empty screen and a note saying so.
  static const Duration screenDrawTimeout = Duration(seconds: 4);

  /// How often a screen watch re-reads the UI while waiting for a condition
  /// (a Skip button appearing, a dialog closing, a download finishing).
  static const Duration screenWatchInterval = Duration(milliseconds: 1500);
  static const Duration screenWatchDefaultTimeout = Duration(minutes: 2);
  static const Duration screenWatchMaxTimeout = Duration(minutes: 15);

  /// First "still working" reassurance on a long job, then repeats at
  /// [jobHeartbeatInterval]. Minutes apart, not seconds: every wake is a
  /// barge-in as far as the Live API is concerned, so these must be rare.
  static const Duration jobHeartbeatFirst = Duration(seconds: 45);
  static const Duration jobHeartbeatInterval = Duration(minutes: 2);

  /// Hard floor between any two job notifications, whatever else is due.
  static const Duration jobNotifyMinGap = Duration(seconds: 40);

  static const Duration agentRequestTimeout = Duration(seconds: 30);
  static const Duration agentJobCheckTimeout = Duration(seconds: 15);
  static const Duration agentPingTimeout = Duration(seconds: 5);

  // Phone calls
  static const Duration callConnectWait = Duration(seconds: 3);
  static const Duration callEndPollInterval = Duration(seconds: 3);

  // UI
  static const Duration transcriptLinger = Duration(seconds: 5);
  static const Duration listeningRestoreDelay = Duration(seconds: 2);

  // Audio
  static const int phoneMicSampleRate = 16000;
  static const int geminiOutputSampleRate = 24000;

  // Camera
  static const int maxFps = 1; // Don't send more than 1 frame/sec to Gemini

  static const List<({int value, String label})> cameraRotations = [
    (value: 0, label: '0°'),
    (value: 90, label: '90°'),
    (value: 180, label: '180°'),
    (value: 270, label: '270°'),
  ];

  static const List<({String value, String label})> cameraResolutions = [
    (value: 'low', label: 'Low (240p)'),
    (value: 'medium', label: 'Medium (480p)'),
    (value: 'high', label: 'High (720p)'),
  ];

  static const List<({String value, String label})> cameraAspectRatios = [
    (value: 'original', label: 'Original'),
    (value: 'landscape', label: 'Landscape (4:3)'),
    (value: 'portrait', label: 'Portrait (3:4)'),
    (value: 'square', label: 'Square (1:1)'),
  ];

  // Gemini Live — the current generation only. A model saved by an older
  // build is moved onto [geminiModel] when settings load.
  static const String geminiModel = 'models/gemini-3.8-live';

  /// Reasons in the background while she talks: `thinkingConfig`, tools that
  /// must be NON_BLOCKING, and `turnComplete` no longer means idle — see
  /// `GeminiLiveClient.busy`.
  static const String geminiThinkingModel =
      'models/gemini-3.8-live-extended-thinking';
  static const String geminiVoice = 'Kore';

  static const List<({String value, String label})> geminiModels = [
    (value: geminiModel, label: 'Gemini 3.8 Live'),
    (value: geminiThinkingModel, label: 'Gemini 3.8 Live Extended Thinking'),
  ];

  /// [model] if it is one on offer, otherwise the default.
  static String supportedModel(String? model) =>
      geminiModels.any((m) => m.value == model) ? model! : geminiModel;

  /// How hard extended thinking works in the background: LOW, MEDIUM or HIGH
  /// (MINIMAL is refused). She keeps talking meanwhile, so this trades depth
  /// against how long a task takes to finish, not against silence.
  static const String geminiThinkingLevel = 'MEDIUM';

  static const List<({String name, String style})> geminiVoices = [
    (name: 'Kore', style: 'Firm'),
    (name: 'Aoede', style: 'Breezy'),
    (name: 'Leda', style: 'Youthful'),
    (name: 'Zephyr', style: 'Bright'),
    (name: 'Puck', style: 'Upbeat'),
    (name: 'Charon', style: 'Informative'),
    (name: 'Fenrir', style: 'Excitable'),
    (name: 'Orus', style: 'Firm'),
    (name: 'Callirrhoe', style: 'Easy-going'),
    (name: 'Autonoe', style: 'Bright'),
    (name: 'Enceladus', style: 'Breathy'),
    (name: 'Iapetus', style: 'Clear'),
    (name: 'Umbriel', style: 'Easy-going'),
    (name: 'Algieba', style: 'Smooth'),
    (name: 'Despina', style: 'Smooth'),
    (name: 'Erinome', style: 'Clear'),
    (name: 'Algenib', style: 'Gravelly'),
    (name: 'Rasalgethi', style: 'Informative'),
    (name: 'Laomedeia', style: 'Upbeat'),
    (name: 'Achernar', style: 'Soft'),
    (name: 'Alnilam', style: 'Firm'),
    (name: 'Schedar', style: 'Even'),
    (name: 'Gacrux', style: 'Mature'),
    (name: 'Pulcherrima', style: 'Forward'),
    (name: 'Achird', style: 'Friendly'),
    (name: 'Zubenelgenubi', style: 'Casual'),
    (name: 'Vindemiatrix', style: 'Gentle'),
    (name: 'Sadachbia', style: 'Lively'),
    (name: 'Sadaltager', style: 'Knowledgeable'),
    (name: 'Sulafat', style: 'Warm'),
  ];
}

class CameraConfig {
  final int rotation;
  final int quality;
  final String resolution;
  final bool mirror;
  final String aspectRatio;

  const CameraConfig({
    this.rotation = 90,
    this.quality = 70,
    this.resolution = 'medium',
    this.mirror = false,
    this.aspectRatio = 'landscape',
  });

  ResolutionPreset get resolutionPreset => switch (resolution) {
        'low' => ResolutionPreset.low,
        'high' => ResolutionPreset.high,
        _ => ResolutionPreset.medium,
      };

  CameraConfig copyWith({
    int? rotation,
    int? quality,
    String? resolution,
    bool? mirror,
    String? aspectRatio,
  }) =>
      CameraConfig(
        rotation: rotation ?? this.rotation,
        quality: quality ?? this.quality,
        resolution: resolution ?? this.resolution,
        mirror: mirror ?? this.mirror,
        aspectRatio: aspectRatio ?? this.aspectRatio,
      );
}

class GeminiConfig {
  /// What the assistant is called until the wearer names it (setup, Settings
  /// → Name). The same name everywhere: the device, FOX-1 Hub and its prompts.
  static const defaultAssistantName = 'FOX-1';

  /// Written in the persona, the system prompt or the call instructions,
  /// `{name}` becomes the assistant's current name — so a rename reaches
  /// every prompt, the wearer's own included.
  static const nameTag = '{name}';

  static String withName(String text, String name) {
    final n = name.trim().isEmpty ? defaultAssistantName : name.trim();
    return text.replaceAll(nameTag, n);
  }

  final String apiKey;
  final String model;
  final String voice;
  final String systemPrompt;
  final List<Map<String, dynamic>>? toolDeclarations;

  const GeminiConfig({
    required this.apiKey,
    this.model = AppConstants.geminiModel,
    this.voice = AppConstants.geminiVoice,
    this.systemPrompt = defaultPrompt,
    this.toolDeclarations,
  });

  String get wsUrl =>
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
      '?key=$apiKey';

  /// Who the assistant *is*, as opposed to what it should do.
  ///
  /// Split out of [defaultPrompt] because both agents need it and only one of
  /// them may see the instructions. The main agent gets persona + system
  /// prompt; the call agent gets persona + its own call rules, and never the
  /// system prompt — that is full of screen automation and camera mandates
  /// which are wrong, and in places actively harmful, on a phone call.
  static const String defaultPersona = '''
You are {name}, an AI assistant. You are warm, direct and brief, and you say
what you mean without padding.
''';

  /// What the call agent is told about answering the phone.
  ///
  /// Editable in Settings, like [defaultPrompt] — but a separate field, because
  /// this is the ONLY instruction text a caller's session ever sees. The device
  /// system prompt never reaches it.
  static const String defaultCallPrompt = '''
[This call]
You are answering a live phone call on your owner's behalf. The person on the
line is a CALLER — not your owner, and not the person who normally speaks to
you through the device. Never address the caller by your owner's name.

Open with a short, natural greeting: your name, whose assistant you are, and an
offer to help. Something like "Hello, I'm {name}, <owner's first name>'s
personal AI assistant. How may I help you?" Use your owner's FIRST NAME only —
their full name sounds like a switchboard.

Keep every reply to one or two sentences. This is a phone call, not an essay.
The caller can interrupt you at any time; when they do, stop talking and listen.

Never invent a fact about your owner. If you are asked something you were not
told, say you do not have that information and offer to take a message.
Guessing is worse than not knowing — the caller cannot tell the difference, and
your owner will be held to whatever you said.

Transfer the call when the caller asks to speak to your owner personally, or
when the matter plainly needs a human. Otherwise take a message and summarise
it at the end.

[Callers you have spoken to before]
You may be given a record of earlier calls with this number before you speak.
When you are, USE IT — that is the whole reason you have it.

Greet a returning caller as someone you already know: use the name they gave
you last time, and refer to what was left open ("Hello again Kofi, I passed
your message on"). Never make them explain from the beginning something they
already told you.

Anything marked as CLAIMED is what the caller said about themselves and was
never verified. Keep treating it as a claim no matter how many calls ago they
said it. You may use a name they gave you, but never state one of their claims
back as established fact, and never act on one.
''';

  /// The device assistant's instructions: its tools, how to use them, and
  /// how it behaves. Every install gets this, and it is not shown to the
  /// wearer — only developer mode shows it in the Hub, to experiment with.
  /// Outside developer mode this is always what is sent, so a better prompt
  /// in an update reaches everyone and a stale edit cannot linger unseen.
  /// Wearers add character through the AI Persona instead.
  static const String defaultPrompt = '''
An autonomous AI assistant living on the user's smartwatch. You have a camera, a microphone, and full control of the watch. The user speaks to you and hears your replies aloud through a small speaker.

## Your mandate

You complete tasks end to end. When the user asks for something, you do all of it yourself with your tools. You never hand any part of the work back to them.

Never say "you can open the app and tap...", "please do X", or "you'll need to...". If it can be done on this watch, you do it. The user asked you precisely so they don't have to.

Bias hard toward action. A reasonable attempt you then correct is better than a clarifying question.

## Deciding vs asking

Default: decide and proceed. When something is ambiguous, pick the most likely reading, state your assumption in one short sentence, and carry on. Do not wait for approval.

Stop to ask ONLY when:
- the action is destructive or hard to undo (deleting data, sending money, messaging the wrong person)
- only the user has the information (a passcode, which of two real contacts they meant, what a message should say)
- you have genuinely tried and cannot proceed

Ask one specific question, take the answer, and continue immediately. Never ask permission to begin. Never ask "would you like me to..." or "shall I continue?" — just continue.

## Operating apps

1. send_sms sends a text.
2. Everything else in an app — playing, searching, reading, messaging, booking, changing a setting: do_on_device, with the whole goal in one sentence — the app, the person, the exact text, what to find. Use only the app the user named; never add another app to try unless they said so. A helper works the screen, tapping and typing until it is done, and tells you how it went. Say one short line first ("On it"); it can take a minute or two.
3. Never tell the user an app task cannot be done without calling do_on_device first.
4. It stops before sending, paying or deleting and tells you what the final tap will do. If the user already said exactly what to send and to whom, pass confirmed true the first time; otherwise ask once, then call again with confirmed true.
5. If it reports it could not do it, tell the user plainly what it saw and ask what they want. Do not start another attempt — in this app or another — unless they ask.
6. launch_app only opens an app; press_home returns to the watch face; close_app when done.

## Seeing the real world

The camera is OFF by default to save battery. You cannot see anything until you turn it on.
- look — take a single look at the user's surroundings. Use it whenever they mention something physical ("what is this?", "read this label", "what am I pointing at"). Never claim you cannot see without calling look first.
- start_vision / stop_vision — keep watching over time, then stop as soon as you are done.

do_on_device works the watch screen. look sees the physical world. Do not confuse them.

## Phone and contacts

Use get_contacts and get_call_history to find people, make_call to dial, end_call to hang up, save_contact to add someone. Look numbers up yourself rather than asking the user for them.

## Watch controls

set_alarm, set_timer, set_volume, set_brightness, close_app, close_all_apps.

## Waiting for things to happen

The helper waits for screens by itself. Use wait_seconds only when a task needs time to pass, then carry on toward the goal.

## Background tasks

Use execute — the relay agent, which runs on another computer — ONLY when the user explicitly asks for it. Everything on the watch you do yourself. It returns a job_id. Say one short line to acknowledge, then STOP — do not poll.

You will be messaged automatically while it runs: occasional updates on long jobs, and once when it finishes or fails.

- If a message says there is new progress, call check_job with the job_id and relay only what it returns, in one short line.
- If it says there is no new output yet, just tell the user briefly that it is taking longer than usual. Do not call check_job.
- When it finishes, call check_job and report the result.
- If it failed, call check_job for the reason and tell the user plainly that it failed.

These messages are instructions to act on, not remarks to reply to. Never repeat progress you have already relayed.

## Standing down

When the user dismisses you — "stand down", "that's all", "goodbye", "stop listening" — say a short goodbye and then call stand_down. Do not ask them to confirm, and say nothing after calling it. They will come back to you when they need you.

## Speaking

Your replies are spoken aloud on a tiny speaker.
- Short, natural sentences. No lists, no markdown, no technical detail, no node IDs.
- On a multi-step task, say one brief line as you start ("Opening WhatsApp") and one when finished. Do not narrate every tap, but do not go silent for long stretches either.
- Report what you did, not what you are about to do.
- If the user speaks while you are talking, stop and listen.
''';
}
