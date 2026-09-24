import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'frame.dart';
import 'params.dart';
import 'rig.dart';
import 'shapes.dart';

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
Color _lighten(Color c, double t) => _mix(c, const Color(0xFFFFFFFF), t);
Color _darken(Color c, double t) => _mix(c, const Color(0xFF000000), t);
Color _alpha(Color c, double a) => c.withValues(alpha: a);

/// A radial gradient positioned in an ellipse's bounding box, the way SVG's
/// objectBoundingBox units work: (cx, cy, radius) are 0..1 fractions of [box].
ui.Gradient _boxRadial(Rect box, double cx, double cy, double radius,
    List<Color> colors, List<double> stops) {
  return ui.Gradient.radial(
    Offset(cx, cy),
    radius,
    colors,
    stops,
    TileMode.clamp,
    Float64List.fromList(<double>[
      box.width, 0, 0, 0, //
      0, box.height, 0, 0,
      0, 0, 1, 0,
      box.left, box.top, 0, 1,
    ]),
  );
}

/// Every path and gradient the fox needs, built once. Each frame only moves
/// them, which is what keeps it cheap on the device's GPU.
class FoxAssets {
  FoxAssets(this.p) {
    final r = p.radius, b = p.body, m = p.muzzle;
    Offset pt(double x, double y) => Offset(x * r, y * r);
    Rect oval(double cx, double cy, double rx, double ry) =>
        Rect.fromCenter(center: pt(cx, cy), width: rx * 2 * r, height: ry * 2 * r);

    // ---- the body: one dome from head to arms, cropped by the screen
    mass = Path()
      ..moveTo(0, -1.02 * r)
      ..cubicTo(0.64 * r, -1.02 * r, 1.0 * r, -0.62 * r, 1.01 * r, -0.04 * r)
      ..cubicTo(1.02 * r, 0.46 * r, 1.03 * r, 0.7 * r, 1.13 * r, 0.96 * r)
      ..cubicTo(1.3 * r, 1.24 * r, 1.38 * r, 1.64 * r, 1.4 * r, 2.2 * r)
      ..lineTo(-1.4 * r, 2.2 * r)
      ..cubicTo(-1.38 * r, 1.64 * r, -1.3 * r, 1.24 * r, -1.13 * r, 0.96 * r)
      ..cubicTo(-1.03 * r, 0.7 * r, -1.02 * r, 0.46 * r, -1.01 * r, -0.04 * r)
      ..cubicTo(-1.0 * r, -0.62 * r, -0.64 * r, -1.02 * r, 0, -1.02 * r)
      ..close();

    // ---- volume, lit high on the dome from the upper left
    fur = Paint()
      ..shader = ui.Gradient.radial(
        pt(-0.3, -0.5),
        3.0 * r,
        <Color>[_lighten(b, 0.28), b, _darken(b, 0.07), _darken(b, 0.18)],
        <double>[0, 0.3, 0.72, 1],
        TileMode.clamp,
        null,
        pt(-0.36, -0.62),
        0,
      );
    // inner shadow toward the rim, so the edges curve away
    rim = Paint()
      ..shader = ui.Gradient.radial(
        pt(0, 0.3),
        1.9 * r,
        <Color>[
          const Color(0x00000000),
          const Color(0x00000000),
          _alpha(const Color(0xFF000000), 0.06),
          _alpha(const Color(0xFF000000), 0.26),
        ],
        <double>[0, 0.56, 0.8, 1],
      );
    // back-light along the upper right edge
    final mb = mass.getBounds();
    backLight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.06 * r
      ..shader = ui.Gradient.linear(
        Offset(mb.left + 0.25 * mb.width, mb.top + 0.7 * mb.height),
        Offset(mb.left + 0.85 * mb.width, mb.top + 0.05 * mb.height),
        <Color>[
          _alpha(_lighten(b, 0.55), 0),
          _alpha(_lighten(b, 0.55), 0),
          _alpha(_lighten(b, 0.65), 0.45),
        ],
        <double>[0, 0.6, 1],
      );

    // ---- cream patches and soft shadows, each with its own box gradient
    Paint cream(Rect box) => Paint()
      ..shader = _boxRadial(box, 0.46, 0.28, 0.8, <Color>[
        _lighten(m, 0.6),
        m,
        _darken(_mix(m, b, 0.25), 0.06),
      ], <double>[0, 0.62, 1]);
    Paint shade(Rect box, double opacity) => Paint()
      ..shader = _boxRadial(box, 0.5, 0.5, 0.5, <Color>[
        _alpha(const Color(0xFF000000), 0.4 * opacity),
        _alpha(const Color(0xFF000000), 0.16 * opacity),
        _alpha(const Color(0xFF000000), 0),
      ], <double>[0, 0.55, 1]);

    belly = oval(0, 1.55, 0.62, 0.6);
    bellyPaint = cream(belly);
    creaseL = oval(-0.86, 1.56, 0.16, 0.66);
    creaseR = oval(0.86, 1.56, 0.16, 0.66);
    creaseLPaint = shade(creaseL, 0.55);
    creaseRPaint = shade(creaseR, 0.55);
    neck = oval(0, 0.66, 0.95, 0.26);
    neckPaint = shade(neck, 0.5);
    underCheek = oval(0, 0.44, 0.7, 0.14);
    underCheekPaint = shade(underCheek, 0.55);
    cheekL = oval(-0.37, 0.24, 0.4, 0.31);
    cheekR = oval(0.37, 0.24, 0.4, 0.31);
    muzzleOval = oval(0, 0.28, 0.28, 0.27);
    cheekLPaint = cream(cheekL);
    cheekRPaint = cream(cheekR);
    muzzlePaint = cream(muzzleOval);

    // a faint warm glow behind, so there's air around the character
    glow = oval(0, -0.1, 1.45, 1.35);
    glowPaint = Paint()
      ..shader = _boxRadial(glow, 0.5, 0.5, 0.5, <Color>[
        _mix(p.bg, b, 0.18),
        _alpha(_mix(p.bg, b, 0.06), 0.8),
        _alpha(_mix(p.bg, b, 0.02), 0),
      ], <double>[0, 0.5, 1]);

    // ---- ears: outer (fur), inner, dark tip
    for (final sg in <double>[-1, 1]) {
      final w = 0.62 * r, l = 0.58 * r, tip = sg * w * 0.14;
      final bl = Offset(-w / 2, w * 0.5), br = Offset(w / 2, w * 0.5), tp = Offset(tip, -l);
      Offset at(Offset base, double t) => tp + (base - tp) * t;
      Path tri(Offset a, Offset b2, Offset c) => Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b2.dx, b2.dy)
        ..lineTo(c.dx, c.dy)
        ..close();
      final ear = FoxEar(
        outer: tri(bl, tp, br),
        inner: tri(Offset(-w * 0.2 - sg * w * 0.03, w * 0.32), Offset(tip * 0.7, -l * 0.5),
            Offset(w * 0.2 - sg * w * 0.03, w * 0.32)),
        tip: tri(at(bl, 0.28), tp, at(br, 0.28)),
        outerStroke: w * 0.34,
        innerStroke: w * 0.18,
        tipStroke: w * 0.3,
      );
      if (sg < 0) {
        earL = ear;
      } else {
        earR = ear;
      }
    }
    furStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..shader = fur.shader;
    final innerColor = _mix(_lighten(m, 0.1), _darken(b, 0.2), 0.15);
    earInner = Paint()..color = innerColor;
    earInnerStroke = Paint()
      ..color = innerColor
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final dark = _darken(b, 0.55);
    earTip = Paint()..color = dark;
    earTipStroke = Paint()
      ..color = dark
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    eyeFlat = Paint()..color = p.eye;
    catchlightPaint = Paint()..color = _alpha(const Color(0xFFFFFFFF), 0.92);
    glintPaint = Paint()..color = _alpha(const Color(0xFFFFFFFF), 0.45);
    tearColor = const Color(0xFFBFE3FF);

