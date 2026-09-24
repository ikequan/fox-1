// The avatar's motion: a line-for-line port of the web design tool's rig.
//
// Written in a deliberately plain style (no %, no .abs(), no ints, no null
// operators) so it can be converted mechanically back to JavaScript and
// checked against the web tool's own output. Keep that style when editing.

import 'dart:math' as math;

import 'params.dart';
import 'state.dart';

// @js-skip-start  (these helpers have hand-written JavaScript equivalents)
const double tau = math.pi * 2;
double rad(double d) => d * math.pi / 180;
double absd(double x) => x < 0 ? -x : x;
double fmod(double x, double m) => x % m; // Dart's % is never negative here
double floorD(double x) => x.floorToDouble();
double clampD(double x, double lo, double hi) => x < lo ? lo : (x > hi ? hi : x);
double powD(double a, double b) => math.pow(a, b).toDouble();
double one(double u, AvatarParams p) => 1;
double zero(double u) => 0;
// @js-skip-end

// ---------------------------------------------------------------- easing

double sw(double u, [double k = 1]) => math.sin(u * tau * k);
double ease(double u) => 0.5 - 0.5 * math.cos(u * tau);

/// A blink centred on [at], [w] wide, [depth] 0..1.
double lid(double u, double at, double w, double depth) {
  var d = absd(u - at);
  d = math.min(d, 1 - d);
  final k = math.max(0.0, 1 - (d / w) * (d / w));
  return 1 - 0.94 * depth * k * k;
}

/// Hold a value, slide quickly to the next: reads as a considered glance.
double steps(double u, List<double> arr) {
  final n = arr.length.toDouble();
  final x = u * n;
  final i = floorD(x);
  final f = x - i;
  var k = math.min(1.0, f / 0.32);
  k = 0.5 - 0.5 * math.cos(k * math.pi);
  final a = arr[fmod(i, n).toInt()];
  final b = arr[fmod(i + 1, n).toInt()];
  return a + (b - a) * k;
}

/// 1 while the gaze is moving, 0 while it rests.
double dartGaze(double u) {
  final f = fmod(u * 5, 1);
  return f < 0.32 ? math.sin(f / 0.32 * math.pi) : 0;
}

/// Ramp in, hold, ramp out: a pose that is taken and kept.
double plateau(double u, double a, double b) {
  if (u < a) return 0.5 - 0.5 * math.cos(u / a * math.pi);
  if (u > b) return 0.5 - 0.5 * math.cos((1 - u) / (1 - b) * math.pi);
  return 1;
}

/// Syllables with a breath pause, continuous across the loop.
double syllables(double u, double n) {
  final beatV = absd(math.sin(math.pi * n * u));
  final vary = 0.55 + 0.45 * math.sin(u * tau * 2 + 1);
  var d = absd(u - 0.87);
  d = math.min(d, 1 - d);
  final pause = d < 0.1 ? 1 - powD(1 - d / 0.1, 2) : 1.0;
  return beatV * vary * pause;
}

/// Fast attack, then decay: never a jump.
double beat(double x) {
  if (x < 0) return 0;
  if (x < 0.04) return x / 0.04;
  return math.exp(-15 * (x - 0.04));
}

/// Two beats per loop, the second softer: a heartbeat.
double thump(double u) {
  final p = fmod(u * 2, 1);
  return math.min(1.0, beat(p) + 0.62 * beat(p - 0.17));
}

double hop(double u, double n) => absd(math.sin(fmod(u * n, 1) * math.pi));

/// A quick ear flick centred on [at].
double flick(double u, double at) {
  var d = u - at;
  if (d < 0) d += 1;
  return d < 0.14 ? math.sin(d / 0.14 * math.pi) : 0;
}

double hash01(double n) {
  final x = math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - floorD(x);
}

// ---------------------------------------------------------------- data

enum EyeKind { shape, arc, heart }

class Head {
  const Head({required this.y, required this.p, required this.r, required this.f,
      this.sx = 1, this.sy = 1});
  final double y, p, r, f, sx, sy;
}

class EyeSpec {
  const EyeSpec({this.w = 1, this.h = 1, this.az = 1, this.el = 0, this.rot = 0,
      this.kind = EyeKind.shape, this.sx = one, this.sy = one});
  final double w, h, az, el, rot;
  final EyeKind kind;
  final double Function(double u, AvatarParams p) sx, sy;
}

class MouthSpec {
  const MouthSpec({this.el = -34, this.w = 2.1, this.h = 1, this.open = zero});
  final double el, w, h;
  final double Function(double u) open;
}

class Ears {
  const Ears({required this.l, required this.r, required this.n});
  final double l, r, n;
}

