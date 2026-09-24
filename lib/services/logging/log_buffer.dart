import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// In-memory ring buffer of log lines, served over the local network.
///
/// There is no ADB access to this device, so `debugPrint` output is otherwise
/// unreadable — diagnosing anything meant guessing. [install] redirects the
/// global hook here so existing debugPrint calls throughout the app are
/// captured without touching a single call site.
class LogBuffer {
  LogBuffer._();
  static final LogBuffer instance = LogBuffer._();

  static const int maxLines = 1000;

  final List<String> _lines = <String>[];
  int get length => _lines.length;

  /// Wraps the global debugPrint. Safe in release builds — debugPrint is a
  /// plain function there, not stripped.
  static void install() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      instance.add(message);
      original(message, wrapWidth: wrapWidth);
    };
  }

  // ---- file persistence --------------------------------------------------
  //
  // The in-memory ring dies with the process, which is exactly the case worth
  // diagnosing: the launcher is killed mid-call, with the screen off, and takes
  // the evidence with it. Lines are mirrored to a file and flushed on a short
  // timer so at most half a second is lost when the process goes away.

  static const _bridge = MethodChannel('ai.fox1/call_bridge');
  static const int _maxFileBytes = 2 * 1024 * 1024;
  static const int _keepFiles = 6;

  File? _file;
  final List<String> _pending = <String>[];
  Timer? _flushTimer;

  String? get filePath => _file?.path;

  /// Starts mirroring to disk. Safe to call before the channel is ready — lines
  /// buffer in memory until the path arrives.
  Future<void> attachFile() async {
    if (_file != null) return;
    try {
      final dir = await _bridge.invokeMethod<String>('logsDir');
      if (dir == null) return;
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);

      _prune(d);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      _file = File('$dir/session-$stamp.log');
      _pending.insert(0, '=== session start ${DateTime.now()} ===');
      _flushTimer =
          Timer.periodic(const Duration(milliseconds: 500), (_) => _flush());
      _flush();
    } catch (e) {
      debugPrint('[LOG] file logging unavailable: $e');
    }
  }

  void _prune(Directory d) {
    try {
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final f in files.skip(_keepFiles - 1)) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  void _flush() {
    final f = _file;
    if (f == null || _pending.isEmpty) return;
    final chunk = _pending.join('\n');
    _pending.clear();
    try {
      // NO flush: true here. fsync blocks until the bytes reach physical
      // storage, and on this device's eMMC that can stall for seconds — twice a
      // second, on the isolate that feeds the call. It stalled the bridge long
      // enough for the board's RFCOMM to give up on us mid-call.
      //
      // It also buys nothing we need: the page cache belongs to the kernel once
      // write() returns, so the log survives the process being killed either
      // way. fsync only guards against power loss.
      f.writeAsStringSync('$chunk\n', mode: FileMode.append);
      if (f.lengthSync() > _maxFileBytes) {
        _file = null;
        attachFile();
      }
    } catch (_) {
      // Never let logging failure break anything that is logging.
    }
  }

  /// Newest first, for the download page.
  List<File> sessionFiles() {
    final f = _file;
    if (f == null) return const [];
    try {
      return f.parent
          .listSync()
          .whereType<File>()
          .where((x) => x.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    } catch (_) {
      return const [];
    }
  }

  void add(String? message) {
    if (message == null || message.isEmpty) return;
    final now = DateTime.now();
    final stamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final line = '$stamp  $message';
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    if (_file != null || _flushTimer == null) _pending.add(line);
    if (_pending.length > 2000) _pending.removeRange(0, _pending.length - 2000);
  }

  /// Newest last, optionally only lines containing [filter].
  String render({String? filter}) {
    final f = filter?.trim().toLowerCase();
    if (f == null || f.isEmpty) return _lines.join('\n');
    return _lines
        .where((l) => l.toLowerCase().contains(f))
        .join('\n');
  }

  void clear() => _lines.clear();
}
