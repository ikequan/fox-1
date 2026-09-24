import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/conversation/conversation_store.dart';

void main() {
  late Directory tmp;
  late ConversationStore store;
  final t0 = DateTime(2026, 9, 13, 20, 10, 31);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  ConversationStore open() => ConversationStore(
        directory: () async => tmp,
        settle: const Duration(hours: 1),
        now: () => t0,
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('conversations');
    store = open();
  });
  tearDown(() async {
    await store.flush();
    await tmp.delete(recursive: true);
  });

  test('fragments of one turn are one entry; the other speaker starts the next', () async {
    store
      ..addTranscript('user', 'What did I', at(0))
      ..addTranscript('user', ' record  today?', at(1))
      ..addTranscript('assistant', 'You recorded', at(3))
      ..addTranscript('assistant', ' one note.', at(4));
    await store.flush();
    final e = await store.entriesOn(t0);
    expect([for (final s in e) s.role], ['user', 'assistant']);
    expect(e.first.text, 'What did I record today?');
    expect(e.last.text, 'You recorded one note.');
  });

  test('a long pause splits the same speaker', () async {
    store
      ..addTranscript('user', 'First.', at(0))
      ..addTranscript('user', 'Much later.', at(45));
    await store.flush();
    expect([for (final s in await store.entriesOn(t0)) s.text], ['First.', 'Much later.']);
  });

  test('a tool keeps its call — not its provider, not its result', () async {
    store
      ..addTranscript('system', 'NativeTools+OpenClaw: read_note({id: latest})', at(0))
      ..addTranscript('system', 'Done: {id: ring_20260913_200816, transcript: …}', at(1))
      ..addTranscript('system', 'Error: nope', at(2))
      ..addTranscript('system', 'NativeTools: search_notes({query: grant})', at(3));
    await store.flush();
    final e = await store.entriesOn(t0);
    expect([for (final s in e) '${s.role}:${s.text}'],
        ['tool:read_note({id: latest})', 'tool:search_notes({query: grant})']);
  });

  test('a turn still being said is visible before it is written', () async {
    store.addTranscript('user', 'half a sentence', at(0));
    expect([for (final s in await store.entriesOn(t0)) s.text], ['half a sentence']);
    expect([for (final d in await store.days()) d.day], ['2026-09-13']);
  });

  test('ten quiet minutes make two conversations', () async {
    store
      ..addTranscript('user', 'Hi FOX-1', at(0))
      ..addTranscript('assistant', 'Hello!', at(5))
      ..addTranscript('system', 'NativeTools: health_today({})', at(6))
      ..addTranscript('user', 'Me again', at(5 + 11 * 60));
    await store.flush();
    final c = await store.on(t0);
    expect(c, hasLength(2));
    expect(c.first.turns, 2, reason: 'a tool is not a turn');
    expect(c.first.preview, 'Hi FOX-1');
    expect(c.first.id, t0.toIso8601String());
    expect(c.last.preview, 'Me again');
  });

  test('written to disk and read back by a new store', () async {
    store
      ..addTranscript('user', 'Remember the grant', at(0))
      ..addTranscript('assistant', 'Noted.', at(2));
    await store.flush();
    final again = open();
    expect([for (final s in await again.entriesOn(t0)) s.text], ['Remember the grant', 'Noted.']);
  });

  test('days are newest first with counts; search finds every word, newest first', () async {
    final yesterday = t0.subtract(const Duration(days: 1));
    store
      ..addTranscript('user', 'Grant report for Emmanuel', yesterday)
      ..addTranscript('assistant', 'On it.', yesterday.add(const Duration(seconds: 3)))
      ..addTranscript('user', 'Is the grant report done?', at(0));
    await store.flush();

    final days = await store.days();
    expect([for (final d in days) d.day], ['2026-09-13', '2026-09-12']);
    expect(days.last.turns, 2);
    expect(days.last.conversations, 1);

    final hits = await store.search('grant report');
    expect([for (final h in hits) h.said.text],
        ['Is the grant report done?', 'Grant report for Emmanuel']);
    expect(hits.last.day, '2026-09-12');
    expect(hits.last.conversation.id, yesterday.toIso8601String());
    expect(await store.search('grant shawarma'), isEmpty);
  });

  test('a year on, a day is removed; a line cut short is skipped', () async {
    await File('${tmp.path}/2025-09-12.jsonl').writeAsString('{"t":"2025-09-12T10:00:00.000","role":"user","text":"old"}\n');
    await File('${tmp.path}/2025-09-14.jsonl').writeAsString('{"t":"2025-09-14T10:00:00.000","role":"user","text":"kept"}\n{"t":"2025-09-14T10');
    store.addTranscript('user', 'now', at(0));
    await store.flush();
    expect(File('${tmp.path}/2025-09-12.jsonl').existsSync(), isFalse);
    expect([for (final s in await store.entriesOn(DateTime(2025, 9, 14))) s.text], ['kept']);
  });
}
