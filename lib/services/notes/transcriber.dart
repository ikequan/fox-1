import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// What Gemini made of one voice note.
class NoteTranscript {
  const NoteTranscript({
    required this.title,
    required this.summary,
    required this.transcript,
    this.language = '',
    this.actionItems = const [],
    this.people = const [],
    this.dates = const [],
  });

  factory NoteTranscript.fromJson(Map<String, dynamic> j) {
    List<String> list(String k) => [
          for (final v in (j[k] as List? ?? const []))
            if ('$v'.trim().isNotEmpty) '$v'.trim(),
        ];
    final title = '${j['title'] ?? ''}'.trim();
    return NoteTranscript(
      title: title.isEmpty ? 'Voice note' : title,
      summary: '${j['summary'] ?? ''}'.trim(),
      transcript: '${j['transcript'] ?? ''}'.trim(),
      language: '${j['language'] ?? ''}'.trim(),
      actionItems: list('action_items'),
      people: list('people'),
      dates: list('dates'),
    );
  }

  final String title, summary, transcript, language;
  final List<String> actionItems, people, dates;
}

/// Why a transcription did not happen, and whether trying again can help.
class TranscribeError implements Exception {
  TranscribeError(this.message, {required this.retryable, this.network = false});

  final String message;

  /// Worth another go later.
  final bool retryable;

  /// No network, a missing key, quota, Gemini busy — not the recording's
  /// fault, so it does not count toward giving up on it.
  final bool network;

  @override
  String toString() => message;
}

/// Voice notes to text with Gemini's REST API, using the same API key as the
/// live assistant. One request per recording returns the transcript in the
/// language it was spoken, plus a title, summary, action items, people and
/// dates, as JSON shaped by [_schema].
class Transcriber {
  Transcriber({
    required this.apiKey,
    http.Client? client,
    this.models = defaultModels,
  }) : _client = client ?? http.Client();

  /// Tried in order: the alias first, so a retired model name does not quietly
  /// end transcription; a pinned model if the alias is not served.
  static const defaultModels = ['gemini-flash-latest', 'gemini-2.5-flash'];

  static const _base = 'https://generativelanguage.googleapis.com';

  /// Inline requests are capped at 20 MB and base64 grows audio by a third.
  /// Longer recordings — about six minutes of 16 kHz WAV — go up through the
  /// Files API instead.
  static const inlineLimit = 12 * 1024 * 1024;

  static const _timeout = Duration(seconds: 90);

  final String Function() apiKey;
  final http.Client _client;
  final List<String> models;

  Future<NoteTranscript> transcribe(Uint8List wav, DateTime recordedAt) async {
    final key = apiKey().trim();
    if (key.isEmpty) {
      throw TranscribeError('no Gemini API key is set', retryable: true, network: true);
    }
    final audio = wav.length <= inlineLimit
        ? {
            'inlineData': {'mimeType': 'audio/wav', 'data': base64Encode(wav)}
          }
        : {
            'fileData': {'mimeType': 'audio/wav', 'fileUri': await _upload(wav, key)}
          };
    final body = jsonEncode(request(audio, recordedAt));
    TranscribeError? last;
    for (final model in models) {
      final http.Response r;
      try {
        r = await _client
            .post(
              Uri.parse('$_base/v1beta/models/$model:generateContent'),
              // The key in a header, not the URL, so it never lands in a log.
              headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
              body: body,
            )
            .timeout(_timeout);
      } catch (e) {
        throw TranscribeError('could not reach Gemini: $e', retryable: true, network: true);
      }
      if (r.statusCode == 404) {
        last = TranscribeError('model $model is not served', retryable: true, network: true);
        continue;
      }
      return parseResponse(r.statusCode, r.body);
    }
    throw last ?? TranscribeError('no model to transcribe with', retryable: true, network: true);
  }

