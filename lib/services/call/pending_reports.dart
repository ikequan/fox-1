import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_report.dart';

/// Things the wearer has not been told yet.
///
/// A call ends and the agent tries to pass the message on straight away. Often
/// nobody answers — the device is on a desk, the wearer is driving, the screen
/// is off. The message must not evaporate because the first attempt missed;
/// it waits here and goes out on the next conversation instead.
///
/// Persisted, because "the app restarted" is not a reason for a message to
/// disappear either.
class PendingReports {
  PendingReports({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('ai.fox1/call_bridge');

  final MethodChannel _channel;

  /// Beyond this the wearer is being read a backlog, not a message. The oldest
  /// fall off; they are still in the call history if anyone asks.
  static const _max = 10;

  final List<CallReport> _queue = [];
  File? _file;
  bool _loaded = false;

  bool get isEmpty => _queue.isEmpty;
  int get length => _queue.length;
  List<CallReport> get all => List.unmodifiable(_queue);

  Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    try {
      final dir = await _channel.invokeMethod<String>('dataDir');
      return dir == null ? null : _file = File('$dir/pending_reports.json');
    } catch (e) {
      debugPrint('[PENDING] no data dir: $e');
      return null;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _ensureFile();
      if (f == null || !await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return;
      for (final e in raw) {
        if (e is Map) {
          _queue.add(_fromJson(Map<String, dynamic>.from(e)));
        }
      }
      if (_queue.isNotEmpty) {
        debugPrint('[PENDING] ${_queue.length} message(s) still undelivered');
      }
    } catch (e) {
      debugPrint('[PENDING] load failed: $e');
    }
  }

  Future<void> add(CallReport r) async {
    _queue.add(r);
    if (_queue.length > _max) _queue.removeRange(0, _queue.length - _max);
    debugPrint('[PENDING] queued a message about ${r.number}'
        ' (${_queue.length} waiting)');
    await _save();
  }

  /// The wearer has heard them.
  Future<void> clear() async {
    if (_queue.isEmpty) return;
    debugPrint('[PENDING] ${_queue.length} message(s) delivered');
    _queue.clear();
    await _save();
  }

  /// What the main agent should say, written as an instruction to it rather
  /// than as a script — it knows the wearer's name and how it usually speaks.
  ///
  /// Claims are marked here for the same reason they are marked everywhere
  /// else: the wearer must be able to hear the difference between what
  /// happened and what someone said happened.
  String briefing({required String wearer}) {
    if (_queue.isEmpty) return '';
    final who = wearer.trim().isEmpty ? 'your owner' : wearer.trim();
    final b = StringBuffer();
    b.writeln('[Messages from calls that have ALREADY HAPPENED and are '
        'finished. Not spoken by anyone — pass them on.]');
    b.writeln('Tell $who about ${_queue.length == 1 ? 'this' : 'these'} now, '
        'in one or two short sentences. Lead with who called. Do not read it '
        'out as a list and do not repeat it once it is delivered.');
    // Without this the model reads the report, finds its own original errand
    // still in context, and dispatches the same call again — four times for one
    // question in testing, the last 1.6 s after this text arrived.
    b.writeln('These errands are COMPLETE. Do NOT call any of these people '
        'back about them, and do not use make_call to check or confirm what is '
        'written below — it is already the answer. Only call again if $who '
        'asks you for something new.');
    for (final r in _queue) {
      final name = r.contactName?.isNotEmpty == true ? r.contactName : r.number;
      b.writeln('- $name called${r.durationS > 0 ? ' (${r.durationS}s)' : ''}: '
          '${r.summary.isEmpty ? 'no summary was captured' : r.summary}');
      for (final c in r.commitments) {
        b.writeln('    you promised them: $c');
      }
      for (final a in r.actionItems) {
        b.writeln('    they need $who to: $a');
      }
      if (r.callbackRequested) {
        b.writeln('    they asked to be called back');
      }
      for (final c in r.callerAsserted) {
        b.writeln('    they CLAIMED (unverified, say so if you mention it): $c');
      }
    }
    return b.toString();
  }

  Future<void> _save() async {
    final f = await _ensureFile();
    if (f == null) return;
    try {
      await f.writeAsString(
          jsonEncode(_queue.map(_toJson).toList()), flush: false);
    } catch (e) {
      debugPrint('[PENDING] save failed: $e');
    }
  }

  static Map<String, dynamic> _toJson(CallReport r) => {
        'number': r.number,
        if (r.contactName != null) 'contactName': r.contactName,
        if (r.startedAt != null) 'startedAt': r.startedAt!.toIso8601String(),
        'durationS': r.durationS,
        'summary': r.summary,
        'commitments': r.commitments,
        'actionItems': r.actionItems,
        'callerAsserted': r.callerAsserted,
        'callbackRequested': r.callbackRequested,
        'unresolved': r.unresolved,
      };

  static CallReport _fromJson(Map<String, dynamic> j) => CallReport(
        number: j['number']?.toString() ?? '',
        contactName: j['contactName']?.toString(),
        startedAt: DateTime.tryParse(j['startedAt']?.toString() ?? ''),
        durationS: (j['durationS'] as num?)?.toInt() ?? 0,
        summary: j['summary']?.toString() ?? '',
        commitments: _strings(j['commitments']),
        actionItems: _strings(j['actionItems']),
        callerAsserted: _strings(j['callerAsserted']),
        callbackRequested: j['callbackRequested'] == true,
        unresolved: j['unresolved'] == true,
      );

  static List<String> _strings(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : const [];
}
