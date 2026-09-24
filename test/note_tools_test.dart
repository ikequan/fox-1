import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/notes/note_store.dart';
import 'package:fox1/services/notes/note_tools.dart';

void main() {
  late Directory tmp;
  late NoteStore store;
  late NoteTools tools;

  final now = DateTime(2026, 9, 11, 21);

  Future<Note> add(String id, DateTime at, {String? title, String? transcript}) async {
    final n = await store.addRecording(
      id: id,
      frames: Uint8List.fromList([1]),
      recordedAt: at,
      duration: const Duration(seconds: 75),
    );
    if (title != null) {
      n
        ..status = NoteStatus.done
        ..title = title
        ..summary = 'About $title.'
        ..transcript = transcript ?? title;
      await store.save(n);
    }
    return n;
  }

  Future<Map> result(String tool, Map<String, dynamic> args) async {
    final r = await tools.handle(tool, args);
    expect(r['success'], isTrue, reason: '$r');
    return r['result'] is Map ? r['result'] as Map : {'text': r['result']};
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('note_tools');
    store = NoteStore(directory: () async => tmp);
    tools = NoteTools(store, now: () => now);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('every declared tool is one the tools answer', () {
    expect({for (final d in NoteTools.declarations) d['name']}, NoteTools.names);
  });

  test('no notes yet says how to make one', () async {
    expect((await result('list_notes', {}))['text'], contains('Quadruple-tap'));
  });

  test("today's notes, including one still being transcribed", () async {
    await add('a', DateTime(2026, 9, 11, 9, 5), title: 'Grant report');
    await add('b', DateTime(2026, 9, 11, 19, 46));
    await add('c', DateTime(2026, 9, 10, 8), title: 'Yesterday');
    final r = await result('list_notes', {'day': 'today'});
    final notes = r['notes'] as List;
    expect([for (final n in notes) n['id']], ['a', 'b']);
    expect(notes.first['recorded'], 'today at 09:05');
    expect(notes.first['length'], '1 min 15 s');
    expect(notes.last['title'], 'not transcribed yet');
    expect(r['still_transcribing'], 1);
  });

  test('search shows where the words are', () async {
    await add('a', DateTime(2026, 9, 11, 9),
        title: 'Grant', transcript: 'Remember to send Emmanuel the grant report on Monday');
    final r = await result('search_notes', {'query': 'emmanuel'});
    final n = (r['notes'] as List).single as Map;
    expect(n['snippet'], contains('Emmanuel the grant'));
  });

  test('read: latest in full; a waiting one says so; an unknown one points to the list',
      () async {
    await add('a', DateTime(2026, 9, 11, 9), title: 'Grant', transcript: 'Nikumbushe grant.');
    var r = await result('read_note', {'id': 'latest'});
    expect(r['transcript'], 'Nikumbushe grant.');
    expect(r['summary'], 'About Grant.');

    await add('b', DateTime(2026, 9, 11, 20));
    r = await result('read_note', {'id': 'latest'});
    expect(r['state'], contains('still being transcribed'));

    final missing = await tools.handle('read_note', {'id': 'nope'});
    expect(missing['success'], isFalse);
    expect(missing['error'], contains('list_notes'));
  });

  test('the announcement names titles, not contents, and stops at five', () async {
    final notes = [
      for (var i = 0; i < 7; i++)
        await add('n$i', DateTime(2026, 9, 11, 9, i), title: 'Note $i'),
    ];
    final text = NoteTools.announcement(notes);
    expect(text, contains('"Note 0"'));
    expect(text, isNot(contains('"Note 5"')));
    expect(text, contains('and 2 more'));
    expect(text, contains('Do not read them out unless asked'));
  });
}
