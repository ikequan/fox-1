/// The mascot's states and characters, kept free of imports: both the
/// widgets and `providers.dart` need them, and each imports the other.
library;

enum MascotMood {
  idle,
  listening,
  thinking,
  speaking,
  happy,
  sad,
  confused,
  excited,
  angry,
  sleepy,
  love,
  charging,
  lowBattery,
  fullBattery,
}

/// Which character the wearer sees — everywhere in the launcher, not just on
/// the AI screen. Both are drawn live on a Canvas by `watch_avatar`: every
/// state animated, the whole design tunable, no image assets.
enum Mascot {
  bloub,
  fox;

  /// What a device with nothing chosen shows — the fox, FOX-1's own
  /// character — and where one that had a mascot since removed (OpenClaw's
  /// GIFs) lands.
  static const fallback = Mascot.fox;

  String get label => switch (this) {
    Mascot.bloub => 'Bloub',
    Mascot.fox => 'Fox',
  };

  static Mascot byName(String? name) =>
      values.firstWhere((m) => m.name == name, orElse: () => fallback);
}
