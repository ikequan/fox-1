import 'package:flutter/services.dart';

/// Controls system settings: Wi-Fi, Bluetooth, brightness, volume.
class QuickSettingsService {
  static const _channel = MethodChannel('ai.fox1/settings');

  // WiFi
  Future<bool> isWifiEnabled() async {
    try {
      return await _channel.invokeMethod('isWifiEnabled') as bool;
    } catch (_) {
      return false;
    }
  }

  Future<void> setWifiEnabled(bool enabled) async {
    await _channel.invokeMethod('setWifiEnabled', {'enabled': enabled});
  }

  // Bluetooth
  Future<bool> isBluetoothEnabled() async {
    try {
      return await _channel.invokeMethod('isBluetoothEnabled') as bool;
    } catch (_) {
      return false;
    }
  }

  Future<void> setBluetoothEnabled(bool enabled) async {
    await _channel.invokeMethod('setBluetoothEnabled', {'enabled': enabled});
  }

  /// Android's "Modify system settings" permission, which brightness needs.
  Future<bool> canWriteSettings() async {
    try {
      return await _channel.invokeMethod('canWriteSettings') as bool;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's "Modify system settings" screen for this app.
  Future<void> openWriteSettings() async {
    await _channel.invokeMethod('openWriteSettings');
  }

  // Brightness
  Future<double> getBrightness() async {
    try {
      return (await _channel.invokeMethod('getBrightness') as num).toDouble();
    } catch (_) {
      return 0.5;
    }
  }

  Future<void> setBrightness(double value) async {
    await _channel.invokeMethod('setBrightness', {'value': value});
  }

  // Volume
  Future<double> getVolume() async {
    try {
      return (await _channel.invokeMethod('getVolume') as num).toDouble();
    } catch (_) {
      return 0.5;
    }
  }

  Future<void> setVolume(double value) async {
    await _channel.invokeMethod('setVolume', {'value': value});
  }
}
