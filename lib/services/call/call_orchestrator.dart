import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../config/constants.dart';
import '../agent/call_tools_bridge.dart';
import '../bridge/call_bridge_service.dart';
import '../bridge/gemini_call_agent.dart';
import 'auto_answer.dart';
import 'call_history.dart';
import 'call_report.dart';
import 'call_state.dart';
import 'call_state_authority.dart';
import 'call_state_source.dart';
import 'call_transfer.dart';
import '../platform/system_actions_service.dart';
import 'crash_journal.dart';
import 'dialed_numbers.dart';
import 'fallback_audio.dart';
import '../memory/memory_store.dart';

/// Runs the call agent without a screen attached.
///
/// The same assembly `BridgeTestScreen` does, owned by a provider instead of a
/// widget. That screen stays as the playground; this is the one the product
/// uses, and the difference matters: a widget-owned session only exists while
/// somebody is looking at it, which is precisely when a call is least likely to
/// arrive.
///
/// Only one of the two may hold the bridge — there is a single SPP socket and a
/// single HFP slot. [harnessActive] is the interlock.
class CallOrchestrator {
  CallOrchestrator({
    required this.history,
    required this.memory,
    required this.dialed,
    required this.journal,
    required this.pending,
  });

  final CallHistory history;
  final MemoryStore memory;
  final DialedNumbers dialed;
  final CrashJournal journal;
  final PendingSink pending;

  /// Set while the bring-up harness owns the bridge. The orchestrator stands
  /// down rather than fighting it for the socket.
  static bool harnessActive = false;

  final _bridge = CallBridgeService();
  final _log = StreamController<String>.broadcast();
  final _reports = StreamController<CallReport>.broadcast();

  Stream<String> get events => _log.stream;
  Stream<CallReport> get reports => _reports.stream;

  /// Hands the audio route over before the bridge takes it.
  Future<void> Function() releaseAudio = () async {};

  /// Pushed to the app-wide prompt so it can draw itself.
  void Function(TransferState)? onTransferState;

  GeminiCallAgent? _agent;
  CallTransferController? _transfer;
  String _lastNumber = '';

  /// Whether this call has already taken the route, so a second ringing frame
  /// does not tear down a session that is already gone.
  bool _audioTaken = false;

  /// This call began with a ring. See the guard in the state listener.
  bool _sawRing = false;

  /// Set while an arm is in flight, so a second frame for the same call does
  /// not ask again. Cleared when the call ends or the board reports armed.
  DateTime? _armAskedAt;
  CallStateAuthority? _authority;
  AutoAnswerController? _autoAnswer;
  FallbackAudio? _fallback;
  final _subs = <StreamSubscription>[];

  bool _running = false;
  bool _starting = false;
  bool get isRunning => _running;

  void _say(String m) {
    debugPrint('[CALL-AGENT] $m');
    if (!_log.isClosed) _log.add(m);
  }

