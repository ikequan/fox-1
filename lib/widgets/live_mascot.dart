import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../watch_avatar/watch_avatar.dart';
import 'mascot.dart';

/// Bloub or the fox, drawn live by `watch_avatar`: every state animated and
/// blended, the whole design tunable, no image assets.
///
/// Follows three things: what the AI is doing ([mascotStateProvider]), the
/// wearer's design ([liveAvatarParamsProvider]) and, with [battery], the
/// charger and battery level. Draws only while [screen] is the page in front
/// of the wearer — every page can hold one, and an avatar nobody can see is
/// battery for nothing.
class LiveMascot extends ConsumerStatefulWidget {
  const LiveMascot({
    super.key,
    required this.screen,
    this.battery = false,
    this.covered = false,
    this.selfTest = false,
  });

  /// The page this avatar lives on; it draws only while that page is showing.
  final ActiveScreen screen;

  /// Show charging / full / low battery while the AI has nothing to say. The
  /// watch face does; the AI screen does not.
  final bool battery;

  /// Something opaque is on top of it.
  final bool covered;

  /// Profile builds only: step through every state of both characters for
  /// screenshots, then the performance table, logging `[AVATAR]` lines, and
  /// go back to normal. See [_SelfTest].
  final bool selfTest;

  @override
  ConsumerState<LiveMascot> createState() => _LiveMascotState();
}

class _LiveMascotState extends ConsumerState<LiveMascot> {
  late final AvatarController _avatar;
  final _battery = Battery();
  StreamSubscription<BatteryState>? _batterySub;
  Timer? _levelPoll;
  BatteryState _plug = BatteryState.unknown;
  int _level = 100;
  _SelfTest? _test;

  @override
  void initState() {
    super.initState();
    _avatar = AvatarController(
      params: _drawn(ref.read(liveAvatarParamsProvider)),
      state: _wanted(),
      paused: _shouldPause(ref.read(activeScreenProvider)),
    );
    if (widget.battery) {
      _batterySub = _battery.onBatteryStateChanged.listen((s) {
        _plug = s;
        _readLevel();
      });
      _readLevel();
      // The level creeps rather than jumps; once a minute is plenty.
      _levelPoll = Timer.periodic(const Duration(minutes: 1), (_) => _readLevel());
    }
    if (widget.selfTest && kProfileMode) {
      _test = _SelfTest(_avatar, onDone: _followProviders);
    }
  }

  Future<void> _readLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (!mounted) return;
      _level = level;
      _applyState();
    } catch (_) {}
  }

  bool get _plugged =>
      _plug == BatteryState.charging ||
      _plug == BatteryState.full ||
      _plug == BatteryState.connectedNotCharging;

  AvatarState _wanted() => avatarStateFor(
        ref.read(mascotStateProvider),
        battery: widget.battery ? (plugged: _plugged, level: _level) : null,
      );

  bool _shouldPause(ActiveScreen showing) =>
      widget.covered || showing != widget.screen;

  void _applyState() {
    if (_test?.running ?? false) return;
    _avatar.state = _wanted();
  }

  void _followProviders() {
    _avatar.params = _drawn(ref.read(liveAvatarParamsProvider));
    _avatar.state = _wanted();
  }

  /// The design without the avatar's own clock: its font is fixed inside the
  /// painter. The watch face draws the time itself instead, in the wearer's
  /// font and position, and the other pages show none.
  static AvatarParams _drawn(AvatarParams p) => p.clock ? p.withValue('clock', false) : p;

  @override
  void didUpdateWidget(LiveMascot old) {
    super.didUpdateWidget(old);
    _avatar.paused = _shouldPause(ref.read(activeScreenProvider));
  }

  @override
  void dispose() {
    _batterySub?.cancel();
    _levelPoll?.cancel();
    _avatar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<MascotMood>(mascotStateProvider, (_, _) => _applyState());
    ref.listen<AvatarParams>(liveAvatarParamsProvider, (_, p) {
      if (!(_test?.running ?? false)) _avatar.params = _drawn(p);
    });
    ref.listen<ActiveScreen>(
        activeScreenProvider, (_, s) => _avatar.paused = _shouldPause(s));
    final avatar = WatchAvatar(controller: _avatar);
    final test = _test;
    if (test == null) return avatar;
    return ListenableBuilder(
      listenable: test,
      builder: (context, _) => AvatarPerfOverlay(
        controller: _avatar,
        onSample: (s) => test.onSample(s, paused: _avatar.paused),
        showReadout: test.showReadout,
        child: avatar,
      ),
    );
  }
}

