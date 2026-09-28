/// What each Gemini Live turn actually cost, from the `usageMetadata` the
/// server sends — Google's own token counts, not an estimate.
///
/// The Live API bills every turn for everything in the session's context (the
/// instructions and every earlier turn), so a long conversation gets dearer
/// with each turn. This makes that visible: one `[COST]` line per turn and a
/// running total for the session.
library;

/// USD per million tokens, by modality. Input and output priced separately.
class LivePrices {
  const LivePrices({
    required this.textIn,
    required this.audioIn,
    required this.imageIn,
    required this.textOut,
    required this.audioOut,
  });

  final double textIn, audioIn, imageIn, textOut, audioOut;

  /// Gemini 3.8 Live and 3.8 Live Extended Thinking (same table).
  static const gemini38Live =
      LivePrices(textIn: 0.75, audioIn: 3.00, imageIn: 1.00, textOut: 4.50, audioOut: 12.00);

  double inputRate(String modality) => switch (modality) {
        'AUDIO' => audioIn,
        'IMAGE' || 'VIDEO' => imageIn,
        _ => textIn,
      };

  double outputRate(String modality) => modality == 'AUDIO' ? audioOut : textOut;
}

/// One turn's usage.
class UsageSample {
  UsageSample({
    required this.at,
    required this.prompt,
    required this.response,
    required this.thoughts,
    required this.toolUsePrompt,
  });

  final DateTime at;

  /// Input tokens by modality (TEXT, AUDIO, IMAGE, VIDEO) — the whole
  /// context this turn was billed for.
  final Map<String, int> prompt;

  /// Output tokens by modality.
  final Map<String, int> response;

  /// Thinking tokens, billed as text output.
  final int thoughts;

  /// Tokens of tool results fed back to the model, where reported separately.
  final Map<String, int> toolUsePrompt;

  int get promptTokens => prompt.values.fold(0, (a, b) => a + b) + toolUsePrompt.values.fold(0, (a, b) => a + b);
  int get responseTokens => response.values.fold(0, (a, b) => a + b) + thoughts;

  double cost(LivePrices p) {
    var usd = 0.0;
    prompt.forEach((m, n) => usd += n * p.inputRate(m) / 1e6);
    toolUsePrompt.forEach((m, n) => usd += n * p.inputRate(m) / 1e6);
    response.forEach((m, n) => usd += n * p.outputRate(m) / 1e6);
    usd += thoughts * p.textOut / 1e6;
    return usd;
  }

  Map<String, Object?> toJson(LivePrices p) => {
        'at': at.toIso8601String(),
        'prompt': prompt,
        'toolUsePrompt': toolUsePrompt,
        'response': response,
        'thoughts': thoughts,
        'usd': double.parse(cost(p).toStringAsFixed(6)),
      };

  /// Reads a `usageMetadata` object, or null when it carries nothing.
  ///
  /// Totals without a per-modality breakdown are booked as TEXT, the
  /// cheapest reading — the log then understates rather than overstates.
  static UsageSample? parse(Map<String, dynamic> u, {DateTime? at}) {
    Map<String, int> details(String key, String totalKey) {
      final out = <String, int>{};
      final list = u[key];
      if (list is List) {
        for (final d in list) {
          if (d is Map) {
            final m = '${d['modality'] ?? 'TEXT'}'.toUpperCase();
            final n = (d['tokenCount'] as num?)?.toInt() ?? 0;
            if (n > 0) out[m] = (out[m] ?? 0) + n;
          }
        }
      }
      final total = (u[totalKey] as num?)?.toInt() ?? 0;
      final listed = out.values.fold(0, (a, b) => a + b);
      if (total > listed) out['TEXT'] = (out['TEXT'] ?? 0) + (total - listed);
      return out;
    }

    final s = UsageSample(
      at: at ?? DateTime.now(),
      prompt: details('promptTokensDetails', 'promptTokenCount'),
      response: details('responseTokensDetails', 'responseTokenCount'),
      toolUsePrompt: details('toolUsePromptTokensDetails', 'toolUsePromptTokenCount'),
      thoughts: (u['thoughtsTokenCount'] as num?)?.toInt() ?? 0,
    );
    return s.promptTokens + s.responseTokens == 0 ? null : s;
  }
}

/// A session's turns and what they came to.
class UsageMeter {
  UsageMeter({this.prices = LivePrices.gemini38Live});

  final LivePrices prices;
  final List<UsageSample> samples = [];

  /// What the conversation cost outside the voice model, by source —
  /// `helper` (do_on_device), `key points` (remembering it) — so the session
  /// total is everything it cost, not just the Live turns.
  final Map<String, double> extras = {};

  double get voiceUsd => samples.fold(0.0, (a, s) => a + s.cost(prices));
  double get totalUsd => voiceUsd + extras.values.fold(0.0, (a, b) => a + b);

  void add(UsageSample s) => samples.add(s);
  void addExtra(String source, double usd) => extras[source] = (extras[source] ?? 0) + usd;
  void clear() {
    samples.clear();
    extras.clear();
  }

  /// `$0.0712 (voice $0.0500 · helper $0.0212)`, or just the total when it
  /// was all voice.
  String get totalLine {
    final t = '\$${totalUsd.toStringAsFixed(4)}';
    if (extras.isEmpty) return t;
    final parts = ['voice \$${voiceUsd.toStringAsFixed(4)}',
      for (final e in extras.entries) '${e.key} \$${e.value.toStringAsFixed(4)}'];
    return '$t (${parts.join(' · ')})';
  }

  /// `turn 12: in 48,210 (TEXT 41,900 · AUDIO 6,310) · out 212 (AUDIO 212) · $0.0540 · session $0.4102`
  String describe(UsageSample s) {
    String mods(Map<String, int> m) => m.entries.map((e) => '${e.key} ${_n(e.value)}').join(' · ');
    return 'turn ${samples.length}: in ${_n(s.promptTokens)} (${mods({...s.prompt, ...s.toolUsePrompt})})'
        ' · out ${_n(s.responseTokens)} (${mods(s.response)}${s.thoughts > 0 ? ' · thinking ${_n(s.thoughts)}' : ''})'
        ' · \$${s.cost(prices).toStringAsFixed(4)} · session $totalLine';
  }

  static String _n(int n) =>
      n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}
