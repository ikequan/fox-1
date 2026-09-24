import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart wrapper for the native InCallService.
/// Provides call state events and call control.
class InCallStateService {
  static const _method = MethodChannel('ai.fox1/in_call');
  static const _event = EventChannel('ai.fox1/in_call/events');

  Stream<Map<String, dynamic>>? _callStateStream;

  /// Stream of call state changes: {state: "active"|"dialing"|"ringing"|"disconnected", phoneNumber: "..."}
  Stream<Map<String, dynamic>> get callStateChanges {
    _callStateStream ??= _event.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event as Map);
    });
    return _callStateStream!;
  }

  Future<bool> isDefaultDialer() async {
    try {
      return await _method.invokeMethod<bool>('isDefaultDialer') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestDefaultDialer() async {
    try {
      return await _method.invokeMethod<bool>('requestDefaultDialer') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> endCall() async {
    try {
      final result = await _method.invokeMethod('endCall');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>?> getCallState() async {
    try {
      final result = await _method.invokeMethod('getCallState');
      if (result == null) return null;
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('[IN_CALL] getCallState error: $e');
      return null;
    }
  }
}
