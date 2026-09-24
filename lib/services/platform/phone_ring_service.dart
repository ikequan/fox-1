import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ring events from the device's own telephony.
///
/// The alternative to asking the board. The board only sees a call while it
/// holds an HFP link, which is why it currently has to hold the device's single
/// HFP slot all day — and why the wearer's earbud can never have it. If the
/// ring can come from here instead, the board can be armed per call and give
/// the slot back in between.
///
/// `ACTION_PHONE_STATE_CHANGED` needs only `READ_PHONE_STATE` (and
/// `READ_CALL_LOG` for the number on API 29+), both already granted. It is not
/// the default-dialer path and does not need to be.
class PhoneRingService {
  static const _method = MethodChannel('ai.fox1/phone_ring');
  static const _events = EventChannel('ai.fox1/phone_ring/events');

  /// Cached, and it must be. `receiveBroadcastStream()` builds a NEW stream on
  /// every call, each one sending its own listen/cancel over the same channel.
  /// Two of them interleaving is how the second cancel arrived at a Kotlin side
  /// that had nothing left to cancel:
  ///
  ///     PlatformException(error, No active stream to cancel, null, null)
  ///       at EventChannel.receiveBroadcastStream
  ///
  /// One stream, ref-counted by Flutter, listened and cancelled once.
  static Stream<Map<String, dynamic>>? _ring;

  /// `{state: ringing|offhook|idle, number: String}`.
  static Stream<Map<String, dynamic>> get ringEvents => _ring ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(
          (e as Map).map((k, v) => MapEntry(k.toString(), v))))
      .asBroadcastStream();

  /// Whether the number will arrive with the ring. Without it the ring is
  /// still seen, but anonymously — and an anonymous call cannot be matched
  /// against history or the auto-answer rules.
  static Future<bool> hasPermission() async {
    try {
      return await _method.invokeMethod<bool>('hasPermission') ?? false;
    } catch (e) {
      debugPrint('[RING] permission check failed: $e');
      return false;
    }
  }
}
