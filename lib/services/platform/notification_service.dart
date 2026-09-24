import 'dart:async';
import 'package:flutter/services.dart';
import '../../models/notification_info.dart';

/// Reads and manages notifications via NotificationListenerService.
class NotificationService {
  static const _channel = MethodChannel('ai.fox1/notifications');
  static const _eventChannel = EventChannel('ai.fox1/notifications/events');

  StreamSubscription? _eventSub;
  final _notifications = StreamController<List<NotificationInfo>>.broadcast();

  Stream<List<NotificationInfo>> get notifications => _notifications.stream;

  void startListening() {
    _eventSub = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is List) {
        final notifs = event
            .map((e) => NotificationInfo.fromMap(e as Map<dynamic, dynamic>))
            .toList();
        _notifications.add(notifs);
      }
    });
  }

  Future<List<NotificationInfo>> getActiveNotifications() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getActiveNotifications');
      return result
          .map((e) => NotificationInfo.fromMap(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> dismissNotification(String key) async {
    await _channel.invokeMethod('dismissNotification', {'key': key});
  }

  Future<bool> isListenerEnabled() async {
    try {
      return await _channel.invokeMethod('isListenerEnabled') as bool;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestListenerPermission() async {
    await _channel.invokeMethod('requestListenerPermission');
  }

  void dispose() {
    _eventSub?.cancel();
    _notifications.close();
  }
}