    // ---- nose, mouth, whisker dots
    final nw = 0.075 * r, nh = 0.05 * r;
    nose = Path()
      ..moveTo(-nw, -nh)
      ..lineTo(nw, -nh)
      ..lineTo(0, nh)
      ..close();
    noseFill = Paint()..color = p.eye;
    noseStroke = Paint()
      ..color = p.eye
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.05 * r
      ..strokeJoin = StrokeJoin.round;
    noseShine = Rect.fromCenter(
        center: Offset(-0.022 * r, -0.028 * r), width: 0.048 * r, height: 0.028 * r);
    noseShinePaint = Paint()..color = _alpha(const Color(0xFFFFFFFF), 0.4);

    final mw = 0.09 * r, md = 0.04 * r, mt = 0.018 * r;
    mouth = Path()
      ..moveTo(-mw, 0)
      ..quadraticBezierTo(-mw / 2, md, 0, 0)
      ..quadraticBezierTo(mw / 2, md, mw, 0)
      ..quadraticBezierTo(mw / 2, md + 2 * mt, 0, mt)
      ..quadraticBezierTo(-mw / 2, md + 2 * mt, -mw, 0)
      ..close();
    mouthPaint = Paint()..color = p.eye;

    whiskers = <Offset>[
      for (final sg in <double>[-1, 1]) ...<Offset>[
        pt(sg * 0.19, 0.16),
        pt(sg * 0.26, 0.21),
        pt(sg * 0.2, 0.25),
      ],
    ];
    whiskerRadius = 0.014 * r;
    whiskerPaint = Paint()..color = _darken(m, 0.4);

