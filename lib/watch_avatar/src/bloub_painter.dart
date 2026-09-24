import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'frame.dart';
import 'params.dart';
import 'rig.dart';
import 'shapes.dart';

/// Bloub: flat colour throughout, so it's drawn directly each frame; flat
/// fills are cheap on this GPU. Only the wobbly outline is cached.
class BloubPainter extends CustomPainter {
  BloubPainter(this.frame, this.params, this.cache) : super(repaint: frame);
  final PoseFrame frame;
  final AvatarParams params;
  final BloubCache cache;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = params, pose = frame.pose, r = p.radius;
    final screen = p.layout != Layout.figure;
    canvas.drawRect(Offset.zero & size, Paint()..color = p.screenColor);

    // fit the square frame to the screen, centred ("meet"); with no padding in
    // the figure layout it fills instead ("slice")
    final side = pose.frameHalf * 2;
    final scale = pose.slice
        ? math.max(size.width, size.height) / side
        : math.min(size.width, size.height) / side;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(0, -pose.frameCy);
    // the whole face moves: drift, then squash and stretch
    canvas.translate(pose.dx, pose.lift);
    canvas.scale(pose.sx, pose.sy);

    if (!screen) canvas.drawPath(cache.body(p, pose.seed), Paint()..color = p.body);

    final eyePaint = Paint()..color = p.eye;
    for (final e in <EyePose>[pose.eyeL, pose.eyeR]) {
      canvas.save();
      canvas.transform(m4(e.m));
      if (pose.hasBattery) {
        drawBatteryEye(canvas, p.eyeShape, e.w, e.h, pose.battery, p.eye,
            pose.boltFull ? p.boltFull : p.boltLow);
      } else if (e.kind == EyeKind.arc) {
        canvas.drawPath(
            arcEye(e.w, e.h),
            Paint()
              ..color = p.eye
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = arcStroke(e.h));
      } else if (e.kind == EyeKind.heart) {
        canvas.drawPath(heartEye(e.w, e.h), eyePaint);
      } else {
        canvas.drawPath(eyeOutline(p.eyeShape, e.w, e.h), eyePaint);
      }
      canvas.restore();
    }

    if (pose.hasMouth) {
      canvas.save();
      canvas.transform(m4(pose.mouth));
      canvas.drawPath(eyeOutline(p.eyeShape, pose.mouthW, pose.mouthH), eyePaint);
      canvas.restore();
    }

    if (pose.hasTear && pose.tearOpacity > 0) {
      canvas.save();
      canvas.transform(m4(pose.tear));
      final tearShape = p.eyeShape == EyeShape.pill ? EyeShape.round : p.eyeShape;
      canvas.drawPath(eyeOutline(tearShape, 14, 18),
          Paint()..color = p.eye.withValues(alpha: pose.tearOpacity.clamp(0.0, 1.0).toDouble()));
      canvas.restore();
    }

    if (p.clock) {
      final tp = cache.clock(clockText(p.clock24, DateTime.now()), p.eye, math.max(10.0, r * 0.22));
      final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      tp.paint(canvas, Offset(-tp.width / 2, r * 0.76 - baseline));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BloubPainter old) =>
      old.frame != frame || old.params != params || old.cache != cache;
}

/// Bloub's outline for each state seed, and the laid-out time.
class BloubCache {
  final Map<String, Path> _bodies = <String, Path>{};
  String _clockKey = '';
  TextPainter? _clock;

  Path body(AvatarParams p, double seed) {
    final key = '${p.radius}|${p.wobble}|${p.faceShape.name}|${p.corner}|$seed';
    if (_bodies.length > 32) _bodies.clear(); // settings being dragged
    return _bodies[key] ??= bloubBody(p.radius, p.wobble, seed, p.faceShape, p.corner);
  }

  TextPainter clock(String text, Color color, double size) {
    final key = '$text|${color.toARGB32()}|$size';
    if (key != _clockKey || _clock == null) {
      _clockKey = key;
      _clock = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    return _clock!;
  }

  void clear() => _bodies.clear();
}