class StateDef {
  const StateDef({
    required this.dur,
    required this.seed,
    required this.wander,
    required this.head,
    required this.ears,
    required this.foxMouth,
    this.eyeL = const EyeSpec(),
    this.eyeR = const EyeSpec(),
    this.hasBattery = false,
    this.battery = zero,
    this.boltFull = false,
    this.hasMouth = false,
    this.mouth = const MouthSpec(),
    this.tear = false,
  });
  final double dur, seed, wander;
  final Head Function(double u) head;
  final Ears Function(double u) ears;
  final double Function(double u) foxMouth;
  final EyeSpec eyeL, eyeR;
  final bool hasBattery;
  final double Function(double u) battery;
  final bool boltFull;
  final bool hasMouth;
  final MouthSpec mouth;
  final bool tear;
}

// ---------------------------------------------------------------- states

final eIdle = EyeSpec(sy: (u, p) => lid(u, 0.78, 0.045, p.blink));
final eCharging = EyeSpec(w: 1.08, h: 0.92, sy: (u, p) => lid(u, 0.9, 0.05, p.blink));
final eFull = EyeSpec(w: 1.08, h: 0.92, sy: (u, p) => 1 - 0.1 * ease(u) * p.blink);
final eLow = EyeSpec(w: 1.12, h: 0.95, sy: (u, p) => lid(u, 0.42, 0.06, p.blink));
final eListening = EyeSpec(w: 1.06, h: 1.16, sy: (u, p) => lid(u, 0.52, 0.032, p.blink));
final eSpeaking = EyeSpec(
    h: 0.96, sy: (u, p) => (1 - 0.14 * syllables(u, 5)) * lid(u, 0.66, 0.035, p.blink));
final eSleeping = EyeSpec(w: 1.35, h: 0.25, sy: (u, p) => 1 + 0.5 * ease(u));
final eSad = EyeSpec(el: -4, rot: 24, sy: (u, p) => lid(u, 0.3, 0.05, p.blink));
final eHappy = EyeSpec(
    kind: EyeKind.arc, el: 8, w: 1.65, h: 0.45, sy: (u, p) => 1 - 0.22 * hop(u, 2));
final eLove = EyeSpec(
    kind: EyeKind.heart,
    el: 3,
    w: 2.0,
    h: 0.92,
    sx: (u, p) => 1 + 0.16 * thump(u),
    sy: (u, p) => 1 + 0.18 * thump(u));

