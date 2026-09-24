import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/call_bridge_service.dart';
import '../platform/system_actions_service.dart';
import 'fallback_audio.dart';

enum TransferPhase {
  /// Nothing happening.
  none,

  /// Board disarmed, wearer alerted, waiting for them to pick it up.
  waiting,

  /// The wearer took the call. The agent is out of it.
  taken,

  /// Nobody answered in time, or they sent it back. The agent has it again.
  returned,
}

class TransferState {
  const TransferState({
    required this.phase,
    this.number = '',
    this.contactName = '',
    this.secondsLeft = 0,
  });

  final TransferPhase phase;
  final String number;
  final String contactName;
  final int secondsLeft;

  bool get isWaiting => phase == TransferPhase.waiting;

  /// Who to put on the prompt. Never "unknown" if we can help it — the wearer
  /// is deciding whether to take a live call in about ten seconds.
  String get who =>
      contactName.isNotEmpty ? contactName : (number.isEmpty ? 'Someone' : number);
}

/// Hands a live call from the agent to the person wearing the device.
///
/// The mechanics were proven before this class existed: disarming the board and
/// dropping its HFP leaves the carrier call running, and telephony falls back to
/// the device — `HfpRouter.releaseToUser` then forces speakerphone so it lands
/// somewhere audible. `sendArm(false)` already triggers all of that.
///
/// What this adds is the part that makes it usable rather than merely possible:
///
///  - the wearer is told, insistently, that a real person is waiting
///  - **SPP stays open**, so the call can be handed back
///  - if nobody answers, it *is* handed back, and the agent covers
///
/// That last point is not a nicety. Without it a caller sits in silence while a
/// device buzzes on a wrist by someone's side, and silence is the worst thing
/// this product can do to a person who rang for help.
class CallTransferController {
  CallTransferController({
    required this.bridge,
    this.fallback,
    this.onReturned,
  });

  final CallBridgeService bridge;

  /// Hold music for the waiting window. Optional; without it the caller simply
  /// waits in silence, which is what used to happen always.
  final FallbackAudio? fallback;

  /// Called when the call comes back to the agent, with a line for it to say.
  /// The agent has to *speak* here — the caller has been listening to nothing.
  final void Function(String recoveryPrompt)? onReturned;

  static const timeout = Duration(seconds: 15);

  final _out = StreamController<TransferState>.broadcast();
  Stream<TransferState> get states => _out.stream;

  TransferState _state = const TransferState(phase: TransferPhase.none);
  TransferState get current => _state;

  Timer? _countdown;

  Future<void> start({
    required String number,
    String contactName = '',
  }) async {
    if (_state.isWaiting) return;

    _log('offering the call to the wearer ($number)');

    // Deliberately NOT disarming yet.
    //
    // Disarming drops the board's HFP, which moves the call to the device — and
    // from there we have no way to put audio on the line at all (see
    // CALL_AUDIO_FINDINGS.md). Doing it at the moment of *offering* meant the
    // caller heard fifteen seconds of nothing while a device buzzed on someone's
    // wrist, and heard nothing even if the wearer declined.
    //
    // Keeping the board armed until the wearer actually accepts means the
    // caller gets hold music instead of silence, and the hand-over happens only
    // when there is a hand to hand it to.
    final music = fallback?.music;
    if (music != null) {
      fallback!.play(music, loop: true, what: 'hold music');
    }

    // Not just a buzz: this also has to put FOX-1 in front of the dialer's
    // in-call UI, or the prompt is drawn where nobody can see it.
    if (!await SystemActionsService.canOverlay()) {
      _log('NO OVERLAY PERMISSION — the prompt cannot be drawn over the '
          'dialer. Grant "draw over other apps" in Settings.');
    }
    await SystemActionsService.alertWearer(
      who: contactName.isNotEmpty
          ? contactName
          : (number.isEmpty ? 'Someone' : number),
    );

    _emit(TransferState(
      phase: TransferPhase.waiting,
      number: number,
      contactName: contactName,
      secondsLeft: timeout.inSeconds,
    ));

    var left = timeout.inSeconds;
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      left--;
      if (left <= 0) {
        t.cancel();
        _timeOut();
        return;
      }
      _emit(TransferState(
        phase: TransferPhase.waiting,
        number: _state.number,
        contactName: _state.contactName,
        secondsLeft: left,
      ));
    });
  }

  /// The wearer took it. Only now does the call actually move.
  Future<void> accept() async {
    if (!_state.isWaiting) return;
    _stopWaiting();
    _log('wearer took the call — handing it over');
    // Disarming drops the board's HFP; HfpRouter.releaseToUser rides along and
    // puts the call on the earbud or the device speaker.
    await bridge.arm(false);
    _emit(TransferState(
      phase: TransferPhase.taken,
      number: _state.number,
      contactName: _state.contactName,
    ));
  }

  /// The wearer declined. Straight back to the agent, no waiting.
  Future<void> decline() => _handBack(
        'The user is not available. Apologise briefly and offer to take a '
        'message.',
        'wearer declined',
      );

  Future<void> _timeOut() => _handBack(
        'You could not reach the user. Apologise briefly for the wait and '
        'offer to take a message.',
        'no answer in ${timeout.inSeconds}s',
      );

  Future<void> _handBack(String recoveryPrompt, String why) async {
    if (!_state.isWaiting) return;
    _stopWaiting();
    _log('call back to the agent — $why');
    // Nothing to re-arm: the board never stopped taking call audio, because the
    // offer was only ever an offer.
    _emit(TransferState(
      phase: TransferPhase.returned,
      number: _state.number,
      contactName: _state.contactName,
    ));
    onReturned?.call(recoveryPrompt);
  }

  void _stopWaiting() {
    _countdown?.cancel();
    _countdown = null;
    fallback?.stop();
    SystemActionsService.stopAlert();
  }

  /// The call is over, however it got there.
  ///
  /// If the wearer had taken it, the bridge has been sitting disarmed with its
  /// HFP slot given away for the whole conversation — and nothing was going to
  /// put it back. Stage 7 stayed "running" while every later call bypassed the
  /// bridge and rang out on the device speaker.
  Future<void> onCallEnded() async {
    if (_state.phase == TransferPhase.none) return;
    final wasTaken = _state.phase == TransferPhase.taken;
    _stopWaiting();
    if (wasTaken) {
      _log("the wearer's call ended — re-arming the bridge");
      await bridge.arm(true);
    } else {
      _log('transfer cancelled — call ended');
    }
    _emit(const TransferState(phase: TransferPhase.none));
  }

  void _emit(TransferState s) {
    _state = s;
    if (!_out.isClosed) _out.add(s);
  }

  void _log(String m) => debugPrint('[TRANSFER] $m');

  void dispose() {
    _stopWaiting();
    _out.close();
  }
}
