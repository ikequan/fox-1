import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ring/ring_ble.dart';

/// One thing said in a conversation with the assistant: by the wearer, by it, or
/// a tool she used.
class Said {
  Said(this.at, this.role, this.text);

  final DateTime at;

  /// `user`, `assistant` or `tool`.
  final String role;
  String text;

  Map<String, Object> toJson() => {'t': at.toIso8601String(), 'role': role, 'text': text};

  static Said? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['t']}');
    final role = '${j['role'] ?? ''}', text = '${j['text'] ?? ''}';
    if (at == null || role.isEmpty || text.isEmpty) return null;
    return Said(at, role, text);
  }
}

/// Entries close enough together to be one conversation.
class Conversation {
  Conversation(this.entries);

  /// Oldest first; never empty.
  final List<Said> entries;

  DateTime get start => entries.first.at;
  DateTime get end => entries.last.at;
  String get id => start.toIso8601String();

  /// Things said, not tools used.
  int get turns => entries.where((e) => e.role != 'tool').length;

  /// The first thing the wearer said — what the conversation was about.
  String get preview {
    final t = entries
        .firstWhere((e) => e.role == 'user', orElse: () => entries.first)
        .text;
    return t.length > 140 ? '${t.substring(0, 140)}…' : t;
  }

  Map<String, Object> toJson({bool withEntries = true}) => {
        'id': id,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'turns': turns,
        'preview': preview,
        if (withEntries) 'entries': [for (final e in entries) e.toJson()],
      };
}

/// What was said with the assistant, kept on the device as it happens — the
/// portal's conversation history.
///
/// One JSON-lines file per day under the internal `files/conversations/`,
/// appended to; nothing is rewritten. Speech arrives in fragments (Gemini
/// transcribes as it goes), so a fragment that continues the same speaker's
/// turn is added to it, and the turn is written once it settles. Tool
/// results are not kept — one can be a whole screen tree, and the call says
/// enough. Files older than [keepDays] are removed.
class ConversationStore {
  ConversationStore({
    Future<Directory?> Function()? directory,
    this.settle = const Duration(seconds: 4),
    this.keepDays = 365,
    DateTime Function()? now,
  })  : _directory = directory ?? _defaultDir,
        _now = now ?? DateTime.now;

  /// Internal storage, beside the notes: what the wearer said is nobody
  /// else's business.
  static Future<Directory?> _defaultDir() async {
    final health = await RingBle.healthDir();
    return health == null ? null : Directory('${health.parent.path}/conversations');
  }

  /// Fragments of one speaker's turn this close together are one entry.
  static const mergeWithin = Duration(seconds: 30);

  /// Entries further apart than this are separate conversations.
  static const conversationGap = Duration(minutes: 10);

  final Future<Directory?> Function() _directory;
  final DateTime Function() _now;

  /// A turn with no new fragment for this long is written out.
  final Duration settle;
  final int keepDays;

  Directory? _root;
  bool _pruned = false;
  Said? _open;
  DateTime? _openLast;
  Timer? _settleTimer;
  Future<void> _writing = Future.value();

  /// Takes what `AISession.transcript` emits — role `user`, `assistant` or
  /// `system` (a tool call, or its result).
  void addTranscript(String role, String text, DateTime at) {
    final r = switch (role) {
      'user' => 'user',
      'assistant' => 'assistant',
      'system' => 'tool',
      _ => '',
    };
    if (r.isEmpty || text.trim().isEmpty) return;
    var t = text;
    if (r == 'tool') {
      if (t.startsWith('Done:') || t.startsWith('Error:')) return;
      // "NativeTools+OpenClaw: read_note({id: latest})" — the provider is
      // plumbing, not something the wearer did.
      final i = t.indexOf(': ');
      if (i >= 0) t = t.substring(i + 2);
      t = t.trim();
      if (t.length > 160) t = '${t.substring(0, 160)}…';
    }
    final open = _open, last = _openLast;
    if (open != null &&
        last != null &&
        r != 'tool' &&
        open.role == r &&
        at.difference(last) < mergeWithin) {
      open.text += t;
      _openLast = at;
    } else {
      unawaited(flush());
      _open = Said(at, r, t);
      _openLast = at;
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, () => unawaited(flush()));
  }

