/// Where a call is in its life, independent of who told us.
enum CallPhase {
  idle,

  /// Incoming, not yet answered.
  ringing,

  /// Outgoing, not yet answered.
  dialing,

  /// Answered and running — bridged or handed to the wearer.
  active,
}

/// One observation of the call, and which source produced it.
class CallState {
  const CallState({
    required this.phase,
    this.number = '',
    this.contactName,
    this.startedAt,
    this.source = 'none',
  });

  final CallPhase phase;

  /// As reported. Normalise before using it as a key — see
  /// docs/CALL_AGENT_INTEGRATION.md.
  final String number;

  final String? contactName;

  /// When the call became [CallPhase.active]. Survives a source handover.
  final DateTime? startedAt;

  /// Which source last moved the state. Diagnostic only.
  final String source;

  bool get isActive => phase == CallPhase.active;
  bool get isRingingOrDialing =>
      phase == CallPhase.ringing || phase == CallPhase.dialing;
  bool get isIdle => phase == CallPhase.idle;

  CallState copyWith({
    CallPhase? phase,
    String? number,
    String? contactName,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? source,
  }) =>
      CallState(
        phase: phase ?? this.phase,
        number: number ?? this.number,
        contactName: contactName ?? this.contactName,
        startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
        source: source ?? this.source,
      );

  @override
  String toString() => 'CallState(${phase.name}'
      '${number.isEmpty ? '' : ' $number'} via $source)';
}