  static Map<String, Object?> request(Map<String, Object?> audio, DateTime recordedAt) => {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt(recordedAt)},
              audio,
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': _schema,
          'temperature': 0.2,
        },
      };

  static String prompt(DateTime recordedAt) {
    final when = DateFormat('EEEE d MMMM yyyy, HH:mm').format(recordedAt);
    return 'This is a voice note the wearer recorded on their smart ring on '
        '$when. Transcribe it word for word in the language or languages '
        'spoken — it may mix English and Swahili — and do not translate the '
        'transcript. Then, in English: a title of at most eight words; a '
        'summary of one to three sentences; action items the speaker committed '
        'to or asked for, each as a short imperative (none if there are none); '
        'the people named; and dates or times mentioned, resolving relative '
        'ones like "tomorrow" against the recording date, as YYYY-MM-DD with a '
        'time if one was said. Give the language as a name, such as "English" '
        'or "English and Swahili". If there is no speech, return an empty '
        'transcript and the title "No speech".';
  }

  static const _schema = {
    'type': 'OBJECT',
    'properties': {
      'title': {'type': 'STRING'},
      'summary': {'type': 'STRING'},
      'transcript': {'type': 'STRING'},
      'language': {'type': 'STRING'},
      'action_items': {
        'type': 'ARRAY',
        'items': {'type': 'STRING'},
      },
      'people': {
        'type': 'ARRAY',
        'items': {'type': 'STRING'},
      },
      'dates': {
        'type': 'ARRAY',
        'items': {'type': 'STRING'},
      },
    },
    'required': ['title', 'summary', 'transcript', 'language', 'action_items', 'people', 'dates'],
  };

  /// Reads a generateContent reply. Every failure says whether a retry can
  /// help, because the pipeline decides on that.
  static NoteTranscript parseResponse(int status, String body) {
    if (status != 200) {
      final keyProblem = status == 401 || status == 403 || body.contains('API_KEY');
      final transient = status == 429 || status >= 500;
      throw TranscribeError('Gemini answered $status: ${_brief(body)}',
          retryable: keyProblem || transient, network: keyProblem || transient);
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      throw TranscribeError('unreadable reply from Gemini', retryable: true);
    }
    final candidates = j['candidates'] as List? ?? const [];
    if (candidates.isEmpty) {
      final block = (j['promptFeedback'] as Map?)?['blockReason'];
      throw TranscribeError(
          block != null ? 'Gemini refused it ($block)' : 'Gemini returned nothing',
          retryable: block == null);
    }
    final c = candidates.first as Map;
    final parts = ((c['content'] as Map?)?['parts'] as List?) ?? const [];
    final text = [
      for (final p in parts)
        if (p is Map && p['text'] is String) p['text'] as String,
    ].join();
    if (text.isEmpty) {
      final reason = '${c['finishReason']}';
      const final_ = {'SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII', 'RECITATION'};
      throw TranscribeError('no transcript came back ($reason)',
          retryable: !final_.contains(reason));
    }
    try {
      return NoteTranscript.fromJson(Map<String, dynamic>.from(jsonDecode(text) as Map));
    } catch (e) {
      throw TranscribeError('the reply was not the JSON asked for: $e', retryable: true);
    }
  }

  static String _brief(String body) {
    try {
      final m = ((jsonDecode(body) as Map)['error'] as Map?)?['message'];
      if (m != null) return '$m';
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  /// Resumable upload through the Files API, for recordings too big to send
  /// inline. Returns the file's URI for a `fileData` part.
  Future<String> _upload(Uint8List bytes, String key) async {
    try {
      final start = await _client
          .post(
            Uri.parse('$_base/upload/v1beta/files'),
            headers: {
              'x-goog-api-key': key,
              'X-Goog-Upload-Protocol': 'resumable',
              'X-Goog-Upload-Command': 'start',
              'X-Goog-Upload-Header-Content-Length': '${bytes.length}',
              'X-Goog-Upload-Header-Content-Type': 'audio/wav',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'file': {'display_name': 'ring voice note'}
            }),
          )
          .timeout(_timeout);
      final url = start.headers['x-goog-upload-url'];
      if (url == null) {
        final transient = start.statusCode == 429 || start.statusCode >= 500;
        throw TranscribeError('upload refused (${start.statusCode}): ${_brief(start.body)}',
            retryable: true, network: transient);
      }
      final done = await _client
          .post(
            Uri.parse(url),
            headers: {'X-Goog-Upload-Offset': '0', 'X-Goog-Upload-Command': 'upload, finalize'},
            body: bytes,
          )
          .timeout(const Duration(minutes: 5));
      final file = (jsonDecode(done.body) as Map)['file'] as Map?;
      var uri = file?['uri'] as String?;
      var state = file?['state'];
      final name = file?['name'];
      // Audio is normally usable at once; give it a little while if not.
      for (var i = 0; i < 15 && state == 'PROCESSING' && name != null; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final g = await _client
            .get(Uri.parse('$_base/v1beta/$name'), headers: {'x-goog-api-key': key})
            .timeout(_timeout);
        final f = jsonDecode(g.body) as Map;
        state = f['state'];
        uri = f['uri'] as String? ?? uri;
      }
      if (uri == null) throw TranscribeError('the upload gave back no file', retryable: true);
      return uri;
    } on TranscribeError {
      rethrow;
    } catch (e) {
      throw TranscribeError('could not upload the recording: $e',
          retryable: true, network: true);
    }
  }
}
