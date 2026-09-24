import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fox1/services/notes/transcriber.dart';

String reply(Map<String, Object?> note) => jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': jsonEncode(note)}
            ]
          },
          'finishReason': 'STOP',
        }
      ]
    });

const note = {
  'title': 'Call Emmanuel about the grant',
  'summary': 'Reminder to call Emmanuel tomorrow about the grant report.',
  'transcript': 'Nikumbushe kumpigia Emmanuel kesho about the grant report.',
  'language': 'English and Swahili',
  'action_items': ['Call Emmanuel about the grant report', ' '],
  'people': ['Emmanuel'],
  'dates': ['2026-09-12'],
};

final at = DateTime(2026, 9, 11, 19, 46);
final wav = Uint8List.fromList([1, 2, 3]);

void main() {
  test('sends the audio inline, the key in a header, and reads the note back', () async {
    late http.Request seen;
    final t = Transcriber(
      apiKey: () => 'KEY',
      client: MockClient((r) async {
        seen = r;
        return http.Response(reply(note), 200);
      }),
    );
    final n = await t.transcribe(wav, at);
    expect(n.title, 'Call Emmanuel about the grant');
    expect(n.actionItems, ['Call Emmanuel about the grant report'], reason: 'blanks dropped');
    expect(n.language, 'English and Swahili');

    expect(seen.url.path, endsWith('gemini-flash-latest:generateContent'));
    expect(seen.url.query, isEmpty, reason: 'the key must not be in the URL');
    expect(seen.headers['x-goog-api-key'], 'KEY');
    final body = jsonDecode(seen.body) as Map;
    final parts = (body['contents'] as List).first['parts'] as List;
    expect(parts.first['text'], contains('Friday 11 September 2026, 19:46'));
    expect(parts.last['inlineData'], {'mimeType': 'audio/wav', 'data': 'AQID'});
    expect(body['generationConfig']['responseMimeType'], 'application/json');
  });

  test('a model that is not served falls back to the next', () async {
    final urls = <String>[];
    final t = Transcriber(
      apiKey: () => 'KEY',
      client: MockClient((r) async {
        urls.add(r.url.path);
        return urls.length == 1 ? http.Response('{}', 404) : http.Response(reply(note), 200);
      }),
    );
    await t.transcribe(wav, at);
    expect(urls.last, endsWith('gemini-2.5-flash:generateContent'));
  });

  test('busy or unreachable: retry later, and not the recording\'s fault', () async {
    for (final client in [
      MockClient((_) async => http.Response('{"error":{"message":"overloaded"}}', 503)),
      MockClient((_) async => throw http.ClientException('no route to host')),
    ]) {
      final t = Transcriber(apiKey: () => 'KEY', client: client);
      await expectLater(
          t.transcribe(wav, at),
          throwsA(isA<TranscribeError>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.network, 'network', isTrue)));
    }
  });

  test('no key yet: waits for one', () async {
    final t = Transcriber(apiKey: () => '', client: MockClient((_) async => fail('no call')));
    await expectLater(t.transcribe(wav, at),
        throwsA(isA<TranscribeError>().having((e) => e.network, 'network', isTrue)));
  });

  test('replies Gemini gives, sorted into retry and give up', () {
    TranscribeError err(int status, String body) {
      try {
        Transcriber.parseResponse(status, body);
      } on TranscribeError catch (e) {
        return e;
      }
      fail('no error for $status $body');
    }

    expect(err(400, '{"error":{"message":"bad audio"}}').retryable, isFalse);
    final key = err(400, '{"error":{"message":"API key not valid","details":"API_KEY_INVALID"}}');
    expect(key.retryable && key.network, isTrue, reason: 'fixed by fixing the key');
    expect(err(200, '{"candidates":[],"promptFeedback":{"blockReason":"SAFETY"}}').retryable,
        isFalse);
    expect(err(200, '{"candidates":[{"content":{"parts":[{"text":"not json"}]}}]}').retryable,
        isTrue);
    expect(err(200, '{"candidates":[{"finishReason":"SAFETY"}]}').retryable, isFalse);
  });

  test('a reply with gaps still makes a note', () {
    final n = NoteTranscript.fromJson({'transcript': ''});
    expect(n.title, 'Voice note');
    expect(n.actionItems, isEmpty);
  });
}
