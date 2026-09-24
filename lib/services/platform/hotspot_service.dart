import 'package:flutter/services.dart';

class HotspotInfo {
  final String ssid;
  final String password;
  final String ip;

  const HotspotInfo({
    required this.ssid,
    required this.password,
    required this.ip,
  });
}

class HotspotService {
  static const _channel = MethodChannel('ai.fox1/hotspot');

  static Future<HotspotInfo?> start() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('startHotspot');
      if (result == null) return null;
      return HotspotInfo(
        ssid: result['ssid'] as String,
        password: result['password'] as String,
        ip: result['ip'] as String,
      );
    } on PlatformException {
      return null;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopHotspot');
    } on PlatformException {
      // ignore
    }
  }
}
