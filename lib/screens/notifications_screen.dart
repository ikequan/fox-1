import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification_info.dart';
import '../providers/providers.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  List<NotificationInfo> _notifications = [];
  bool _listenerEnabled = false;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _checkAndLoad();
  }

  Future<void> _checkAndLoad() async {
    final service = ref.read(notificationServiceProvider);
    _listenerEnabled = await service.isListenerEnabled();
    if (_listenerEnabled) {
      _notifications = await service.getActiveNotifications();
      service.startListening();
      _sub = service.notifications.listen((notifs) {
        if (mounted) setState(() => _notifications = notifs);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: SafeArea(
        child: _listenerEnabled ? _buildNotificationList() : _buildPermissionPrompt(),
      ),
    );
  }

  Widget _buildPermissionPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.notifications_off_outlined, color: Colors.white38, size: 40),
            const SizedBox(height: 16),
            const Text(
              'Notification access needed',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                ref.read(notificationServiceProvider).requestListenerPermission();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5CC),
                foregroundColor: Colors.black,
              ),
              child: const Text('Grant Access'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationList() {
    if (_notifications.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none, color: Colors.white38, size: 40),
            SizedBox(height: 16),
            Text(
              'No notifications',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _notifications.length,
      itemBuilder: (context, index) {
        final notif = _notifications[index];
        return Dismissible(
          key: Key(notif.key),
          direction: DismissDirection.endToStart,
          onDismissed: (_) {
            ref.read(notificationServiceProvider).dismissNotification(notif.key);
            setState(() => _notifications.removeAt(index));
          },
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            color: Colors.red.withValues(alpha: 0.3),
            child: const Icon(Icons.delete_outline, color: Colors.white54),
          ),
          child: Card(
            color: Colors.white.withValues(alpha: 0.08),
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: notif.icon != null
                  ? Image.memory(notif.icon!, width: 24, height: 24)
                  : const Icon(Icons.notifications, color: Colors.white38, size: 24),
              title: Text(
                notif.title,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                notif.text,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      },
    );
  }
}
