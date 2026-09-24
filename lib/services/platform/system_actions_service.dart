import 'package:flutter/services.dart';

/// System-level actions that need native APIs.
class SystemActionsService {
  static const _events = EventChannel('ai.fox1/system/events');

  /// Cached, and it must be — this getter has two simultaneous subscribers.
  ///
  /// `receiveBroadcastStream()` builds a NEW stream per call, each sending its
  /// own listen and cancel over the same channel. `BridgeTestScreen` and
  /// `CallOrchestrator` both listen here and both are alive while the agent is
  /// on duty, so leaving the screen cancelled one, tore down the native
  /// handler, and left the other's later cancel with nothing to cancel:
  ///
  ///     PlatformException(error, No active stream to cancel, null, null)
  ///       at EventChannel.receiveBroadcastStream
  ///
  /// One stream, ref-counted by Flutter, listened and cancelled once.
  static Stream<String>? _transfers;

  /// The wearer answering the hand-over prompt from the notification.
  ///
  /// The notification is the prompt on this device: the dialer owns the screen
  /// during a call, so an in-app overlay is drawn where nobody can see it.
  /// Emits 'take' or 'back'.
  static Stream<String> get transferActions => _transfers ??= _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['type'] == 'transfer')
      .map((e) => (e as Map)['action'].toString())
      .asBroadcastStream();

  static const _channel = MethodChannel('ai.fox1/system');

  /// Hold the display awake. Required while the agent drives other apps —
  /// AccessibilityService gestures are dropped once the screen times out, which
  /// strands a task half-finished.
  ///
  /// Re-calling refreshes the hold rather than stacking locks, and the native
  /// side expires it after 5 minutes regardless, so a missed release cannot
  /// drain the battery.
  static Future<bool> acquireScreenLock() async {
    try {
      return await _channel.invokeMethod<bool>('acquireScreenLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> releaseScreenLock() async {
    try {
      return await _channel.invokeMethod<bool>('releaseScreenLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Wake the screen and buzz, for something a live person is waiting on.
  static Future<bool> alertWearer({
    bool repeat = true,
    String who = 'Someone',
  }) async {
    try {
      return await _channel.invokeMethod<bool>(
              'alertWearer', {'repeat': repeat, 'who': who}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Wake the screen and buzz once. "Look at your wrist", nothing more.
  ///
  /// Deliberately not [alertWearer], which puts the hand-over overlay up — that
  /// asks the wearer to decide something immediately. A message from a finished
  /// call is not urgent in that way.
  static Future<void> nudge() async {
    try {
      await _channel.invokeMethod('nudgeWearer');
    } catch (_) {}
  }

  /// A short buzz with no screen wake — the ring's hold-to-talk feedback.
  /// [nudge] also turns the screen on, which is wrong for a gesture made with
  /// the wrist down.
  static Future<void> vibrate({int ms = 40, int amplitude = 200}) async {
    try {
      await _channel.invokeMethod('vibrate', {'ms': ms, 'amplitude': amplitude});
    } catch (_) {
      // No vibrator is not an error worth surfacing mid-gesture.
    }
  }

  /// Keeps the CPU running for [d]. With the screen off the device sleeps
  /// between Bluetooth events, and a wake from the ring stalled half-built
  /// until the next event came along. Expires on its own; nothing to release.
  static Future<void> keepCpuAwake(Duration d) async {
    try {
      await _channel.invokeMethod('keepCpuAwake', {'ms': d.inMilliseconds});
    } catch (_) {}
  }

  /// Whether Android lets FOX-1 use the network while the device idles (the
  /// battery-optimisation exemption). Without it, hold-to-talk with the screen
  /// off can find no network at all.
  /// The Impeller setting in the manifest, and the engine's own start-up line
  /// naming the renderer it used — for performance tests that compare them.
  static Future<Map<String, String>> rendererInfo() async {
    try {
      final m = await _channel.invokeMapMethod<String, String>('rendererInfo');
      return m ?? const {};
    } catch (e) {
      return {'error': '$e'};
    }
  }

  static Future<bool> backgroundAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('backgroundAllowed') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android's own prompt for [backgroundAllowed].
  static Future<void> allowBackground() async {
    try {
      await _channel.invokeMethod('allowBackground');
    } catch (_) {}
  }

  /// Whether the hand-over prompt can be drawn over the dialer.
  ///
  /// Without this the prompt has nowhere to go on this device — the in-app
  /// overlay is behind the dialer and the shade will not open over it.
  static Future<bool> canOverlay() async {
    try {
      return await _channel.invokeMethod<bool>('canOverlay') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlay() async {
    try {
      await _channel.invokeMethod('requestOverlay');
    } catch (_) {}
  }

  /// Starts the app again from scratch — after a backup is restored, so
  /// every store loads what was restored. Does not return in practice.
  static Future<void> restartApp() async {
    try {
      await _channel.invokeMethod('restartApp');
    } catch (_) {}
  }

  static Future<bool> stopAlert() async {
    try {
      return await _channel.invokeMethod<bool>('stopAlert') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isScreenLockHeld() async {
    try {
      return await _channel.invokeMethod<bool>('isScreenLockHeld') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> expandStatusBar() async {
    try {
      await _channel.invokeMethod('expandStatusBar');
    } catch (_) {}
  }
}
