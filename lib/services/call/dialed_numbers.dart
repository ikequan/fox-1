import 'package:flutter/foundation.dart';

import '../platform/phone_service.dart';
import 'call_history.dart';

/// Which number an outgoing call is to.
///
/// The board reports an outgoing call as `[0,2] dialling` and never sends a
/// caller ID for one — there is nobody to identify, from its point of view. So
/// without this an outbound call has no key, and everything said on it is
/// dropped: one ran 195 seconds and produced a commitment, an action item and
/// a claim, none of which could be filed.
///
/// That breaks the case the whole feature exists for:
///
/// ```
/// wearer  → main agent: "call the printer for an update"
/// main    → make_call(0200000003)
/// printer:  "we'll ring you back in thirty minutes"
///    … later …
/// printer rings in
/// call agent picks up ALREADY KNOWING about the job and the promised callback
/// ```
///
/// Two sources, because they become available at different moments:
///
///  * **What we dialled ourselves** — exact, and available the instant the call
///    starts, so the agent can be briefed before it says hello. This is the
///    path the flow above takes.
///  * **The call log** — for a number the wearer dialled by hand. Android only
///    writes the entry when the call *ends*, so this cannot brief the call it
///    belongs to. It can still file it, which means the *next* call from that
///    number is briefed.
class DialedNumbers {
  DialedNumbers({PhoneService? phone}) : _phone = phone ?? PhoneService();

  final PhoneService _phone;

  String _last = '';
  String _task = '';
  DateTime? _at;

  /// Record a number this device is dialling, and why.
  ///
  /// The [task] is what turns an outbound call from "a machine rang you" into
  /// a dispatched errand — the agent opens the call already knowing it is
  /// chasing the printing job, so the person answering is not left working out
  /// why they have been telephoned.
  void note(String number, {String task = ''}) {
    final n = number.trim();
    if (n.isEmpty) return;
    _last = n;
    _task = task.trim();
    _at = DateTime.now();
    debugPrint('[DIALED] $n${_task.isEmpty ? '' : ' — $_task'}');
  }

  /// Why we rang them, if this is the call we just placed.
  ///
  /// Bounded in time exactly like [recent], and for a sharper reason. Without
  /// the bound an errand outlived its call: a dispatch at 22:54 was still on
  /// file when the same person rang IN at 22:58, so the agent was briefed as
  /// though it had been sent to call them — and opened with "I checked with
  /// Alex and he says the kids don't need anything", a check that never
  /// happened. A stale errand does not merely mislabel the call; it invents
  /// work the agent then reports as done.
  String taskFor(String number, {Duration within = const Duration(minutes: 2)}) {
    if (_task.isEmpty) return '';
    final at = _at;
    if (at == null || DateTime.now().difference(at) > within) return '';
    return CallHistory.keyFor(number) == CallHistory.keyFor(_last) ? _task : '';
  }

  /// The errand is spent — this call was it.
  ///
  /// The time bound above is the safety net; this is the correct moment. Only
  /// clears when the number matches, so a call that interrupts a dispatch does
  /// not discard it.
  void noteCallEnded(String number) {
    if (_last.isEmpty) return;
    if (CallHistory.keyFor(number) != CallHistory.keyFor(_last)) return;
    _doneNumber = _last;
    _doneTask = _task;
    _doneAt = DateTime.now();
    clear();
  }

  String _doneNumber = '';
  String _doneTask = '';
  DateTime? _doneAt;

  /// What we last finished asking this number, if it was recent.
  ///
  /// The main agent dispatches a call, gets the answer back as a report, and
  /// then — with the original "call Emma and ask about the game" still sitting
  /// in its context — dispatches the same errand again. Observed four times for
  /// one question, the last firing 1.6 seconds after the report arrived, with
  /// nothing from the wearer in between. A person's phone rang four times.
  ///
  /// The model is told the errand is finished (see PendingReports.briefing),
  /// but a prompt is guidance and this is somebody's evening.
  ({Duration ago, String task})? completedFor(
    String number, {
    Duration within = const Duration(minutes: 3),
  }) {
    final at = _doneAt;
    if (at == null || _doneNumber.isEmpty) return null;
    final ago = DateTime.now().difference(at);
    if (ago > within) return null;
    if (CallHistory.keyFor(number) != CallHistory.keyFor(_doneNumber)) {
      return null;
    }
    return (ago: ago, task: _doneTask);
  }

  /// The wearer said something — the previous errand no longer blocks a fresh
  /// call to the same person.
  ///
  /// Called whenever the wearer speaks, because the loop being guarded against
  /// is precisely the agent re-dispatching with no human in the exchange. A
  /// blanket "no calls to this number for three minutes" was wrong: it refused
  /// "also ask him to bring the GTA disc" as a duplicate of the controller
  /// errand thirty seconds earlier, which is a different thing entirely and
  /// exactly what the wearer had just asked for.
  void allowRedial() {
    _doneNumber = '';
    _doneTask = '';
    _doneAt = null;
  }

  /// The number we dialled, if it was recent enough to be this call.
  ///
  /// Bounded in time so a call an hour ago cannot label an unrelated one. A
  /// missed window costs a briefing; a stale hit files a conversation under
  /// the wrong person, which is worse and much harder to notice.
  String recent({Duration within = const Duration(minutes: 2)}) {
    final at = _at;
    if (at == null || _last.isEmpty) return '';
    return DateTime.now().difference(at) <= within ? _last : '';
  }

  void clear() {
    _last = '';
    _task = '';
    _at = null;
  }

  /// Last resort, at the end of a call: what does the call log say we rang?
  ///
  /// Only useful once the call has ended, which is exactly when history is
  /// filed. Returns '' rather than guessing when nothing matches.
  Future<String> lastOutgoing({
    Duration within = const Duration(minutes: 15),
  }) async {
    try {
      final res = await _phone.getCallHistory(limit: 8);
      if (res['success'] != true) return '';
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final e in (res['history'] as List).cast<Map<String, dynamic>>()) {
        if (e['type']?.toString() != 'outgoing') continue;
        final ms = (e['date_ms'] as num?)?.toInt();
        // No timestamp means we cannot bound it, and an unbounded match could
        // file this call under whoever was rung last week.
        if (ms == null || now - ms > within.inMilliseconds) continue;
        final n = e['phone_number']?.toString().trim() ?? '';
        if (n.isNotEmpty) return n;
      }
    } catch (e) {
      debugPrint('[DIALED] call log lookup failed: $e');
    }
    return '';
  }
}