final Map<AvatarState, StateDef> kStates = <AvatarState, StateDef>{
  AvatarState.idle: StateDef(
    dur: 6.4,
    seed: 3,
    wander: 1,
    head: (u) => Head(
        y: sw(u), p: -0.2 + 0.3 * sw(u, 2), r: 0.4 * sw(u), f: -0.4 - 0.6 * ease(fmod(u * 2, 1))),
    eyeL: eIdle,
    eyeR: eIdle,
    ears: (u) => Ears(l: 12 + 22 * flick(u, 0.3), r: 12 + 22 * flick(u, 0.72), n: 1),
    foxMouth: (u) => 0.22,
  ),
  AvatarState.charging: StateDef(
    dur: 3.4,
    seed: 7,
    wander: 0.55,
    head: (u) => Head(y: 0.45 * sw(u), p: 0.5, r: -0.3 * sw(u), f: -0.5 - 0.4 * ease(u)),
    eyeL: eCharging,
    eyeR: eCharging,
    hasBattery: true,
    battery: (u) {
      final p = fmod(u * 1.15, 1);
      return p > 0.87 ? 1 : math.min(1.0, 0.05 + p * 1.1);
    },
    ears: (u) => Ears(l: 18 + 4 * sw(u), r: 18 - 4 * sw(u), n: 0.97),
    foxMouth: (u) => 0.26 + 0.05 * ease(u),
  ),
  AvatarState.fullBattery: StateDef(
    dur: 3.0,
    seed: 11,
    wander: 0.7,
    head: (u) => Head(y: 0.55 * sw(u), p: -0.3, r: 0.5 * sw(u), f: -0.4 - 1.1 * ease(u)),
    eyeL: eFull,
    eyeR: eFull,
    hasBattery: true,
    battery: (u) => 1,
    boltFull: true,
    ears: (u) => Ears(l: 4 - 5 * ease(u), r: 4 - 5 * ease(u), n: 1.06),
    foxMouth: (u) => 0.5 + 0.1 * ease(u),
  ),
  AvatarState.lowBattery: StateDef(
    dur: 4.6,
    seed: 13,
    wander: 0.3,
    head: (u) =>
        Head(y: -0.35 + 0.3 * sw(u), p: 0.8 + 0.12 * ease(u), r: -0.55, f: 0.25 * ease(u) - 0.1),
    eyeL: eLow,
    eyeR: eLow,
    hasBattery: true,
    battery: (u) => fmod(u * 2, 1) < 0.62 ? 0.3 : 0,
    ears: (u) => Ears(l: 60 + 6 * ease(u), r: 56 + 6 * ease(u), n: 0.9),
    foxMouth: (u) => -0.12,
  ),
  AvatarState.listening: StateDef(
    dur: 3.2,
    seed: 17,
    wander: 0.3,
    head: (u) {
      final k = plateau(u, 0.16, 0.84);
      return Head(
          y: 0.95 * k,
          p: -0.28 + 0.22 * math.max(0.0, math.sin(u * tau * 3)) * k,
          r: -2.4 * k,
          f: -0.5 - 0.25 * ease(u));
    },
    eyeL: eListening,
    eyeR: eListening,
    ears: (u) {
      final k = plateau(u, 0.16, 0.84);
      return Ears(l: 6 - 18 * k + 14 * flick(u, 0.5), r: 6 + 18 * k, n: 1.1);
    },
    foxMouth: (u) => 0.3 + 0.06 * math.sin(u * tau * 3),
  ),
  AvatarState.speaking: StateDef(
    dur: 2.8,
    seed: 19,
    wander: 0.55,
    head: (u) {
      final s = syllables(u, 5);
      return Head(y: 0.55 * sw(u), p: -0.12 + 0.3 * s, r: 0.4 * sw(u, 2), f: -0.5 - 0.5 * s);
    },
    eyeL: eSpeaking,
    eyeR: eSpeaking,
    hasMouth: true,
    mouth: MouthSpec(el: -31, w: 2.1, h: 1.02, open: (u) => 0.14 + 0.86 * syllables(u, 5)),
    ears: (u) => Ears(l: 10 + 7 * syllables(u, 5), r: 10 + 7 * syllables(u, 5), n: 1),
    foxMouth: (u) => 0.18 + 0.9 * syllables(u, 5),
  ),
  AvatarState.sleeping: StateDef(
    dur: 7.2,
    seed: 23,
    wander: 0.08,
    head: (u) =>
        Head(y: -0.45 + 0.25 * sw(u), p: 1.05 + 0.2 * ease(u), r: -0.7, f: -0.2 - 0.8 * ease(u)),
    eyeL: eSleeping,
    eyeR: eSleeping,
    ears: (u) => Ears(l: 72 + 4 * ease(u), r: 70 + 4 * ease(u), n: 0.86),
    foxMouth: (u) => 0.06 + 0.04 * ease(u),
  ),
  AvatarState.thinking: StateDef(
    dur: 4.4,
    seed: 29,
    wander: 0.35,
    head: (u) => Head(
        y: steps(u, <double>[-0.95, -0.95, 0.55, 0.62, -0.3]),
        p: steps(u, <double>[-0.75, -0.8, -0.72, -0.35, -0.7]) + 0.05 * sw(u, 3),
        r: 0.45 * sw(u, 2),
        f: -0.55 - 0.15 * sw(u, 2)),
    eyeL: EyeSpec(
        az: 0.95,
        el: 6,
        h: 1.02,
        sy: (u, p) => (0.82 + 0.18 * dartGaze(u)) * lid(u, 0.7, 0.035, p.blink)),
    eyeR: EyeSpec(
        az: 0.95,
        el: 6,
        h: 0.86,
        sy: (u, p) => (0.7 + 0.3 * dartGaze(u)) * lid(u, 0.7, 0.035, p.blink)),
    ears: (u) => Ears(l: 8 + 4 * dartGaze(u), r: 10 + 26 * dartGaze(u), n: 1.02),
    foxMouth: (u) => 0.1 + 0.06 * dartGaze(u),
  ),
  AvatarState.sad: StateDef(
    dur: 5.2,
    seed: 31,
    wander: 0.35,
    tear: true,
    head: (u) => Head(y: 0.3 * sw(u), p: 0.95 + 0.15 * ease(u), r: -0.4, f: 0.3 * ease(u)),
    eyeL: eSad,
    eyeR: eSad,
    ears: (u) => Ears(l: 62 + 5 * ease(u), r: 62 + 5 * ease(u), n: 0.9),
    foxMouth: (u) => -0.34,
  ),
  AvatarState.happy: StateDef(
    dur: 1.9,
    seed: 37,
    wander: 0.8,
    head: (u) {
      final h = hop(u, 2);
      final p = fmod(u * 2, 1);
      final sq = p < 0.12 ? (0.12 - p) / 0.12 : (p > 0.88 ? (p - 0.88) / 0.12 : 0.0);
      return Head(
          y: 0.75 * sw(u),
          p: -0.7 - 0.3 * h,
          r: 0.8 * sw(u, 2),
          f: -0.6 - 4 * h,
          sx: 1 + 0.05 * sq - 0.015 * h,
          sy: 1 - 0.06 * sq + 0.02 * h);
    },
    eyeL: eHappy,
    eyeR: eHappy,
    ears: (u) => Ears(l: 8 - 12 * hop(u, 2), r: 8 - 12 * hop(u, 2), n: 1.04 + 0.04 * hop(u, 2)),
    foxMouth: (u) => 0.66 + 0.24 * hop(u, 2),
  ),
  AvatarState.love: StateDef(
    dur: 2.2,
    seed: 43,
    wander: 0.6,
    head: (u) {
      final t = thump(u);
      return Head(
          y: 0.45 * sw(u),
          p: -0.45 - 0.1 * t,
          r: 0.9 * sw(u),
          f: -0.6 - 1.1 * t,
          sx: 1 + 0.03 * t,
          sy: 1 + 0.04 * t);
    },
    eyeL: eLove,
    eyeR: eLove,
    ears: (u) => Ears(l: 6 - 8 * thump(u), r: 6 - 8 * thump(u), n: 1.05),
    foxMouth: (u) => 0.5 + 0.22 * thump(u),
  ),
  AvatarState.confused: StateDef(
    dur: 4.2,
    seed: 41,
    wander: 1,
    head: (u) => Head(
        y: -1.05 * math.sin(u * tau) - 0.2,
        p: -0.2 + 0.35 * sw(u, 2),
        r: 1.8 * math.sin(u * tau + 0.6),
        f: -0.5 - 0.3 * sw(u, 2)),
    eyeL: EyeSpec(h: 1.1, el: 5, rot: -4, sy: (u, p) => lid(u, 0.44, 0.03, p.blink)),
    eyeR: EyeSpec(
        h: 0.4,
        w: 1.25,
        el: -3,
        rot: 11,
        sy: (u, p) => 1 + 1.1 * math.max(0.0, math.sin((u - 0.5) * tau))),
    ears: (u) => Ears(
        l: 4 + 44 * math.max(0.0, math.sin(u * tau)),
        r: 48 - 44 * math.max(0.0, math.sin(u * tau)),
        n: 1),
    foxMouth: (u) => 0.06 + 0.12 * math.max(0.0, math.sin(u * tau)),
  ),
};