    // ---- lite tier: the same shapes with flat colour
    flatBody = Paint()..color = b;
    flatBodyStroke = Paint()
      ..color = b
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    flatCream = Paint()..color = m;
    bgPaint = Paint()..color = p.bg;
  }

  final AvatarParams p;
  late final Path mass, nose, mouth;
  late final Paint fur, furStroke, rim, backLight;
  late final Rect belly, creaseL, creaseR, neck, underCheek, cheekL, cheekR, muzzleOval, glow;
  late final Paint bellyPaint, creaseLPaint, creaseRPaint, neckPaint, underCheekPaint;
  late final Paint cheekLPaint, cheekRPaint, muzzlePaint, glowPaint;
  late final FoxEar earL, earR;
  late final Paint earInner, earInnerStroke, earTip, earTipStroke;
  late final Paint eyeFlat, catchlightPaint, glintPaint;
  late final Color tearColor;
  late final Rect noseShine;
  late final double whiskerRadius;

  /// A glossy eye, w x h in the chosen shape: gradient plus two catchlights.
  void drawGlossyEye(Canvas c, double w, double h, bool lite) {
    final rr = math.min(w, h);
    final outline = eyeOutline(p.eyeShape, w, h);
    c.drawPath(
        outline,
        lite
            ? eyeFlat
            : (Paint()
              ..shader = _boxRadial(centred(w, h), 0.38, 0.3, 0.75,
                  <Color>[_lighten(p.eye, 0.22), p.eye], <double>[0, 1])));
    c.drawOval(Rect.fromCenter(center: Offset(w * 0.14, -h * 0.24), width: rr * 0.4, height: rr * 0.52),
        catchlightPaint);
    c.drawCircle(Offset(-w * 0.12, h * 0.24), rr * 0.09, glintPaint);
  }
  late final Paint noseFill, noseStroke, noseShinePaint, mouthPaint, whiskerPaint;
  late final List<Offset> whiskers;
  late final Paint flatBody, flatBodyStroke, flatCream, bgPaint;

  // the time only changes once a minute, so its layout is cached too
  String _clockText = '';
  TextPainter? _clock;
  TextPainter clockFor(String text) {
    if (text != _clockText || _clock == null) {
      _clockText = text;
      _clock = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: p.eye,
            fontSize: 0.18 * p.radius,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    return _clock!;
  }
}

class FoxEar {
  const FoxEar({
    required this.outer,
    required this.inner,
    required this.tip,
    required this.outerStroke,
    required this.innerStroke,
    required this.tipStroke,
  });
  final Path outer, inner, tip;
  final double outerStroke, innerStroke, tipStroke;
}

/// One layer drawn once into an image, then only moved each frame.
class FoxSprite {
  FoxSprite(this.image, this.rect);
  final ui.Image image;

  /// Where the image sits in its layer's local space, in design units.
  final Rect rect;

  void draw(Canvas canvas, Paint paint) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      paint,
    );
  }
}

/// Records [draw] (in design units) into an image [k] pixels per unit.
FoxSprite _bake(Rect bounds, double k, void Function(Canvas canvas) draw) {
  final b = bounds.inflate(1.5); // room for anti-aliased edges
  final w = math.max(1, (b.width * k).ceil());
  final h = math.max(1, (b.height * k).ceil());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(k);
  canvas.translate(-b.left, -b.top);
  draw(canvas);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(w, h);
  picture.dispose();
  // map the whole image back onto exactly the area it was recorded from
  return FoxSprite(image, Rect.fromLTWH(b.left, b.top, w / k, h / k));
}

