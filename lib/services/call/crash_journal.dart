import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What was happening when the process died.
///
/// FOX-1 is the HOME launcher, so when the system kills it — low memory, an
/// uncaught throw — Android restarts it within seconds. The *call* does not
/// stop for any of that. Without this the wearer's phone is still connected to
/// somebody who is now talking to nothing: the board is unarmed, the Gemini
/// session is gone, and the conversation is unrecoverable and unfiled.
///
/// Written during a call and cleared when one ends cleanly. Finding it on
/// startup means the last run did not get to clear it.
@immutable
class CrashSnapshot {
  const CrashSnapshot({
    required this.number,
    required this.startedAt,
    required this.writtenAt,
    this.resumeHandle = '',
    this.deviceAddress = '',
    this.stage = 7,
  });

  final String number;
  final DateTime startedAt;

  /// When this snapshot was last written, which bounds how much we can trust
  /// it — see [isFresh].
  final DateTime writtenAt;

  /// Gemini session resumption handle, so the agent can pick the conversation
  /// up rather than restart it. May lag by a few seconds; that is fine.
  final String resumeHandle;

  final String deviceAddress;
  final int stage;

  int get durationS => DateTime.now().difference(startedAt).inSeconds;

  /// Old enough that whatever it describes is certainly over.
  ///
  /// A restart takes seconds. A snapshot from twenty minutes ago is a call
  /// that ended long before the crash, or one whose journal was never cleared
  /// because of a bug — either way, re-adopting on it would have the device
  /// seize an unrelated call.
  bool get isFresh =>
      DateTime.now().difference(writtenAt) < const Duration(minutes: 3);

  Map<String, dynamic> toJson() => {
        'number': number,
        'startedAt': startedAt.toIso8601String(),
        'writtenAt': writtenAt.toIso8601String(),
        if (resumeHandle.isNotEmpty) 'resumeHandle': resumeHandle,
        if (deviceAddress.isNotEmpty) 'deviceAddress': deviceAddress,
        'stage': stage,
      };

  factory CrashSnapshot.fromJson(Map<String, dynamic> j) => CrashSnapshot(
        number: j['number']?.toString() ?? '',
        startedAt: DateTime.tryParse(j['startedAt']?.toString() ?? '') ??
            DateTime.now(),
        writtenAt: DateTime.tryParse(j['writtenAt']?.toString() ?? '') ??
            DateTime.now(),
        resumeHandle: j['resumeHandle']?.toString() ?? '',
        deviceAddress: j['deviceAddress']?.toString() ?? '',
        stage: (j['stage'] as num?)?.toInt() ?? 7,
      );
}

/// What to do about a snapshot found on startup.
enum Recovery {
  /// Nothing was in progress.
  nothing,

  /// A call is still up on the device. Bring the bridge and the agent back to
  /// it before the caller notices.
  readopt,

  /// The call is over. Too late to rejoin, but the conversation still has to
  /// be filed rather than silently lost.
  fileOnly,
}

class CrashJournal {
  CrashJournal({MethodChannel? channel, MethodChannel? audio})
      : _channel =
            channel ?? const MethodChannel('ai.fox1/call_bridge'),
        _audio =
            audio ?? const MethodChannel('ai.fox1/audio');

  final MethodChannel _channel;
  final MethodChannel _audio;

  /// `AudioManager.MODE_IN_CALL`.
  static const _modeInCall = 2;

  /// Handles change several times a second. Writing the file that often would
  /// put a flash write in the path of every model turn, to save at most a few
  /// seconds of conversation.
  static const _handleWriteEvery = Duration(seconds: 10);

  File? _file;
  CrashSnapshot? _live;
  DateTime _lastHandleWrite = DateTime.fromMillisecondsSinceEpoch(0);
  String _address = '';
  int _stage = 7;

  Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    try {
      final dir = await _channel.invokeMethod<String>('dataDir');
      if (dir == null) return null;
      return _file = File('$dir/in_flight_call.json');
    } catch (e) {
      debugPrint('[RECOVER] no data dir: $e');
      return null;
    }
  }

  /// Which board, and at which stage, so a restart can go straight back.
  void bridgeStarted(String address, int stage) {
    _address = address;
    _stage = stage;
  }

  Future<void> callStarted(String number, DateTime startedAt) async {
    _live = CrashSnapshot(
      number: number,
      startedAt: startedAt,
      writtenAt: DateTime.now(),
      deviceAddress: _address,
      stage: _stage,
    );
    _lastHandleWrite = DateTime.fromMillisecondsSinceEpoch(0);
    await _write();
    debugPrint('[RECOVER] journalled a call with $number');
  }

  /// Throttled. Safe to call on every watchdog tick.
  Future<void> noteHandle(String? handle) async {
    final s = _live;
    if (s == null || handle == null || handle.isEmpty) return;
    if (handle == s.resumeHandle) return;
    if (DateTime.now().difference(_lastHandleWrite) < _handleWriteEvery) return;
    _lastHandleWrite = DateTime.now();
    _live = CrashSnapshot(
      number: s.number,
      startedAt: s.startedAt,
      writtenAt: DateTime.now(),
      resumeHandle: handle,
      deviceAddress: s.deviceAddress,
      stage: s.stage,
    );
    await _write();
  }

  /// The call ended the way it was supposed to. Nothing to recover.
  Future<void> callEnded() async {
    if (_live == null) return;
    _live = null;
    try {
      final f = await _ensureFile();
      if (f != null && await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[RECOVER] clear failed: $e');
    }
  }

  Future<void> _write() async {
    final s = _live;
    final f = await _ensureFile();
    if (s == null || f == null) return;
    try {
      await f.writeAsString(jsonEncode(s.toJson()), flush: false);
    } catch (e) {
      debugPrint('[RECOVER] write failed: $e');
    }
  }

  /// Read on startup. Returns null when the last run ended cleanly.
  Future<CrashSnapshot?> findUnfinished() async {
    try {
      final f = await _ensureFile();
      if (f == null || !await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      return CrashSnapshot.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('[RECOVER] read failed: $e');
      return null;
    }
  }

  /// Is a call still up on the device right now?
  ///
  /// Audio mode rather than the board: the board is exactly what we have lost,
  /// so asking it is circular. Telephony is the one source that survived the
  /// process dying.
  Future<bool> callStillLive() async {
    try {
      return await _audio.invokeMethod<int>('audioMode') == _modeInCall;
    } catch (e) {
      debugPrint('[RECOVER] audioMode failed: $e');
      return false;
    }
  }

  /// The decision, kept separate from the doing so it can be tested.
  static Recovery decide(CrashSnapshot? s, {required bool callLive}) {
    if (s == null) return Recovery.nothing;
    if (!s.isFresh) return Recovery.nothing;
    return callLive ? Recovery.readopt : Recovery.fileOnly;
  }
}