// ---------------------------------------------------------------- glances

class Glance {
  const Glance({required this.y, required this.p, required this.r, required this.e,
      required this.x, required this.hold});
  final double y, p, r, e, x, hold;
}

Glance glanceTarget(double seed, double i) {
  final b = seed * 17.23 + i * 3.71;
  return Glance(
      y: hash01(b) * 2 - 1,
      p: hash01(b + 1.3) * 2 - 1,
      r: hash01(b + 2.9) * 2 - 1,
      e: hash01(b + 4.1) * 2 - 1,
      x: hash01(b + 5.7) * 2 - 1,
      hold: hash01(b + 7.3));
}

/// The move between two held glances: eased and varied, or a near-instant snap.
double glanceMove(double f, double hold, AvatarParams p) {
  final span = p.glanceStyle == GlanceStyle.sharp ? 0.035 : 0.18 + 0.22 * hold;
  final k = math.min(1.0, f / span);
  return k * k * (3 - 2 * k);
}

class Wander {
  const Wander({required this.y, required this.p, required this.r, required this.x,
      required this.eT, required this.eAmt});
  final double y, p, r, x, eT, eAmt;
}

/// Random glances on real time: [gx] is time measured in glances.
Wander wanderAt(StateDef s, AvatarParams p, double gx) {
  final amt = p.wander * s.wander;
  if (amt == 0) return const Wander(y: 0, p: 0, r: 0, x: 0, eT: 0, eAmt: 0);
  final i = floorD(gx);
  final f = gx - i;
  final a = glanceTarget(s.seed, i);
  final b = glanceTarget(s.seed, i + 1);
  final k = glanceMove(f, a.hold, p);
  return Wander(
      y: (a.y + (b.y - a.y) * k) * amt,
      p: (a.p + (b.p - a.p) * k) * amt,
      r: (a.r + (b.r - a.r) * k) * amt,
      x: (a.x + (b.x - a.x) * k) * amt,
      eT: a.e + (b.e - a.e) * k,
      eAmt: s.wander);
}

/// In sharp mode the state's own head motion is sampled on the glance grid:
/// it holds a pose, then snaps. Lift and squash stay continuous.
Head headAt(StateDef s, AvatarParams p, double u) {
  final hu = s.head(u);
  if (p.glanceStyle != GlanceStyle.sharp) return hu;
  final k0 = math.max(2.0, (s.dur / p.glance).roundToDouble());
  final x = u * k0;
  final i = floorD(x);
  final f = x - i;
  final a = s.head(i / k0);
  final b = s.head(fmod(i + 1, k0) / k0);
  final k = glanceMove(f, 0, p);
  return Head(
      y: a.y + (b.y - a.y) * k,
      p: a.p + (b.p - a.p) * k,
      r: a.r + (b.r - a.r) * k,
      f: hu.f,
      sx: hu.sx,
      sy: hu.sy);
}

