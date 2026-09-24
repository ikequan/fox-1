import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/health_store.dart';
import 'package:fox1/services/ring/ring_protocol.dart';
import 'package:fox1/services/ring/sleep_analysis.dart';

RingHealthRecord hr(DateTime t, int bpm, [int spo2 = 98]) =>
    RingHealthRecord(t, bpm, spo2, 31.0);

RingStepRecord st(DateTime t, int total) =>
    RingStepRecord(t, 60, total, total ~/ 35, (total * 0.77).round());

/// Light sleep every five minutes from [from] to [to] inclusive.
List<SleepSample> night(DateTime from, DateTime to) => [
      for (var t = from; !t.isAfter(to); t = t.add(const Duration(minutes: 5)))
        SleepSample(t, 3),
    ];

void main() {
  late Directory tmp;
  late HealthStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('health');
    store = HealthStore(directory: () async => tmp);
  });
  tearDown(() => tmp.delete(recursive: true));

  // 2026-09-07 is a Monday.
  final mon = DateTime(2026, 9, 7), tue = DateTime(2026, 9, 8), wed = DateTime(2026, 9, 9);

  test('a re-sync overwrites instead of duplicating', () async {
    final recs = [for (var m = 0; m < 60; m += 5) hr(tue.add(Duration(minutes: m)), 60 + m ~/ 5)];
    await store.add(heart: recs);
    await store.add(heart: recs);
    expect((await store.raw(tue)).hr.length, 12);
  });

  test('steps are the running total at the last record; a week adds days up', () async {
    await store.add(steps: [
      st(tue.add(const Duration(hours: 8)), 100),
      st(tue.add(const Duration(hours: 12)), 500),
      st(tue.add(const Duration(hours: 18)), 1200),
      st(wed.add(const Duration(hours: 9)), 800),
    ]);
    expect((await store.summary(tue))!.steps, 1200);
    final week = await store.report(ReportPeriod.week, wed);
    expect(week.total.steps, 2000);
    expect(week.total.stepsPerDay, 1000);
    expect(week.buckets, hasLength(7));
    expect(week.buckets.first.from, mon);
  });

  test('the night that ended this morning spans two day files', () async {
    await store.add(sleep: night(tue.add(const Duration(hours: 23)), wed.add(const Duration(hours: 6))));
    final n = (await store.summary(wed))!.night!;
    expect(n.asleep, 85 * 5);
    expect(n.fellAsleep, tue.add(const Duration(hours: 22, minutes: 55)));
    expect(n.woke, wed.add(const Duration(hours: 6)));
  });

  test('a period averages the nights that had sleep, not the days', () async {
    await store.add(
      steps: [st(mon.add(const Duration(hours: 12)), 3000)],
      sleep: [
        ...night(tue.add(const Duration(hours: 23)), wed.add(const Duration(hours: 6))), // 425
        ...night(wed.add(const Duration(hours: 23, minutes: 30)),
            DateTime(2026, 9, 10, 5, 30)), // 365
      ],
    );
    final week = await store.report(ReportPeriod.week, wed);
    expect(week.total.nights, 2);
    expect(week.total.sleepMinutes, 395);
  });

  test('the heart-rate summary drops the ring\'s fill value', () async {
    await store.add(heart: [
      for (var i = 0; i < 20; i++)
        hr(tue.add(Duration(minutes: 5 * i)), i.isEven ? 75 : 60 + i % 5),
    ]);
    final s = (await store.summary(tue))!.hr!;
    expect(s.n, 10);
    expect(s.max, lessThan(75));
  });

  test('a year is twelve monthly buckets; a month is its days', () async {
    await store.add(steps: [st(tue.add(const Duration(hours: 12)), 4000)]);
    final year = await store.report(ReportPeriod.year, tue);
    expect(year.buckets, hasLength(12));
    expect(year.buckets[8].steps, 4000);
    expect(year.buckets[7].steps, isNull);
    final month = await store.report(ReportPeriod.month, tue);
    expect(month.buckets, hasLength(30));
  });

  test('summaries survive a restart', () async {
    await store.add(steps: [st(tue.add(const Duration(hours: 12)), 4000)]);
    final again = HealthStore(directory: () async => tmp);
    expect((await again.summary(tue))!.steps, 4000);
  });

  test('a corrupt day file is started over, not fatal', () async {
    await Directory('${tmp.path}/days').create(recursive: true);
    await File('${tmp.path}/days/${dayKey(tue)}.json').writeAsString('{not json');
    await store.add(steps: [st(tue.add(const Duration(hours: 12)), 10)]);
    expect((await store.summary(tue))!.steps, 10);
  });
}
