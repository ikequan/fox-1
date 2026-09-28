import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ring/ring_ble.dart';

/// How big each screen read is — what the model gets from `get_screen`,
/// which stays in the Live conversation and is billed again on every later
/// turn. Logged as `[SCREEN]`; during a developer measurement
/// (`/api/dev/task`) the reads themselves are kept too.
///
/// In developer mode every read is also written to the screen log with the
/// raw accessibility tree beside it, so what the model was told can be checked
/// against what was really on screen (Hub: `/dev/screens`). The log holds
/// whatever the screens showed — messages, codes, contacts — so it is kept in
/// the app's internal storage, only while developer mode is on, for
/// [keepDays] days.
class ScreenCapture {
  ScreenCapture._();

  static bool capturing = false;
  static final List<String> captured = [];
  static int _count = 0;

  /// Whether reads go to the screen log. Set at startup to follow developer
  /// mode.
  static bool Function() logging = () => false;

  static const keepDays = 3;

  static void record(String screen, {Map? raw}) {
    _count++;
    final ids = RegExp(r'^\[\d+\]', multiLine: true).allMatches(screen).length;
    debugPrint('[SCREEN] read $_count: ${screen.length} chars ≈ ${screen.length ~/ 4} tokens, $ids to act on');
    if (capturing && captured.length < 300) captured.add(screen);
    if (raw != null) unawaited(_log(_count, screen, raw));
  }

  static void start() {
    captured.clear();
    capturing = true;
  }

  // ------------------------------------------------------------ the log

  static Future<Directory?> _dir() async {
    final files = (await RingBle.healthDir())?.parent;
    return files == null ? null : Directory('${files.path}/screen_log');
  }

  static String _day(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static Future<void> _log(int n, String compact, Map raw) async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      await dir.create(recursive: true);
      final now = DateTime.now();
      final rawJson = jsonEncode(raw);
      final entry = {
        'at': now.toIso8601String(),
        'read': n,
        'compact': compact,
        'compactTokens': compact.length ~/ 4,
        'rawTokens': (rawJson.length / 3.5).round(),
        'raw': raw,
      };
      await File('${dir.path}/${_day(now)}.jsonl')
          .writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
      await _prune(dir, now);
    } catch (e) {
      debugPrint('[SCREEN] log: $e');
    }
  }

  static Future<void> _prune(Directory dir, DateTime now) async {
    final oldest = _day(now.subtract(const Duration(days: keepDays - 1)));
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.jsonl') && name.compareTo('$oldest.jsonl') < 0) await f.delete();
    }
  }

  /// The days the log has, newest first.
  static Future<List<String>> days() async {
    final dir = await _dir();
    if (dir == null || !await dir.exists()) return [];
    final out = <String>[];
    await for (final f in dir.list()) {
      if (f.path.endsWith('.jsonl')) out.add(f.uri.pathSegments.last.replaceAll('.jsonl', ''));
    }
    return out..sort((a, b) => b.compareTo(a));
  }

  /// One day's reads, oldest first.
  static Future<List<Map<String, dynamic>>> read(String day) async {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) return [];
    final dir = await _dir();
    if (dir == null) return [];
    final f = File('${dir.path}/$day.jsonl');
    if (!await f.exists()) return [];
    return [
      for (final line in await f.readAsLines())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  static Future<void> clear() async {
    final dir = await _dir();
    if (dir != null && await dir.exists()) await dir.delete(recursive: true);
  }
}
