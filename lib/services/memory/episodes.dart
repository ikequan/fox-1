import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../conversation/conversation_store.dart';
import '../ring/ring_ble.dart';

/// One conversation with the wearer, remembered the way people remember:
/// the key points while it is fresh, a summary after a day, a gist after a
/// week. Nothing is thrown away — the points, the summary and the words
/// themselves (in [ConversationStore]) are all kept; what fades is how much
/// comes back unasked.
///
/// This is why a conversation can end: the next one starts fresh, briefed
/// with today's key points, instead of re-sending the last one word for word
/// on every turn — 56,738 tokens by the end of one morning, most of it old
/// speech billed as audio.
class Episode {
  Episode({
    required this.start,
    required this.end,
    this.gist = '',
    this.summary = '',
    this.points = const [],
    this.asked = const [],
    this.pending = true,
    this.strikes = 0,
  });

  final DateTime start;
  DateTime end;

  /// One line: what the conversation was about.
  String gist;

  /// Two to four sentences.
  String summary;

  /// The key points: requests, outcomes, names, numbers, what is still open.
  List<String> points;

  /// The wearer's first requests, word for word — what stands in for the
  /// points until they are written, so a conversation is never blank.
  List<String> asked;

  /// Not yet written by the model.
  bool pending;

  /// Failed writes that were the model's fault, not the network's.
  int strikes;

  String get id => start.toIso8601String();

  static const maxStrikes = 4;

  Map<String, Object?> toJson() => {
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'gist': gist,
        'summary': summary,
        'points': points,
        'asked': asked,
        'pending': pending,
        'strikes': strikes,
      };

  static Episode? fromJson(Object? j) {
    if (j is! Map) return null;
    final start = DateTime.tryParse('${j['start']}');
    final end = DateTime.tryParse('${j['end']}');
    if (start == null || end == null) return null;
    List<String> list(Object? v) => [for (final x in (v as List? ?? const [])) '$x'];
    return Episode(
      start: start,
      end: end,
      gist: '${j['gist'] ?? ''}',
      summary: '${j['summary'] ?? ''}',
      points: list(j['points']),
      asked: list(j['asked']),
      pending: j['pending'] == true,
      strikes: (j['strikes'] as num?)?.toInt() ?? 0,
    );
  }

  /// How much of it comes back without asking, by age.
  static Recall levelFor(Duration age) => age < const Duration(days: 1)
      ? Recall.points
      : age < const Duration(days: 7)
          ? Recall.summary
          : Recall.gist;

  /// What the agent is given at [level]. Falls back down the levels, and to
  /// the wearer's own words while it is still being written.
  String at(Recall level) {
    final stand = asked.isEmpty ? '' : 'Asked: ${asked.map((a) => '"$a"').join('; ')}';
    String first(List<String> xs) => xs.firstWhere((x) => x.trim().isNotEmpty, orElse: () => '');
    return switch (level) {
      Recall.points => first([points.join('; '), summary, gist, stand]),
      Recall.summary => first([summary, gist, points.join('; '), stand]),
      Recall.gist => first([gist, summary, stand]),
    };
  }

  /// "Mon 28 Sep, 11:12–11:31".
  String get when => '${DateFormat('EEE d MMM, HH:mm').format(start)}–${DateFormat('HH:mm').format(end)}';
}

enum Recall { points, summary, gist }

/// Episodes on disk: one JSON file per day under the internal
/// `files/episodes/`, beside the conversations they summarise.
class EpisodeStore {
  EpisodeStore({Future<Directory?> Function()? directory, DateTime Function()? now})
      : _directory = directory ?? _defaultDir,
        _now = now ?? DateTime.now;

  static Future<Directory?> _defaultDir() async {
    final health = await RingBle.healthDir();
    return health == null ? null : Directory('${health.parent.path}/episodes');
  }

  final Future<Directory?> Function() _directory;
  final DateTime Function() _now;
  Directory? _root;
  Future<void> _writing = Future.value();

