import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_history.dart';

/// Who the device picks up for.
enum AutoAnswerMode {
  /// Never. The wearer answers their own phone.
  off,

  /// Only people already on file — a caller with call history, which on this
  /// device means somebody the agent has spoken to before or the wearer dialled.
  known,

  /// Anyone not blocked.
  everyone,
}

/// What to do about a ringing phone.
enum AnswerDecision {
  /// Pick up after the ring delay.
  answer,

  /// Leave it. The wearer's phone, the wearer's call.
  ring,

  /// Blocked — do not touch it, and do not let the agent near it.
  ignore,
}

/// Whether to answer, and after how long.
///
/// Deliberately pure: no channels, no timers, no history lookups of its own.
/// This is the part where a wrong answer means the device took a call it had no
/// business taking, so it has to be readable in one sitting and testable
/// without a phone.
@immutable
class AutoAnswerPolicy {
  const AutoAnswerPolicy({
    this.mode = AutoAnswerMode.off,
    this.blocked = const {},
    this.always = const {},
    this.ringFirst = const Duration(seconds: 6),
  });

  final AutoAnswerMode mode;

  /// Never answered, whatever the mode says.
  final Set<String> blocked;

  /// Always answered, even in [AutoAnswerMode.known] with no history.
  final Set<String> always;

  /// How long to let it ring before picking up.
  ///
  /// Never zero. Instant pickup denies the wearer their own call and reads as
  /// the device stealing their phone — they must always get the chance to
  /// answer it themselves first.
  final Duration ringFirst;

  AnswerDecision decide(String number, {required bool onFile}) {
    final key = CallHistory.keyFor(number);

    // Blocking wins over everything, including [always] and [everyone]. A list
    // whose entries can be overridden by another setting is not a block list.
    if (key.isNotEmpty && _has(blocked, key)) return AnswerDecision.ignore;

    if (mode == AutoAnswerMode.off) return AnswerDecision.ring;

    // No caller ID. Under `known` there is nothing to match, and under
    // `everyone` it is still someone who chose not to identify themselves —
    // ring it through either way rather than having the agent greet a number
    // it cannot file the conversation against.
    if (key.isEmpty) return AnswerDecision.ring;

    if (_has(always, key)) return AnswerDecision.answer;

    switch (mode) {
      case AutoAnswerMode.everyone:
        return AnswerDecision.answer;
      case AutoAnswerMode.known:
        return onFile ? AnswerDecision.answer : AnswerDecision.ring;
      case AutoAnswerMode.off:
        return AnswerDecision.ring;
    }
  }

  /// Lists are stored as the wearer typed them, matched the way calls are.
  static bool _has(Set<String> list, String key) =>
      list.any((n) => CallHistory.keyFor(n) == key);

  static Set<String> parseList(String raw) => raw
      .split(RegExp(r'[,\n;]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
}

/// Picks the phone up.
///
/// Two mechanisms. `dialer` is `InCallService.answer()`, available only when
/// FOX-1 is the default dialer. `telecom` is
/// `TelecomManager.acceptRingingCall()`, which needs nothing but the
/// ANSWER_PHONE_CALLS runtime permission.
///
/// The plan recorded acceptRingingCall as system-only. That stopped being true
/// at API 26, when ANSWER_PHONE_CALLS became a normal runtime permission — so
/// the supported path was available all along, and the default-dialer decision
/// never gated this. An earlier version reflected `BluetoothHeadset.acceptCall`
/// instead and could never have worked: `acceptCall` is on
/// `BluetoothHeadsetClient`, the *headset* role. The device is the phone.
class CallAnswerer {
  CallAnswerer({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel('ai.fox1/in_call');

  final MethodChannel _channel;

  /// Returns 'dialer', 'telecom', or null if it could not answer.
  ///
  /// [onFail] gets the reason, which the platform returns rather than logs:
  /// there is no ADB on this device, so an android.util.Log line explaining the
  /// failure is a line nobody can read.
  Future<String?> answer({void Function(String)? onFail}) async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('answerCall');
      final via = r?['via']?.toString();
      if (r?['success'] == true && via != null) {
        debugPrint('[AUTO-ANSWER] answered via $via');
        return via;
      }
      final why = r?['reason']?.toString() ?? 'no mechanism available';
      debugPrint('[AUTO-ANSWER] could not answer — $why');
      onFail?.call(why);
    } catch (e) {
      debugPrint('[AUTO-ANSWER] answer failed: $e');
      onFail?.call('$e');
    }
    return null;
  }

  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasAnswerPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for ANSWER_PHONE_CALLS. Returns once the dialog is up, not once it
  /// is answered — the grant lands on the next call, not this one.
  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestAnswerPermission');
    } catch (e) {
      debugPrint('[AUTO-ANSWER] permission request failed: $e');
    }
  }
}

/// Runs the policy against a ringing phone.
///
/// Holds the pending pickup so it can be cancelled — because the two things
/// that should cancel it both happen constantly: the wearer answers first, or
/// the caller gives up.
class AutoAnswerController {
  AutoAnswerController({
    required this.history,
    CallAnswerer? answerer,
    this.log,
  }) : _answerer = answerer ?? CallAnswerer();

  final CallHistory history;
  final CallAnswerer _answerer;
  final void Function(String)? log;

  Timer? _pending;
  String _pendingFor = '';

  bool get isPending => _pending != null;

  void _say(String m) {
    debugPrint('[AUTO-ANSWER] $m');
    log?.call(m);
  }

  /// The phone started ringing. Decide, and schedule if we are taking it.
  void onRinging(String number, AutoAnswerPolicy policy) {
    // The board reports the ring before the caller ID, so the first emission
    // has no number. Deciding on it produced a confusing "not answering an
    // unknown number" a millisecond before the real decision, and the outcome
    // for a genuinely withheld number is the same either way: it rings.
    if (number.isEmpty) return;
    if (_pendingFor == number && _pending != null) return;
    cancel();

    final onFile = history.threadFor(number)?.calls.isNotEmpty ?? false;
    final decision = policy.decide(number, onFile: onFile);
    final who = number.isEmpty ? 'an unknown number' : number;

    switch (decision) {
      case AnswerDecision.ignore:
        _say('$who is blocked — leaving it alone');
        return;
      case AnswerDecision.ring:
        _say('not answering $who — ${policy.mode == AutoAnswerMode.off ? "auto-answer is off" : "not on file"}');
        return;
      case AnswerDecision.answer:
        break;
    }

    _pendingFor = number;
    _say('answering $who in ${policy.ringFirst.inSeconds}s'
        '${onFile ? " (on file)" : ""}');
    _pending = Timer(policy.ringFirst, () async {
      _pending = null;
      _pendingFor = '';
      final via = await _answerer.answer(
          onFail: (why) => _say('could not answer $who — $why'));
      if (via != null) _say('picked up $who via $via');
    });
  }

  /// Someone else got there first, or the caller hung up.
  void cancel([String why = '']) {
    if (_pending == null) return;
    _pending?.cancel();
    _pending = null;
    _pendingFor = '';
    _say('pickup cancelled${why.isEmpty ? '' : ' — $why'}');
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}
