import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/providers.dart';
import '../watch_avatar/watch_avatar.dart' show AvatarParams;
import '../widgets/live_mascot.dart';

class WatchfaceScreen extends ConsumerStatefulWidget {
  const WatchfaceScreen({super.key});

  @override
  ConsumerState<WatchfaceScreen> createState() => _WatchfaceScreenState();
}

class _WatchfaceScreenState extends ConsumerState<WatchfaceScreen> {
  final Battery _battery = Battery();
  Timer? _levelPoll;
  StreamSubscription<BatteryState>? _batterySub;
  int _batteryLevel = 100;
  BatteryState _batteryState = BatteryState.full;

  /// The battery over a live mascot: out of sight until the wearer double
  /// taps, then gone again on its own.
  bool _chromeShown = false;
  Timer? _chromeTimer;

  static const _chromeLingers = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _fetchBattery();
    // Real-time battery state updates
    _batterySub = _battery.onBatteryStateChanged.listen((state) {
      if (mounted) {
        setState(() => _batteryState = state);
        _fetchBatteryLevel();
      }
    });
    // Poll battery level every 30s for gradual changes. The time is
    // [_LiveTime], with its own tick: redrawing the whole page twice a second
    // would be two extra frames on top of the avatar's own.
    _levelPoll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _fetchBatteryLevel();
    });
  }

  Future<void> _fetchBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (mounted) {
        setState(() {
          _batteryLevel = level;
          _batteryState = state;
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {}
  }

  @override
  void dispose() {
    _levelPoll?.cancel();
    _chromeTimer?.cancel();
    _batterySub?.cancel();
    super.dispose();
  }

  void _toggleChrome() {
    _chromeTimer?.cancel();
    setState(() => _chromeShown = !_chromeShown);
    if (_chromeShown) {
      _fetchBattery();
      _chromeTimer = Timer(_chromeLingers, () {
        if (mounted) setState(() => _chromeShown = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Black until the settings are read. Before that the mascot is only the
    // default mascot — once Bloub, whose face is off-white — so a device set to the fox
    // flashed white at every start. Waits on loading, not success: if the
    // settings fail to load, the face still appears.
    if (ref.watch(settingsInitProvider).isLoading) {
      return const ColoredBox(color: Colors.black);
    }
    final size = MediaQuery.of(context).size;
    final isCharging = _batteryState == BatteryState.charging;

    // The mascot is the whole watch face. The time sits on it in the
    // watch-face font, weight and size, centred wherever the wearer put it.
    // The battery stays out of the way until a double tap.
    return GestureDetector(
      // Double tap, not a single one: a stray touch on a watch face worn on
      // a wrist must not light it up.
      onDoubleTap: _toggleChrome,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          const Positioned.fill(
            child: LiveMascot(
              screen: ActiveScreen.home,
              battery: true,
              selfTest: true,
            ),
          ),
          const Positioned.fill(child: _LiveTime()),
          Positioned(
            top: size.height * 0.06,
            left: size.width * 0.08,
            child: AnimatedSlide(
              // Off the top of the screen, and back down on a double tap.
              offset: _chromeShown ? Offset.zero : const Offset(0, -2.5),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _chromeShown ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: _BatteryIcon(level: _batteryLevel, charging: isCharging),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

FontWeight _fontWeightFromInt(int weight) => switch (weight) {
  100 => FontWeight.w100,
  300 => FontWeight.w300,
  400 => FontWeight.w400,
  500 => FontWeight.w500,
  600 => FontWeight.w600,
  700 => FontWeight.w700,
  800 => FontWeight.w800,
  _ => FontWeight.w600,
};

/// The time on the mascot's face: the watch-face font, weight and size,
/// in the design's ink colour, centred on the wearer's X/Y. The design's
/// "Show the time" and "24-hour time" still decide whether and how.
///
/// Its own widget and tick, behind its own repaint boundary, so the colon's
/// blink redraws only this — never the avatar underneath.
class _LiveTime extends ConsumerStatefulWidget {
  const _LiveTime();

  @override
  ConsumerState<_LiveTime> createState() => _LiveTimeState();
}

class _LiveTimeState extends ConsumerState<_LiveTime> {
  Timer? _tick;
  DateTime _now = DateTime.now();
  bool _colon = true;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
          _colon = !_colon;
        });
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final design = ref.watch(liveAvatarParamsProvider);
    if (!design.clock) return const SizedBox.shrink();
    final width = MediaQuery.sizeOf(context).width;
    final fontSize = width * ref.watch(watchFontSizeFactorProvider);
    final family = ref.watch(watchFontFamilyProvider);
    final weight = _fontWeightFromInt(ref.watch(watchFontWeightProvider));
    TextStyle styled(double size, {Color? color, Paint? foreground}) =>
        GoogleFonts.getFont(
          family,
          fontSize: size,
          fontWeight: weight,
          color: color,
          foreground: foreground,
          height: 1,
        );
    // The design's ink, outlined in whichever of its other colours stands out
    // most against that ink — so the time reads wherever it is put: on
    // Bloub's face, on the fox's fur, or out over the background.
    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, fontSize * 0.08)
      ..strokeJoin = StrokeJoin.round
      ..color = _halo(design);
    final h24 = _now.hour;
    final hour = design.clock24 ? '$h24' : '${h24 % 12 == 0 ? 12 : h24 % 12}';
    final minute = _now.minute.toString().padLeft(2, '0');
    Widget row({Color? color, Paint? foreground}) {
      final st = styled(fontSize, color: color, foreground: foreground);
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(hour, style: st),
          SizedBox(
            width: fontSize * 0.3,
            child: Text(
              _colon ? ':' : ' ',
              textAlign: TextAlign.center,
              style: st,
            ),
          ),
          Text(minute, style: st),
          if (!design.clock24)
            Text(
              h24 < 12 ? ' AM' : ' PM',
              style: styled(
                fontSize * 0.32,
                color: color,
                foreground: foreground,
              ),
            ),
        ],
      );
    }

    final x = ref.watch(watchTimeXProvider), y = ref.watch(watchTimeYProvider);
    return Align(
      alignment: Alignment(x * 2 - 1, y * 2 - 1),
      child: RepaintBoundary(
        child: Stack(
          children: [
            row(foreground: halo),
            row(color: design.eye),
          ],
        ),
      ),
    );
  }

  /// The design colour that contrasts most with its ink.
  static Color _halo(AvatarParams p) {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    return [p.body, p.muzzle, p.bg].reduce(
      (best, c) => contrast(c, p.eye) > contrast(best, p.eye) ? c : best,
    );
  }
}

class _BatteryIcon extends StatelessWidget {
  final int level;
  final bool charging;

  const _BatteryIcon({required this.level, required this.charging});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Battery outline
        Container(
          width: 28,
          height: 13,
          decoration: BoxDecoration(
            border: Border.all(
              color: charging ? Colors.greenAccent : Colors.white60,
              width: 1.2,
            ),
            borderRadius: BorderRadius.circular(2.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(1.5),
            child: Row(
              children: [
                Expanded(
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: level / 100,
                    child: Container(
                      decoration: BoxDecoration(
                        color: charging
                            ? Colors.greenAccent
                            : level <= 20
                            ? Colors.redAccent
                            : Colors.greenAccent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Tip
        Container(
          width: 2.5,
          height: 6,
          margin: const EdgeInsets.only(left: 0.5),
          decoration: BoxDecoration(
            color: charging ? Colors.greenAccent : Colors.white60,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        // Charging indicator
        if (charging)
          const Padding(
            padding: EdgeInsets.only(left: 3),
            child: Icon(Icons.bolt, color: Colors.greenAccent, size: 14),
          ),
      ],
    );
  }
}