  /// Bring the bridge and the agent up. Idempotent.
  ///
  /// [config] carries the API key and prompts; [policy] is read fresh on every
  /// ring by [onDutyPolicy] rather than captured here, so a Settings change
  /// lands on the next call rather than the next restart.
  Future<String?> start({
    required String address,
    required GeminiConfig config,
    required AutoAnswerPolicy Function() onDutyPolicy,
    required String Function() wearerName,
  }) async {
    if (_running || _starting) return null;
    if (harnessActive) {
      return 'The bring-up harness has the bridge — stop it first.';
    }
    _starting = true;
    try {
      await history.load();
      await memory.load();

      // Subscribe BEFORE starting: the bridge emits during connect, and
      // anything sent between start() and listen() is simply lost.
      _bridge.listen();

      journal.bridgeStarted(address, 7);
      // Arm-on-demand. The board stays off the device's single HFP slot until a
      // call actually arrives, so between calls the slot belongs to the
      // wearer's earbud and the assistant has a real audio route.
      //
      // The alternative — arming at connect and holding the slot all day —
      // works, and every call in testing proved it. It also means the board is
      // permanently an HFP headset, which takes the slot the earbud needs and
      // drops the assistant to forced speakerphone. Measured on hardware, the
      // swap costs ~850 ms to take the slot and ~1.2 s to give it back, well
      // inside the auto-answer ring delay.
      //
      // Note the consequence: a disarmed board sees no calls at all, so ring
      // detection MUST come from telephony below.
      final err = await _bridge.start(address: address, stage: 7, autoArm: false);
      if (err != null) return err;
      // Explicitly, not just by omission. A board left connected by a previous
      // run still holds the HFP slot — "board already holds the slot" — and
      // nothing would take it back, so the earbud never got it and the
      // assistant stayed on the device speaker. ARM(0) is the message that
      // hands the slot to the wearer.
      await _bridge.arm(false);
      await _bridge.prepareNetwork();

      _fallback = FallbackAudio(bridge: _bridge);

      final transfer = CallTransferController(
        bridge: _bridge,
        fallback: _fallback,
        onReturned: (prompt) => _agent?.endTransfer(prompt),
      );
      _transfer = transfer;
      _subs.add(transfer.states.listen((t) {
        onTransferState?.call(t);
        _say('transfer: ${t.phase.name}'
            '${t.isWaiting ? ' (${t.secondsLeft}s)' : ''}');
      }));
      // The overlay's buttons. This is the path that reaches the wearer during
      // a call — an in-app prompt is behind the dialer, which is where the
      // wearer is looking.
      _subs.add(SystemActionsService.transferActions.listen((a) async {
        _say('wearer chose: $a');
        if (a == 'take') {
          await acceptTransfer();
        } else {
          await declineTransfer();
        }
      }));

      final tools = CallToolsBridge(
        memory: memory,
        onEndCall: (reason) async {
          _say('agent hung up: $reason');
          await _agent?.letHerFinish();
        },
        onTransfer: (reason) async {
          _say('transfer requested: $reason');
          // Before beginTransfer, not after: that closes the audio gate, and
          // "please hold while I connect you" arrives just after the tool call.
          await _agent?.letHerFinish(cap: const Duration(seconds: 6));
          _agent?.beginTransfer();
          await transfer.start(number: _lastNumber);
        },
      );

      final agent = GeminiCallAgent(
        bridge: _bridge,
        config: config,
        tools: tools,
        fallback: _fallback,
        history: history,
        dialed: dialed,
        journal: journal,
      );
      _subs.add(agent.events.listen(_say));
      _subs.add(agent.reports.listen((r) async {
        await pending.onReport(r);
        if (!_reports.isClosed) _reports.add(r);
      }));

      _subs.add(_bridge.stats.listen((st) {
        final asked = _armAskedAt;
        if (asked != null && st.armed) {
          _armAskedAt = null;
          _say('board has the HFP slot '
              '(${DateTime.now().difference(asked).inMilliseconds}ms)');
        }
      }));

      final startErr = await agent.start();
      if (startErr != null) {
        await _bridge.stop();
        return startErr;
      }
      _agent = agent;

      final authority = CallStateAuthority(
        bridge: BridgeCallStateSource(_bridge),
        // The only source that can say "ringing" and name the caller while the
        // board is off the slot. Without it, arm-on-demand has nothing to arm
        // on: `spp_send_call_state()` in the firmware fires only from HFP
        // indicator events, so a board with no SLC reports nothing at all.
        telephony: TelephonyCallStateSource(watchRinging: true),
      );
      await authority.start();
      _authority = authority;

      final auto = AutoAnswerController(history: history, log: _say);
      _autoAnswer = auto;
      _subs.add(authority.states.listen((c) {
        if (c.number.isNotEmpty) _lastNumber = c.number;
        if (c.isIdle) transfer.onCallEnded();
        // A ringing phone outranks a conversation. The main session holds
        // MODE_IN_COMMUNICATION and an app-owned SCO while it is warm, and
        // stays warm for two minutes after standing down — leaving it there
        // once ran it straight through a live bridged call. releaseAudio only
        // fired when the agent went on duty, which is not the moment that
        // matters; this is.
        if (c.phase == CallPhase.ringing) _sawRing = true;
        // Whether this call is the agent's to take.
        //
        // Incoming: it rang. Outgoing: WE dialled it — `make_call` notes the
        // number and the errand, and that note is the only honest signal that
        // an outgoing call was ours. A number the wearer dialled themselves is
        // their call, and arming would hand their conversation to the agent
        // mid-sentence.
        //
        // The same test also rejects the phantom: the board calls our own audio
        // route a call, and acting on that is a loop — it kills the assistant,
        // the route drops, the board says idle, the assistant wakes again.
        //
        // `dialing` must NOT stand on its own. The device is the HFP audio
        // gateway, so when the assistant wakes and sets MODE_IN_COMMUNICATION
        // the board reports [0,2] dialling → [1,3] active out of our own audio
        // route. Trusting `dialing` armed the board off that phantom, which
        // took the HFP slot away from the wearer's earbud, dropped the
        // assistant to the device speaker, and left the agent believing a call
        // was up — five forced reconnects into silence. Only a ring, or a
        // number we dispatched, makes a call ours.
        final dispatched = dialed.recent().isNotEmpty;
        final ours = c.phase == CallPhase.ringing ||
            ((c.phase == CallPhase.dialing || c.isActive) &&
                (_sawRing || dispatched));
        if (ours) {
          // The board was off the slot while this rang, so it will never send
          // the [0,1] frame the agent uses to tell a real call from a phantom
          // one. Telephony saw it; say so.
          _agent?.noteRing(number: c.number);
          // Stand the assistant down FIRST. Its teardown is asynchronous and
          // takes a second or two; starting it before the arm gives it the best
          // chance of finishing before the board owns the route. HfpRouter
          // .ownsCallAudio is the backstop for when it does not.
          if (!_audioTaken) {
            _audioTaken = true;
            _say('taking the audio route from the device assistant');
            unawaited(Future(releaseAudio).catchError(
                (e) => _say('!! could not release the audio route: $e')));
          }
          if (!_bridge.lastStats.armed && _armAskedAt == null) {
            _armAskedAt = DateTime.now();
            _say('arming the board for ${c.number.isEmpty ? 'this call' : c.number}');
            unawaited(_bridge.arm(true));
          }
        } else if (c.isActive && !_bridge.lastStats.armed) {
          _say('a call we did not place — leaving it to the wearer');
        } else if (c.isIdle) {
          _sawRing = false;
          _armAskedAt = null;
          if (_bridge.lastStats.armed) {
            _say('call over — the HFP slot goes back to the earbud/device');
            unawaited(_bridge.arm(false));
          }
          // The audio route is not grabbed back here. The wearer gets it when
          // they next speak, or when the briefer wakes the agent to pass the
          // message on — taking it the instant a call ends would fight the
          // report delivery.
          _audioTaken = false;
        }
        if (c.phase == CallPhase.ringing) {
          // Guarded: a throw in here used to take the whole handler with it, so
          // the phone rang and rang and nothing said why. A policy that cannot
          // be read is a bug worth shouting about, not a reason to go silent.
          try {
            auto.onRinging(c.number, onDutyPolicy());
          } catch (e) {
            _say('!! could not read the auto-answer policy — NOT answering: $e');
          }
        } else if (c.isActive) {
          auto.cancel('the call was answered');
        } else if (c.isIdle) {
          auto.cancel('the caller rang off');
        }
      }));

      unawaited(_fallback!.ensureClips(config));
      _running = true;
      _say('on duty — the agent will take calls');
      return null;
    } finally {
      _starting = false;
    }
  }

