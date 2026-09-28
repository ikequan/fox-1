import 'package:flutter/services.dart';

class ScreenAutomationService {
  static const _channel = MethodChannel('ai.fox1/screen_automation');

  /// Whether FOX-1 is switched on in Android's accessibility settings.
  /// Independent of whether the system has bound the service yet.
  Future<bool> isServiceEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether FOX-1 may put its accessibility service back when Android drops
  /// it (`granted`: WRITE_SECURE_SETTINGS, given once over ADB), whether the
  /// wearer wants it on, and whether this call just did (`restored`).
  Future<({bool granted, bool wanted, bool restored})> keepStatus() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('keepStatus') ?? const {};
      return (
        granted: m['granted'] == true,
        wanted: m['wanted'] == true,
        restored: m['restored'] == true,
      );
    } catch (_) {
      return (granted: false, wanted: false, restored: false);
    }
  }

  /// `enabled` — switched on in Settings. `bound` — the system has actually
  /// bound the service in the current process. `enabled && !bound` is normal
  /// for a moment after every process start, including boot.
  Future<({bool enabled, bool bound})> getServiceStatus() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('getServiceStatus');
      return (
        enabled: result?['enabled'] as bool? ?? false,
        bound: result?['bound'] as bool? ?? false,
      );
    } catch (_) {
      return (enabled: false, bound: false);
    }
  }

  /// Hash of the current screen contents. Safe to sample around an
  /// interaction — unlike [getScreen] it does not renumber node ids.
  Future<String?> screenSignature() async {
    try {
      return await _channel.invokeMethod<String>('getScreenSignature');
    } catch (_) {
      return null;
    }
  }

  /// The screen as the model reads it: `{success, screen}` where `screen` is
  /// the compact text form (see `Fox1AccessibilityService.getCompactScreen`).
  ///
  /// [keep] makes its `[n]` ids the ones `tap` and `scroll` take, retiring the
  /// previous ones. Anything reading the screen in the background — waiting
  /// for an app, a screen watch — passes `keep: false` so the ids the model is
  /// holding stay valid.
  Future<Map<String, dynamic>> getScreen({bool keep = true}) async {
    try {
      final result = await _channel.invokeMethod('getCompactScreen', {'keep': keep});
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// The app a compact screen belongs to — its header's package.
  static String packageOf(String screen) =>
      screen.split('\n').first.split(RegExp(r'[/ ]')).first;

  /// Whether a compact screen has anything under its header. An app that
  /// has just come to the front has a window but, for a second or more,
  /// nothing drawn in it: Spotify read as its header alone, twice, and the
  /// agent decided there was nothing there.
  static bool hasContent(String screen) => screen.trim().contains('\n');

  /// The raw nested accessibility tree — what the model used to get. Only the
  /// Hub's developer comparison reads it now. Renumbers the ids like [getScreen].
  Future<Map<String, dynamic>> getScreenTree() async {
    try {
      final result = await _channel.invokeMethod('getScreen');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Where a real touch on [nodeId] lands, or null when it is gone or off
  /// screen.
  Future<({double x, double y})?> nodeCenter(int nodeId) async {
    try {
      final r = await _channel.invokeMethod<List>('nodeCenter', {'node_id': nodeId});
      if (r == null || r.length != 2) return null;
      return (x: (r[0] as num).toDouble(), y: (r[1] as num).toDouble());
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> tap({int? nodeId, String? text, double? x, double? y}) async {
    try {
      final result = await _channel.invokeMethod('tap', {
        'node_id': ?nodeId,
        'text': ?text,
        'x': ?x,
        'y': ?y,
      });
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> swipe(double x1, double y1, double x2, double y2, {int durationMs = 300}) async {
    try {
      final result = await _channel.invokeMethod('swipe', {
        'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2,
        'duration_ms': durationMs,
      });
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> typeText(String text, {int? nodeId}) async {
    try {
      final result = await _channel.invokeMethod('typeText', {'text': text, 'node_id': ?nodeId});
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> pressBack() async {
    try {
      final result = await _channel.invokeMethod('pressBack');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> pressEnter() async {
    try {
      final result = await _channel.invokeMethod('pressEnter');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> pressHome() async {
    try {
      final result = await _channel.invokeMethod('pressHome');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> scroll(String direction, {int? nodeId}) async {
    try {
      final result = await _channel.invokeMethod('scroll', {
        'direction': direction,
        'node_id': ?nodeId,
      });
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }
}
