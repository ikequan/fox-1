import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'params.dart';

/// A pose transform [a b c d e f] as the 4x4 Canvas.transform expects.
Float64List m4(List<double> m) => Float64List.fromList(
    <double>[m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1]);

Rect centred(double w, double h) => Rect.fromCenter(center: Offset.zero, width: w, height: h);

/// The eye outline in the chosen shape, w x h, centred on the origin.
Path eyeOutline(EyeShape shape, double w, double h) {
  final rect = centred(w, h);
  if (shape == EyeShape.round) return Path()..addOval(rect);
  final r = shape == EyeShape.square ? math.min(w, h) * 0.3 : math.min(w, h) / 2;
  return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
}

/// Happy / full-battery eyes: an upward arc, stroked with round caps.
Path arcEye(double w, double h) => Path()
  ..moveTo(-w / 2, h * 0.25)
  ..quadraticBezierTo(0, -h * 0.75, w / 2, h * 0.25);

double arcStroke(double h) => h * 0.55;

/// Love eyes.
Path heartEye(double w, double h) => Path()
  ..moveTo(0, h * 0.46)
  ..cubicTo(-w * 0.62, h * 0.04, -w * 0.58, -h * 0.5, -w * 0.23, -h * 0.46)
  ..cubicTo(-w * 0.1, -h * 0.44, -w * 0.02, -h * 0.3, 0, -h * 0.14)
  ..cubicTo(w * 0.02, -h * 0.3, w * 0.1, -h * 0.44, w * 0.23, -h * 0.46)
  ..cubicTo(w * 0.58, -h * 0.5, w * 0.62, h * 0.04, 0, h * 0.46)
  ..close();

/// The lightning bolt inside a battery-cell eye.
Path boltPath(double w, double h) {
  final bw = w * 0.82, bh = h * 0.6;
  const pts = <List<double>>[
    <double>[0.15, -0.5],
    <double>[-0.34, 0.1],
    <double>[-0.03, 0.1],
    <double>[-0.15, 0.5],
    <double>[0.34, -0.1],
    <double>[0.03, -0.1],
  ];
  final p = Path()..moveTo(pts[0][0] * bw, pts[0][1] * bh);
  for (var i = 1; i < pts.length; i++) {
    p.lineTo(pts[i][0] * bw, pts[i][1] * bh);
  }
  return p..close();
}

/// Draws a battery-cell eye: outline, a level rising from the floor, and the
/// bolt on top. [level] 0..1.
void drawBatteryEye(Canvas canvas, EyeShape shape, double w, double h, double level,
    Color eyeColor, Color boltColor) {
  final outline = eyeOutline(shape, w, h);
  canvas.drawPath(
      outline,
      Paint()
        ..color = eyeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.4, math.min(w, h) * 0.17));
  canvas.save();
  canvas.clipPath(outline);
  canvas.drawRect(Rect.fromLTWH(-w / 2, -h / 2 + h * (1 - level), w, h), Paint()..color = eyeColor);
  canvas.restore();
  canvas.drawPath(boltPath(w, h), Paint()..color = boltColor);
}

/// Bloub's outline: a circle or a squircle with a hand-drawn wobble, a port
/// of the web tool's bodyPath (same seed, same shape).
Path bloubBody(double radius, double wobble, double seed, FaceShape shape, double corner) {
  final squircle = shape == FaceShape.squircle;
  final n = squircle ? 64 : 40;
  final ex = 2 / (corner == 0 ? 4 : corner);
  final rnd = <double>[
    for (var i = 0; i < 4; i++) ((seed * 9301 + i * 49297) % 233280) / 233280,
  ];
  final tau = math.pi * 2;
  final pts = <Offset>[];
  for (var i = 0; i < n; i++) {
    final t = tau * i / n;
    final w = wobble *
        (math.sin(3 * t + rnd[0] * tau) +
            0.6 * math.sin(5 * t + rnd[1] * tau) +
            0.35 * math.sin(8 * t + rnd[2] * tau));
    final ct = math.cos(t), st = math.sin(t), r = radius + w;
    if (squircle) {
      pts.add(Offset(ct.sign * math.pow(ct.abs(), ex).toDouble() * r,
          st.sign * math.pow(st.abs(), ex).toDouble() * r));
    } else {
      pts.add(Offset(ct * r, st * r));
    }
  }
  // closed Catmull-Rom through the points, as cubic Beziers
  final path = Path()..moveTo(pts[0].dx, pts[0].dy);
  for (var i = 0; i < n; i++) {
    final a = pts[(i - 1 + n) % n], b = pts[i], c = pts[(i + 1) % n], e = pts[(i + 2) % n];
    path.cubicTo(b.dx + (c.dx - a.dx) / 6, b.dy + (c.dy - a.dy) / 6, c.dx - (e.dx - b.dx) / 6,
        c.dy - (e.dy - b.dy) / 6, c.dx, c.dy);
  }
  return path..close();
}

/// The time as the web tool shows it.
String clockText(bool h24, DateTime now) {
  final mm = now.minute.toString().padLeft(2, '0');
  if (h24) return '${now.hour.toString().padLeft(2, '0')}:$mm';
  final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
  return '$h:$mm ${now.hour >= 12 ? 'PM' : 'AM'}';
}
