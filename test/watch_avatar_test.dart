import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/providers/providers.dart';
import 'package:fox1/watch_avatar/watch_avatar.dart';
import 'package:fox1/widgets/live_mascot.dart';
import 'package:fox1/widgets/mascot.dart';

/// `watch_avatar` was written without a Dart toolchain; these catch what that
/// leaves, on top of the app's own wiring.
void main() {
  Future<void> draw(WidgetTester tester, AvatarController c) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(width: 320, height: 385, child: WatchAvatar(controller: c)),
          ),
        ),
      );

  testWidgets('both characters, every state and quick switches mid-blend, at the device size',
      (tester) async {
    for (final base in [const AvatarParams(), AvatarParams.fox]) {
      final c = AvatarController(params: base);
      await draw(tester, c);
      for (final s in AvatarState.values) {
        c.state = s;
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 800));
      }
      for (var i = 0; i < 24; i++) {
        c.state = AvatarState.values[(i * 5) % AvatarState.values.length];
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the other layouts, eye shapes, face shape, lite and clock settings draw too',
      (tester) async {
    final variants = <AvatarParams>[
      const AvatarParams(layout: Layout.figure, faceShape: FaceShape.squircle, eyeShape: EyeShape.round),
      const AvatarParams(eyeShape: EyeShape.square, clock24: false, glanceStyle: GlanceStyle.sharp),
      AvatarParams.fox.withValue('clock', false).withValue('layout', Layout.figure),
    ];
    for (final p in variants) {
      final c = AvatarController(params: p, lite: true);
      await draw(tester, c);
      for (final s in [AvatarState.idle, AvatarState.love, AvatarState.charging]) {
        c.state = s;
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  group('what the avatar shows', () {
    const plugged = (plugged: true, level: 60), full = (plugged: true, level: 100);
    const low = (plugged: false, level: 12), fine = (plugged: false, level: 60);

    test('the conversation comes first, even on the charger', () {
      expect(avatarStateFor(MascotMood.listening, battery: plugged), AvatarState.listening);
      expect(avatarStateFor(MascotMood.speaking, battery: low), AvatarState.speaking);
      expect(avatarStateFor(MascotMood.thinking, battery: full), AvatarState.thinking);
    });

    test('then the brief reactions, the three the avatar lacks borrowing the nearest', () {
      expect(avatarStateFor(MascotMood.confused, battery: plugged), AvatarState.confused);
      expect(avatarStateFor(MascotMood.angry), AvatarState.sad);
      expect(avatarStateFor(MascotMood.excited), AvatarState.happy);
      expect(avatarStateFor(MascotMood.sleepy), AvatarState.sleeping);
    });

    test('then the battery, only while idle, and only on the pages that ask', () {
      expect(avatarStateFor(MascotMood.idle, battery: plugged), AvatarState.charging);
      expect(avatarStateFor(MascotMood.idle, battery: full), AvatarState.fullBattery);
      expect(avatarStateFor(MascotMood.idle, battery: low), AvatarState.lowBattery);
      expect(avatarStateFor(MascotMood.idle, battery: fine), AvatarState.idle);
      expect(avatarStateFor(MascotMood.idle), AvatarState.idle);
    });
  });

  test('a saved design comes back as saved; junk or nothing gives the default', () {
    final p = AvatarParams.fox.withValue('eyeShape', EyeShape.round).withValue('speed', 1.5);
    expect(loadAvatarParams(jsonEncode(p.toJson())), p);
    // The default is the fox's own design.
    expect(loadAvatarParams(null), AvatarParams.fox);
    expect(loadAvatarParams('{not json'), AvatarParams.fox);
    expect(loadAvatarParams('[1,2]'), AvatarParams.fox);
  });

  test('the drawn design follows the chosen character, keeping hand-picked colours', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // A new device: the fox, in the fox's own colours.
    expect(c.read(liveAvatarParamsProvider).character, Character.fox);
    expect(c.read(liveAvatarParamsProvider).body, AvatarParams.fox.body);

    c.read(mascotProvider.notifier).state = Mascot.bloub;
    final bloub = c.read(liveAvatarParamsProvider);
    expect(bloub.character, Character.bloub);
    expect(bloub.body, const AvatarParams().body, reason: 'untouched defaults swap');

    const picked = Color(0xFF3355AA);
    c.read(avatarParamsProvider.notifier).state = AvatarParams.fox.withValue('body', picked);
    expect(c.read(liveAvatarParamsProvider).body, picked, reason: 'hand-picked stays');
  });
}
