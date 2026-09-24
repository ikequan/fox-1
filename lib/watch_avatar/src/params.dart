import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

enum Character { bloub, fox }

/// Bloub only. `screen`: the whole screen is the face. `figure`: the face
/// sits on a background. (For the fox, `screen` just means tighter framing.)
enum Layout { screen, figure }

/// Bloub only.
enum FaceShape { circle, squircle }

enum EyeShape { pill, round, square }

enum GlanceStyle { smooth, sharp }

/// Every setting from the web design tool, with the same names, units and
/// defaults. A settings page reads and writes these; [toJson] / [fromJson]
/// use exactly the web tool's format, so a design exported there loads here.
@immutable
class AvatarParams {
  const AvatarParams({
    // colour
    this.body = const Color(0xFFF2F2EC),
    this.eye = const Color(0xFF0A0A0C),
    this.bg = const Color(0xFF0A0A0C),
    this.muzzle = const Color(0xFFFFFFFF),
    this.boltLow = const Color(0xFFFF453A),
    this.boltFull = const Color(0xFF32D74B),
    // character and shape
    this.character = Character.bloub,
    this.layout = Layout.screen,
    this.faceShape = FaceShape.circle,
    this.eyeShape = EyeShape.pill,
    this.radius = 100,
    this.pad = 12,
    this.corner = 4,
    this.wobble = 0.6,
    this.eyeW = 21,
    this.eyeH = 44,
    this.eyeAz = 21,
    this.eyeEl = 9,
    // motion
    this.speed = 1,
    this.yaw = 17,
    this.pitch = 11,
    this.roll = 6,
    this.drift = 5,
    this.blink = 1,
    this.wander = 0.6,
    this.glance = 1.5,
    this.eyeJump = 100,
    this.glanceStyle = GlanceStyle.smooth,
    // clock
    this.clock = true,
    this.clock24 = true,
  });

  /// The fox with its own palette; everything else at the defaults.
  static const AvatarParams fox = AvatarParams(
    character: Character.fox,
    bg: Color(0xFF0B0B0C),
    body: Color(0xFFE8823C),
    eye: Color(0xFF141010),
    muzzle: Color(0xFFFBE7D2),
  );

  final Color body, eye, bg, muzzle, boltLow, boltFull;
  final Character character;
  final Layout layout;
  final FaceShape faceShape;
  final EyeShape eyeShape;
  final double radius, pad, corner, wobble, eyeW, eyeH, eyeAz, eyeEl;
  final double speed, yaw, pitch, roll, drift, blink, wander, glance, eyeJump;
  final GlanceStyle glanceStyle;
  final bool clock, clock24;

  /// The colour to paint behind everything: for bloub with the screen as its
  /// face that is the face colour, otherwise the background.
  Color get screenColor =>
      (layout == Layout.figure || character == Character.fox) ? bg : body;

  // ---------------------------------------------------------------- JSON

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static Color _color(Object? v, Color fallback) {
    if (v is! String) return fallback;
    final s = v.startsWith('#') ? v.substring(1) : v;
    final n = int.tryParse(s, radix: 16);
    if (n == null || s.length != 6) return fallback;
    return Color(0xFF000000 | n);
  }