  /// Writes the turn in progress, if any.
  Future<void> flush() {
    final s = _open;
    _open = null;
    _openLast = null;
    _settleTimer?.cancel();
    if (s == null) return _writing;
    s.text = _tidy(s.text);
    if (s.text.isEmpty) return _writing;
    return _writing = _writing.then((_) => _append(s)).catchError((Object e) {
      debugPrint('[CONVERSATIONS] could not save: $e');
    });
  }

  static String _tidy(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<Directory?> _dir() async {
    final d = _root ??= await _directory();
    if (d == null) return null;
    if (!await d.exists()) await d.create(recursive: true);
    if (!_pruned) {
      _pruned = true;
      await _prune(d);
    }
    return d;
  }

  Future<void> _prune(Directory d) async {
    final today = _now();
    final cutoff = dayKey(DateTime(today.year, today.month, today.day - keepDays));
    await for (final e in d.list()) {
      final name = e.uri.pathSegments.last;
      if (e is File && name.endsWith('.jsonl') && name.compareTo('$cutoff.jsonl') < 0) {
        await e.delete();
      }
    }
  }

  Future<void> _append(Said s) async {
    final d = await _dir();
    if (d == null) return;
    await File('${d.path}/${dayKey(s.at)}.jsonl')
        .writeAsString('${jsonEncode(s.toJson())}\n', mode: FileMode.append, flush: true);
  }

  /// Everything said on [day], oldest first — including a turn not yet
  /// written.
  Future<List<Said>> entriesOn(DateTime day) async {
    await _writing;
    final key = dayKey(day);
    final out = <Said>[];
    final d = await _dir();
    final f = d == null ? null : File('${d.path}/$key.jsonl');
    if (f != null && await f.exists()) {
      for (final line in await f.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final s = Said.fromJson(jsonDecode(line));
          if (s != null) out.add(s);
        } catch (_) {
          // A line cut short by a crash is skipped, not fatal.
        }
      }
    }
    final open = _open;
    if (open != null && dayKey(open.at) == key) {
      out.add(Said(open.at, open.role, _tidy(open.text)));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// [day]'s conversations, oldest first.
  Future<List<Conversation>> on(DateTime day) async => group(await entriesOn(day));

  /// Splits [entries] (oldest first) wherever more than [conversationGap]
  /// passes without a word.
  static List<Conversation> group(List<Said> entries) {
    final out = <Conversation>[];
    List<Said>? current;
    for (final e in entries) {
      if (current == null || e.at.difference(current.last.at) > conversationGap) {
        current = [];
        out.add(Conversation(current));
      }
      current.add(e);
    }
    return out;
  }

  /// Days with anything said, newest first.
  Future<List<({String day, int conversations, int turns})>> days({int limit = 30}) async {
    final out = <({String day, int conversations, int turns})>[];
    for (final key in (await _dayKeys()).take(limit)) {
      final c = await on(DateTime.parse(key));
      if (c.isEmpty) continue;
      out.add((
        day: key,
        conversations: c.length,
        turns: c.fold(0, (n, x) => n + x.turns),
      ));
    }
    return out;
  }

  /// Entries holding every word of [query], newest first, over the last
  /// [withinDays] days.
  Future<List<({String day, Conversation conversation, Said said})>> search(
    String query, {
    int withinDays = 90,
    int limit = 50,
  }) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final hits = <({String day, Conversation conversation, Said said})>[];
    if (words.isEmpty) return hits;
    final today = _now();
    final oldest = dayKey(DateTime(today.year, today.month, today.day - withinDays));
    for (final key in await _dayKeys()) {
      if (key.compareTo(oldest) < 0) break;
      final conversations = await on(DateTime.parse(key));
      for (final c in conversations.reversed) {
        for (final s in c.entries.reversed) {
          final t = s.text.toLowerCase();
          if (!words.every(t.contains)) continue;
          hits.add((day: key, conversation: c, said: s));
          if (hits.length >= limit) return hits;
        }
      }
    }
    return hits;
  }

  /// Newest first.
  Future<List<String>> _dayKeys() async {
    await _writing;
    final keys = <String>{};
    final d = await _dir();
    if (d != null) {
      await for (final e in d.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File && name.endsWith('.jsonl')) {
          keys.add(name.substring(0, name.length - 6));
        }
      }
    }
    final open = _open;
    if (open != null) keys.add(dayKey(open.at));
    return keys.toList()..sort((a, b) => b.compareTo(a));
  }

  void dispose() {
    unawaited(flush());
  }
}
