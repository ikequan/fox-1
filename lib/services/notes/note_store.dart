import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ring/ring_ble.dart';

/// Where a voice note is in its life.
enum NoteStatus {
  /// On the device, waiting to be transcribed — or waiting to retry after a
  /// failure that may clear (no network, Gemini busy).
  pending,

  /// Transcribed.
  done,

  /// Gemini could not make anything of it, for good. The recording is kept.
  failed,
}

/// One quadruple-tap recording from the ring, and what Gemini made of it.
class Note {
  Note({
    required this.id,
    required this.recordedAt,
    required this.pulledAt,
    required this.duration,
    this.status = NoteStatus.pending,
    this.tries = 0,
    this.strikes = 0,
    this.nextTryAt,
    this.error,
    this.title,
    this.summary,
    this.transcript,
    this.language,
    this.actionItems = const [],
    this.people = const [],
    this.dates = const [],
    this.announced = false,
  });

  /// The ring's recording time as a name: `ring_20260911_194621`.
  final String id;
  final DateTime recordedAt, pulledAt;
  final Duration duration;

  NoteStatus status;

  /// Every failed try — drives the retry backoff.
  int tries;

  /// Failed tries that count toward giving up. Network and quota failures do
  /// not: a device that was offline for a day still gets everything done.
  int strikes;
  DateTime? nextTryAt;
  String? error;

  String? title, summary, language;

  /// Verbatim, in the language it was spoken.
  String? transcript;
  List<String> actionItems, people, dates;

  /// Whether the wearer has been told about it. Set only once they have spoken
  /// after the assistant mentioned it — the agent being told is not the wearer
  /// hearing it.
  bool announced;

  bool get transcribed => status == NoteStatus.done;

  /// Transcribed, and nothing was said — almost always a quadruple tap by
  /// mistake. Kept on the device, but left out of lists, search, counts and
  /// announcements. The transcriber answers silence with an empty transcript.
  bool get silent => transcribed && transcript != null && transcript!.trim().isEmpty;

  String get searchText => [
        title,
        summary,
        transcript,
        ...people,
        ...actionItems,
      ].whereType<String>().join(' ').toLowerCase();

  Map<String, Object?> toJson() => {
        'id': id,
        'recordedAt': recordedAt.toIso8601String(),
        'pulledAt': pulledAt.toIso8601String(),
        'durationMs': duration.inMilliseconds,
        'status': status.name,
        'tries': tries,
        'strikes': strikes,
        'nextTryAt': ?nextTryAt?.toIso8601String(),
        'error': ?error,
        'title': ?title,
        'summary': ?summary,
        'transcript': ?transcript,
        'language': ?language,
        'actionItems': actionItems,
        'people': people,
        'dates': dates,
        'announced': announced,
      };

  factory Note.fromJson(Map<String, dynamic> j) {
    List<String> list(String k) => [for (final v in (j[k] as List? ?? const [])) '$v'];
    final recorded = DateTime.parse('${j['recordedAt']}');
    return Note(
      id: '${j['id']}',
      recordedAt: recorded,
      pulledAt: DateTime.tryParse('${j['pulledAt']}') ?? recorded,
      duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
      status: NoteStatus.values.asNameMap()[j['status']] ?? NoteStatus.pending,
      tries: (j['tries'] as num?)?.toInt() ?? 0,
      strikes: (j['strikes'] as num?)?.toInt() ?? 0,
      nextTryAt: j['nextTryAt'] == null ? null : DateTime.tryParse('${j['nextTryAt']}'),
      error: j['error'] as String?,
      title: j['title'] as String?,
      summary: j['summary'] as String?,
      transcript: j['transcript'] as String?,
      language: j['language'] as String?,
      actionItems: list('actionItems'),
      people: list('people'),
      dates: list('dates'),
      announced: j['announced'] == true,
    );
  }
}

/// The device's voice notes: each recording's Opus packets exactly as the ring
/// sent them (`<id>.opus40`, ~120 KB a minute) and a JSON note beside it.
///
/// Playable WAV is not kept — it is ten times the size and is rebuilt from the
/// packets whenever someone listens. Same one-file-per-thing approach as
/// HealthStore and MemoryStore; no database dependency.
class NoteStore {
  NoteStore({Future<Directory?> Function()? directory})
      : _directory = directory ?? _defaultDir;

  /// Internal storage, beside the health history: voice notes are nobody
  /// else's business, and on API 27 the external files dir is readable by any
  /// app holding the storage permission.
  static Future<Directory?> _defaultDir() async {
    final health = await RingBle.healthDir();
    return health == null ? null : Directory('${health.parent.path}/notes');
  }

  final Future<Directory?> Function() _directory;
  Directory? _root;
  Map<String, Note>? _notes;
  final _changes = StreamController<void>.broadcast();

  /// Fires whenever a note is added or changes.
  Stream<void> get changes => _changes.stream;

  Future<Directory?> _dir() async {
    final d = _root ??= await _directory();
    if (d != null && !await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Map<String, Note>> _all() async {
    final cached = _notes;
    if (cached != null) return cached;
    final out = <String, Note>{};
    final d = await _dir();
    if (d != null) {
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final n = Note.fromJson(
              Map<String, dynamic>.from(jsonDecode(await e.readAsString()) as Map));
          out[n.id] = n;
        } catch (err) {
          // One bad file must not take the rest with it.
          debugPrint('[NOTES] ${e.path} unreadable, skipped: $err');
        }
      }
    }
    return _notes = out;
  }

