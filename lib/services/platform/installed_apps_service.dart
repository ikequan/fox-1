import 'package:flutter/services.dart';
import '../../models/app_info.dart';

/// Queries installed apps and launches them via platform channel.
class InstalledAppsService {
  static const _channel = MethodChannel('ai.fox1/apps');

  /// Names only, kept a few minutes: the agent looks an app up on every
  /// launch, and drawing every icon each time for a name was wasted work.
  static Future<List<AppInfo>>? _names;
  static DateTime _namesAt = DateTime(0);

  Future<List<AppInfo>> getAppNames() {
    if (_names == null || DateTime.now().difference(_namesAt) > const Duration(minutes: 5)) {
      _namesAt = DateTime.now();
      _names = getInstalledApps(icons: false);
    }
    return _names!;
  }

  /// Whether any app is playing audio right now.
  Future<bool> isMusicActive() async {
    try {
      return await _channel.invokeMethod<bool>('isMusicActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<List<AppInfo>> getInstalledApps({bool icons = true}) async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getInstalledApps', {'icons': icons});
      return result
          .map((e) => AppInfo.fromMap(e as Map<dynamic, dynamic>))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (e) {
      return [];
    }
  }

  /// An app opened at the right place in one step (see
  /// `InstalledAppsChannel.openShortcut`): `kind` is play, search, navigate
  /// or whatsapp.
  Future<Map<String, dynamic>> openShortcut(String kind,
      {String? package, String query = '', String? number, String? text}) async {
    try {
      final r = await _channel.invokeMethod('openShortcut', {
        'kind': kind,
        'package': package,
        'query': query,
        'number': number,
        'text': text,
      });
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      return {'success': false, 'error': '$e'};
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
