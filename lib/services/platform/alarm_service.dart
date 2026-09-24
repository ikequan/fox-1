import 'package:flutter/services.dart';

/// Sets alarms and timers via Android's AlarmClock intents.
class AlarmService {
  static const _channel = MethodChannel('ai.fox1/alarm');

  Future<bool> setAlarm(int hour, int minute, {String? message}) async {
    try {
      final args = <String, dynamic>{'hour': hour, 'minute': minute};
      if (message != null) args['message'] = message;
      return await _channel.invokeMethod('setAlarm', args) as bool;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setTimer(int seconds, {String? message}) async {
    try {
      final args = <String, dynamic>{'seconds': seconds};
      if (message != null) args['message'] = message;
      return await _channel.invokeMethod('setTimer', args) as bool;
    } catch (_) {
      return false;
    }
  }
}
