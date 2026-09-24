import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/setup/device_setup.dart';

void main() {
  group('whether setup is done', () {
    test('a new device, with nothing saved, starts at setup', () {
      expect(DeviceSetup.isDone(saved: null, apiKey: ''), isFalse);
    });

    test('a device that already has a key was set up before the flag existed', () {
      expect(DeviceSetup.isDone(saved: null, apiKey: 'AIza-test'), isTrue);
    });

    test('the saved flag wins: "Set up again" sends a set-up device back', () {
      expect(DeviceSetup.isDone(saved: false, apiKey: 'AIza-test'), isFalse);
      expect(DeviceSetup.isDone(saved: true, apiKey: ''), isTrue);
    });
  });

  group('what the FOX-1 Hub is sent', () {
    Map<String, Object?> json({bool hasKey = true, bool mic = true}) => DeviceSetup.json(
          done: false,
          hasKey: hasKey,
          profile: 'Name: Alex',
          mascot: 'fox',
          ringPaired: false,
          granted: {SetupPermission.microphone: mic, SetupPermission.camera: true},
        );

    test('every permission, in order, with what the page needs to show it', () {
      final perms = (json()['permissions'] as List).cast<Map>();
      expect(perms.map((p) => p['id']), SetupPermission.values.map((p) => p.name));
      final mic = perms.first;
      expect(mic['required'], isTrue);
      expect(mic['askedBy'], 'prompt');
      expect(mic['granted'], isTrue);
      final a11y = perms.firstWhere((p) => p['id'] == 'accessibility');
      expect(a11y['askedBy'], 'screen');
      expect(a11y['granted'], isFalse, reason: 'not checked means not granted');
      expect(perms.every((p) => (p['label'] as String).isNotEmpty && (p['why'] as String).isNotEmpty), isTrue);
    });

    test('only the microphone is required', () {
      expect(SetupPermission.values.where((p) => p.required), [SetupPermission.microphone]);
    });

    test('setup can finish once FOX-1 can hold a conversation: a key and the microphone', () {
      expect(json()['canFinish'], isTrue);
      expect(json(hasKey: false)['canFinish'], isFalse);
      expect(json(mic: false)['canFinish'], isFalse);
    });

    test('a permission is found by the name the Hub sends', () {
      expect(SetupPermission.byName('systemSettings'), SetupPermission.systemSettings);
      expect(SetupPermission.byName('nope'), isNull);
      expect(SetupPermission.byName(null), isNull);
    });
  });
}
