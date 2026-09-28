import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Does an on-device task — opening apps, reading screens, tapping, typing —
/// with a small text model, and hands back only the outcome.
///
/// Driving the screen from the voice model re-sent the whole conversation on
/// every step: a Spotify search that went nowhere cost $2. Here each step
/// sends only the task, one line per step so far and the current screen —
/// about 2,000 tokens — and nothing of it ever enters the conversation.
class DeviceHelper {
  DeviceHelper({
    required this.apiKey,
    required this.act,
    required this.readScreen,
    this.audioPlaying,
    Future<Map<String, dynamic>> Function(Map<String, Object?> request)? model,
    this.maxSteps = 25,
    this.timeLimit = const Duration(minutes: 3),
    this.log = _debugLog,
  }) : _model = model;

  final String Function() apiKey;

  /// Runs one of the device's own tools (`tap`, `type_text`, …) by name.
  final Future<Map<String, dynamic>> Function(String name, Map<String, dynamic> args) act;

  /// The screen in its compact form, ids fresh for `tap`.
  final Future<String> Function() readScreen;

  /// Whether sound is playing. The screen alone did not show it: a podcast
  /// started at step 16 and the helper ran out of time still looking.
  final Future<bool> Function()? audioPlaying;

  bool _cancelled = false;

  /// Stops at the next step. The wearer moved on — asked to close the apps,
  /// stood down — and a helper that carried on started a second app playing.
  void cancel() => _cancelled = true;

  final Future<Map<String, dynamic>> Function(Map<String, Object?> request)? _model;
  final int maxSteps;
  final Duration timeLimit;
  final void Function(String) log;

  static void _debugLog(String s) => debugPrint('[HELPER] $s');

  static const models = ['gemini-flash-latest', 'gemini-2.5-flash'];

  /// Cleared if a model refuses the thinking budget.
  static bool _thinkingBudget = true;
  static const _base = 'https://generativelanguage.googleapis.com';

  /// USD per million tokens, Flash text. A table, not fetched — the same
  /// caveat as `LivePrices`.
  static const priceIn = 0.30, priceOut = 2.50;

  /// Does [task]. [confirmed]: the wearer has already said exactly what to
  /// send, pay or delete, so the helper may do it without stopping first.
  Future<HelperResult> run(String task, {bool confirmed = false}) async {
    final steps = <String>[];
    final started = DateTime.now();
    var tokensIn = 0, tokensOut = 0;
    String? lastScreen;
    var unchanged = 0;

    HelperResult end(String status, String message) {
      final usd = tokensIn * priceIn / 1e6 + tokensOut * priceOut / 1e6;
      log('$status after ${steps.length} step(s) · in $tokensIn out $tokensOut · \$${usd.toStringAsFixed(4)} · $message');
      return HelperResult(status, message, steps: steps.length, usd: usd);
    }

    /// A stop the helper did not choose. Sound playing means a play task
    /// has most likely worked, whatever the screen says.
    Future<HelperResult> outOfSteps(String why) async {
      if (await audioPlaying?.call() == true) {
        return end('done', 'Audio is playing on the watch now (I stopped because: ${why.split('\n').first}).');
      }
      return end('stuck', '$why. Last: ${steps.isEmpty ? '-' : steps.last}');
    }

    for (var i = 1; i <= maxSteps; i++) {
      if (_cancelled) return end('cancelled', 'Stopped: the wearer moved on.');
      if (DateTime.now().difference(started) > timeLimit) {
        return outOfSteps('Ran out of time after ${steps.length} steps');
      }
      final screen = await _settled();
      if (screen == lastScreen) {
        unchanged++;
        if (unchanged >= 4) {
          return outOfSteps('The screen stopped changing — nothing I tried moved it. It shows:\n${_clip(screen, 600)}\n');
        }
      } else {
        unchanged = 0;
      }
      lastScreen = screen;

      final Map<String, dynamic> reply;
      try {
        final playing = await audioPlaying?.call();
        reply = await _ask(request(task, confirmed: confirmed, steps: steps, screen: screen, audioPlaying: playing));
      } on HelperError catch (e) {
        return end('stuck', 'The helper model failed: $e');
      }
      final usage = reply['usageMetadata'] as Map? ?? const {};
      tokensIn += (usage['promptTokenCount'] as num?)?.toInt() ?? 0;
      tokensOut += ((usage['candidatesTokenCount'] as num?)?.toInt() ?? 0) +
          ((usage['thoughtsTokenCount'] as num?)?.toInt() ?? 0);

      final call = functionCall(reply);
      if (call == null) {
        steps.add('$i. (no action chosen)');
        continue;
      }
      final name = call.name;
      final args = call.args;
      if (name == 'finish') {
        return end('${args['status'] ?? 'done'}', '${args['message'] ?? ''}');
      }
      final outcome = await _do(name, args);
      final line = '$i. $name ${_brief(args)} → $outcome';
      log(line);
      steps.add(line);
    }
    return outOfSteps('Stopped after $maxSteps steps');
  }

