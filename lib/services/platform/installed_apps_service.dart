import 'package:flutter/services.dart';
import '../../models/app_info.dart';

/// Queries installed apps and launches them via platform channel.
class InstalledAppsService {
  static const _channel = MethodChannel('ai.fox1/apps');

  Future<List<AppInfo>> getInstalledApps() async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('getInstalledApps');
      return result
          .map((e) => AppInfo.fromMap(e as Map<dynamic, dynamic>))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (e) {
      return [];
    }
  }

  Future<void> launchApp(String packageName) async {
    await _channel.invokeMethod('launchApp', {'packageName': packageName});
  }

  /// Closes an app by killing its background processes. Returns false if the
  /// platform refused (e.g. asked to close FOX-1 itself).
  ///
  /// Not a force-stop — the system may restart persistent services — but it
  /// clears the app's activities and frees its memory.
  Future<bool> closeApp(String packageName) async {
    try {
      return await _channel.invokeMethod<bool>(
            'closeApp',
            {'packageName': packageName},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Closes every launchable app except FOX-1. Returns how many were swept.
  Future<int> closeAllApps() async {
    try {
      return await _channel.invokeMethod<int>('closeAllApps') ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
