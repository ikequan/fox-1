import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'bloub_painter.dart';
import 'controller.dart';
import 'fox_painter.dart';
import 'frame.dart';
import 'params.dart';
import 'rig.dart';
import 'state.dart';

/// The avatar, bloub or fox, drawn live at the screen's native resolution.
///
/// Give it a bounded size (full screen, or a SizedBox). It fills that box and
/// frames the character exactly as the web design tool does.
class WatchAvatar extends StatefulWidget {
  const WatchAvatar({super.key, this.controller, this.params = const AvatarParams()});

  /// Optional. Without one the avatar runs idle with [params].
  final AvatarController? controller;

  /// Only used when no [controller] is given.
  final AvatarParams params;

  @override
  State<WatchAvatar> createState() => _WatchAvatarState();
}

class _WatchAvatarState extends State<WatchAvatar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  AvatarController? _own;
  late final PoseFrame _frame;
  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _appVisible = true;

  // what's showing, and what's blending out
  late AvatarState _cur;
  double _curSince = 0;
  AvatarState _prev = AvatarState.idle;
  double _prevSince = 0;
  double _blendStart = -1000;

  // drawing resources, rebuilt only when the design changes
  AvatarParams? _builtFor;
  FoxAssets? _foxAssets;
  final FoxSpriteCache _sprites = FoxSpriteCache();
  final BloubCache _bloub = BloubCache();

  AvatarController get _ctrl =>
      widget.controller ?? (_own ??= AvatarController(params: widget.params));

  double get _now => _clock.elapsedMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    _cur = _ctrl.state;
    _builtFor = _ctrl.params; // so set-up never calls setState
    _frame = PoseFrame(poseFromSample(sampleState(_cur, _ctrl.params, 0, 0), _ctrl.params));
    _ticker = createTicker((_) => _step());
    WidgetsBinding.instance.addObserver(this);
    _ctrl.addListener(_onControl);
    _onControl();
  }

  @override
  void didUpdateWidget(WatchAvatar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _own)?.removeListener(_onControl);
      _ctrl.addListener(_onControl);
      _onControl();
    }
  }

  void _onControl() {
    final c = _ctrl;
    if (c.state != _cur) {
      _prev = _cur;
      _prevSince = _curSince;
      _cur = c.state;
      _curSince = _now; // the new state's own loop starts from its beginning
      _blendStart = _now;
    }
    if (c.params != _builtFor) {
      _builtFor = c.params;
      _foxAssets = null; // rebuilt lazily for the fox
      _sprites.dispose();
      _bloub.clear();
      if (mounted) setState(() {});
    }
    _frame.lite = c.lite;

    // how frames are requested:
    //  - capped (default): a 30 Hz timer asks for a frame only when there is
    //    a new pose; the screen's other refreshes produce no frame at all
    //  - uncapped: a ticker, one frame per screen refresh
    final running = !c.paused && _appVisible;
    if (running) {
      _clock.start();
    } else {
      _clock.stop();
    }
    final useTicker = running && !c.cap30;
    if (useTicker && !_ticker.isActive) _ticker.start();
    if (!useTicker && _ticker.isActive) _ticker.stop();
    final useTimer = running && c.cap30;
    if (useTimer && _timer == null) {
      _timer = Timer.periodic(const Duration(microseconds: 33333), (_) => _step());
    } else if (!useTimer && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
    _step(); // show changes at once, even while paused
  }

  /// One new pose, from real elapsed time: a late frame never slows the
  /// animation down, it only makes that one step bigger.
  void _step() {
    final p = _ctrl.params, t = _now;
    var s = sampleState(_cur, p, t, _curSince);
    final into = (t - _blendStart) / math.max(0.001, _ctrl.transition.inMicroseconds / 1e6);
    if (into >= 0 && into < 1) {
      final w = into * into * (3 - 2 * into);
      s = blendSamples(sampleState(_prev, p, t, _prevSince), s, w);
    }
    _frame.update(poseFromSample(s, p));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible = state == AppLifecycleState.resumed;
    _onControl();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControl);
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _ticker.dispose();
    _sprites.dispose();
    _frame.dispose();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _ctrl.params;
    final CustomPainter painter;
    if (p.character == Character.fox) {
      final assets = _foxAssets ??= FoxAssets(p);
      painter = FoxPainter(_frame, assets, _sprites, MediaQuery.devicePixelRatioOf(context));
    } else {
      painter = BloubPainter(_frame, p, _bloub);
    }
    return RepaintBoundary(
      child: SizedBox.expand(child: CustomPaint(painter: painter)),
    );
  }
}
