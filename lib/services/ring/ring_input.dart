import 'package:flutter/services.dart';

/// The ring's second path: it is also a Bluetooth touchscreen that injects one
/// of two canned swipes — up for a tap or swipe, down for a double-tap
/// (SMART_RING_PROTOCOL.md §11). `RingInputChannel` forwards a copy of every
/// input event and can swallow the ones from external devices.
///
/// One stream for the whole app. A second `receiveBroadcastStream()` would
/// share the single native sink, and cancelling either would cut the other off
/// — and would reset `blockExternal` underneath it.
enum RingHidGesture { tap, hold, swipeUp, swipeDown, swipeLeft, swipeRight }

/// A finished touch from a device that is not part of the device.
class RingHidEvent {
  const RingHidEvent({
    required this.gesture,
    required this.ms,
    required this.device,
    required this.blocked,
  });

  final RingHidGesture gesture;
  final int ms;
  final String device;

  /// FOX-1 consumed it, so it did not move the UI.
  final bool blocked;

  @override
  String toString() => '${gesture.name} (${ms}ms, $device)';
}

/// Movement thresholds match the harness's, so its log and production agree.
RingHidGesture ringGestureOf(double dx, double dy, int ms) {
  if (dx.abs() < 24 && dy.abs() < 24) {
    return ms < 350 ? RingHidGesture.tap : RingHidGesture.hold;
  }
  if (dx.abs() > dy.abs()) {
    return dx > 0 ? RingHidGesture.swipeRight : RingHidGesture.swipeLeft;
  }
  return dy > 0 ? RingHidGesture.swipeDown : RingHidGesture.swipeUp;
}

class RingInput {
  RingInput._();

  static const _method = MethodChannel('ai.fox1/ring_input');
  static const _channel = EventChannel('ai.fox1/ring_input/events');

  /// Everything the channel reports: `key`, `motion`, `touch`, `device`.
  static final Stream<Map<String, dynamic>> events = _channel
      .receiveBroadcastStream()
      .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)));

  /// Completed gestures only. The UP carries the whole movement; the DOWN has
  /// no `ms` and would double every gesture.
  static final Stream<RingHidEvent> gestures = events
      .where((e) => e['type'] == 'touch' && e.containsKey('ms'))
      .map((e) => RingHidEvent(
            gesture: ringGestureOf((e['dx'] as num).toDouble(),
                (e['dy'] as num).toDouble(), (e['ms'] as num).toInt()),
            ms: (e['ms'] as num).toInt(),
            device: e['device']?.toString() ?? '?',
            blocked: e['blocked'] == true,
          ));

  /// Swallow touches from external devices inside FOX-1. Without this the
  /// ring's canned swipes flip the launcher's pages under the wearer.
  static Future<bool> setBlockExternal(bool on) async =>
      await _method.invokeMethod<bool>('setBlockExternal', {'on': on}) ?? false;

  static Future<List<Map<String, dynamic>>> listInputDevices() async {
    final list = await _method.invokeListMethod<Map>('listInputDevices');
    return [
      for (final m in list ?? const <Map>[])
        m.map((k, v) => MapEntry(k.toString(), v)),
    ];
  }
}
