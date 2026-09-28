import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/gemini/usage_meter.dart';

void main() {
  test('Google\'s counts, priced by modality with the 3.8 Live table', () {
    final s = UsageSample.parse({
      'promptTokenCount': 12000,
      'promptTokensDetails': [
        {'modality': 'TEXT', 'tokenCount': 10000},
        {'modality': 'AUDIO', 'tokenCount': 2000},
      ],
      'responseTokenCount': 500,
      'responseTokensDetails': [
        {'modality': 'AUDIO', 'tokenCount': 500},
      ],
    })!;
    expect(s.promptTokens, 12000);
    // 10k text × 0.75 + 2k audio × 3 + 500 audio out × 12, per million.
    expect(s.cost(LivePrices.gemini38Live), closeTo(0.0075 + 0.006 + 0.006, 1e-9));
  });

  test('a total with no breakdown is booked as text — the cheapest reading', () {
    final s = UsageSample.parse({'promptTokenCount': 1000000})!;
    expect(s.prompt, {'TEXT': 1000000});
    expect(s.cost(LivePrices.gemini38Live), closeTo(0.75, 1e-9));
  });

  test('thinking is billed as text output; empty usage is nothing', () {
    final s = UsageSample.parse({'thoughtsTokenCount': 1000000})!;
    expect(s.cost(LivePrices.gemini38Live), closeTo(4.5, 1e-9));
    expect(UsageSample.parse({}), isNull);
  });

  test('the meter keeps a running session total', () {
    final m = UsageMeter();
    m.add(UsageSample.parse({'promptTokenCount': 1000000})!);
    m.add(UsageSample.parse({'promptTokenCount': 1000000})!);
    expect(m.totalUsd, closeTo(1.5, 1e-9));
    expect(m.describe(m.samples.last), contains('session \$1.5000'));
  });
}
