import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/agent/device_helper.dart';

Map<String, dynamic> _call(String name, [Map<String, dynamic> args = const {}]) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {'functionCall': {'name': name, 'args': args}}
            ]
          }
        }
      ],
      'usageMetadata': {'promptTokenCount': 1500, 'candidatesTokenCount': 20},
    };

DeviceHelper _helper(List<Map<String, dynamic>> script, {List<String>? screens, List<String>? did, int maxSteps = 25}) {
  var i = 0, s = 0;
  return DeviceHelper(
    apiKey: () => 'k',
    model: (_) async => script[i++ < script.length ? i - 1 : script.length - 1],
    act: (name, args) async {
      did?.add('$name $args');
      return {'success': true, 'result': 'ok'};
    },
    readScreen: () async => screens == null ? 'screen ${s++}' : screens[(s++).clamp(0, screens.length - 1)],
    maxSteps: maxSteps,
    log: (_) {},
  );
}

void main() {
  test('acts until the model finishes, and reports only the outcome', () async {
    final did = <String>[];
    final r = await _helper([
      _call('shortcut', {'action': 'whatsapp', 'number': 'Emmanuel', 'text': 'late'}),
      _call('finish', {'status': 'confirm', 'message': "Send 'late' to Emmanuel"}),
    ], did: did).run('tell Emmanuel I am late');
    expect(did, ['app_shortcut {action: whatsapp, number: Emmanuel, text: late}']);
    expect(r.status, 'confirm');
    expect(r.steps, 1);
    expect(r.toToolResult()['result'], contains('confirmed true'));
    expect(r.usd, greaterThan(0));
  });

  test('a screen that stops changing ends it as stuck, without the model saying so', () async {
    final r = await _helper([_call('wait', {'seconds': 1})], screens: ['same']).run('search Spotify');
    expect(r.status, 'stuck');
    expect(r.message, contains('stopped changing'));
    expect(r.toToolResult()['success'], false);
  });

  test('the step cap holds', () async {
    final r = await _helper([_call('press_back')], maxSteps: 3).run('loop');
    expect(r.status, 'stuck');
    expect(r.steps, 3);
  });

  test('only its own actions reach the device', () async {
    final did = <String>[];
    await _helper([
      _call('execute', {'task': 'x'}),
      _call('finish', {'status': 'done', 'message': 'ok'}),
    ], did: did).run('t');
    expect(did, isEmpty);
  });

  test('the request carries the task, the steps and the screen — not a conversation', () {
    final req = DeviceHelper.request('play X', confirmed: false, steps: ['1. tap {node_id: 2} → ok'], screen: 'com.x/Main · 320×385');
    final text = ((req['contents'] as List).first as Map)['parts'].first['text'] as String;
    expect(text, contains('TASK: play X'));
    expect(text, contains('CONFIRMED BY THE WEARER: no'));
    expect(text, contains('1. tap'));
    expect(text, contains('com.x/Main'));
  });

  test('cancel stops it at the next step', () async {
    late DeviceHelper h;
    var steps = 0;
    h = DeviceHelper(
      apiKey: () => 'k',
      model: (_) async => _call('press_back'),
      act: (name, args) async {
        if (++steps == 2) h.cancel();
        return {'success': true};
      },
      readScreen: () async => 'screen $steps',
      log: (_) {},
    );
    final r = await h.run('play something');
    expect(r.status, 'cancelled');
    expect(steps, 2);
    expect(r.toToolResult()['error'], contains('Do not mention it'));
  });

  test('out of steps while sound plays is done, not stuck', () async {
    var n = 0;
    final r = await DeviceHelper(
      apiKey: () => 'k',
      model: (_) async => _call('wait', {'seconds': 1}),
      act: (_, _) async => {'success': true},
      readScreen: () async => 'screen ${n++}',
      audioPlaying: () async => true,
      maxSteps: 2,
      log: (_) {},
    ).run('play the podcast');
    expect(r.status, 'done');
    expect(r.message, contains('Audio is playing'));
  });

  test('a failure tells her not to try again on her own', () {
    final e = HelperResult('stuck', 'Spotify would not load.').toToolResult()['error'] as String;
    expect(e, contains('ask what they want'));
    expect(e, contains('in this app or another'));
  });

  test('each step is told whether sound is playing', () {
    final req = DeviceHelper.request('t', confirmed: false, steps: const [], screen: 's', audioPlaying: true);
    final text = ((req['contents'] as List).first as Map)['parts'].first['text'] as String;
    expect(text, contains('SOUND NOW: something IS playing'));
  });
}
