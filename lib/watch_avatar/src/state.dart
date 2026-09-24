/// Every state the avatar can be in.
enum AvatarState {
  idle,
  charging,
  fullBattery,
  lowBattery,
  listening,
  speaking,
  sleeping,
  thinking,
  sad,
  happy,
  love,
  confused,
}

extension AvatarStateInfo on AvatarState {
  /// The name used by the web design tool and in exported settings.
  String get key {
    switch (this) {
      case AvatarState.fullBattery:
        return 'full_battery';
      case AvatarState.lowBattery:
        return 'low_battery';
      default:
        return name;
    }
  }

  /// A short description, handy for debug menus.
  String get label {
    switch (this) {
      case AvatarState.idle:
        return 'awake, nothing asked of it';
      case AvatarState.charging:
        return 'taking on power';
      case AvatarState.fullBattery:
        return 'topped up and pleased';
      case AvatarState.lowBattery:
        return 'nearly out';
      case AvatarState.listening:
        return 'turned toward the voice';
      case AvatarState.speaking:
        return 'saying something';
      case AvatarState.sleeping:
        return 'out cold, still breathing';
      case AvatarState.thinking:
        return 'working on it';
      case AvatarState.sad:
        return 'not having a good time';
      case AvatarState.happy:
        return 'genuinely delighted';
      case AvatarState.love:
        return 'smitten';
      case AvatarState.confused:
        return 'lost the thread';
    }
  }
}
