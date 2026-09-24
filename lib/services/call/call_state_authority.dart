import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_state.dart';
import 'call_state_source.dart';

/// One truth about the call, assembled from two partial witnesses.
///
/// The board sees the call precisely and only while it holds HFP. The moment
/// the bridge drops that link — which is exactly what `transfer_to_human` does
/// — the board goes blind, and it goes blind *while a human is on the line*.
/// Telephony can always answer "is a call up", but below default-dialer it
/// cannot say who is calling or that it is ringing.
///
/// So: the board leads while it can see, telephony catches the call when it
/// cannot, and neither is allowed to end a call the other still sees.
///
/// Two rules do the work:
///
///  1. **A source going blind is not a call ending.** The board falling silent
///     during a hand-over must not produce [CallPhase.idle]; authority moves to
///     telephony and the call stays up until telephony says otherwise.
///  2. **Every transition is idempotent.** Both sources will report the same
///     hangup, in either order. Repeats are dropped, not re-emitted.
class CallStateAuthority {
  CallStateAuthority({
    required CallStateSource bridge,
    required CallStateSource telephony,
  })  : _bridge = bridge,
        _telephony = telephony;

  final CallStateSource _bridge;
  final CallStateSource _telephony;

  final _out = StreamController<CallState>.broadcast();
  final _subs = <StreamSubscription>[];

  CallState _state = const CallState(phase: CallPhase.idle);

  /// Transitions only. Nothing is emitted for a repeated observation.
  Stream<CallState> get states => _out.stream;
  CallState get current => _state;

  /// Which source we are currently believing. Diagnostic.
  String get authority => _bridge.isLive ? _bridge.name : _telephony.name;

  Future<void> start() async {
    await _bridge.start();
    await _telephony.start();
    _subs.add(_bridge.states.listen((s) => _observe(s, fromBridge: true)));
    _subs.add(_telephony.states.listen((s) => _observe(s, fromBridge: false)));
  }

  void _observe(CallState obs, {required bool fromBridge}) {
    // Rule 1. While the board can still see the call it leads, and telephony's
    // coarser view is not allowed to contradict it — `AudioManager.mode` lags
    // the board by a second or so at both ends of a call, and letting it win
    // would flap the state at exactly the moments that matter.
    if (!fromBridge && _bridge.isLive) {
      if (obs.phase != CallPhase.active && _state.isActive) return;
    }

    // Rule 1 again, the other way: the board saying nothing is not the board
    // saying idle. A blind source cannot end a call. This is only reachable if
    // a stale frame arrives after the link went down.
    if (fromBridge && !_bridge.isLive && obs.phase == CallPhase.idle) {
      _log('ignoring idle from a board that can no longer see the call');
      return;
    }

    _apply(obs);
  }

  void _apply(CallState obs) {
    // Rule 2.
    if (obs.phase == _state.phase &&
        (obs.number.isEmpty || obs.number == _state.number)) {
      return;
    }

    final was = _state.phase;
    final becomingActive = obs.phase == CallPhase.active && !_state.isActive;
    final ending = obs.phase == CallPhase.idle && _state.phase != CallPhase.idle;

    _state = _state.copyWith(
      phase: obs.phase,
      // Keep the number we already have if this source cannot supply one —
      // audio-mode polling never can, and losing the caller ID at hand-over is
      // how the wearer ends up staring at an anonymous prompt.
      number: obs.number.isNotEmpty ? obs.number : _state.number,
      startedAt: becomingActive ? DateTime.now() : _state.startedAt,
      clearStartedAt: ending,
      source: obs.source,
    );

    if (was == _state.phase) {
      // Same phase, new detail — almost always the caller ID catching up with
      // a ring that arrived without one. Not a transition, and logging it as
      // "active -> active" reads like a bug.
      _log('caller is ${_state.number} (${obs.source})');
    } else {
      _log('${was.name} -> ${_state.phase.name} (${obs.source})'
          '${_state.number.isEmpty ? '' : ' ${_state.number}'}');
    }
    if (!_out.isClosed) _out.add(_state);
  }

  /// Announce that authority has moved, for the log's sake. Called by the
  /// orchestrator around a deliberate hand-over so the transition is legible
  /// rather than inferred from a gap.
  void noteAuthorityChange(String why) => _log('authority -> $authority ($why)');

  void _log(String msg) => debugPrint('[CALL] $msg');

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _bridge.stop();
    await _telephony.stop();
  }

  void dispose() {
    stop();
    _out.close();
  }
}
