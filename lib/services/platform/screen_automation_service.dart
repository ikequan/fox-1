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

  Future<Map<String, dynamic>> getScreen() async {
    try {
      final result = await _channel.invokeMethod('getScreen');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
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

  Future<Map<String, dynamic>> typeText(String text) async {
    try {
      final result = await _channel.invokeMethod('typeText', {'text': text});
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
