import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/constants.dart';
import '../../main.dart' show globalContainer;
import '../../providers/providers.dart';
import '../../widgets/transfer_prompt.dart';
import '../session/ai_session_manager.dart';
import 'auto_answer.dart';
import 'call_briefing.dart';
import 'call_orchestrator.dart';

/// Putting the call agent on duty, in one place.
///
/// Called from boot, from the Settings toggle, and from crash recovery. Two
/// call sites assembling the config separately is how the booted agent and the
/// on-device one end up with different prompts.
///
/// **Everything here reads `globalContainer`, never a `WidgetRef`.** The
/// orchestrator holds these callbacks for as long as it is on duty, which is
/// far longer than any screen lives. An earlier version captured the Settings
/// screen's ref: closing Settings killed it, and from then on every ringing
/// call threw "Cannot use ref after the widget was disposed" out of the policy
/// lookup — so the phone rang and rang and was never answered.

void _wire(CallOrchestrator o) {
  final c = globalContainer;

  // The main session owns the audio route until it is told otherwise. Handing
  // it over here rather than inside the orchestrator keeps the orchestrator
  // free of the session manager.
  o.releaseAudio = () => c.read(aiSessionManagerProvider).goCold();

  // The hand-over prompt is app-wide — it has to outrank whatever screen is
  // showing, because during a call that is the dialer.
  o.onTransferState = (t) => c.read(transferStateProvider.notifier).state = t;

  _transferSub?.close();
  _transferSub = c.listen<TransferAction?>(transferActionProvider,
      (_, action) async {
    if (action == null) return;
    c.read(transferActionProvider.notifier).state = null;
    if (action == TransferAction.take) {
      await o.acceptTransfer();
    } else {
      await o.declineTransfer();
    }
  });
}

/// Held so re-wiring does not stack up duplicate listeners across restarts.
ProviderSubscription<TransferAction?>? _transferSub;

GeminiConfig _config() {
  final c = globalContainer;
  return GeminiConfig(
    apiKey: c.read(geminiApiKeyProvider),
    // Always plain 3.8 Live, whatever the wearer picked: hang-up and the call
    // report wait on turnComplete, which extended thinking no longer means.
    model: AppConstants.geminiModel,
    voice: c.read(geminiVoiceProvider),
    // Persona and profile, never the device system prompt — see
    // composeCallPrompt.
    systemPrompt: composeCallPrompt(
      persona: c.read(aiPersonaProvider),
      userProfile: c.read(userProfileProvider),
      callInstructions: c.read(callAgentPromptProvider),
      name: c.read(assistantNameProvider),
    ),
  );
}

/// Read per ring, so a Settings change lands on the next call rather than the
/// next restart.
AutoAnswerPolicy _policy() {
  final c = globalContainer;
  return AutoAnswerPolicy(
    mode: c.read(autoAnswerModeProvider),
    blocked: AutoAnswerPolicy.parseList(c.read(autoAnswerBlockedProvider)),
    always: AutoAnswerPolicy.parseList(c.read(autoAnswerAlwaysProvider)),
    ringFirst: Duration(seconds: c.read(autoAnswerDelayProvider)),
  );
}

String _wearerName() => globalContainer.read(userProfileProvider);

Future<String?> startCallAgent(String address) async {
  final o = globalContainer.read(callOrchestratorProvider);
  _wire(o);
  return o.start(
    address: address,
    config: _config(),
    onDutyPolicy: _policy,
    wearerName: _wearerName,
  );
}

/// Rejoin a call the process died in the middle of, with no screen involved.
///
/// The bridge test screen can still do this when the agent is off duty — that
/// is the playground. In production the wearer must not be handed a device
/// picker and a log window during a live call.
Future<String?> readoptCall(
  String address, {
  required String number,
  required DateTime startedAt,
}) async {
  final o = globalContainer.read(callOrchestratorProvider);
  _wire(o);
  return o.readopt(
    address: address,
    config: _config(),
    onDutyPolicy: _policy,
    wearerName: _wearerName,
    number: number,
    startedAt: startedAt,
  );
}

Future<void> stopCallAgent() =>
    globalContainer.read(callOrchestratorProvider).stop();