  static double _num(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
  static bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;
  static T _enum<T extends Enum>(Object? v, List<T> values, T fallback) {
    for (final e in values) {
      if (e.name == v) return e;
    }
    return fallback;
  }

  /// Exactly the web tool's keys and value formats.
  Map<String, Object> toJson() => <String, Object>{
        'body': _hex(body),
        'eye': _hex(eye),
        'bg': _hex(bg),
        'muzzle': _hex(muzzle),
        'boltLow': _hex(boltLow),
        'boltFull': _hex(boltFull),
        'character': character.name,
        'layout': layout.name,
        'faceShape': faceShape.name,
        'eyeShape': eyeShape.name,
        'radius': radius,
        'pad': pad,
        'corner': corner,
        'wobble': wobble,
        'eyeW': eyeW,
        'eyeH': eyeH,
        'eyeAz': eyeAz,
        'eyeEl': eyeEl,
        'speed': speed,
        'yaw': yaw,
        'pitch': pitch,
        'roll': roll,
        'drift': drift,
        'blink': blink,
        'wander': wander,
        'glance': glance,
        'eyeJump': eyeJump,
        'glanceStyle': glanceStyle.name,
        'clock': clock,
        'clock24': clock24,
      };

  /// Reads the web tool's export. Unknown keys (such as the tool's GIF
  /// settings) are ignored; missing or malformed values fall back to [base].
  factory AvatarParams.fromJson(Map<String, Object?> j,
      {AvatarParams base = const AvatarParams()}) {
    return AvatarParams(
      body: _color(j['body'], base.body),
      eye: _color(j['eye'], base.eye),
      bg: _color(j['bg'], base.bg),
      muzzle: _color(j['muzzle'], base.muzzle),
      boltLow: _color(j['boltLow'], base.boltLow),
      boltFull: _color(j['boltFull'], base.boltFull),
      character: _enum(j['character'], Character.values, base.character),
      layout: _enum(j['layout'], Layout.values, base.layout),
      faceShape: _enum(j['faceShape'], FaceShape.values, base.faceShape),
      eyeShape: _enum(j['eyeShape'], EyeShape.values, base.eyeShape),
      radius: _num(j['radius'], base.radius),
      pad: _num(j['pad'], base.pad),
      corner: _num(j['corner'], base.corner),
      wobble: _num(j['wobble'], base.wobble),
      eyeW: _num(j['eyeW'], base.eyeW),
      eyeH: _num(j['eyeH'], base.eyeH),
      eyeAz: _num(j['eyeAz'], base.eyeAz),
      eyeEl: _num(j['eyeEl'], base.eyeEl),
      speed: _num(j['speed'], base.speed),
      yaw: _num(j['yaw'], base.yaw),
      pitch: _num(j['pitch'], base.pitch),
      roll: _num(j['roll'], base.roll),
      drift: _num(j['drift'], base.drift),
      blink: _num(j['blink'], base.blink),
      wander: _num(j['wander'], base.wander),
      glance: _num(j['glance'], base.glance),
      eyeJump: _num(j['eyeJump'], base.eyeJump),
      glanceStyle: _enum(j['glanceStyle'], GlanceStyle.values, base.glanceStyle),
      clock: _bool(j['clock'], base.clock),
      clock24: _bool(j['clock24'], base.clock24),
    );
  }

  /// One setting changed by its key: what a settings page calls.
  /// [value] is a Color, an enum value, a num or a bool, matching the key.
  AvatarParams withValue(String key, Object value) {
    final j = Map<String, Object?>.of(toJson());
    if (value is Color) {
      j[key] = _hex(value);
    } else if (value is Enum) {
      j[key] = value.name;
    } else {
      j[key] = value;
    }
    return AvatarParams.fromJson(j, base: this);
  }

  /// The value of one setting by its key, in the same types [withValue] takes.
  Object? valueOf(String key) {
    switch (key) {
      case 'body':
        return body;
      case 'eye':
        return eye;
      case 'bg':
        return bg;
      case 'muzzle':
        return muzzle;
      case 'boltLow':
        return boltLow;
      case 'boltFull':
        return boltFull;
      case 'character':
        return character;
      case 'layout':
        return layout;
      case 'faceShape':
        return faceShape;
      case 'eyeShape':
        return eyeShape;
      case 'glanceStyle':
        return glanceStyle;
      case 'clock':
        return clock;
      case 'clock24':
        return clock24;
    }
    final v = toJson()[key];
    return v is num ? v.toDouble() : v;
  }

  /// Switch character the way the web tool does: if the colours are still the
  /// other character's defaults, take this character's; hand-picked colours
  /// are kept.
  AvatarParams switchCharacter(Character c) {
    if (c == character) return this;
    const bloubDefault = AvatarParams();
    final from = character == Character.fox ? AvatarParams.fox : bloubDefault;
    final to = c == Character.fox ? AvatarParams.fox : bloubDefault;
    final untouched = body == from.body && eye == from.eye && bg == from.bg;
    final j = Map<String, Object?>.of(toJson())..['character'] = c.name;
    if (untouched) {
      j['body'] = _hex(to.body);
      j['eye'] = _hex(to.eye);
      j['bg'] = _hex(to.bg);
      j['muzzle'] = _hex(to.muzzle);
    }
    return AvatarParams.fromJson(j, base: this);
  }

  @override
  bool operator ==(Object other) =>
      other is AvatarParams && _mapEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);

  static bool _mapEquals(Map<String, Object> a, Map<String, Object> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }
}
