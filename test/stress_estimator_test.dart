import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_protocol.dart';
import 'package:fox1/services/ring/sleep_analysis.dart';
import 'package:fox1/services/ring/stress_estimator.dart';

/// A synthetic week: asleep 00:00–06:00 at 55 bpm, awake and still around
/// 65 bpm (±3, the way a real pulse wanders), and a brisk 30-minute walk at
/// noon at 110 bpm.
class Week {
  final heart = <RingHealthRecord>[];
  final steps = <RingStepRecord>[];
  final sleep = <SleepSample>[];

  static DateTime day(int i) => DateTime(2026, 9, 1 + i);
  static const _wander = [-3, -1, 0, 2, 1, -2, 3, -1, 0, 1];

  /// [fill] replaces every other awake reading with the ring's fill value.
  void addDay(int i,
      {int awakeBpm = 65, bool walk = true, int hours = 24, int? fill}) {
    final d = day(i);
    for (var m = 0; m < hours * 60; m += 5) {
      final t = d.add(Duration(minutes: m));
      final int bpm;
      if (m <= 360) {
        bpm = 55;
      } else if (walk && m >= 720 && m < 750) {
        bpm = 110;
      } else if (fill != null && m % 10 == 0) {
        bpm = fill;
      } else {
        bpm = awakeBpm + _wander[(m ~/ 5) % 10];
      }
      heart.add(RingHealthRecord(t, bpm, 98, 36.5));
    }
    for (var m = 0; m <= 360; m += 5) {
      sleep.add(SleepSample(d.add(Duration(minutes: m)), m % 20 == 0 ? 4 : 3));
    }
    if (walk) {
      steps
        ..add(RingStepRecord(d.add(const Duration(hours: 12)), 60, 100, 4, 80))
        ..add(RingStepRecord(
            d.add(const Duration(hours: 12, minutes: 30)), 1800, 1600, 60, 1200))
        ..add(RingStepRecord(d.add(const Duration(hours: 20)), 60, 1650, 62, 1240));
    } else {
      steps.add(RingStepRecord(d.add(const Duration(hours: 20)), 60, 40, 2, 30));
    }
  }

  List<StressDay> run({List<TimeWindow> exclude = const []}) =>
      estimateStress(heart: heart, steps: steps, sleep: sleep, exclude: exclude);
}

void main() {
  test('bands follow Garmin: 0–25 rest, 26–50 low, 51–75 medium, 76+ high', () {
    expect(stressBand(25), StressBand.rest);
    expect(stressBand(26), StressBand.low);
    expect(stressBand(50), StressBand.low);
    expect(stressBand(51), StressBand.medium);
    expect(stressBand(75), StressBand.medium);
    expect(stressBand(76), StressBand.high);
  });

  test('an ordinary day scores near the wearer\'s usual (25)', () {
    final w = Week();
    for (var i = 0; i < 7; i++) {
      w.addDay(i);
    }
    final last = w.run().last;
    expect(last.score, isNotNull);
    expect(last.score!, inInclusiveRange(15, 35));
    expect(last.provisional, isFalse);
  });

  test('a raised resting heart rate raises the score by bands, not points', () {
    final w = Week();
    for (var i = 0; i < 6; i++) {
      w.addDay(i);
    }
    w.addDay(6, awakeBpm: 75);
    final days = w.run();
    final normal = days[5].score!, raised = days[6].score!;
    expect(raised - normal, greaterThan(30));
    expect(days[6].band, anyOf(StressBand.medium, StressBand.high));
    expect(days[6].highSamples, greaterThan(0));
  });

  test('the walk is not stress: exercise heart rate never gets scored', () {
    final walking = Week(), resting = Week();
    for (var i = 0; i < 7; i++) {
      walking.addDay(i);
      resting.addDay(i, walk: false);
    }
    final a = walking.run().last, b = resting.run().last;
    expect(a.stillSamples, lessThan(b.stillSamples));
    expect((a.score! - b.score!).abs(), lessThanOrEqualTo(5));
  });

  test('scores are provisional until five earlier days exist', () {
    final w = Week();
    for (var i = 0; i < 7; i++) {
      w.addDay(i);
    }
    final days = w.run();
    expect(days.first.provisional, isTrue);
    expect(days.first.notes.join(), contains('against itself'));
    expect(days[5].provisional, isFalse);
  });

  test('too little still, awake time is not scored', () {
    final w = Week();
    w.addDay(0, hours: 8); // up at 06:00, ring off at 08:00
    final d = w.run().single;
    expect(d.score, isNull);
    expect(d.notes.join(), contains('still and awake'));
  });

  test('time the device knows about — a conversation — is left out', () {
    final w = Week();
    for (var i = 0; i < 7; i++) {
      w.addDay(i);
    }
    final all = w.run().last.stillSamples;
    final d = Week.day(6);
    final fewer = w.run(exclude: [
      (from: d.add(const Duration(hours: 9)), to: d.add(const Duration(hours: 10))),
    ]).last.stillSamples;
    expect(all - fewer, 12);
  });

  group('cleaning the ring\'s heart-rate history', () {
    test('a value that fills a third of the readings is "no reading"', () {
      final t0 = DateTime(2026, 9, 10);
      final recs = [
        for (var i = 0; i < 20; i++)
          RingHealthRecord(t0.add(Duration(minutes: 5 * i)),
              i.isEven ? 75 : 60 + i % 5, 98, 31.0),
      ];
      final c = cleanHeartRate(recs);
      expect(c.quality.fillValue, 75);
      expect(c.quality.filled, 10);
      expect(c.kept.any((r) => r.hr == 75), isFalse);
    });

    test('an isolated spike is dropped; a real rise is kept', () {
      final t0 = DateTime(2026, 9, 10);
      RingHealthRecord at(int i, int bpm) =>
          RingHealthRecord(t0.add(Duration(minutes: 5 * i)), bpm, 98, 31.0);
      final spike = cleanHeartRate(
          [at(0, 60), at(1, 62), at(2, 111), at(3, 61), at(4, 63), at(5, 60)]);
      expect(spike.quality.spikes, 1);
      expect(spike.kept.map((r) => r.hr), isNot(contains(111)));
      final rise = cleanHeartRate(
          [at(0, 62), at(1, 63), at(2, 104), at(3, 108), at(4, 110), at(5, 109)]);
      expect(rise.quality.spikes, 0);
    });

    test('fill readings do not move the stress score', () {
      final clean = Week(), filled = Week();
      for (var i = 0; i < 7; i++) {
        clean.addDay(i);
        filled.addDay(i, fill: 75);
      }
      final a = clean.run().last, b = filled.run().last;
      expect((a.score! - b.score!).abs(), lessThanOrEqualTo(10));
      expect(b.sleepingHr, 55);
    });
  });

  test('overnight load comes from the night that ended that morning', () {
    final w = Week();
    for (var i = 0; i < 7; i++) {
      w.addDay(i);
    }
    final last = w.run().last;
    expect(last.night, isNotNull);
    expect(last.sleepingHr, 55);
    expect(last.overnight, isNotNull);
  });
}