// ---------------------------------------------------------------- sample
// Everything about a state at one moment, as plain numbers, so two states
// can be blended during a transition before any geometry is worked out.

class EyeSample {
  const EyeSample({required this.w, required this.h, required this.az, required this.el,
      required this.rot, required this.sx, required this.sy, required this.kind});
  final double w, h, az, el, rot, sx, sy;
  final EyeKind kind;
}

class Sample {
  const Sample({
    required this.y,
    required this.p,
    required this.r,
    required this.f,
    required this.sx,
    required this.sy,
    required this.wy,
    required this.wp,
    required this.wr,
    required this.wx,
    required this.eT,
    required this.eAmt,
    required this.eyeL,
    required this.eyeR,
    required this.hasBattery,
    required this.battery,
    required this.boltFull,
    required this.hasMouth,
    required this.mouthEl,
    required this.mouthW,
    required this.mouthH,
    required this.mouthOpen,
    required this.foxMouth,
    required this.earL,
    required this.earR,
    required this.earN,
    required this.hasTear,
    required this.tearPr,
    required this.tearFade,
    required this.fMid,
    required this.seed,
    required this.breath,
  });
  final double y, p, r, f, sx, sy;
  final double wy, wp, wr, wx, eT, eAmt;
  final EyeSample eyeL, eyeR;
  final bool hasBattery;
  final double battery;
  final bool boltFull;
  final bool hasMouth;
  final double mouthEl, mouthW, mouthH, mouthOpen;
  final double foxMouth, earL, earR, earN;
  final bool hasTear;
  final double tearPr, tearFade;
  final double fMid;
  final double seed;

  /// The fox's breathing, -1..1, twice per loop.
  final double breath;
}

EyeSample eyeSample(EyeSpec e, double u, AvatarParams p) {
  return EyeSample(
      w: e.w, h: e.h, az: e.az, el: e.el, rot: e.rot, sx: e.sx(u, p), sy: e.sy(u, p), kind: e.kind);
}

/// State [st] at [t] seconds, entered at [since] seconds (its own loop starts
/// then; the glances run on absolute time so they never jump).
Sample sampleState(AvatarState st, AvatarParams p, double t, double since) {
  final s = kStates[st]!;
  final u = fmod((t - since) * p.speed / s.dur, 1);
  final hu = headAt(s, p, u);
  final wd = wanderAt(s, p, t * p.speed / p.glance);
  final ears = s.ears(u);
  // the middle of this state's float range, which centres the frame
  var fLo = 1000.0;
  var fHi = -1000.0;
  for (var li = 0.0; li < 16; li += 1) {
    final fv = s.head(li / 16).f;
    fLo = math.min(fLo, fv);
    fHi = math.max(fHi, fv);
  }
  final pr = clampD((u - 0.18) / 0.62, 0, 1);
  final fade = (u < 0.18 || u > 0.86) ? 0.0 : (pr < 0.12 ? pr / 0.12 : (pr > 0.82 ? (1 - pr) / 0.18 : 1.0));
  return Sample(
    y: hu.y,
    p: hu.p,
    r: hu.r,
    f: hu.f,
    sx: hu.sx,
    sy: hu.sy,
    wy: wd.y,
    wp: wd.p,
    wr: wd.r,
    wx: wd.x,
    eT: wd.eT,
    eAmt: wd.eAmt,
    eyeL: eyeSample(s.eyeL, u, p),
    eyeR: eyeSample(s.eyeR, u, p),
    hasBattery: s.hasBattery,
    battery: s.hasBattery ? s.battery(u) : 0,
    boltFull: s.boltFull,
    hasMouth: s.hasMouth,
    mouthEl: s.mouth.el,
    mouthW: s.mouth.w,
    mouthH: s.mouth.h,
    mouthOpen: s.hasMouth ? s.mouth.open(u) : 0,
    foxMouth: s.foxMouth(u),
    earL: ears.l,
    earR: ears.r,
    earN: ears.n,
    hasTear: s.tear,
    tearPr: pr,
    tearFade: s.tear ? fade : 0,
    fMid: (fLo + fHi) / 2,
    seed: s.seed,
    breath: math.sin(u * tau * 2),
  );
}

double lerpD(double a, double b, double w) => a + (b - a) * w;

