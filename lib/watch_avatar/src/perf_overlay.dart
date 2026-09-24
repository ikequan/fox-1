import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Testing aid: wraps the avatar with a live readout of frames per second and
/// build / raster time. Only meaningful in profile or release mode.
///
/// With a [controller]: tap switches full / lite, double tap switches the
/// 30 fps cap, long press hides the readout. Remove it for production.
/// One second of frame timings, as the readout shows it.
class AvatarPerfSample {
  const AvatarPerfSample({
    required this.fps,
    required this.lite,
    required this.cap30,
    required this.rasterAvg,
    required this.rasterWorst,
    required this.buildAvg,
    required this.buildWorst,
    required this.widthPx,
    required this.heightPx,
    required this.dpr,
  });
  final int fps, widthPx, heightPx;
  final bool lite, cap30;
  final double rasterAvg, rasterWorst, buildAvg, buildWorst, dpr;
}

class AvatarPerfOverlay extends StatefulWidget {
  const AvatarPerfOverlay({
    super.key,
    required this.child,
    this.controller,
    this.onSample,
    this.showReadout = true,
  });

  final Widget child;
  final AvatarController? controller;

  /// Every one-second sample, for logging it somewhere easier to read than a
  /// device screen. (App addition.)
  final void Function(AvatarPerfSample sample)? onSample;

  /// Hide the readout, e.g. while taking screenshots. (App addition.)
  final bool showReadout;

  @override
  State<AvatarPerfOverlay> createState() => _AvatarPerfOverlayState();
}

class _AvatarPerfOverlayState extends State<AvatarPerfOverlay> {
  final List<FrameTiming> _timings = <FrameTiming>[];
  Timer? _timer;
  bool _visible = true;
  String _readout = 'measuring…';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _summarise());
  }

  void _onTimings(List<FrameTiming> timings) => _timings.addAll(timings);

  void _summarise() {
    if (!mounted) return;
    final t = List<FrameTiming>.of(_timings);
    _timings.clear();
    if (t.isEmpty) {
      setState(() => _readout = 'no frame timings: run in --profile mode');
      return;
    }
    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = t.map((f) => ms(f.buildDuration)).toList();
    final raster = t.map((f) => ms(f.rasterDuration)).toList();
    double avg(List<double> v) => v.reduce((a, b) => a + b) / v.length;
    double worst(List<double> v) => v.reduce((a, b) => a > b ? a : b);
    final mq = MediaQuery.of(context);
    final px = mq.size * mq.devicePixelRatio;
    final c = widget.controller;
    widget.onSample?.call(AvatarPerfSample(
      fps: t.length,
      lite: c?.lite ?? false,
      cap30: c?.cap30 ?? true,
      rasterAvg: avg(raster),
      rasterWorst: worst(raster),
      buildAvg: avg(build),
      buildWorst: worst(build),
      widthPx: px.width.round(),
      heightPx: px.height.round(),
      dpr: mq.devicePixelRatio,
    ));
    setState(() {
      _readout = '${t.length} fps'
          '${c == null ? '' : '  ${c.lite ? 'LITE' : 'FULL'}  ${c.cap30 ? 'cap 30' : 'uncapped'}'}\n'
          'raster ${avg(raster).toStringAsFixed(1)} ms (worst ${worst(raster).toStringAsFixed(1)})\n'
          'build ${avg(build).toStringAsFixed(1)} ms (worst ${worst(build).toStringAsFixed(1)})\n'
          '${px.width.round()}x${px.height.round()} px, dpr ${mq.devicePixelRatio.toStringAsFixed(2)}';
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: c == null ? null : () => c.lite = !c.lite,
      onDoubleTap: c == null ? null : () => c.cap30 = !c.cap30,
      onLongPress: () => setState(() => _visible = !_visible),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: widget.child),
          if (_visible && widget.showReadout)
            Positioned(
              left: 6,
              right: 6,
              top: 6,
              child: IgnorePointer(
                child: Text(
                  _readout,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Color(0xFF7CFC9A),
                    fontSize: 10,
                    height: 1.25,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