  /// Dial someone and tell the agent why it is calling.
  ///
  /// The task is what turns an outbound call from "the device rang you" into a
  /// dispatched errand: the agent opens knowing it is chasing the printing job,
  /// so the person on the other end is not asked to work out why a machine has
  /// telephoned them.
  Future<String?> dispatch({required String number, required String task}) async {
    if (!_running) return 'The call agent is not on duty.';
    // A dispatch to someone we have only just finished calling is almost
    // always the model re-reading its own instruction after the report came
    // back. Refused with the reason, so it can say what it already knows
    // instead of ringing them again. See DialedNumbers.completedFor.
    final done = dialed.completedFor(number);
    if (done != null) {
      _say('refusing a repeat call to $number — done ${done.ago.inSeconds}s ago');
      return 'You already called $number ${done.ago.inSeconds} seconds ago'
          '${done.task.isEmpty ? '' : ' about: "${done.task}"'}. That call is '
          'finished and its result is in the message you were just given. Tell '
          'the wearer what came back rather than calling again. If they then '
          'ask you for something new, say it back to them and this call will '
          'go through.';
    }
    dialed.note(number, task: task);
    _say('dialling $number — $task');
    return null;
  }

  /// The wearer took the call. The agent stands down; the call carries on.
  Future<void> acceptTransfer() async {
    await _transfer?.accept();
    await _agent?.concludeForTransfer();
  }

  /// Nobody took it. The agent comes back and speaks.
  Future<void> declineTransfer() => _transfer?.decline() ?? Future.value();

  /// Rejoin a call the process died in the middle of.
  ///
  /// Same start path as any other, then [GeminiCallAgent.adoptCall] — because
  /// the board announces an in-progress call only in its post-arm `initial`
  /// dump, which is deliberately ignored, so nothing else would tell the agent
  /// it is already on a call.
  Future<String?> readopt({
    required String address,
    required GeminiConfig config,
    required AutoAnswerPolicy Function() onDutyPolicy,
    required String Function() wearerName,
    required String number,
    required DateTime startedAt,
  }) async {
    final err = await start(
      address: address,
      config: config,
      onDutyPolicy: onDutyPolicy,
      wearerName: wearerName,
    );
    if (err != null) return err;
    _audioTaken = true;
    // The bridge now starts disarmed, and a call we are rejoining is already
    // running — nothing will ring to trigger the arm.
    _armAskedAt = DateTime.now();
    await _bridge.arm(true);
    _agent?.adoptCall(number: number, startedAt: startedAt);
    await journal.callStarted(number, startedAt);
    return null;
  }

  Future<void> stop() async {
    if (!_running && !_starting) return;
    _running = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _authority?.stop();
    _authority = null;
    _autoAnswer?.dispose();
    _autoAnswer = null;
    _audioTaken = false;
    _sawRing = false;
    _armAskedAt = null;
    _transfer?.dispose();
    _transfer = null;
    await _agent?.stop();
    _agent = null;
    _fallback = null;
    await _bridge.stop();
    _say('off duty');
  }

  void dispose() {
    stop();
    _log.close();
    _reports.close();
  }
}

/// Where a finished call's report goes. Kept as an interface so the
/// orchestrator does not have to know about the main agent.
abstract class PendingSink {
  Future<void> onReport(CallReport r);
}