  Future<Directory?> _dir() async {
    final d = _root ??= await _directory();
    if (d != null && !await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File?> _file(DateTime day) async {
    final d = await _dir();
    return d == null ? null : File('${d.path}/${ConversationStore.dayKey(day)}.json');
  }

  /// [day]'s episodes, oldest first.
  Future<List<Episode>> on(DateTime day) async {
    await _writing;
    final f = await _file(day);
    if (f == null || !await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      return [for (final j in list) ?Episode.fromJson(j)]..sort((a, b) => a.start.compareTo(b.start));
    } catch (e) {
      debugPrint('[MEMORY] unreadable episodes for ${ConversationStore.dayKey(day)}: $e');
      return [];
    }
  }

  /// Adds [e], or replaces the episode with its start.
  Future<void> save(Episode e) => _writing = _writing.then((_) async {
        final f = await _file(e.start);
        if (f == null) return;
        final all = <Episode>[];
        if (await f.exists()) {
          try {
            all.addAll([for (final j in jsonDecode(await f.readAsString()) as List) ?Episode.fromJson(j)]);
          } catch (_) {}
        }
        all.removeWhere((x) => x.id == e.id);
        all.add(e);
        all.sort((a, b) => a.start.compareTo(b.start));
        await f.writeAsString(jsonEncode([for (final x in all) x.toJson()]), flush: true);
      }).catchError((Object err) {
        debugPrint('[MEMORY] could not save an episode: $err');
      });

  /// Day keys that have episodes, newest first.
  Future<List<String>> _days() async {
    final d = await _dir();
    if (d == null) return [];
    final keys = [
      for (final e in d.listSync())
        if (e is File && e.path.endsWith('.json')) e.uri.pathSegments.last.replaceAll('.json', ''),
    ]..sort((a, b) => b.compareTo(a));
    return keys;
  }

  /// Episodes from the last [days] days, oldest first.
  Future<List<Episode>> recent({int days = 2}) async {
    final now = _now();
    final out = <Episode>[];
    for (var i = days - 1; i >= 0; i--) {
      out.addAll(await on(now.subtract(Duration(days: i))));
    }
    return out;
  }

  /// Episodes whose words match every word of [query], newest first.
  Future<List<Episode>> search(String query, {int limit = 5}) async {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    final out = <Episode>[];
    for (final key in await _days()) {
      final day = DateTime.parse(key);
      for (final e in (await on(day)).reversed) {
        final text = [e.gist, e.summary, ...e.points, ...e.asked].join(' ').toLowerCase();
        if (words.every(text.contains)) out.add(e);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// The newest episodes, newest first.
  Future<List<Episode>> latest({int limit = 5}) async {
    final out = <Episode>[];
    for (final key in await _days()) {
      out.addAll((await on(DateTime.parse(key))).reversed);
      if (out.length >= limit) break;
    }
    return out.take(limit).toList();
  }

  /// Unwritten episodes from the last few days, oldest first.
  Future<List<Episode>> pending() async =>
      (await recent(days: 3)).where((e) => e.pending && e.strikes < Episode.maxStrikes).toList();
}

/// What the new conversation is told about today's earlier ones. Newest in
/// full; when over [maxChars], older ones fade to their summary, then gist —
/// the same fading as across days, within one.
String episodeBriefing(List<Episode> today, {int maxChars = 1800}) {
  if (today.isEmpty) return '';
  final lines = <String>[];
  var used = 0;
  for (final e in today.reversed) {
    final left = maxChars - used;
    String line = '';
    for (final level in Recall.values) {
      final t = '${DateFormat('HH:mm').format(e.start)} — ${e.at(level)}';
      if (t.length <= left) {
        line = t;
        break;
      }
    }
    if (line.isEmpty) break;
    lines.insert(0, line);
    used += line.length + 1;
  }
  if (lines.isEmpty) return '';
  return '[Earlier today — background you remember. Do not recite it; use it '
      'when it is relevant. recall_conversations has more.]\n${lines.join('\n')}';
}

/// Writes an episode's gist, summary and key points with a small text
/// model, from the words of the conversation.
class EpisodeWriter {
  EpisodeWriter({required this.apiKey, http.Client? client, this.models = defaultModels})
      : _client = client ?? http.Client();

  /// Cheapest first. Aliases before pinned names, so a retired model does
  /// not quietly stop the writing.
  static const defaultModels = ['gemini-flash-lite-latest', 'gemini-2.5-flash-lite', 'gemini-flash-latest'];

  static const _base = 'https://generativelanguage.googleapis.com';

  /// The conversation sent is cut to this many characters (about 6k tokens).
  static const maxInput = 24000;

  final String Function() apiKey;
  final http.Client _client;
  final List<String> models;

  /// USD per million tokens for the writing models — a table, not fetched,
  /// with the same caveat as `LivePrices`.
  static const priceIn = 0.10, priceOut = 0.40;

  /// Fills in [e] from [said] and returns what it cost. Throws
  /// [EpisodeWriteError].
  Future<double> write(Episode e, List<Said> said, {String name = 'FOX-1'}) async {
    final key = apiKey().trim();
    if (key.isEmpty) throw EpisodeWriteError('no Gemini API key', network: true);
    final body = jsonEncode(request(said, e.start, name));
    EpisodeWriteError? last;
    for (final model in models) {
      final http.Response r;
      try {
        r = await _client
            .post(Uri.parse('$_base/v1beta/models/$model:generateContent'),
                headers: {'Content-Type': 'application/json', 'x-goog-api-key': key}, body: body)
            .timeout(const Duration(seconds: 45));
      } catch (err) {
        throw EpisodeWriteError('could not reach Gemini: $err', network: true);
      }
      if (r.statusCode == 404) {
        last = EpisodeWriteError('model $model is not served', network: true);
        continue;
      }
      final j = parse(r.statusCode, r.body);
      e
        ..gist = j.gist
        ..summary = j.summary
        ..points = j.points
        ..pending = false;
      return cost(r.body);
    }
    throw last ?? EpisodeWriteError('no model to write with', network: true);
  }

  /// From the reply's usageMetadata; nothing if it has none.
  static double cost(String body) {
    try {
      final u = (jsonDecode(body) as Map)['usageMetadata'] as Map? ?? const {};
      int n(String k) => (u[k] as num?)?.toInt() ?? 0;
      return n('promptTokenCount') * priceIn / 1e6 +
          (n('candidatesTokenCount') + n('thoughtsTokenCount')) * priceOut / 1e6;
    } catch (_) {
      return 0;
    }
  }

  static String transcript(List<Said> said, String name) {
    final lines = [
      for (final s in said)
        '${DateFormat('HH:mm').format(s.at)} ${switch (s.role) {
          'user' => 'Wearer',
          'assistant' => name,
          _ => '[tool]',
        }}: ${s.role == 'tool' && s.text.length > 200 ? '${s.text.substring(0, 200)}…' : s.text}',
    ];
    var text = lines.join('\n');
    // Keep the end: it holds the outcomes.
    if (text.length > maxInput) text = '…\n${text.substring(text.length - maxInput)}';
    return text;
  }

  static Map<String, Object?> request(List<Said> said, DateTime start, String name) => {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {
                'text': 'Below is a conversation between the wearer of a smartwatch and '
                    'their assistant, $name, on ${DateFormat('EEEE d MMMM yyyy').format(start)}. '
                    'Write $name\'s memory of it, the way a person remembers a '
                    'conversation: not sentence by sentence, only what matters later.\n'
                    '- gist: one line, at most 15 words, what it was about.\n'
                    '- summary: two to four sentences: what was asked, what was done '
                    'and how it ended.\n'
                    '- points: up to 10 short key points: each request and its outcome '
                    '(done, failed and why, or still open), names, numbers, times, '
                    'decisions, and any preference the wearer stated.\n'
                    'Only what happened in the conversation; never invent. Lines marked '
                    '[tool] are $name\'s actions on the device.\n\n'
                    '${transcript(said, name)}',
              },
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': {
            'type': 'OBJECT',
            'properties': {
              'gist': {'type': 'STRING'},
              'summary': {'type': 'STRING'},
              'points': {
                'type': 'ARRAY',
                'items': {'type': 'STRING'},
              },
            },
            'required': ['gist', 'summary', 'points'],
          },
          'temperature': 0.2,
        },
      };

  static ({String gist, String summary, List<String> points}) parse(int status, String body) {
    if (status != 200) {
      final transient = status == 429 || status >= 500 || status == 401 || status == 403;
      throw EpisodeWriteError('Gemini answered $status', network: transient);
    }
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final parts = (((j['candidates'] as List).first as Map)['content'] as Map)['parts'] as List;
      final text = [for (final p in parts) if (p is Map && p['text'] is String) p['text']].join();
      final m = jsonDecode(text) as Map<String, dynamic>;
      final points = [
        for (final p in (m['points'] as List? ?? const []))
          if ('$p'.trim().isNotEmpty) '$p'.trim(),
      ];
      final gist = '${m['gist'] ?? ''}'.trim();
      if (gist.isEmpty && points.isEmpty) throw const FormatException('empty');
      return (gist: gist, summary: '${m['summary'] ?? ''}'.trim(), points: points);
    } catch (e) {
      throw EpisodeWriteError('unusable reply: $e');
    }
  }
}