  /// The screen once it stops changing — two reads in a row the same, for
  /// up to about 4 s. Acting on a page mid-load threw a Spotify podcast away:
  /// its page showed only the tab bar for a moment, and the helper tapped
  /// Search instead of waiting for the episodes.
  Future<String> _settled() async {
    var screen = await readScreen();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final again = await readScreen();
      if (again == screen) return again;
      screen = again;
    }
    return screen;
  }

  Future<String> _do(String name, Map<String, dynamic> args) async {
    if (name == 'wait') {
      final s = ((args['seconds'] as num?)?.toInt() ?? 2).clamp(1, 10);
      await Future<void>.delayed(Duration(seconds: s));
      return 'waited ${s}s';
    }
    final tool = switch (name) {
      'open_app' => 'launch_app',
      'shortcut' => 'app_shortcut',
      _ => name,
    };
    if (!_actions.contains(name)) return 'unknown action';
    final Map<String, dynamic> r;
    try {
      r = await act(tool, Map<String, dynamic>.from(args));
    } catch (e) {
      return 'failed: $e';
    }
    if (r['success'] == false) return 'FAILED: ${r['error'] ?? 'no reason given'}';
    if (r['screen_changed'] == false) return 'accepted, but the screen did NOT change';
    final result = '${r['result'] ?? 'ok'}';
    return _clip(result, 200);
  }

  static const _actions = {
    'open_app', 'shortcut', 'tap', 'type_text', 'press_enter', 'press_back',
    'press_home', 'scroll', 'swipe', 'wait',
  };

  Future<Map<String, dynamic>> _ask(Map<String, Object?> req) async {
    final m = _model;
    if (m != null) return m(req);
    final key = apiKey().trim();
    if (key.isEmpty) throw HelperError('no Gemini API key');
    // A busy moment at Google (503, 429) or a dropped request is not the
    // task failing: one ended a run that was two taps from done. Each model
    // gets a second try after a pause, then the next model.
    HelperError? last;
    for (final model in models) {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
        final http.Response r;
        try {
          r = await http
              .post(Uri.parse('$_base/v1beta/models/$model:generateContent'),
                  headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
                  body: jsonEncode(req))
              .timeout(const Duration(seconds: 40));
        } catch (e) {
          last = HelperError('could not reach Gemini: $e');
          continue;
        }
        if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
        if (r.statusCode == 400 && _thinkingBudget && r.body.toLowerCase().contains('thinking')) {
          _thinkingBudget = false;
          log('$model refused the thinking budget — sending without it');
          return _ask(Map<String, Object?>.from(req)
            ..['generationConfig'] = {'temperature': 0.1});
        }
        last = HelperError('Gemini answered ${r.statusCode} ($model)');
        if (r.statusCode == 404) break;
        if (r.statusCode != 429 && r.statusCode < 500) throw last;
        log('$model answered ${r.statusCode} — trying again');
      }
    }
    throw last ?? HelperError('no model');
  }

  static ({String name, Map<String, dynamic> args})? functionCall(Map<String, dynamic> reply) {
    final candidates = reply['candidates'] as List? ?? const [];
    if (candidates.isEmpty) return null;
    final parts = ((candidates.first as Map)['content'] as Map?)?['parts'] as List? ?? const [];
    for (final p in parts) {
      final fc = (p as Map)['functionCall'];
      if (fc is Map && fc['name'] is String) {
        return (name: fc['name'] as String, args: Map<String, dynamic>.from(fc['args'] as Map? ?? const {}));
      }
    }
    return null;
  }

  static Map<String, Object?> request(String task,
          {required bool confirmed, required List<String> steps, required String screen, bool? audioPlaying}) =>
      {
        'systemInstruction': {
          'parts': [
            {'text': instructions}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {
                'text': 'TASK: $task\n'
                    'CONFIRMED BY THE WEARER: ${confirmed ? 'yes — you may send/pay/delete as the task says' : 'no'}\n\n'
                    'DONE SO FAR:\n${steps.isEmpty ? '(nothing yet)' : steps.join('\n')}\n\n'
                    '${audioPlaying == null ? '' : 'SOUND NOW: ${audioPlaying ? 'something IS playing' : 'nothing is playing'}\n'}'
                    'SCREEN NOW:\n$screen',
              }
            ],
          }
        ],
        'tools': [
          {'functionDeclarations': declarations}
        ],
        'toolConfig': {
          'functionCallingConfig': {'mode': 'ANY'}
        },
        'generationConfig': {
          'temperature': 0.1,
          // One tap at a time needs little reasoning; unbounded thinking
          // made steps take 10–25 s.
          if (_thinkingBudget) 'thinkingConfig': {'thinkingBudget': 512},
        },
      };

  static const instructions = '''
You operate the apps of a small Android smartwatch (about 320×385) for the wearer's voice assistant. Each turn you get the task, what you have done so far, and the screen now. Choose exactly ONE action.

The screen: the first line is package/Activity and the size in pixels. A quoted line is text. A line [n] is something to act on; n is its node_id. Kinds: tap, input (its value, or placeholder marked (hint)), scroll, check[x]/check[ ], sel. A drop-down or dialog over the app comes first, between — on top — and — under it —. "(keyboard open …)" means the keyboard covers the screen: press_enter submits what you typed, press_back closes it.

Rules:
- A shortcut does in one step what taps take ten: play, search, navigate or whatsapp. Try it first when it fits — but it is only a start. If "play" plays nothing, search in the app and tap the best result; if a search opens with no results, type it into the app's search box yourself.
- You are the one doing the task. Keep going — different buttons, the search box, scrolling — until it is done or truly impossible.
- Stay in the app the task names. Move to another app only if the task itself says to; otherwise, if the app truly cannot do it, finish "stuck" and say why.
- A page that shows only the tab bar, a spinner, "Loading" or "Slow connection" is still loading: wait 3 seconds and look again (several times if needed). Do not tap away from it — that throws away the page you were opening.
- After typing into a search box or a recipient field, press_enter.
- If an action did not change the screen, do something different. Never repeat a failing action more than twice.
- A screen with nothing on it may still be loading: wait 2–3 seconds once or twice, then try another way.
- Never send, post, pay, buy, delete or call unless CONFIRMED is yes. Get everything ready, then finish with status "confirm" and a message saying exactly what the final tap will do ("Send 'running late' to Emmanuel on WhatsApp").
- A login, a code, payment details, or a choice the task does not settle (two people with the same name): finish with status "ask" and the question.
- If it cannot be done after a few different tries, finish with "stuck" and say what you saw.
- A chat list shows each chat's last message whoever wrote it. To say who wrote something, open the chat: the wearer's own messages sit on the right, marked sent or read.
- A "Pause" button, a now-playing bar or "Playing" means something is already playing. Do not tap Play again: on most players it pauses.
- SOUND NOW tells you whether audio is playing. For a play task, "something IS playing" right after your play tap means it worked: finish "done".
- Finish "done" only once you have seen it happen on screen — the song playing, the message showing as sent. Then give the facts the wearer wants: what was sent, what is playing, what the screen says.''';

  static const declarations = [
    {
      'name': 'shortcut',
      'description': 'Open an app at the right place in one step. play: play query in app. search: app\'s search results for query. navigate: Google Maps directions to query. whatsapp: chat with number (or contact name) with text typed in, not sent.',
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {'type': 'string', 'enum': ['play', 'search', 'navigate', 'whatsapp']},
          'app': {'type': 'string'},
          'query': {'type': 'string'},
          'number': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['action'],
      },
    },
    {
      'name': 'open_app',
      'description': 'Open an app by name.',
      'parameters': {
        'type': 'object',
        'properties': {'app_name': {'type': 'string'}},
        'required': ['app_name'],
      },
    },
    {
      'name': 'tap',
      'description': 'Tap [n] by node_id, or a point x,y in pixels.',
      'parameters': {
        'type': 'object',
        'properties': {'node_id': {'type': 'integer'}, 'x': {'type': 'number'}, 'y': {'type': 'number'}},
      },
    },
    {
      'name': 'type_text',
      'description': 'Set the text of an input (node_id), or of the focused one.',
      'parameters': {
        'type': 'object',
        'properties': {'text': {'type': 'string'}, 'node_id': {'type': 'integer'}},
        'required': ['text'],
      },
    },
    {'name': 'press_enter', 'description': 'The keyboard\'s Enter / Search / Done / Send key.', 'parameters': {'type': 'object', 'properties': {}}},
    {'name': 'press_back', 'description': 'Back.', 'parameters': {'type': 'object', 'properties': {}}},
    {'name': 'press_home', 'description': 'Home.', 'parameters': {'type': 'object', 'properties': {}}},
    {
      'name': 'scroll',
      'description': 'Scroll a list: down shows more below.',
      'parameters': {
        'type': 'object',
        'properties': {
          'direction': {'type': 'string', 'enum': ['up', 'down', 'left', 'right']},
          'node_id': {'type': 'integer'},
        },
        'required': ['direction'],
      },
    },
    {
      'name': 'swipe',
      'description': 'Swipe from x1,y1 to x2,y2 in pixels.',
      'parameters': {
        'type': 'object',
        'properties': {'x1': {'type': 'number'}, 'y1': {'type': 'number'}, 'x2': {'type': 'number'}, 'y2': {'type': 'number'}},
        'required': ['x1', 'y1', 'x2', 'y2'],
      },
    },
    {
      'name': 'wait',
      'description': 'Wait for the app to load, 1–10 seconds.',
      'parameters': {
        'type': 'object',
        'properties': {'seconds': {'type': 'integer'}},
        'required': ['seconds'],
      },
    },
    {
      'name': 'finish',
      'description': 'Stop and report.',
      'parameters': {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'enum': ['done', 'confirm', 'ask', 'stuck']},
          'message': {'type': 'string'},
        },
        'required': ['status', 'message'],
      },
    },
  ];

  static String _brief(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final s = args.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    return '{${_clip(s, 120)}}';
  }

  static String _clip(String s, int max) => s.length > max ? '${s.substring(0, max)}…' : s;
}

class HelperResult {
  HelperResult(this.status, this.message, {this.steps = 0, this.usd = 0});

  /// done, confirm, ask or stuck.
  final String status;
  final String message;
  final int steps;
  final double usd;

  /// What the voice model is told — the outcome, and what to do with it.
  Map<String, dynamic> toToolResult() => switch (status) {
        'done' => {'success': true, 'result': 'Done: $message'},
        'confirm' => {
            'success': true,
            'result': 'Ready, not done yet: $message. Ask the wearer. On a yes, call '
                'do_on_device again with the same task and confirmed true — the screen is left as it is.',
          },
        'ask' => {'success': true, 'result': 'Needs the wearer: $message Ask them, then call do_on_device again with the answer in the task.'},
        'cancelled' => {'success': false, 'error': 'Stopped because the wearer asked for something else. Do not mention it unless asked.'},
        _ => {
            'success': false,
            'error': 'Could not do it: $message Tell the wearer plainly and ask what they want. Do not start another attempt — in this app or another — unless they ask.',
          },
      };
}

class HelperError implements Exception {
  HelperError(this.message);
  final String message;
  @override
  String toString() => message;
}
