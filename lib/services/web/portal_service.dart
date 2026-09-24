import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/providers.dart';
import '../platform/hotspot_service.dart';
import '../platform/quick_settings_service.dart';
import 'portal_api.dart';
import 'portal_auth.dart';
import 'settings_server.dart';

/// The wearer's portal: the device's web server, for their phone or laptop —
/// notes, health, conversations, memory and settings (docs/HUB_API.md).
///
/// Off by default. On from Controls, Settings or the assistant (`web_portal`), on
/// the Wi-Fi the device is already on, or its own hotspot when it is on none —
/// with a new PIN each time. Off again after [idleTimeout] without a
/// signed-in request, and every session ends with it.
class PortalService {
  PortalService(this._ref);

  final Ref _ref;

  static const port = 8080;
  static const idleTimeout = Duration(minutes: 30);

  PortalAuth? _auth;
  String? _ip, _address;
  HotspotInfo? _hotspot;
  Timer? _idle;
  DateTime? _closesAt;
  bool _starting = false;
  bool _held = false;
  bool _visited = false;
  final _changes = StreamController<void>.broadcast();

  bool get running => _auth != null;
  bool get starting => _starting;

  /// A phone has signed in since the Hub was turned on. First-time setup
  /// swaps the QR code for "continue on your phone" once this is true.
  bool get visited => _visited;
  String? get address => _address;
  String? get pin => _auth?.pin;

  /// What the device's QR code opens. The PIN rides in the fragment, which a
  /// browser never sends, so it signs the wearer in without being logged.
  String? get openUrl => running ? '$_address/#pin=${_auth!.pin}' : null;

  /// Set when the portal had to bring up its own hotspot.
  HotspotInfo? get hotspot => _hotspot;
  DateTime? get closesAt => _closesAt;
  Stream<void> get changes => _changes.stream;

  /// Turns the portal on. Returns why it could not, or null.
  Future<String?> start() async {
    if (running) {
      _touch();
      return null;
    }
    if (_starting) return null;
    _starting = true;
    _changed();
    HotspotInfo? hotspot;
    try {
      // The Wi-Fi the device is already on first — the phone usually is too,
      // and it keeps the phone's own internet.
      var ip = await SettingsServer.wifiIp();
      // Wi-Fi on but not connected yet — just after a restart, say: give it
      // a moment rather than taking the network away with a hotspot.
      if (ip == null && await QuickSettingsService().isWifiEnabled()) {
        for (var i = 0; i < 12 && ip == null; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          ip = await SettingsServer.wifiIp();
        }
      }
      if (ip == null) {
        if (!(await Permission.location.request()).isGranted) {
          return 'The hotspot needs the location permission';
        }
        hotspot = await HotspotService.start();
        if (hotspot == null) return 'Could not start the hotspot';
        ip = hotspot.ip;
      }
      final auth = PortalAuth();
      final address = 'http://$ip:$port';
      // Just after a restart the port can still belong to the process that
      // is going away, for a moment. Try again for a few seconds before
      // calling it a failure.
      for (var attempt = 1;; attempt++) {
        try {
          await SettingsServer.instance.start(
            ip,
            auth: auth,
            api: PortalApi(auth: auth, address: address, closesAt: () => _closesAt, stop: stop),
            onVisit: _visit,
          );
          break;
        } on SocketException catch (e) {
          if (attempt >= 8) rethrow;
          debugPrint('[PORTAL] port busy ($attempt): ${e.osError?.message ?? e.message}');
          await SettingsServer.instance.stop();
          await Future<void>.delayed(const Duration(milliseconds: 750));
        }
      }
      _auth = auth;
      _ip = ip;
      _address = address;
      _hotspot = hotspot;
      _touch();
      debugPrint('[PORTAL] on at $address'
          '${hotspot == null ? '' : ' — hotspot "${hotspot.ssid}"'}');
      return null;
    } catch (e) {
      if (hotspot != null) await HotspotService.stop();
      await SettingsServer.instance.stop();
      debugPrint('[PORTAL] could not start: $e');
      return 'Could not start the portal: $e';
    } finally {
      _starting = false;
      _publish();
    }
  }

  Future<void> stop() async {
    if (!running) return;
    _idle?.cancel();
    _idle = null;
    _closesAt = null;
    _auth = null;
    _visited = false;
    _ip = null;
    _address = null;
    final hotspot = _hotspot;
    _hotspot = null;
    try {
      await SettingsServer.instance.stop();
    } catch (e) {
      debugPrint('[PORTAL] stopping: $e');
    }
    if (hotspot != null) await HotspotService.stop();
    debugPrint('[PORTAL] off');
    _publish();
  }

  /// the assistant's `web_portal` tool.
  Future<Map<String, dynamic>> toolCall(bool on) async {
    if (!on) {
      await stop();
      return {'success': true, 'result': 'FOX-1 Hub is off.'};
    }
    final why = await start();
    if (why != null) return {'success': false, 'error': why};
    final hotspot = _hotspot;
    return {
      'success': true,
      'result': {
        'address': _address,
        'pin': pin,
        if (hotspot != null) 'wifi': {'name': hotspot.ssid, 'password': hotspot.password},
        'note': 'Tell the wearer the address and the PIN, the PIN digit by digit'
            '${hotspot != null ? ", and to join the device's Wi-Fi first" : ''}. '
            'Controls on the device shows a QR code that opens it already signed '
            'in. It turns itself off after ${idleTimeout.inMinutes} minutes unused.',
      },
    };
  }

  /// The address a phone should use now, if it is not the one the Hub is
  /// showing — Wi-Fi came up, or changed, after it started. First-time setup
  /// checks this so its QR code is never for an address nobody can reach.
  Future<String?> betterAddress() async {
    if (!running || _hotspot != null) return null;
    final ip = await SettingsServer.wifiIp();
    return ip != null && ip != _ip ? ip : null;
  }

  /// Keeps the Hub on however long it goes unused — first-time setup, where
  /// the device shows nothing but the Hub's code. Off again, the usual
  /// [idleTimeout] starts from now.
  void hold(bool on) {
    if (_held == on) return;
    _held = on;
    _touch();
  }

  void _visit() {
    _touch();
    if (_visited) return;
    _visited = true;
    _changed();
  }

  void _touch() {
    if (!running) return;
    _idle?.cancel();
    if (_held) {
      _idle = null;
      _closesAt = null;
      return;
    }
    _closesAt = DateTime.now().add(idleTimeout);
    _idle = Timer(idleTimeout, () {
      debugPrint('[PORTAL] ${idleTimeout.inMinutes} min unused — turning it off');
      unawaited(stop());
    });
  }

  /// Settings and Controls watch these.
  void _publish() {
    _ref.read(webServerRunningProvider.notifier).state = running;
    _ref.read(webServerHotspotInfoProvider.notifier).state = running
        ? {
            'ssid': _hotspot?.ssid ?? '',
            'password': _hotspot?.password ?? '',
            'ip': _ip!,
            'address': _address!,
            'pin': _auth!.pin,
            'url': openUrl!,
          }
        : null;
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _idle?.cancel();
    _changes.close();
  }
}