class EpisodeWriteError implements Exception {
  EpisodeWriteError(this.message, {this.network = false});
  final String message;

  /// Not the conversation's fault — does not count toward giving up.
  final bool network;

  @override
  String toString() => message;
}

/// `recall_conversations`: the agent looking back. Recent conversations come
/// back in detail, older ones fainter; asking for `full` or `words` always
/// gets everything, so nothing is out of reach.
class EpisodeTools {
  EpisodeTools(this.store, this.conversations, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final EpisodeStore store;
  final ConversationStore conversations;
  final DateTime Function() _now;

  static const names = {'recall_conversations'};

  static const declarations = [
    {
      'name': 'recall_conversations',
      'description': 'Look back at earlier conversations with the wearer — what they asked, '
          'what you did, how it ended. Today\'s are already in your instructions in '
          'outline. Recent ones come back as key points, older ones as a summary, the '
          'oldest as one line; ask detail "full" for every point, or "words" for exactly '
          'what was said. Use it before saying you do not remember.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Words to look for, e.g. "Spotify" or "Emmanuel". Leave out for the latest.'},
          'day': {'type': 'string', 'description': 'today, yesterday, or YYYY-MM-DD.'},
          'detail': {'type': 'string', 'enum': ['auto', 'full', 'words']},
        },
      },
    },
  ];

  Future<Map<String, dynamic>> handle(String name, Map<String, dynamic> args) async {
    try {
      final query = '${args['query'] ?? ''}'.trim();
      final day = _day('${args['day'] ?? ''}'.trim());
      final detail = '${args['detail'] ?? 'auto'}';
      var found = day != null
          ? (await store.on(day)).reversed.toList()
          : query.isNotEmpty
              ? await store.search(query)
              : await store.latest();
      if (day != null && query.isNotEmpty) {
        final words = query.toLowerCase().split(RegExp(r'\s+'));
        found = found
            .where((e) => words.every([e.gist, e.summary, ...e.points, ...e.asked].join(' ').toLowerCase().contains))
            .toList();
      }
      if (found.isEmpty) {
        return {'success': true, 'result': 'No earlier conversation matches that.'};
      }
      if (detail == 'words') {
        final e = found.first;
        final said = await _words(e);
        return {'success': true, 'result': {'when': e.when, 'words': said}};
      }
      final now = _now();
      return {
        'success': true,
        'result': [
          for (final e in found.take(5))
            {
              'when': e.when,
              'remembered': e.at(detail == 'full' ? Recall.points : Episode.levelFor(now.difference(e.end))),
            },
        ],
      };
    } catch (e) {
      return {'success': false, 'error': 'Could not look back: $e'};
    }
  }

  Future<String> _words(Episode e) async {
    final said = [
      for (final s in await conversations.entriesOn(e.start))
        if (!s.at.isBefore(e.start.subtract(const Duration(seconds: 1))) && !s.at.isAfter(e.end.add(const Duration(seconds: 1))))
          s,
    ];
    final text = EpisodeWriter.transcript(said, 'You');
    return text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
  }

  DateTime? _day(String s) {
    final now = _now();
    return switch (s) {
      '' => null,
      'today' => now,
      'yesterday' => now.subtract(const Duration(days: 1)),
      _ => DateTime.tryParse(s),
    };
  }
}
