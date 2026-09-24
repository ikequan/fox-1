import 'package:flutter/painting.dart';

import 'params.dart';

enum ParamKind { color, choice, number, toggle }

/// One tunable setting, described so a settings page can be built from it.
class ParamSpec {
  const ParamSpec({
    required this.key,
    required this.label,
    required this.group,
    required this.kind,
    required this.help,
    this.min = 0,
    this.max = 1,
    this.step = 1,
    this.unit = '',
    this.choices = const <ParamChoice>[],
    this.bloub = true,
    this.fox = true,
  });

  /// The key for [AvatarParams.valueOf] / [AvatarParams.withValue], and in JSON.
  final String key;
  final String label;

  /// 'Character', 'Colour', 'Shape', 'Eyes', 'Motion' or 'Clock'.
  final String group;
  final ParamKind kind;

  /// What changing it does, in plain words.
  final String help;

  /// For numbers: the slider range, step and unit.
  final double min, max, step;
  final String unit;

  /// For choices: the values and their labels.
  final List<ParamChoice> choices;

  /// Which characters it affects.
  final bool bloub, fox;

  bool appliesTo(Character c) => c == Character.fox ? fox : bloub;
}

class ParamChoice {
  const ParamChoice(this.value, this.label);
  final Enum value;
  final String label;
}