/// Blend two states for a transition, [w] from 0 (all [a]) to 1 (all [b]).
/// Numbers blend; things that can't (eye shape, battery cells) swap at the
/// midpoint under a blink, so the change is never seen happening.
Sample blendSamples(Sample a, Sample b, double w) {
  final first = w < 0.5;
  final lookChanges = a.eyeL.kind != b.eyeL.kind || a.hasBattery != b.hasBattery;
  final blinkK = lookChanges ? 1 - 0.94 * math.sin(math.pi * w) : 1.0;
  EyeSample eye(EyeSample x, EyeSample y) => EyeSample(
      w: lerpD(x.w, y.w, w),
      h: lerpD(x.h, y.h, w),
      az: lerpD(x.az, y.az, w),
      el: lerpD(x.el, y.el, w),
      rot: lerpD(x.rot, y.rot, w),
      sx: lerpD(x.sx, y.sx, w),
      sy: lerpD(x.sy, y.sy, w) * blinkK,
      kind: first ? x.kind : y.kind);
  final bothBattery = a.hasBattery && b.hasBattery;
  final bothMouth = a.hasMouth && b.hasMouth;
  final m = b.hasMouth ? b : a; // whichever state has the mouth
  final mouthOpen = bothMouth
      ? lerpD(a.mouthOpen, b.mouthOpen, w)
      : (b.hasMouth ? b.mouthOpen * w : a.mouthOpen * (1 - w));
  final tearFade = lerpD(a.hasTear ? a.tearFade : 0, b.hasTear ? b.tearFade : 0, w);
  return Sample(
    y: lerpD(a.y, b.y, w),
    p: lerpD(a.p, b.p, w),
    r: lerpD(a.r, b.r, w),
    f: lerpD(a.f, b.f, w),
    sx: lerpD(a.sx, b.sx, w),
    sy: lerpD(a.sy, b.sy, w),
    wy: lerpD(a.wy, b.wy, w),
    wp: lerpD(a.wp, b.wp, w),
    wr: lerpD(a.wr, b.wr, w),
    wx: lerpD(a.wx, b.wx, w),
    eT: lerpD(a.eT, b.eT, w),
    eAmt: lerpD(a.eAmt, b.eAmt, w),
    eyeL: eye(a.eyeL, b.eyeL),
    eyeR: eye(a.eyeR, b.eyeR),
    hasBattery: first ? a.hasBattery : b.hasBattery,
    battery: bothBattery ? lerpD(a.battery, b.battery, w) : (first ? a.battery : b.battery),
    boltFull: first ? a.boltFull : b.boltFull,
    hasMouth: a.hasMouth || b.hasMouth,
    mouthEl: m.mouthEl,
    mouthW: m.mouthW,
    mouthH: m.mouthH,
    mouthOpen: mouthOpen,
    foxMouth: lerpD(a.foxMouth, b.foxMouth, w),
    earL: lerpD(a.earL, b.earL, w),
    earR: lerpD(a.earR, b.earR, w),
    earN: lerpD(a.earN, b.earN, w),
    hasTear: a.hasTear || b.hasTear,
    tearPr: b.hasTear ? b.tearPr : a.tearPr,
    tearFade: tearFade,
    fMid: lerpD(a.fMid, b.fMid, w),
    seed: first ? a.seed : b.seed,
    breath: lerpD(a.breath, b.breath, w),
  );
}

// ---------------------------------------------------------------- geometry

/// Rotate a 3D vector by pitch (x), then yaw (y), then roll (z).
List<double> rot3(List<double> v, double yaw, double pitch, double roll) {
  final cp = math.cos(pitch);
  final sp = math.sin(pitch);
  final y1 = v[1] * cp - v[2] * sp;
  final z1 = v[1] * sp + v[2] * cp;
  final cy = math.cos(yaw);
  final sy = math.sin(yaw);
  final x2 = v[0] * cy + z1 * sy;
  final z2 = -v[0] * sy + z1 * cy;
  final cr = math.cos(roll);
  final sr = math.sin(roll);
  return <double>[x2 * cr - y1 * sr, x2 * sr + y1 * cr, z2];
}

/// A feature at (azimuth, elevation) on the invisible sphere: its screen
/// point plus the 2x2 from the rotated tangent frame. That matrix is the whole
/// trick: the far eye narrows and skews on its own.
List<double> place(double az, double el, double yaw, double pitch, double roll, double radius,
    double rot, double sx, double sy) {
  final a = rad(az);
  final e = rad(el);
  final ca = math.cos(a);
  final sa = math.sin(a);
  final ce = math.cos(e);
  final se = math.sin(e);
  final v = rot3(<double>[sa * ce, se, ca * ce], yaw, pitch, roll);
  final uu = rot3(<double>[ca, 0, -sa], yaw, pitch, roll);
  final ww = rot3(<double>[-sa * se, ce, -ca * se], yaw, pitch, roll);
  final aa = uu[0];
  final bb = -uu[1];
  final cc = -ww[0];
  final dd = ww[1];
  final rl = rad(rot);
  final cs = math.cos(rl);
  final sn = math.sin(rl);
  return <double>[
    sx * (aa * cs + cc * sn),
    sx * (bb * cs + dd * sn),
    sy * (-aa * sn + cc * cs),
    sy * (-bb * sn + dd * cs),
    radius * v[0],
    -radius * v[1],
  ];
}

