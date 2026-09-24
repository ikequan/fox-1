import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/sleep_analysis.dart';

List<SleepSample> samples(DateTime start, List<int> qualities) => [
      for (var i = 0; i < qualities.length; i++)
        SleepSample(start.add(Duration(minutes: 5 * i)), qualities[i]),
    ];

void main() {
  test('reproduces the LoraFit screenshot: 6h20, deep 110, light 205, REM 65', () {
    final q = [
      0, 0, 0,
      ...List.filled(20, 3),
      ...List.filled(22, 4),
      1, // one awake sample inside the night
      ...List.filled(21, 3),
      ...List.filled(13, 2),
      0, 0,
    ];
    final n = summarizeNight(samples(DateTime(2026, 9, 10), q))!;
    expect(n.deepMinutes, 110);
    expect(n.lightMinutes, 205);
    expect(n.remMinutes, 65);
    expect(n.awakeMinutes, 5);
    expect(n.asleepMinutes, 380);
    // First asleep sample is 00:15; LoraFit shows it one sample earlier.
    expect(n.fellAsleep, DateTime(2026, 9, 10, 0, 10));
    expect(n.woke, DateTime(2026, 9, 10, 6, 35));
    expect(n.score, 100);
    expect(n.label, 'perfect');
  });

  test('quality 1 is awake and does not add to sleep time', () {
    final n = summarizeNight(samples(DateTime(2026, 9, 10), [3, 1, 1, 3]))!;
    expect(n.asleepMinutes, 10);
    expect(n.awakeMinutes, 10);
    expect(n.awakeBouts, 1);
  });

  test('awake before and after the night is trimmed away', () {
    final n = summarizeNight(samples(DateTime(2026, 9, 10), [0, 1, 4, 0, 0]))!;
    expect(n.asleepMinutes, 5);
    expect(n.awakeMinutes, 0);
  });

  test('no asleep sample is no night', () {
    expect(summarizeNight(samples(DateTime(2026, 9, 10), [0, 1, 0])), isNull);
  });

  group('score, as the vendor app weights it', () {
    test('4.5 h of nothing but light sleep is poor', () {
      // duration 60 × .35 + deep 0 + light(100 %) 30 × .2 + REM 0 = 27
      expect(sleepScore(asleep: 270, deep: 0, light: 270, rem: 0, awake: 0), 27);
      expect(sleepScoreLabel(27), 'severe insomnia');
    });

    test('5.5 h with thin deep sleep is average', () {
      // 80×.35 + 60×.3 + 80×.2 + 100×.15 = 28 + 18 + 16 + 15 = 77
      expect(sleepScore(asleep: 330, deep: 30, light: 240, rem: 60, awake: 30), 77);
      expect(sleepScoreLabel(77), 'average');
    });

    test('nothing asleep scores zero', () {
      expect(sleepScore(asleep: 0, deep: 0, light: 0, rem: 0, awake: 60), 0);
    });
  });

  test('the night of a day is 18:00 the evening before to noon, naps apart', () {
    final all = [
      // Before the window opens: an afternoon doze the day before.
      SleepSample(DateTime(2026, 9, 9, 17, 0), 3),
      ...samples(DateTime(2026, 9, 9, 22, 0), List.filled(97, 3)),
      // Replies for neighbouring days overlap; the same sample twice.
      SleepSample(DateTime(2026, 9, 9, 22, 0), 3),
      // A nap after noon.
      ...samples(DateTime(2026, 9, 10, 13, 0), List.filled(6, 3)),
    ];
    final n = nightEnding(DateTime(2026, 9, 10), all)!;
    expect(n.fellAsleep, DateTime(2026, 9, 9, 21, 55));
    expect(n.woke, DateTime(2026, 9, 10, 6, 0));
    expect(n.asleepMinutes, 485);
  });
}
