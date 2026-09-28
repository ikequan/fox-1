import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/conversation/conversation_store.dart';
import 'package:fox1/services/memory/episodes.dart';

Episode _ep(DateTime start, {String gist = 'Spotify search', List<String> points = const ['Asked for The Diary Of A CEO', 'Search results never loaded'], String summary = 'Tried to play a podcast on Spotify; the search did not load.'}) =>
    Episode(start: start, end: start.add(const Duration(minutes: 5)), gist: gist, summary: summary, points: points, pending: false);

void main() {
  group('fading', () {
    test('points for a day, summary for a week, then the gist', () {
      expect(Episode.levelFor(const Duration(hours: 3)), Recall.points);
      expect(Episode.levelFor(const Duration(days: 2)), Recall.summary);
      expect(Episode.levelFor(const Duration(days: 30)), Recall.gist);
    });

    test('each level says what it holds', () {
      final e = _ep(DateTime(2026, 9, 28, 11));
      expect(e.at(Recall.points), 'Asked for The Diary Of A CEO; Search results never loaded');
      expect(e.at(Recall.summary), startsWith('Tried to play'));
      expect(e.at(Recall.gist), 'Spotify search');
    });

    test('an unwritten episode is never blank: the wearer\'s own words stand in', () {
      final e = Episode(start: DateTime(2026, 9, 28, 11), end: DateTime(2026, 9, 28, 11, 5), asked: ['Play the CEO diaries']);
      for (final l in Recall.values) {
        expect(e.at(l), 'Asked: "Play the CEO diaries"');
      }
    });
  });

  group('briefing', () {
    test('empty day, no briefing', () => expect(episodeBriefing([]), ''));

    test('older conversations fade first when over budget', () {
      final long = List.generate(10, (i) => 'point number $i with some detail in it');
      final eps = [
        _ep(DateTime(2026, 9, 28, 9), gist: 'Morning weather', points: long),
        _ep(DateTime(2026, 9, 28, 11), gist: 'Spotify search', points: long),
      ];
      final b = episodeBriefing(eps, maxChars: 500);
      expect(b, contains('11:00 — point number 0'));
      expect(b, contains('09:00 — Tried to play'), reason: 'the older one drops to its summary');
      expect(b.indexOf('09:00'), lessThan(b.indexOf('11:00')), reason: 'oldest first');
    });
  });

  group('writer', () {
    test('parses the model reply', () {
      final body = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': jsonEncode({'gist': 'SMS to Emmanuel', 'summary': 'Sent it.', 'points': ['Sent "running late" to Emmanuel', ' ']})}
              ]
            }
          }
        ]
      });
      final r = EpisodeWriter.parse(200, body);
      expect(r.gist, 'SMS to Emmanuel');
      expect(r.points, ['Sent "running late" to Emmanuel']);
    });

    test('quota is the network\'s fault, a bad reply is not', () {
      expect(() => EpisodeWriter.parse(429, ''), throwsA(isA<EpisodeWriteError>().having((e) => e.network, 'network', true)));
      expect(() => EpisodeWriter.parse(200, '{}'), throwsA(isA<EpisodeWriteError>().having((e) => e.network, 'network', false)));
    });

    test('the transcript keeps the end when too long', () {
      final said = [for (var i = 0; i < 2000; i++) Said(DateTime(2026, 9, 28, 11), 'user', 'line $i of a long conversation')];
      final t = EpisodeWriter.transcript(said, 'FOX-1');
      expect(t.length, lessThanOrEqualTo(EpisodeWriter.maxInput + 2));
      expect(t, contains('line 1999'));
    });
  });

  group('store and recall', () {
    late Directory tmp;
    late EpisodeStore store;
    late ConversationStore conversations;
    final now = DateTime(2026, 9, 28, 15);

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('episodes');
      store = EpisodeStore(directory: () async => Directory('${tmp.path}/episodes'), now: () => now);
      conversations = ConversationStore(directory: () async => Directory('${tmp.path}/conversations'), now: () => now);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('save replaces by start and reads back', () async {
      final e = Episode(start: DateTime(2026, 9, 28, 11), end: DateTime(2026, 9, 28, 11, 5), asked: ['hi']);
      await store.save(e);
      e
        ..gist = 'Greeting'
        ..pending = false;
      await store.save(e);
      final day = await store.on(now);
      expect(day, hasLength(1));
      expect(day.single.gist, 'Greeting');
      expect(await store.pending(), isEmpty);
    });

    test('recall fades with age unless asked for everything', () async {
      await store.save(_ep(DateTime(2026, 9, 1, 10)));
      await store.save(_ep(DateTime(2026, 9, 28, 11)));
      final tools = EpisodeTools(store, conversations, now: () => now);

      final auto = (await tools.handle('recall_conversations', {'query': 'spotify'}))['result'] as List;
      expect(auto.first['remembered'], contains('Search results never loaded'), reason: 'today: the points');
      expect(auto.last['remembered'], 'Spotify search', reason: 'four weeks ago: the gist');

      final full = (await tools.handle('recall_conversations', {'query': 'spotify', 'detail': 'full'}))['result'] as List;
      expect(full.last['remembered'], contains('Search results never loaded'), reason: 'nothing is lost');
    });

    test('words brings back exactly what was said', () async {
      conversations.addTranscript('user', 'Play the Diary of a CEO', DateTime(2026, 9, 28, 11, 1));
      await conversations.flush();
      await store.save(_ep(DateTime(2026, 9, 28, 11)));
      final tools = EpisodeTools(store, conversations, now: () => now);
      final r = (await tools.handle('recall_conversations', {'day': 'today', 'detail': 'words'}))['result'] as Map;
      expect(r['words'], contains('Play the Diary of a CEO'));
    });
  });
}