class EyePose {
  const EyePose({required this.m, required this.w, required this.h, required this.kind});

  /// 2D transform [a b c d e f], as in SVG's matrix().
  final List<double> m;
  final double w, h;
  final EyeKind kind;
}

/// Everything a painter needs for one frame. Transforms are [a b c d e f].
class AvatarPose {
  const AvatarPose({
    required this.fox,
    required this.frameHalf,
    required this.frameCy,
    required this.slice,
    required this.dx,
    required this.lift,
    required this.sx,
    required this.sy,
    required this.eyeL,
    required this.eyeR,
    required this.hasBattery,
    required this.battery,
    required this.boltFull,
    required this.hasMouth,
    required this.mouth,
    required this.mouthW,
    required this.mouthH,
    required this.hasTear,
    required this.tear,
    required this.tearOpacity,
    required this.seed,
    required this.mass,
    required this.glow,
    required this.mask,
    required this.feat,
    required this.earL,
    required this.earR,
    required this.foxMouth,
  });
  final bool fox;

  /// The square frame: half its side and its vertical centre, design units.
  final double frameHalf, frameCy;

  /// Fill the screen (crop) rather than fit it.
  final bool slice;

  /// The whole face: translate (dx, lift), then scale (sx, sy).
  final double dx, lift, sx, sy;
  final EyePose eyeL, eyeR;
  final bool hasBattery;
  final double battery;
  final bool boltFull;
  final bool hasMouth;
  final List<double> mouth;
  final double mouthW, mouthH;
  final bool hasTear;
  final List<double> tear;
  final double tearOpacity;

  /// Bloub's body outline varies slightly per state.
  final double seed;

  // fox only (identity for bloub)
  final List<double> mass, glow, mask, feat, earL, earR, foxMouth;
}

const List<double> identityM = <double>[1, 0, 0, 1, 0, 0];

double foxEyeY(double el, double radius) => -math.sin(rad(el)) * radius * 0.62 - 0.14 * radius;