/// Every setting, in the order a settings page should show them.
const List<ParamSpec> kParamSpecs = <ParamSpec>[
  // ------------------------------------------------------------ character
  ParamSpec(
    key: 'character',
    label: 'Character',
    group: 'Character',
    kind: ParamKind.choice,
    choices: <ParamChoice>[
      ParamChoice(Character.bloub, 'Bloub'),
      ParamChoice(Character.fox, 'Fox'),
    ],
    help: 'Which character is on the device. Use AvatarParams.switchCharacter() '
        'to change it: it also swaps to the character\'s own colours, unless the '
        'user has picked colours of their own.',
  ),
  ParamSpec(
    key: 'layout',
    label: 'Layout',
    group: 'Character',
    kind: ParamKind.choice,
    choices: <ParamChoice>[
      ParamChoice(Layout.screen, 'Screen is the face'),
      ParamChoice(Layout.figure, 'Face on a background'),
    ],
    help: 'Bloub: the whole screen is its face, or its face sits on the '
        'background colour. Fox: "screen" frames it more tightly.',
  ),

  // ------------------------------------------------------------ colour
  ParamSpec(
    key: 'body',
    label: 'Face',
    group: 'Colour',
    kind: ParamKind.color,
    help: 'Bloub\'s face; the fox\'s fur.',
  ),
  ParamSpec(
    key: 'eye',
    label: 'Eyes',
    group: 'Colour',
    kind: ParamKind.color,
    help: 'Eyes, mouth, nose, tear and the time.',
  ),
  ParamSpec(
    key: 'bg',
    label: 'Background',
    group: 'Colour',
    kind: ParamKind.color,
    help: 'Behind the character. Bloub shows it only in the "Face on a '
        'background" layout; the fox always does.',
  ),
  ParamSpec(
    key: 'muzzle',
    label: 'Cheeks and belly',
    group: 'Colour',
    kind: ParamKind.color,
    bloub: false,
    help: 'The fox\'s cream cheeks, belly and inner ears.',
  ),
  ParamSpec(
    key: 'boltLow',
    label: 'Charging bolt',
    group: 'Colour',
    kind: ParamKind.color,
    help: 'The bolt in the battery-cell eyes while charging or low.',
  ),
  ParamSpec(
    key: 'boltFull',
    label: 'Full bolt',
    group: 'Colour',
    kind: ParamKind.color,
    help: 'The bolt in the battery-cell eyes when fully charged.',
  ),

  // ------------------------------------------------------------ shape
  ParamSpec(
    key: 'faceShape',
    label: 'Face shape',
    group: 'Shape',
    kind: ParamKind.choice,
    fox: false,
    choices: <ParamChoice>[
      ParamChoice(FaceShape.circle, 'Circle'),
      ParamChoice(FaceShape.squircle, 'Rounded square'),
    ],
    help: 'Bloub\'s outline, seen in the "Face on a background" layout.',
  ),
  ParamSpec(
    key: 'radius',
    label: 'Face size',
    group: 'Shape',
    kind: ParamKind.number,
    min: 50,
    max: 118,
    step: 1,
    help: 'The character\'s size in design units. The picture is always scaled '
        'to fit the screen, so this mostly changes how much room the padding '
        'and the eyes take relative to the face.',
  ),
  ParamSpec(
    key: 'pad',
    label: 'Padding',
    group: 'Shape',
    kind: ParamKind.number,
    min: 0,
    max: 60,
    step: 1,
    unit: 'px',
    help: 'Space around the character. Lower = bigger on screen.',
  ),
  ParamSpec(
    key: 'corner',
    label: 'Corner sharpness',
    group: 'Shape',
    kind: ParamKind.number,
    fox: false,
    min: 2.2,
    max: 9,
    step: 0.1,
    help: 'For the rounded-square face: higher = squarer corners.',
  ),
  ParamSpec(
    key: 'wobble',
    label: 'Edge wobble',
    group: 'Shape',
    kind: ParamKind.number,
    fox: false,
    min: 0,
    max: 6,
    step: 0.1,
    help: 'A hand-drawn wobble in bloub\'s outline. 0 = perfectly smooth.',
  ),

  // ------------------------------------------------------------ eyes
  ParamSpec(
    key: 'eyeShape',
    label: 'Eye shape',
    group: 'Eyes',
    kind: ParamKind.choice,
    choices: <ParamChoice>[
      ParamChoice(EyeShape.pill, 'Pill'),
      ParamChoice(EyeShape.round, 'Round'),
      ParamChoice(EyeShape.square, 'Rounded square'),
    ],
    help: 'The resting eye shape. Round and rounded square use the average of '
        'width and height, so they come out even.',
  ),
  ParamSpec(
    key: 'eyeW',
    label: 'Eye width',
    group: 'Eyes',
    kind: ParamKind.number,
    min: 8,
    max: 46,
    step: 1,
    help: 'Eye width. The fox draws its eyes at 62% of this.',
  ),
  ParamSpec(
    key: 'eyeH',
    label: 'Eye height',
    group: 'Eyes',
    kind: ParamKind.number,
    min: 8,
    max: 64,
    step: 1,
    help: 'Eye height. The fox draws its eyes at 62% of this.',
  ),
  ParamSpec(
    key: 'eyeAz',
    label: 'Eye spread',
    group: 'Eyes',
    kind: ParamKind.number,
    min: 8,
    max: 42,
    step: 1,
    unit: '°',
    help: 'How far apart the eyes sit, as an angle around the head.',
  ),
  ParamSpec(
    key: 'eyeEl',
    label: 'Eye height on face',
    group: 'Eyes',
    kind: ParamKind.number,
    min: -20,
    max: 32,
    step: 1,
    unit: '°',
    help: 'Where the eyes rest vertically. With "Eye height jump" on, they '
        'roam around this point.',
  ),

  // ------------------------------------------------------------ motion
  ParamSpec(
    key: 'speed',
    label: 'Speed',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0.2,
    max: 3,
    step: 0.05,
    unit: '×',
    help: 'Speed of all motion. 1 = as designed.',
  ),
  ParamSpec(
    key: 'yaw',
    label: 'Turn',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 55,
    step: 1,
    unit: '°',
    help: 'How far the head turns left and right.',
  ),
  ParamSpec(
    key: 'pitch',
    label: 'Nod',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 45,
    step: 1,
    unit: '°',
    help: 'How far the head tips up and down.',
  ),
  ParamSpec(
    key: 'roll',
    label: 'Tilt',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 30,
    step: 1,
    unit: '°',
    help: 'How far the head tilts sideways.',
  ),
  ParamSpec(
    key: 'drift',
    label: 'Drift',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 26,
    step: 1,
    unit: 'px',
    help: 'How much the whole character floats and bobs.',
  ),
  ParamSpec(
    key: 'blink',
    label: 'Blink depth',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 1,
    step: 0.05,
    help: '0 = never blinks, 1 = full blinks.',
  ),
  ParamSpec(
    key: 'wander',
    label: 'Wander',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 1,
    step: 0.05,
    help: 'Random glances around, on top of each state\'s own motion. '
        '0 = none. They never repeat.',
  ),
  ParamSpec(
    key: 'glance',
    label: 'Glance every',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0.5,
    max: 4,
    step: 0.1,
    unit: 's',
    help: 'Seconds between random glances.',
  ),
  ParamSpec(
    key: 'eyeJump',
    label: 'Eye height jump',
    group: 'Motion',
    kind: ParamKind.number,
    min: 0,
    max: 100,
    step: 5,
    unit: '%',
    help: 'How far the eyes jump up and down with each glance, as a share of '
        'their full range. 0 = eyes stay at their resting height.',
  ),
  ParamSpec(
    key: 'glanceStyle',
    label: 'Glance style',
    group: 'Motion',
    kind: ParamKind.choice,
    choices: <ParamChoice>[
      ParamChoice(GlanceStyle.smooth, 'Smooth'),
      ParamChoice(GlanceStyle.sharp, 'Sharp'),
    ],
    help: 'Smooth: eased glances. Sharp: the head holds, then snaps to the next '
        'look, like a small robot.',
  ),

  // ------------------------------------------------------------ clock
  ParamSpec(
    key: 'clock',
    label: 'Show the time',
    group: 'Clock',
    kind: ParamKind.toggle,
    help: 'The time on the character: under bloub\'s eyes, on the fox\'s belly.',
  ),
  ParamSpec(
    key: 'clock24',
    label: '24-hour time',
    group: 'Clock',
    kind: ParamKind.toggle,
    help: 'Off: 12-hour time with AM/PM.',
  ),
];