/// The fox's layers, each baked once. Gradients, clipping and soft shading
/// all happen here, a single time; per frame the GPU only positions images.
class FoxSprites {
  FoxSprites._(this.key, this.k, this.lite, this.assets, this.glow, this.mass, this.mask,
      this.earL, this.earR, this.feat);

  final String key;
  final double k;
  final bool lite;
  final FoxAssets assets;
  final FoxSprite glow, mass, mask, earL, earR, feat;

  /// Glossy eyes, baked per size. Sizes change between states and while
  /// blending, so they're rounded to whole units and a few are kept.
  final Map<String, FoxSprite> _eyes = <String, FoxSprite>{};
  FoxSprite eye(double w, double h) {
    final bw = math.max(1.0, w.roundToDouble()), bh = math.max(1.0, h.roundToDouble());
    final key = '$bw|$bh';
    final hit = _eyes[key];
    if (hit != null) return hit;
    if (_eyes.length > 24) {
      for (final s in _eyes.values) {
        s.image.dispose();
      }
      _eyes.clear();
    }
    return _eyes[key] = _bake(centred(bw, bh), k, (c) => assets.drawGlossyEye(c, bw, bh, lite));
  }

  factory FoxSprites.bake(FoxAssets a, double k, bool lite, String key) {
    final r = a.p.radius;

    final glow = _bake(a.glow, k, (c) => c.drawOval(a.glow, a.glowPaint));

    // body with belly, arm creases, neck shade, inner shadow and back-light
    final mass = _bake(a.mass.getBounds().inflate(0.04 * r), k, (c) {
      c.drawPath(a.mass, lite ? a.flatBody : a.fur);
      c.save();
      c.clipPath(a.mass);
      c.drawOval(a.belly, lite ? a.flatCream : a.bellyPaint);
      if (!lite) {
        c.drawOval(a.creaseL, a.creaseLPaint);
        c.drawOval(a.creaseR, a.creaseRPaint);
        c.drawOval(a.neck, a.neckPaint);
        c.drawPath(a.mass, a.rim);
        c.drawPath(a.mass, a.backLight);
      }
      c.restore();
    });

    // cheeks and muzzle: they slide across the face, so they're their own layer.
    // They stay inside the body's outline at every head angle the rig produces,
    // so they need no clip.
    final maskBounds = a.underCheek
        .expandToInclude(a.cheekL)
        .expandToInclude(a.cheekR)
        .expandToInclude(a.muzzleOval);
    final mask = _bake(maskBounds, k, (c) {
      if (!lite) c.drawOval(a.underCheek, a.underCheekPaint);
      c.drawOval(a.cheekL, lite ? a.flatCream : a.cheekLPaint);
      c.drawOval(a.cheekR, lite ? a.flatCream : a.cheekRPaint);
      c.drawOval(a.muzzleOval, lite ? a.flatCream : a.muzzlePaint);
    });

    FoxSprite ear(FoxEar e) => _bake(e.outer.getBounds().inflate(e.outerStroke / 2), k, (c) {
          if (lite) {
            c.drawPath(e.outer, a.flatBody);
            c.drawPath(e.outer, a.flatBodyStroke..strokeWidth = e.outerStroke);
          } else {
            c.drawPath(e.outer, a.fur);
            c.drawPath(e.outer, a.furStroke..strokeWidth = e.outerStroke);
          }
          c.drawPath(e.inner, a.earInner);
          c.drawPath(e.inner, a.earInnerStroke..strokeWidth = e.innerStroke);
          c.drawPath(e.tip, a.earTip);
          c.drawPath(e.tip, a.earTipStroke..strokeWidth = e.tipStroke);
        });

    // whisker dots and the nose never move relative to the face
    final noseAt = Offset(0, 0.07 * r);
    var featBounds = a.nose.getBounds().shift(noseAt).inflate(0.03 * r);
    for (final w in a.whiskers) {
      featBounds = featBounds.expandToInclude(Rect.fromCircle(center: w, radius: a.whiskerRadius));
    }
    final feat = _bake(featBounds, k, (c) {
      for (final w in a.whiskers) {
        c.drawCircle(w, a.whiskerRadius, a.whiskerPaint);
      }
      c.save();
      c.translate(noseAt.dx, noseAt.dy);
      c.drawPath(a.nose, a.noseFill);
      c.drawPath(a.nose, a.noseStroke);
      c.drawOval(a.noseShine, a.noseShinePaint);
      c.restore();
    });

    return FoxSprites._(key, k, lite, a, glow, mass, mask, ear(a.earL), ear(a.earR), feat);
  }

