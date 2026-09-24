import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/notes/note_store.dart';
import 'package:fox1/services/notes/ring_notes.dart';

void main() {
  late Directory tmp;
  late NoteStore store;

  final mon = DateTime(2026, 9, 7, 9), tue = DateTime(2026, 9, 8, 18, 30);

  Future<Note> add(String id, DateTime at) => store.addRecording(
        id: id,
        frames: Uint8List.fromList([1, 2, 3]),
        recordedAt: at,
        duration: const Duration(seconds: 4),
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('notes');
    store = NoteStore(directory: () async => tmp);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('a recording and its note are on disk, and read back by a new store', () async {
    final n = await add('ring_20260907_090000', mon);
    n
      ..status = NoteStatus.done
      ..title = 'Grant report'
      ..actionItems = ['Call Emmanuel'];
    await store.save(n);

    final again = NoteStore(directory: () async => tmp);
    final back = (await again.get('ring_20260907_090000'))!;
    expect(back.title, 'Grant report');
    expect(back.actionItems, ['Call Emmanuel']);
    expect(back.duration, const Duration(seconds: 4));
    expect(await again.frames(back.id), [1, 2, 3]);
  });

  test('the same recording twice keeps the first', () async {
    final first = await add('a', mon);
    first.title = 'kept';
    await store.save(first);
    final second = await add('a', tue);
    expect(second.title, 'kept');
    expect(await store.all(), hasLength(1));
  });

  test('due: waiting notes, oldest first, not before their retry time', () async {
    await add('late', tue);
    final early = await add('early', mon);
    final later = await add('later', tue.add(const Duration(hours: 1)));
    later.nextTryAt = tue.add(const Duration(days: 1));
    await store.save(later);
    early.status = NoteStatus.done;
    await store.save(early);
    expect([for (final n in await store.due(tue)) n.id], ['late']);
    expect(await store.nextRetry(), DateTime.fromMillisecondsSinceEpoch(0),
        reason: 'one is due now');
  });

  test('search needs every word; a day lists that day', () async {
    final a = await add('a', mon)
      ..status = NoteStatus.done
      ..transcript = 'Remember the grant report for Emmanuel';
    await store.save(a);
    final b = await add('b', tue)
      ..status = NoteStatus.done
      ..transcript = 'Buy shawarma';
    await store.save(b);
    expect([for (final n in await store.search('grant emmanuel')) n.id], ['a']);
    expect(await store.search('grant shawarma'), isEmpty);
    expect([for (final n in await store.on(tue)) n.id], ['b']);
  });

  test('only transcribed notes are announced, and only until heard', () async {
    final a = await add('a', mon)..status = NoteStatus.done;
    await store.save(a);
    await add('b', tue);
    expect([for (final n in await store.unannounced()) n.id], ['a']);
    await store.markAnnounced(['a']);
    expect(await store.unannounced(), isEmpty);
  });

  test('a recording with no speech is kept but not listed, found or announced', () async {
    final said = await add('said', mon)
      ..status = NoteStatus.done
      ..title = 'Grant report'
      ..transcript = 'Remember the grant report';
    await store.save(said);
    final silent = await add('silent', tue)
      ..status = NoteStatus.done
      ..title = 'No speech'
      ..summary = 'No speech was detected in the audio recording.'
      ..transcript = '';
    await store.save(silent);
    await add('waiting', tue.add(const Duration(hours: 1)));

    expect(silent.silent, isTrue);
    expect([for (final n in await store.all()) n.id], ['waiting', 'said'],
        reason: 'a note still being transcribed is not silent');
    expect([for (final n in await store.all(withSilent: true)) n.id],
        ['waiting', 'silent', 'said']);
    expect(await store.silentCount(), 1);
    expect(await store.search('speech'), isEmpty);
    expect([for (final n in await store.on(tue)) n.id], ['waiting']);
    expect([for (final n in await store.unannounced()) n.id], ['said']);
    expect((await store.get('silent'))?.title, 'No speech', reason: 'still on the device');
    expect(await store.frames('silent'), [1, 2, 3]);
  });

  test('only silent recordings: the notes count as empty', () async {
    final s = await add('silent', mon)
      ..status = NoteStatus.done
      ..transcript = ' ';
    await store.save(s);
    expect(await store.isEmpty, isTrue);
  });

  test('requeue gives a failed note a clean slate; delete removes it for good', () async {
    final a = await add('a', mon)
      ..status = NoteStatus.failed
      ..tries = 5
      ..strikes = 5
      ..error = 'Gemini could not read it';
    await store.save(a);
    expect(await store.requeue('a'), isTrue);
    final back = (await store.get('a'))!;
    expect(back.status, NoteStatus.pending);
    expect(back.strikes, 0);
    expect(back.error, isNull);
    expect([for (final n in await store.due(mon)) n.id], ['a']);

    expect(await store.delete('a'), isTrue);
    expect(await store.get('a'), isNull);
    expect(await store.frames('a'), isNull);
    expect(File('${tmp.path}/a.json').existsSync(), isFalse);
    expect(await store.delete('a'), isFalse);
    expect(await store.requeue('nothing'), isFalse);
  });

  test('an unreadable note is skipped, not fatal', () async {
    await add('a', mon);
    await File('${tmp.path}/broken.json').writeAsString('{not json');
    final again = NoteStore(directory: () async => tmp);
    expect(await again.all(), hasLength(1));
  });

  test('file names carry the recording time', () {
    expect(recordedAtFromName('ring_20260911_194621'), DateTime(2026, 9, 11, 19, 46, 21));
    expect(recordedAtFromName('something else'), isNull);
  });
}
