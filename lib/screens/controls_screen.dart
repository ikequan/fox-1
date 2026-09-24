import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/providers.dart';
import '../services/ring/ring_service.dart';
import '../services/web/portal_service.dart';

class ControlsScreen extends ConsumerStatefulWidget {
  const ControlsScreen({super.key});

  @override
  ConsumerState<ControlsScreen> createState() => _ControlsScreenState();
}

class _ControlsScreenState extends ConsumerState<ControlsScreen> {
  bool _wifi = false;
  bool _bluetooth = false;
  double _brightness = 0.5;
  double _volume = 0.5;
  int _batteryLevel = 100;
  bool _charging = false;

  /// The ring service, captured here: never reach for a provider in dispose.
  RingService? _ring;
  StreamSubscription? _ringSub;

  /// The portal, captured the same way.
  late PortalService _portal;
  StreamSubscription? _portalSub;

  @override
  void initState() {
    super.initState();
    _loadState();
    final ring = ref.read(ringServiceProvider);
    _ring = ring;
    _ringSub = ring.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _portal = ref.read(portalServiceProvider);
    _portalSub = _portal.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ringSub?.cancel();
    _portalSub?.cancel();
    super.dispose();
  }

  Future<void> _loadState() async {
    final service = ref.read(quickSettingsServiceProvider);
    final battery = Battery();

    final results = await Future.wait([
      service.isWifiEnabled(),
      service.isBluetoothEnabled(),
      service.getBrightness(),
      service.getVolume(),
      battery.batteryLevel,
      battery.batteryState,
    ]);

    if (mounted) {
      setState(() {
        _wifi = results[0] as bool;
        _bluetooth = results[1] as bool;
        _brightness = results[2] as double;
        _volume = results[3] as double;
        _batteryLevel = results[4] as int;
        _charging = (results[5] as BatteryState) == BatteryState.charging;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            // Battery status
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _charging ? Icons.battery_charging_full : Icons.battery_full,
                    color: _batteryLevel <= 20 ? Colors.redAccent : const Color(0xFF00E5CC),
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_batteryLevel%',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  ..._ringStatus(),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Toggle grid
            Row(
              children: [
                Expanded(child: _buildToggle('WiFi', Icons.wifi, _wifi, (v) {
                  setState(() => _wifi = v);
                  ref.read(quickSettingsServiceProvider).setWifiEnabled(v);
                })),
                const SizedBox(width: 8),
                Expanded(child: _buildToggle('BT', Icons.bluetooth, _bluetooth, (v) {
                  setState(() => _bluetooth = v);
                  ref.read(quickSettingsServiceProvider).setBluetoothEnabled(v);
                })),
              ],
            ),
            const SizedBox(height: 8),
            _buildPortalTile(),
            const SizedBox(height: 16),
            // Brightness slider
            _buildSlider('Brightness', Icons.brightness_6, _brightness, (v) {
              setState(() => _brightness = v);
              ref.read(quickSettingsServiceProvider).setBrightness(v);
            }),
            const SizedBox(height: 8),
            // Volume slider
            _buildSlider('Volume', Icons.volume_up, _volume, (v) {
              setState(() => _volume = v);
              ref.read(quickSettingsServiceProvider).setVolume(v);
            }),
            const SizedBox(height: 12),
            // Settings button
            Center(
              child: IconButton(
                onPressed: () {
                  Navigator.of(context).pushNamed('/settings');
                },
                icon: const Icon(Icons.settings, color: Colors.white38),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }

  /// The ring, beside the device's own battery — nothing at all until one is
  /// paired, so a wearer without a ring never sees it. Tapping opens Settings,
  /// where the Smart Ring card can pair, sync or forget it.
  List<Widget> _ringStatus() {
    final ring = _ring;
    if (ring == null || !ring.paired) return const [];
    final ready = ring.ready;
    final colour = ready
        ? const Color(0xFF00E5CC)
        : ring.link == RingLink.connecting
            ? Colors.orangeAccent
            : Colors.white38;
    final pct = ring.battery;
    return [
      const SizedBox(width: 10),
      Text('·', style: TextStyle(color: Colors.white.withValues(alpha: 0.2))),
      const SizedBox(width: 10),
      GestureDetector(
        onTap: () => Navigator.of(context).pushNamed('/settings'),
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radio_button_unchecked, color: colour, size: 16),
            const SizedBox(width: 4),
            Text(
              ready && pct != null ? '$pct%' : _ringWord(ring.link),
              style: TextStyle(color: colour, fontSize: 14),
            ),
          ],
        ),
      ),
    ];
  }

  /// Off: a tap turns the portal on. On: the tile shows the PIN, and a tap
  /// opens the QR code that signs the phone straight in.
  Widget _buildPortalTile() {
    final on = _portal.running;
    const accent = Color(0xFF00E5CC);
    return GestureDetector(
      onTap: () async {
        if (_portal.starting) return;
        if (!on) {
          final why = await _portal.start();
          if (!mounted) return;
          if (why != null) {
            await _showMessage(why);
            return;
          }
        }
        if (mounted && _portal.running) await _showPortal();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? accent.withValues(alpha: 0.4) : Colors.white12),
        ),
        child: Row(
          children: [
            Icon(Icons.language, color: on ? accent : Colors.white38, size: 20),
            const SizedBox(width: 10),
            Text('Hub',
                style: TextStyle(color: on ? accent : Colors.white38, fontSize: 12)),
            const Spacer(),
            Text(
              _portal.starting
                  ? 'starting…'
                  : on
                      ? 'PIN ${_portal.pin}'
                      : 'off',
              style: TextStyle(
                color: on ? accent : Colors.white38,
                fontSize: 12,
                letterSpacing: on ? 1.5 : 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPortal() => showDialog<void>(
        context: context,
        builder: (context) {
          final hotspot = _portal.hotspot;
          return AlertDialog(
            backgroundColor: const Color(0xFF111111),
            contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hotspot != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'First join Wi-Fi "${hotspot.ssid}"\npassword ${hotspot.password}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(6),
                  color: Colors.white,
                  child: QrImageView(
                    data: _portal.openUrl ?? '',
                    version: QrVersions.auto,
                    size: 150,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text('PIN ${_portal.pin ?? ''}',
                    style: const TextStyle(
                        color: Color(0xFF00E5CC), fontSize: 20, letterSpacing: 3)),
                Text(_portal.address ?? '',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await _portal.stop();
                },
                child: const Text('Turn off', style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done', style: TextStyle(color: Color(0xFF00E5CC))),
              ),
            ],
          );
        },
      );

  Future<void> _showMessage(String text) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF111111),
          content: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK', style: TextStyle(color: Color(0xFF00E5CC))),
            ),
          ],
        ),
      );

  String _ringWord(RingLink l) => switch (l) {
        RingLink.ready => 'ring',
        RingLink.connecting => 'linking',
        // Paired but not connected: out of range, or waiting on a retry.
        RingLink.idle => 'offline',
        RingLink.unpaired => 'off',
      };

  Widget _buildToggle(
      String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: value
              ? const Color(0xFF00E5CC).withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value
                ? const Color(0xFF00E5CC).withValues(alpha: 0.4)
                : Colors.white12,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: value ? const Color(0xFF00E5CC) : Colors.white38,
                size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: value ? const Color(0xFF00E5CC) : Colors.white38,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(
      String label, IconData icon, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        Icon(icon, color: Colors.white38, size: 18),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF00E5CC),
              inactiveTrackColor: Colors.white12,
              thumbColor: const Color(0xFF00E5CC),
              overlayColor: const Color(0xFF00E5CC).withValues(alpha: 0.2),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