  void dispose() {
    for (final s in <FoxSprite>[glow, mass, mask, earL, earR, feat, ..._eyes.values]) {
      s.image.dispose();
    }
    _eyes.clear();
  }
}

/// Keeps the baked layers; rebakes only when size, density or quality change.
class FoxSpriteCache {
  FoxSprites? _current;

  FoxSprites get(FoxAssets assets, double k, bool lite) {
    final key = '${identityHashCode(assets)}|${k.toStringAsFixed(3)}|$lite';
    final current = _current;
    if (current != null && current.key == key) return current;
    current?.dispose();
    return _current = FoxSprites.bake(assets, k, lite, key);
  }

  void dispose() {
    _current?.dispose();
    _current = null;
  }
}

class FoxPainter extends CustomPainter {
  FoxPainter(this.frame, this.assets, this.sprites, this.devicePixelRatio)
      : super(repaint: frame);
  final PoseFrame frame;
  final FoxAssets assets;
  final FoxSpriteCache sprites;
  final double devicePixelRatio;

  static final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final a = assets, p = a.p, r = p.radius, pose = frame.pose;
    final lite = frame.lite;
    canvas.drawRect(Offset.zero & size, a.bgPaint);

    // fit the square frame to the screen, centred; the body runs past the
    // frame and is cropped by the screen edge, as designed
    final scale = math.min(size.width, size.height) / (pose.frameHalf * 2);
    // baked at 1.5x the screen's pixel density, so turns and tilts stay crisp
    final sp = sprites.get(a, scale * devicePixelRatio * 1.5, lite);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(0, -pose.frameCy);
    canvas.translate(pose.dx, pose.lift);
    canvas.scale(pose.sx, pose.sy);

    if (!lite) _at(canvas, pose.glow, sp.glow);

    canvas.save();
    canvas.transform(m4(pose.mass));
    _at(canvas, pose.earL, sp.earL);
    _at(canvas, pose.earR, sp.earR);
    sp.mass.draw(canvas, _imagePaint);
    _at(canvas, pose.mask, sp.mask);

    canvas.save();
    canvas.transform(m4(pose.feat));
    sp.feat.draw(canvas, _imagePaint);
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
        canvas.drawPath(heartEye(e.w, e.h), a.eyeFlat);
      } else {
        // the eye is baked at a whole-unit size; stretch it the last fraction
        final bw = math.max(1.0, e.w.roundToDouble());
        final bh = math.max(1.0, e.h.roundToDouble());
        canvas.scale(e.w / bw, e.h / bh);
        sp.eye(e.w, e.h).draw(canvas, _imagePaint);
      }
      canvas.restore();
    }
    canvas.save();
    canvas.transform(m4(pose.foxMouth));
    canvas.drawPath(a.mouth, a.mouthPaint);
    canvas.restore();
    if (pose.hasTear && pose.tearOpacity > 0) {
      canvas.save();
      canvas.transform(m4(pose.tear));
      canvas.drawOval(
          Rect.fromCenter(center: Offset.zero, width: r * 0.07, height: r * 0.1),
          Paint()..color = a.tearColor.withValues(alpha: pose.tearOpacity.clamp(0.0, 1.0).toDouble()));
      canvas.restore();
    }
    canvas.restore(); // feat

    // the time rides the belly, so it leans and breathes with the body
    if (p.clock) {
      final tp = a.clockFor(clockText(p.clock24, DateTime.now()));
      final baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      tp.paint(canvas, Offset(-tp.width / 2, 1.36 * r - baseline));
    }

    canvas.restore(); // mass
    canvas.restore(); // frame
  }

  void _at(Canvas canvas, List<double> t, FoxSprite s) {
    canvas.save();
    canvas.transform(m4(t));
    s.draw(canvas, _imagePaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FoxPainter old) =>
      old.assets != assets ||
      old.frame != frame ||
      old.sprites != sprites ||
      old.devicePixelRatio != devicePixelRatio;
}
