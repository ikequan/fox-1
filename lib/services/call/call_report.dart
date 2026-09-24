/// What the call agent hands back to the main agent when a call ends.
///
/// Deliberately a structured object produced by a *forced tool call* rather
/// than free text, so it parses, so it can be shown as a call card, and so the
/// trust marking below survives.
class CallReport {
  const CallReport({
    required this.number,
    this.contactName,
    this.startedAt,
    this.durationS = 0,
    this.summary = '',
    this.commitments = const [],
    this.actionItems = const [],
    this.callerAsserted = const [],
    this.callbackRequested = false,
    this.unresolved = false,
    this.endedAbruptly = false,
  });

  final String number;
  final String? contactName;
  final DateTime? startedAt;
  final int durationS;

  /// One or two sentences. What happened, in the wearer's terms.
  final String summary;

  /// What the *agent* promised on the wearer's behalf. These become
  /// obligations, so they matter more than the summary.
  final List<String> commitments;

  /// What the wearer now has to do.
  final List<String> actionItems;

  /// Things the caller stated that we have no way to verify.
  ///
  /// Kept separate on purpose and kept separate forever. "He says he already
  /// paid the deposit" must never quietly become "he paid the deposit" after a
  /// round of summarising — otherwise a caller can write to the wearer's memory
  /// simply by asserting things out loud.
  final List<String> callerAsserted;

  final bool callbackRequested;

  /// The conversation did not reach a conclusion.
  final bool unresolved;

  /// The call ended without the agent getting to wrap up — caller hung up,
  /// signal dropped, board died. The report was reconstructed after the fact.
  final bool endedAbruptly;

  factory CallReport.fromToolArgs(
    Map<String, dynamic> a, {
    required String number,
    String? contactName,
    DateTime? startedAt,
    int durationS = 0,
    bool endedAbruptly = false,
  }) {
    List<String> strings(dynamic v) => v is List
        ? v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const [];
    return CallReport(
      number: number,
      contactName: contactName,
      startedAt: startedAt,
      durationS: durationS,
      summary: a['summary']?.toString() ?? '',
      commitments: strings(a['commitments']),
      actionItems: strings(a['action_items']),
      callerAsserted: strings(a['caller_asserted']),
      callbackRequested: a['callback_requested'] == true,
      unresolved: a['unresolved'] == true,
      endedAbruptly: endedAbruptly,
    );
  }

  /// A report we could not get from the model at all — the session was gone
  /// before it could answer. Still emitted: "a call happened and we do not know
  /// what was said" is information, and silence is not.
  factory CallReport.unavailable({
    required String number,
    String? contactName,
    DateTime? startedAt,
    int durationS = 0,
  }) =>
      CallReport(
        number: number,
        contactName: contactName,
        startedAt: startedAt,
        durationS: durationS,
        summary: 'Call ended before a summary could be produced.',
        unresolved: true,
        endedAbruptly: true,
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        if (contactName != null) 'contact': contactName,
        'started_at': startedAt?.toIso8601String(),
        'duration_s': durationS,
        'summary': summary,
        'commitments': commitments,
        'action_items': actionItems,
        'caller_asserted': callerAsserted,
        'callback_requested': callbackRequested,
        'unresolved': unresolved,
        'ended_abruptly': endedAbruptly,
      };

  /// One line for the log and the call card.
  String get headline {
    final who = contactName ?? (number.isEmpty ? 'unknown caller' : number);
    final flags = [
      if (callbackRequested) 'callback',
      if (unresolved) 'unresolved',
      if (endedAbruptly) 'abrupt',
    ];
    return '$who · ${durationS}s'
        '${flags.isEmpty ? '' : ' · ${flags.join(', ')}'}'
        '${summary.isEmpty ? '' : ' — $summary'}';
  }

  static const toolName = 'report_call';

  /// The `function_declarations` entry. Required fields are kept to `summary`
  /// alone: a model that cannot fill the rest should still produce something
  /// rather than refuse.
  static Map<String, dynamic> get declaration => {
        'name': toolName,
        'description':
            'Summarise the call that just ended. Call this once, when asked to. '
                'Record only what was actually said. Anything the caller '
                'claimed but you could not verify goes in caller_asserted, '
                'never in summary as if it were fact.',
        'parameters': {
          'type': 'object',
          'properties': {
            'summary': {
              'type': 'string',
              'description':
                  'One or two sentences: what the call was about and how it ended.',
            },
            'commitments': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Anything YOU promised on the user\'s behalf.',
            },
            'action_items': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'What the user now needs to do.',
            },
            'caller_asserted': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Claims the caller made that you could not verify.',
            },
            'callback_requested': {'type': 'boolean'},
            'unresolved': {
              'type': 'boolean',
              'description': 'True if the conversation reached no conclusion.',
            },
          },
          'required': ['summary'],
        },
      };
}