/// The group names, in display order.
const List<String> kParamGroups = <String>['Character', 'Colour', 'Shape', 'Eyes', 'Motion', 'Clock'];

ParamSpec? paramSpec(String key) {
  for (final s in kParamSpecs) {
    if (s.key == key) return s;
  }
  return null;
}

/// A named colour scheme, as in the web tool's presets.
class AvatarPalette {
  const AvatarPalette(this.name, this.bg, this.body, this.eye, this.muzzle);
  final String name;
  final Color bg, body, eye, muzzle;

  AvatarParams applyTo(AvatarParams p) => p
      .withValue('bg', bg)
      .withValue('body', body)
      .withValue('eye', eye)
      .withValue('muzzle', muzzle);
}

/// The web tool's palettes.
const List<AvatarPalette> kPalettes = <AvatarPalette>[
  AvatarPalette('Paper on ink', Color(0xFF0A0A0C), Color(0xFFF2F2EC), Color(0xFF0A0A0C),
      Color(0xFFFFFFFF)),
  AvatarPalette('Ink on paper', Color(0xFFF7F7F4), Color(0xFF0A0A0C), Color(0xFFF7F7F4),
      Color(0xFF3A3A40)),
  AvatarPalette('Fox', Color(0xFF0B0B0C), Color(0xFFE8823C), Color(0xFF141010),
      Color(0xFFFBE7D2)),
  AvatarPalette('Amber', Color(0xFF120D06), Color(0xFFFFB457), Color(0xFF120D06),
      Color(0xFFFFF0DA)),
  AvatarPalette('Signal', Color(0xFF07100D), Color(0xFF5FF2C0), Color(0xFF07100D),
      Color(0xFFDCFFF2)),
  AvatarPalette('Ash', Color(0xFF1D1E22), Color(0xFF8E9099), Color(0xFF1D1E22),
      Color(0xFFD2D3D8)),
];

/// Colours offered for a single colour setting. On a device, picking from a
/// short list works far better than a free colour wheel.
const List<Color> kSwatches = <Color>[
  Color(0xFF0A0A0C), Color(0xFF1D1E22), Color(0xFF3A3A40), Color(0xFF8E9099),
  Color(0xFFF2F2EC), Color(0xFFFFFFFF), Color(0xFFE8823C), Color(0xFFFFB457),
  Color(0xFFFBE7D2), Color(0xFF5FF2C0), Color(0xFF4DA3FF), Color(0xFFB18CFF),
  Color(0xFFFF6B8B), Color(0xFFFF453A), Color(0xFF32D74B), Color(0xFF141010),
];
