import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ring_input.dart';
import 'ring_service.dart';

/// The ring as a control for the assistant — the intended model, kept deliberately
/// plain:
///
/// - **Press and hold** summons the assistant if it is asleep, and the wearer's
///   voice reaches Gemini for as long as they hold. Holding again while she is
///   talking cuts her off: her audio is dropped at once and the mic gate is
///   forced open, so Gemini hears the wearer over her and interrupts itself.
/// - **Release** ends the override. The conversation carries on hands-free —
///   Gemini's own end-of-speech detection takes it from there.
/// - **Double-tap** (the ring's canned swipe down) stands her down.
/// - A single tap or swipe (canned swipe up) is swallowed and does nothing;
///   left alone it would flip the launcher's pages.
///
/// Everything hardware-shaped is injected, so the rules above are testable
/// without a ring, a session or a platform channel.
class RingGestures {
  RingGestures({
    required this.buttons,
    required this.gestures,
    required this.hold,
    required this.standDown,
    this.block,
  });

  final Stream<RingButtonEvent> buttons;
  final Stream<RingHidEvent> gestures;

  /// True while the wearer holds the ring.
  final Future<void> Function(bool holding) hold;
  final Future<void> Function() standDown;

  /// Turns swallowing of external touches on and off.
  final Future<bool> Function(bool on)? block;

  StreamSubscription? _buttonSub, _gestureSub;
  bool _holding = false;
  bool _busy = false;
  bool get holding => _holding;
  bool get running => _buttonSub != null;

  Future<void> start() async {
    if (running) return;
    _buttonSub = buttons.listen(_onButton);
    _gestureSub = gestures.listen(_onGesture);
    await block?.call(true);
    debugPrint('[RING] gestures on — hold to talk, double-tap to stand down');
  }

  Future<void> stop() async {
    await _buttonSub?.cancel();
    await _gestureSub?.cancel();
    _buttonSub = null;
    _gestureSub = null;
    if (_holding) await _apply(false);
    await block?.call(false);
  }

  /// The app came back to the front. Android drops the swallow-external-touches
  /// flag whenever the input channel's listener goes away — for instance when
  /// the launcher is recreated — so assert it again rather than assume it.
  Future<void> resume() async {
    if (!running) return;
    final on = await block?.call(true);
    debugPrint('[RING] resumed — swallowing ring touches: ${on ?? 'n/a'}');
  }

  void _onButton(RingButtonEvent e) {
    unawaited(_apply(e.pressed));
  }

  void _onGesture(RingHidEvent e) {
    switch (e.gesture) {
      case RingHidGesture.swipeDown:
        debugPrint('[RING] double-tap — standing down');
        unawaited(standDown());
      case RingHidGesture.swipeUp:
        // Tap or swipe. Nothing is mapped to it yet; swallowing it is the
        // point, so the launcher does not move under the wearer.
        break;
      default:
        break;
    }
  }

  /// Waking a session takes a moment, and the wearer can let go inside it.
  /// The last thing they did wins, and only one call is ever in flight.
  Future<void> _apply(bool holding) async {
    _holding = holding;
    if (_busy) return;
    _busy = true;
    try {
      var want = _holding;
      while (true) {
        await hold(want);
        if (_holding == want) break;
        want = _holding;
      }
    } catch (e) {
      debugPrint('[RING] hold-to-talk failed: $e');
    } finally {
      _busy = false;
    }
  }
}
