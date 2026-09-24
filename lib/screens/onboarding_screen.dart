import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/providers.dart';
import '../services/web/portal_service.dart';
import '../widgets/live_mascot.dart';

/// First launch: the device shows the FOX-1 Hub's QR code and PIN — with a
/// title and one line of help, so a first-time wearer knows what to do with
/// them — and the wearer sets everything up from their phone. The Hub stays on
/// for as long as this screen does, and the device moves on to its watch
/// face when the Hub says setup is done (`POST /api/setup/done`).
///
/// With no Wi-Fi, the Hub runs on the device's own hotspot, so a Wi-Fi code
/// comes first. Once a phone has signed in, the code gives way to the
/// mascot — a tap brings the code back for another phone.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late final PortalService _hub;
  StreamSubscription<void>? _changes;
  Timer? _network;
  String? _error;
  bool _wifiFirst = true;
  bool _showCode = false;

  static const _accent = Color(0xFF00E5CC);

  @override
  void initState() {
    super.initState();
    _hub = ref.read(portalServiceProvider);
    _hub.hold(true);
    _changes = _hub.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _start();
    // Wi-Fi can connect, or change, after the Hub started: follow it, so the
    // code on screen always opens.
    _network = Timer.periodic(const Duration(seconds: 4), (_) => _followNetwork());
  }

  Future<void> _followNetwork() async {
    if (_hub.visited || _hub.starting) return;
    final ip = await _hub.betterAddress();
    if (ip == null || !mounted) return;
    debugPrint('[SETUP] network changed — moving the Hub to $ip');
    await _hub.stop();
    if (mounted) await _start();
  }

  Future<void> _start({bool retry = true}) async {
    setState(() => _error = null);
    final why = await _hub.start();
    if (!mounted) return;
    setState(() => _error = why);
    // Once more by itself: most failures here are a moment's worth.
    if (why != null && retry) {
      Timer(const Duration(seconds: 3), () {
        if (mounted && !_hub.running) _start(retry: false);
      });
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _network?.cancel();
    _hub.hold(false);
    super.dispose();
  }

  /// Hidden way past setup, for a developer with no phone to hand: hold the
  /// PIN for a few seconds. Settings → "Set up again" brings setup back.
  Future<void> _skip() async {
    final skip = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111111),
        content: const Text('Skip setup? You can run it again from Settings.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Skip', style: TextStyle(color: _accent))),
        ],
      ),
    );
    if (skip != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_done', true);
    ref.read(setupDoneProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    final side = MediaQuery.sizeOf(context).shortestSide;
    return PopScope(
      canPop: false,
      // Material, not a bare ColoredBox: text with no Material behind it is
      // drawn with Flutter's yellow "missing ancestor" underline.
      child: Material(
        color: Colors.black,
        child: SafeArea(child: Center(child: _body(side))),
      ),
    );
  }

  Widget _body(double side) {
    if (_error != null) return _problem(_error!);
    if (!_hub.running) {
      return const SizedBox(
          width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: _accent));
    }
    if (_hub.visited && !_showCode) {
      // A phone is in: the mascot, and a tap for the code again.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _showCode = true),
        child: Stack(
          children: [
            const Positioned.fill(child: LiveMascot(screen: ActiveScreen.home)),
            Positioned(
              left: 0,
              right: 0,
              bottom: side * 0.06,
              // In the character's own ink, like the watch face's time:
              // white would vanish on Bloub's face.
              child: Text('Continue on your phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: ref.watch(liveAvatarParamsProvider).eye.withValues(alpha: 0.75),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    }
    final hotspot = _hub.hotspot;
    // Small enough to leave room for a title and a line of help on the
    // smallest screens (320×385).
    final qr = side * 0.5;
    final title = (side * 0.056).clamp(15, 24).toDouble();
    final hint = (side * 0.036).clamp(11, 15).toDouble();
    if (hotspot != null && _wifiFirst) {
      return _page(
        side: side,
        title: 'Step 1 · Connect your phone',
        titleSize: title,
        qr: _qr('WIFI:T:WPA;S:${_esc(hotspot.ssid)};P:${_esc(hotspot.password)};;', qr),
        below: _hint(
            'Scan to join the Wi-Fi “${hotspot.ssid}”\n'
            'Password ${hotspot.password} · then tap here',
            hint),
        onTap: () => setState(() => _wifiFirst = false),
        step: 0,
        steps: 2,
      );
    }
    final address = (_hub.address ?? '').replaceFirst(RegExp(r'^https?://'), '');
    return _page(
      side: side,
      title: hotspot == null ? 'Set up FOX-1' : 'Step 2 · Open FOX-1 Hub',
      titleSize: title,
      qr: _qr(_hub.openUrl ?? '', qr),
      below: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onLongPress: _skip,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'PIN  ',
                    style: TextStyle(color: Colors.white54, fontSize: hint, letterSpacing: 1)),
                TextSpan(
                    text: _spaced(_hub.pin ?? ''),
                    style: TextStyle(
                        color: _accent,
                        fontSize: (side * 0.075).clamp(18, 30).toDouble(),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ),
          ),
          SizedBox(height: side * 0.02),
          _hint('Scan with your phone’s camera, or go to\n$address and enter the PIN', hint),
        ],
      ),
      onTap: hotspot == null
          ? (_hub.visited ? () => setState(() => _showCode = false) : null)
          : () => setState(() => _wifiFirst = true),
      step: hotspot == null ? null : 1,
      steps: 2,
    );
  }

  Widget _hint(String text, double size) => Text(text,
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white60, fontSize: size, height: 1.35));

  Widget _page({
    required double side,
    required String title,
    required double titleSize,
    required Widget qr,
    required Widget below,
    VoidCallback? onTap,
    int? step,
    required int steps,
  }) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: side * 0.05),
          child: FittedBox(
            // Never taller than the screen, whatever the font scale.
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                        color: Colors.white, fontSize: titleSize, fontWeight: FontWeight.w600)),
                SizedBox(height: side * 0.035),
                qr,
                SizedBox(height: side * 0.035),
                below,
                if (step != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < steps; i++)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == step ? _accent : Colors.white24,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );

  Widget _qr(String data, double size) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: QrImageView(
          data: data,
          version: QrVersions.auto,
          size: size,
          padding: EdgeInsets.zero,
          backgroundColor: Colors.white,
        ),
      );

  Widget _problem(String why) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(why,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _start(retry: false),
              child: const Text('Try again', style: TextStyle(color: _accent)),
            ),
          ],
        ),
      );

  /// "123456" → "123 456": easier to read across a room.
  static String _spaced(String pin) =>
      pin.length == 6 ? '${pin.substring(0, 3)} ${pin.substring(3)}' : pin;

  /// A Wi-Fi QR code escapes \ ; , : and " in the name and password.
  static String _esc(String s) => s.replaceAllMapped(RegExp(r'[\\;,:"]'), (m) => '\\${m[0]}');
}