  /// Newest first. Recordings with no speech in them are left out unless
  /// [withSilent]: everything that lists, searches or counts notes goes
  /// through here, so one filter covers the assistant, the card and the portal.
  Future<List<Note>> all({bool withSilent = false}) async => [
        for (final n in (await _all()).values)
          if (withSilent || !n.silent) n,
      ]..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));

  Future<Note?> get(String id) async => (await _all())[id];

  /// No note worth listing — silent recordings do not count.
  Future<bool> get isEmpty async => (await _all()).values.every((n) => n.silent);

  /// How many recordings [all] is leaving out.
  Future<int> silentCount() async => (await _all()).values.where((n) => n.silent).length;

  /// Stores a recording's packets and a pending note for it, and returns only
  /// once both are flushed to disk: the caller acknowledges the file to the
  /// ring on that, and the acknowledgement deletes the ring's copy.
  Future<Note> addRecording({
    required String id,
    required Uint8List frames,
    required DateTime recordedAt,
    required Duration duration,
    DateTime? now,
  }) async {
    final d = await _dir();
    if (d == null) throw StateError('no storage for notes');
    // The same recording again (a repeat send, a re-import): the copy already
    // here is whole, so keep it.
    final existing = (await _all())[id];
    if (existing != null) return existing;
    await File('${d.path}/$id.opus40').writeAsBytes(frames, flush: true);
    final note = Note(
      id: id,
      recordedAt: recordedAt,
      pulledAt: now ?? DateTime.now(),
      duration: duration,
    );
    await save(note);
    return note;
  }

  /// Written to a temporary file and renamed, so a crash mid-write leaves the
  /// previous version rather than half a file.
  Future<void> save(Note n) async {
    final d = await _dir();
    if (d == null) throw StateError('no storage for notes');
    final f = File('${d.path}/${n.id}.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(n.toJson()), flush: true);
    await tmp.rename(f.path);
    (await _all())[n.id] = n;
    if (!_changes.isClosed) _changes.add(null);
  }

  /// The recording and its note, gone for good. Only ids the store holds —
  /// never a path someone typed.
  Future<bool> delete(String id) async {
    final all = await _all();
    if (all.remove(id) == null) return false;
    final d = await _dir();
    if (d != null) {
      for (final ext in const ['opus40', 'json']) {
        final f = File('${d.path}/$id.$ext');
        if (await f.exists()) await f.delete();
      }
    }
    if (!_changes.isClosed) _changes.add(null);
    return true;
  }

  /// A note that failed, or is waiting out a backoff, back to the front of
  /// the queue with a clean slate.
  Future<bool> requeue(String id) async {
    final n = (await _all())[id];
    if (n == null || n.status == NoteStatus.done) return false;
    n
      ..status = NoteStatus.pending
      ..tries = 0
      ..strikes = 0
      ..nextTryAt = null
      ..error = null;
    await save(n);
    return true;
  }

  /// The ring's packets for [id], or null if they are gone.
  Future<Uint8List?> frames(String id) async {
    final d = await _dir();
    if (d == null) return null;
    final f = File('${d.path}/$id.opus40');
    return await f.exists() ? f.readAsBytes() : null;
  }

  /// Due for transcription at [now], oldest first.
  Future<List<Note>> due(DateTime now) async => [
        for (final n in (await all()).reversed)
          if (n.status == NoteStatus.pending &&
              (n.nextTryAt == null || !n.nextTryAt!.isAfter(now)))
            n,
      ];

  /// When the next waiting note is due, if any is waiting.
  Future<DateTime?> nextRetry() async {
    DateTime? next;
    for (final n in (await _all()).values) {
      if (n.status != NoteStatus.pending) continue;
      final t = n.nextTryAt;
      if (t == null) return DateTime.fromMillisecondsSinceEpoch(0);
      if (next == null || t.isBefore(next)) next = t;
    }
    return next;
  }

  /// Transcribed notes the wearer has not been told about, oldest first.
  Future<List<Note>> unannounced() async => [
        for (final n in (await all()).reversed)
          if (n.transcribed && !n.announced) n,
      ];

  Future<void> markAnnounced(Iterable<String> ids) async {
    for (final id in ids) {
      final n = (await _all())[id];
      if (n == null || n.announced) continue;
      n.announced = true;
      await save(n);
    }
  }

  /// Recorded on [day], oldest first.
  Future<List<Note>> on(DateTime day) async {
    final d = DateTime(day.year, day.month, day.day);
    return [
      for (final n in (await all()).reversed)
        if (DateTime(n.recordedAt.year, n.recordedAt.month, n.recordedAt.day) == d) n,
    ];
  }

  /// Notes holding every word of [query] — title, summary, transcript, people
  /// or action items. Newest first.
  Future<List<Note>> search(String query) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    return [
      for (final n in await all())
        if (words.every(n.searchText.contains)) n,
    ];
  }

  void dispose() => _changes.close();
}