/// The app's mascot states as the avatar knows them, in the order the
/// integration guide gives: the conversation first, then the brief
/// reactions, then the battery, then idle.
AvatarState avatarStateFor(
  MascotMood mood, {
  ({bool plugged, int level})? battery,
  int lowAt = 15,
}) {
  switch (mood) {
    case MascotMood.listening:
      return AvatarState.listening;
    case MascotMood.speaking:
      return AvatarState.speaking;
    case MascotMood.thinking:
      return AvatarState.thinking;
    case MascotMood.confused:
      return AvatarState.confused;
    case MascotMood.sad:
    case MascotMood.angry:
      return AvatarState.sad;
    case MascotMood.happy:
    case MascotMood.excited:
      return AvatarState.happy;
    case MascotMood.love:
      return AvatarState.love;
    case MascotMood.sleepy:
      return AvatarState.sleeping;
    case MascotMood.charging:
      return AvatarState.charging;
    case MascotMood.lowBattery:
      return AvatarState.lowBattery;
    case MascotMood.fullBattery:
      return AvatarState.fullBattery;
    case MascotMood.idle:
      break;
  }
  if (battery != null) {
    if (battery.plugged) {
      return battery.level >= 100 ? AvatarState.fullBattery : AvatarState.charging;
    }
    if (battery.level <= lowAt) return AvatarState.lowBattery;
  }
  return AvatarState.idle;
}

/// The integration guide's checks, run by the device itself in a profile
/// build so nobody has to tap through 24 states on a tiny screen:
///
///  1. **Screenshots**: each state of each character held for [_shotHold]
///     seconds, with `[AVATAR] SHOT <character>-<state>` logged once it has
///     settled — the cue for `adb exec-out screencap`.
///  2. **Performance**: the guide's six rows, [_perfCount] counted seconds
///     each after [_warmUp], logged as `[AVATAR] SUMMARY` lines.
///
/// It counts one-second samples rather than running timers, so seconds while
/// the page is not showing simply do not count. When it is done the avatar
/// goes back to following the app.
class _SelfTest extends ChangeNotifier {
  _SelfTest(this.avatar, {required this.onDone});

  final AvatarController avatar;
  final VoidCallback onDone;

  static const _shotHold = 4, _shotAt = 2, _warmUp = 2, _perfCount = 60;

  static final _steps = <({Character who, AvatarState state, bool perf})>[
    for (final who in Character.values)
      for (final state in AvatarState.values) (who: who, state: state, perf: false),
    (who: Character.fox, state: AvatarState.idle, perf: true),
    (who: Character.fox, state: AvatarState.charging, perf: true),
    (who: Character.fox, state: AvatarState.love, perf: true),
    (who: Character.bloub, state: AvatarState.idle, perf: true),
    (who: Character.bloub, state: AvatarState.charging, perf: true),
    (who: Character.bloub, state: AvatarState.speaking, perf: true),
  ];

  int _step = -1, _seconds = 0;
  bool _done = false;
  final _perf = <AvatarPerfSample>[];

  bool get running => _step >= 0 && !_done;

  /// The readout stays off the screenshots.
  bool get showReadout => !running || _steps[_step].perf;

  void onSample(AvatarPerfSample s, {required bool paused}) {
    if (_done || paused) return;
    if (_step < 0) {
      debugPrint('[AVATAR] ==== self-test · watch_avatar $watchAvatarVersion · '
          '${s.widthPx}x${s.heightPx} px, dpr ${s.dpr.toStringAsFixed(2)}');
      _enter(0);
      return;
    }
    final step = _steps[_step];
    _seconds++;
    final name = '${step.who.name}-${step.state.key}';
    if (!step.perf) {
      if (_seconds == _shotAt) debugPrint('[AVATAR] SHOT $name');
      if (_seconds >= _shotHold) _next();
      return;
    }
    if (_seconds <= _warmUp) return;
    _perf.add(s);
    String ms(double v) => v.toStringAsFixed(1);
    debugPrint('[AVATAR] $name ${s.fps} fps · raster ${ms(s.rasterAvg)} / '
        '${ms(s.rasterWorst)} ms · build ${ms(s.buildAvg)} / ${ms(s.buildWorst)} ms');
    if (_perf.length < _perfCount) return;
    double mean(double Function(AvatarPerfSample) f) =>
        _perf.map(f).reduce((a, b) => a + b) / _perf.length;
    double top(double Function(AvatarPerfSample) f) =>
        _perf.map(f).reduce((a, b) => a > b ? a : b);
    final lowest = _perf.map((x) => x.fps).reduce((a, b) => a < b ? a : b);
    debugPrint('[AVATAR] SUMMARY ${step.who.name} ${step.state.key}: '
        'fps ${mean((x) => x.fps.toDouble()).toStringAsFixed(1)} (lowest $lowest) · '
        'raster ${ms(mean((x) => x.rasterAvg))} / ${ms(top((x) => x.rasterWorst))} ms · '
        'build ${ms(mean((x) => x.buildAvg))} / ${ms(top((x) => x.buildWorst))} ms');
    _next();
  }

  void _next() => _step + 1 < _steps.length ? _enter(_step + 1) : _finish();

  void _enter(int i) {
    _step = i;
    _seconds = 0;
    _perf.clear();
    final step = _steps[i];
    // The default designs: the reference pictures were drawn with them.
    avatar
      ..params = step.who == Character.fox ? AvatarParams.fox : const AvatarParams()
      ..state = step.state;
    if (step.perf && (i == 0 || !_steps[i - 1].perf)) {
      debugPrint('[AVATAR] ---- performance: full quality, cap 30, '
          '$_perfCount s each');
    }
    notifyListeners();
  }

  void _finish() {
    _done = true;
    debugPrint('[AVATAR] ==== self-test done');
    onDone();
    notifyListeners();
  }
}
