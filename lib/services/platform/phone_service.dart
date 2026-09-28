import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Dart wrapper for native phone operations via platform channel.
class PhoneService {
  static const _channel = MethodChannel('ai.fox1/phone');

  Future<Map<String, dynamic>> getContacts({String query = ''}) async {
    if (!await _ensurePermission(Permission.contacts)) {
      return {'success': false, 'error': 'Contacts permission denied'};
    }
    try {
      final result = await _channel.invokeMethod('getContacts', {
        'query': query,
      });
      final contacts = (result as List).cast<Map>();
      return {
        'success': true,
        'contacts': contacts.map((c) => Map<String, String>.from(c)).toList(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> getCallHistory({int limit = 20}) async {
    if (!await _ensurePermission(Permission.phone)) {
      return {'success': false, 'error': 'Call log permission denied'};
    }
    try {
      final result = await _channel.invokeMethod('getCallHistory', {
        'limit': limit,
      });
      final history = (result as List).cast<Map>();
      return {
        'success': true,
        'history': history.map((h) => Map<String, dynamic>.from(h)).toList(),
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> makeCall(String phoneNumber) async {
    if (!await _ensurePermission(Permission.phone)) {
      return {'success': false, 'error': 'Phone permission denied'};
    }
    try {
      final result = await _channel.invokeMethod('makeCall', {
        'phone_number': phoneNumber,
      });
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> saveContact(String name, String phoneNumber) async {
    if (!await _ensurePermission(Permission.contacts)) {
      return {'success': false, 'error': 'Contacts permission denied'};
    }
    try {
      final result = await _channel.invokeMethod('saveContact', {
        'name': name,
        'phone_number': phoneNumber,
      });
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> endCall() async {
    if (!await _ensurePermission(Permission.phone)) {
      return {'success': false, 'error': 'Phone permission denied'};
    }
    try {
      final result = await _channel.invokeMethod('endCall');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Sends a text directly; answers once the network has taken it.
  Future<Map<String, dynamic>> sendSms(String to, String text) async {
    if (!await _ensurePermission(Permission.sms)) {
      return {
        'success': false,
        'error': 'Permission to send texts is off. Tell the wearer to allow '
            '"Text messages" in Settings → Permissions, or send it through the '
            'Messages app on screen.',
      };
    }
    try {
      final r = await _channel.invokeMethod('sendSms', {'to': to, 'text': text});
      return Map<String, dynamic>.from(r as Map);
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  Future<bool> _ensurePermission(Permission permission) async {
    var status = await permission.status;
    if (status.isGranted) return true;
    status = await permission.request();
    return status.isGranted;
  }
}
