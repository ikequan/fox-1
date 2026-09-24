import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_gestures.dart';
import 'package:fox1/services/ring/ring_input.dart';
import 'package:fox1/services/ring/ring_service.dart';

/// Let queued stream events and the futures they start run.
Future<void> settle() => Future<void>.delayed(Duration.zero);

RingHidEvent hid(RingHidGesture g) =>
    RingHidEvent(gesture: g, ms: 130, device: 'SR116-0767', blocked: true);

RingButtonEvent press() => RingButtonEvent(true, DateTime(2026, 9, 11));
RingButtonEvent release() =>
    RingButtonEvent(false, DateTime(2026, 9, 11), const Duration(seconds: 3));

void main() {
  late StreamController<RingButtonEvent> buttons;
  late StreamController<RingHidEvent> gestures;
  late List<bool> holds;
  late List<bool> blocks;
  var stoodDown = 0;
  Future<void> Function(bool)? slowHold;

  RingGestures build() => RingGestures(
        buttons: buttons.stream,
        gestures: gestures.stream,
        hold: (h) async {
          holds.add(h);
          await slowHold?.call(h);
        },
        standDown: () async => stoodDown++,
        block: (on) async {
          blocks.add(on);
          return on;
        },
      );

  setUp(() {
    buttons = StreamController<RingButtonEvent>.broadcast();
    gestures = StreamController<RingHidEvent>.broadcast();
    holds = [];
    blocks = [];
    stoodDown = 0;
    slowHold = null;
  });

  tearDown(() async {
    await buttons.close();
    await gestures.close();
  });

  test('hold opens the mic, letting go closes it', () async {
    final g = build();
    await g.start();
    buttons.add(press());
    await settle();
    expect(holds, [true]);
    expect(g.holding, isTrue);
    buttons.add(release());
    await settle();
    expect(holds, [true, false]);
    expect(g.holding, isFalse);
  });

  test('letting go while she is still waking up still closes the mic', () async {
    final waking = Completer<void>();
    slowHold = (h) => h ? waking.future : Future.value();
    final g = build();
    await g.start();
    buttons.add(press());
    await settle();
    buttons.add(release()); // the wearer is quick; the session is not
    await settle();
    expect(holds, [true], reason: 'the first call has not returned yet');
    waking.complete();
    await settle();
    await settle();
    expect(holds, [true, false], reason: 'the last thing they did wins');
    expect(g.holding, isFalse);
  });

  test('double-tap stands her down; a tap does nothing', () async {
    final g = build();
    await g.start();
    gestures.add(hid(RingHidGesture.swipeUp));
    await settle();
    expect(stoodDown, 0);
    gestures.add(hid(RingHidGesture.swipeDown));
    await settle();
    expect(stoodDown, 1);
    expect(holds, isEmpty, reason: 'touches never touch the mic');
  });

  test('running swallows the ring\'s touches, stopping gives them back', () async {
    final g = build();
    await g.start();
    expect(blocks, [true]);
    expect(g.running, isTrue);
    await g.stop();
    expect(blocks, [true, false]);
    expect(g.running, isFalse);
  });

  test('stopping mid-hold releases the mic', () async {
    final g = build();
    await g.start();
    buttons.add(press());
    await settle();
    await g.stop();
    expect(holds, [true, false]);
  });

  group('what the ring\'s canned swipes look like', () {
    test('a tap and a hold stay put', () {
      expect(ringGestureOf(0, -2, 120), RingHidGesture.tap);
      expect(ringGestureOf(1, 3, 900), RingHidGesture.hold);
    });

    test('the two canned swipes, as measured on hardware', () {
      // (160,238) → (160,46) is tap/swipe; (160,135) → (160,354) double-tap.
      expect(ringGestureOf(0, -192, 120), RingHidGesture.swipeUp);
      expect(ringGestureOf(0, 219, 150), RingHidGesture.swipeDown);
    });
  });
}
