import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/gemini/usage_meter.dart';

void main() {
  test('the session total counts the helper and the key points, and says so', () {
    final m = UsageMeter();
    m.add(UsageSample(at: DateTime(2026), prompt: {'TEXT': 40000}, response: {'AUDIO': 100}, thoughts: 0, toolUsePrompt: {}));
    expect(m.totalLine, '\$0.0312', reason: 'all voice: just the total');
    m.addExtra('helper', 0.0212);
    m.addExtra('key points', 0.0004);
    expect(m.totalUsd, closeTo(0.0528, 1e-9));
    expect(m.totalLine, '\$0.0528 (voice \$0.0312 · helper \$0.0212 · key points \$0.0004)');
    m.clear();
    expect(m.totalUsd, 0);
  });
}
