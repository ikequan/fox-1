import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/notes/note_store.dart';
import 'package:fox1/services/notes/notes_pipeline.dart';
import 'package:fox1/services/notes/transcriber.dart';

const done = NoteTranscript(
  title: 'Grant report',
  summary: 'Call Emmanuel.',
  transcript: 'Remember to call Emmanuel.',
  actionItems: ['Call Emmanuel'],
);

void main() {
  late Directory tmp;
  late NoteStore store;
  late DateTime now;
  late int calls;
  late List<NotesPipeline> made;

  NotesPipeline pipeline(Object Function() outcome,
          {Future<Uint8List> Function(Uint8List)? toWav}) =>
      NotesPipeline(
        store: store,
        transcribe: (wav, at) async {
          calls++;
          final o = outcome();
          if (o is NoteTranscript) return o;
          throw o;
        },
        toWav: toWav ?? (f) async => f,
        now: () => now,
      )..let(made.add);

  Future<Note> add() => store.addRecording(
        id: 'ring_20260911_194621',
        frames: Uint8List.fromList([1, 2, 3]),
        recordedAt: DateTime(2026, 9, 11, 19, 46, 21),
        duration: const Duration(seconds: 3),
      );

  Future<Note> note() async => (await store.get('ring_20260911_194621'))!;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pipeline');
    store = NoteStore(directory: () async => tmp);
    now = DateTime(2026, 9, 11, 20);
    calls = 0;
    made = [];
  });
  tearDown(() async {
    for (final p in made) {
      p.dispose();
    }
    await tmp.delete(recursive: true);
  });

  test('a recording becomes a note', () async {
    await add();
    await pipeline(() => done).run();
    final n = await note();
    expect(n.status, NoteStatus.done);
    expect(n.title, 'Grant report');
    expect(n.actionItems, ['Call Emmanuel']);
  });

  test('no network: it waits and tries again, and it never counts against the note',
      () async {
    await add();
    final p = pipeline(() => TranscribeError('offline', retryable: true, network: true));
    await p.run();
    var n = await note();
    expect(n.status, NoteStatus.pending);
    expect(n.strikes, 0);
    expect(n.nextTryAt, now.add(const Duration(minutes: 1)));

    await p.run();
    expect(calls, 1, reason: 'not due yet');
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(hours: 4));
      await p.run();
    }
    n = await note();
    expect(n.status, NoteStatus.pending, reason: 'a day offline is not a reason to give up');
  });

  test('a reply it cannot use, five times over, is given up — the recording stays',
      () async {
    await add();
    final p = pipeline(() => TranscribeError('not json', retryable: true));
    for (var i = 0; i < NotesPipeline.maxStrikes; i++) {
      await p.run();
      now = now.add(const Duration(hours: 4));
    }
    final n = await note();
    expect(n.status, NoteStatus.failed);
    expect(n.error, 'not json');
    expect(await store.frames(n.id), isNotNull);
  });

  test('Gemini refusing it is final at once', () async {
    await add();
    await pipeline(() => TranscribeError('blocked', retryable: false)).run();
    expect((await note()).status, NoteStatus.failed);
  });

  test('a decode that fails is tried again later', () async {
    await add();
    await pipeline(() => done, toWav: (_) async => throw StateError('codec')).run();
    final n = await note();
    expect(n.status, NoteStatus.pending);
    expect(n.strikes, 1);
    expect(calls, 0);
  });
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}