/// Geometry for one frame of either character.
AvatarPose poseFromSample(Sample s, AvatarParams p) {
  final fox = p.character == Character.fox;
  final screen = p.layout != Layout.figure;
  final radius = p.radius;
  final yaw = rad((s.y + s.wy * 0.9) * p.yaw);
  final pitch = rad((s.p + s.wp * 0.7) * p.pitch);
  final roll = rad((s.r + s.wr * 0.7) * p.roll);
  final lift = s.f * p.drift;
  final dx = s.wx * p.drift * 1.4;

  // the eyes roam their range; for bloub with the clock on, the floor rises
  // just enough that nothing on the face ever lands on the time
  final floorEl = p.clock ? -37.0 : -62.0;
  final lowest = s.hasMouth ? (fox ? -48.0 : -39.0) : (fox ? -30.0 : -14.0);
  final lo = fox ? -4.0 : math.max(-20.0, floorEl - lowest);
  final hi = fox ? 18.0 : 32.0;
  final jumpK = (p.wander > 0 ? 1.0 : 0.0) * s.eAmt * (p.eyeJump / 100);
  final target = lo + (s.eT + 1) / 2 * (hi - lo);
  final effEl = clampD(p.eyeEl + (target - p.eyeEl) * jumpK, lo, hi);

  // the frame: bloub hugs the face; the fox hugs its whole silhouette
  final half = fox ? 1.5 * radius : radius + p.wobble * 2;
  final frameHalf = half + ((fox && screen) ? p.pad * 0.35 : p.pad);
  final frameCy = (screen && !fox) ? 0.0 : s.fMid * p.drift;

  var bw = p.eyeW;
  var bh = p.eyeH;
  if (p.eyeShape != EyeShape.pill) {
    bw = (p.eyeW + p.eyeH) / 2;
    bh = bw;
  }

  if (!fox) {
    EyePose bloubEye(EyeSample e, double sign) {
      return EyePose(
          m: place(-sign * p.eyeAz * e.az, effEl + e.el, yaw, pitch, roll, radius, sign * e.rot,
              e.sx, e.sy),
          w: bw * e.w,
          h: bh * e.h,
          kind: e.kind);
    }

    var mw = p.eyeW * s.mouthW;
    var mh = p.eyeH * 0.5 * s.mouthH;
    if (p.eyeShape != EyeShape.pill) {
      final ms = (p.eyeW + p.eyeH) / 2;
      mw = ms * s.mouthW * 0.62;
      mh = ms * 0.5 * s.mouthH;
    }
    final tm = place(-p.eyeAz - 6, effEl - 16, yaw, pitch, roll, radius, 0, 1, 1);
    return AvatarPose(
      fox: false,
      frameHalf: frameHalf,
      frameCy: frameCy,
      slice: p.pad <= 0 && !screen,
      dx: dx,
      lift: lift,
      sx: s.sx,
      sy: s.sy,
      eyeL: bloubEye(s.eyeL, 1),
      eyeR: bloubEye(s.eyeR, -1),
      hasBattery: s.hasBattery,
      battery: s.battery,
      boltFull: s.boltFull,
      hasMouth: s.hasMouth,
      mouth: place(0, effEl + s.mouthEl, yaw, pitch, roll, radius, 0, 1, s.mouthOpen),
      mouthW: mw,
      mouthH: mh,
      hasTear: s.hasTear,
      tear: <double>[tm[0], tm[1], tm[2], tm[3], tm[4], tm[5] + 32 * s.tearPr * s.tearPr],
      tearOpacity: s.tearFade,
      seed: s.seed,
      mass: identityM,
      glow: identityM,
      mask: identityM,
      feat: identityM,
      earL: identityM,
      earR: identityM,
      foxMouth: identityM,
    );
  }

  // ---- fox: one soft mass that leans and breathes from its base
  final yN = math.sin(yaw);
  final pN = math.sin(pitch);
  final ang = roll * 0.6;
  final ca = math.cos(ang);
  final sa = math.sin(ang);
  final lean = yN * 0.035;
  final br = 1 + 0.012 * s.breath;
  final sxB = 1 + (br - 1) * 0.5;
  final m0 = ca * sxB;
  final m1 = sa * sxB;
  final m2 = (ca * lean - sa) * br;
  final m3 = (sa * lean + ca) * br;
  final py = 2.2 * radius;
  final fx = yN * 0.16 * radius;
  final fy = pN * 0.08 * radius;
  final sep = math.sin(rad(p.eyeAz)) * radius * 0.95;
  final farL = math.max(0.0, -yN);
  final farR = math.max(0.0, yN);
  final k = 0.62 * (s.hasBattery ? 1.2 : 1.0);

  EyePose foxEye(EyeSample e, double sg, double far) {
    final sxE = (1 - 0.3 * far) * e.sx;
    final rr = rad(sg * -e.rot);
    final cr = math.cos(rr);
    final sr = math.sin(rr);
    return EyePose(
        m: <double>[
          cr * sxE,
          sr * sxE,
          -sr * e.sy,
          cr * e.sy,
          sg * sep * e.az * (1 - 0.14 * far),
          foxEyeY(effEl + e.el, radius),
        ],
        w: bw * k * e.w,
        h: bh * k * e.h,
        kind: e.kind);
  }

  List<double> ear(double sg, double deg) {
    final a = rad(sg * (18 + 0.6 * deg));
    final c = math.cos(a);
    final sn = math.sin(a);
    return <double>[c, sn, -sn * s.earN, c * s.earN, sg * 0.56 * radius + yN * 0.06 * radius,
      -0.8 * radius];
  }

  return AvatarPose(
    fox: true,
    frameHalf: frameHalf,
    frameCy: frameCy,
    slice: false,
    dx: dx,
    lift: lift,
    sx: s.sx,
    sy: s.sy,
    eyeL: foxEye(s.eyeL, -1, farL),
    eyeR: foxEye(s.eyeR, 1, farR),
    hasBattery: s.hasBattery,
    battery: s.battery,
    boltFull: s.boltFull,
    hasMouth: false,
    mouth: identityM,
    mouthW: 0,
    mouthH: 0,
    hasTear: s.hasTear,
    tear: <double>[
      1,
      0,
      0,
      1,
      -sep - 0.02 * radius,
      foxEyeY(effEl, radius) + 0.16 * radius + 0.2 * radius * s.tearPr * s.tearPr,
    ],
    tearOpacity: s.tearFade,
    seed: s.seed,
    mass: <double>[m0, m1, m2, m3, -m2 * py, py - m3 * py],
    glow: <double>[1, 0, 0, 1, -yN * 0.05 * radius, -pN * 0.04 * radius],
    mask: <double>[1, 0, 0, 1, fx, fy],
    feat: <double>[1, 0, 0, 1, fx * 1.25, fy * 1.25],
    earL: ear(-1, s.earL),
    earR: ear(1, s.earR),
    foxMouth: <double>[1, 0, 0, s.foxMouth * 2.2, 0, 0.19 * radius],
  );
}
