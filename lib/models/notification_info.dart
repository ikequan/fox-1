import 'dart:typed_data';

class NotificationInfo {
  final String key;
  final String packageName;
  final String title;
  final String text;
  final Uint8List? icon;
  final DateTime timestamp;

  NotificationInfo({
    required this.key,
    required this.packageName,
    required this.title,
    required this.text,
    this.icon,
    required this.timestamp,
  });

  factory NotificationInfo.fromMap(Map<dynamic, dynamic> map) {
    return NotificationInfo(
      key: map['key'] as String? ?? '',
      packageName: map['packageName'] as String? ?? '',
      title: map['title'] as String? ?? '',
      text: map['text'] as String? ?? '',
      icon: map['icon'] as Uint8List?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestamp'] as int?) ?? 0,
      ),
    );
  }
}
