import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ring_ble.dart';
import 'ring_protocol.dart';
import 'sleep_analysis.dart';
import 'stress_estimator.dart';

/// The device's own copy of the ring's health data.
///
/// The ring keeps about seven days (LoraFit syncs day offsets 0–6), so week,
/// month and year reports only exist if the device keeps the history itself.
///
/// One JSON file per calendar day — the same approach as MemoryStore and
/// CallHistory, and no database dependency. Records are keyed by minute of
/// the day, so a re-sync overwrites instead of duplicating. Per-day summaries
/// are cached in `summaries.json` and recomputed only for the days a sync
/// touched. Aggregation follows LoraFit (SMART_RING_PROTOCOL.md §12):
///
///  * steps — the day's running total at its last record; periods add days up
///    and average over the days that had steps;
///  * heart rate / SpO₂ — daily average, min, max; a period's average is the
///    mean of its daily averages;
///  * sleep — the night that ended that morning; a period averages the nights
///    that had sleep, so an unworn night does not drag it down;
///  * stress — our own estimate (stress_estimator.dart), averaged.
class HealthStore {
  HealthStore({Future<Directory?> Function()? directory})
      : _directory = directory ?? RingBle.healthDir;

  final Future<Directory?> Function() _directory;
  Directory? _root;
  Map<String, DaySummary>? _summaries;

  /// How far back stress looks for its baseline.
  static const stressWindow = 28;

  Future<Directory?> _dir() async => _root ??= await _directory();

  Future<File?> _dayFile(DateTime day) async {
    final root = await _dir();
    return root == null ? null : File('${root.path}/days/${dayKey(day)}.json');
  }

  Future<DayData> raw(DateTime day) async {
    final d = dayOf(day);
    final f = await _dayFile(d);
    if (f == null || !await f.exists()) return DayData(d);
    try {
      return DayData.fromJson(
          d, Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map));
    } catch (e) {
      // A corrupt day must not take the whole history with it.
      debugPrint('[HEALTH] ${dayKey(d)} unreadable, starting it over: $e');
      return DayData(d);
    }
  }

  Future<void> _write(File f, String text) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  /// Merges a sync's records. Returns the days whose data changed.
  Future<Set<DateTime>> add({
    List<RingHealthRecord> heart = const [],
    List<RingStepRecord> steps = const [],
    List<SleepSample> sleep = const [],
  }) async {
    final days = <DateTime, DayData>{};
    Future<DayData> day(DateTime t) async => days[dayOf(t)] ??= await raw(t);

    for (final r in heart) {
      if (r.hr <= 0 && r.spo2 <= 0) continue;
      (await day(r.t)).hr[minuteOf(r.t)] = [r.hr, r.spo2, (r.temp * 10).round()];
    }
    for (final r in steps) {
      (await day(r.t)).steps[minuteOf(r.t)] =
          [r.steps, r.calories, r.distance, r.duration];
    }
    for (final s in sleep) {
      (await day(s.t)).sleep[minuteOf(s.t)] = [s.quality, s.move];
    }
    for (final d in days.values) {
      final f = await _dayFile(d.day);
      if (f != null) await _write(f, jsonEncode(d.toJson()));
    }
    if (days.isNotEmpty) await _refresh(days.keys.toSet());
    return days.keys.toSet();
  }

  /// Recomputes summaries for [touched] and the day after each — the night
  /// of D+1 starts on the evening of D.
  Future<void> _refresh(Set<DateTime> touched) async {
    final targets = {
      for (final d in touched) ...[d, nextDay(d)],
    }.toList()
      ..sort();
    final from = DateTime(targets.first.year, targets.first.month,
        targets.first.day - stressWindow);
    final loaded = <DateTime, DayData>{};
    for (var d = from; !d.isAfter(targets.last); d = nextDay(d)) {
      loaded[d] = await raw(d);
    }
    final stress = {
      for (final s in estimateStress(
        heart: [for (final d in loaded.values) ...d.heartRecords],
        steps: [for (final d in loaded.values) ...d.stepRecords],
        sleep: [for (final d in loaded.values) ...d.sleepSamples],
      ))
        s.day: s,
    };

    final all = await _all();
    for (final d in targets) {
      final today = loaded[d] ?? DayData(d);
      final before = loaded[prevDay(d)] ?? DayData(prevDay(d));
      final s = DaySummary.build(
        day: d,
        today: today,
        night: nightEnding(d, [...before.sleepSamples, ...today.sleepSamples]),
        stress: stress[d],
      );
      if (s.isEmpty) {
        all.remove(dayKey(d));
      } else {
        all[dayKey(d)] = s;
      }
    }
    final root = await _dir();
    if (root != null) {
      await _write(File('${root.path}/summaries.json'),
          jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}));
    }
  }

  Future<Map<String, DaySummary>> _all() async {
    if (_summaries != null) return _summaries!;
    final root = await _dir();
    final f = root == null ? null : File('${root.path}/summaries.json');
    final out = <String, DaySummary>{};
    if (f != null && await f.exists()) {
      try {
        final j = Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
        for (final e in j.entries) {
          out[e.key] = DaySummary.fromJson(Map<String, dynamic>.from(e.value as Map));
        }
      } catch (e) {
        debugPrint('[HEALTH] summaries unreadable — they rebuild on the next sync: $e');
      }
    }
    return _summaries = out;
  }

  Future<DaySummary?> summary(DateTime day) async => (await _all())[dayKey(dayOf(day))];

  /// Summaries from [from] to [to], both inclusive, oldest first.
  Future<List<DaySummary>> between(DateTime from, DateTime to) async {
    final all = await _all();
    return [
      for (var d = dayOf(from); !d.isAfter(dayOf(to)); d = nextDay(d))
        if (all[dayKey(d)] != null) all[dayKey(d)]!,
    ];
  }

  /// Day, ISO week (Monday–Sunday), calendar month, or calendar year in
  /// twelve monthly buckets.
  Future<HealthReport> report(ReportPeriod period, DateTime anchor) async {
    final a = dayOf(anchor);
    switch (period) {
      case ReportPeriod.day:
        return HealthReport(period,
            Aggregate.of(dayKey(a), a, a, await between(a, a)), const []);
      case ReportPeriod.week:
        final from = DateTime(a.year, a.month, a.day - (a.weekday - 1));
        return _byDay(period, from, DateTime(from.year, from.month, from.day + 6));
      case ReportPeriod.month:
        return _byDay(period, DateTime(a.year, a.month, 1), DateTime(a.year, a.month + 1, 0));
      case ReportPeriod.year:
        final days = await between(DateTime(a.year, 1, 1), DateTime(a.year, 12, 31));
        final buckets = [
          for (var m = 1; m <= 12; m++)
            Aggregate.of(
              '${a.year}-${two(m)}',
              DateTime(a.year, m, 1),
              DateTime(a.year, m + 1, 0),
              days.where((d) => d.day.month == m),
            ),
        ];
        return HealthReport(period,
            Aggregate.of('${a.year}', DateTime(a.year, 1, 1), DateTime(a.year, 12, 31), days),
            buckets);
    }
  }

  Future<HealthReport> _byDay(ReportPeriod p, DateTime from, DateTime to) async {
    final days = await between(from, to);
    final byKey = {for (final d in days) dayKey(d.day): d};
    return HealthReport(p, Aggregate.of('${dayKey(from)} … ${dayKey(to)}', from, to, days), [
      for (var d = from; !d.isAfter(to); d = nextDay(d))
        Aggregate.of(dayKey(d), d, d, [if (byKey[dayKey(d)] != null) byKey[dayKey(d)]!]),
    ]);
  }
}

// ------------------------------------------------------------------ dates

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);
DateTime prevDay(DateTime d) => DateTime(d.year, d.month, d.day - 1);
int minuteOf(DateTime t) => t.hour * 60 + t.minute;
String two(int v) => v.toString().padLeft(2, '0');
String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

// ------------------------------------------------------------------- data

/// One calendar day of raw ring data, keyed by minute of the day.
class DayData {
  DayData(this.day);
  final DateTime day;

  /// minute → [bpm, SpO₂, temperature in tenths]
  final hr = <int, List<int>>{};

  /// minute → [running step total, kcal, metres, duration s]
  final steps = <int, List<int>>{};

  /// minute → [quality, movement]
  final sleep = <int, List<int>>{};

  bool get isEmpty => hr.isEmpty && steps.isEmpty && sleep.isEmpty;

  DateTime _at(int minute) => day.add(Duration(minutes: minute));

  static List<MapEntry<int, List<int>>> _sorted(Map<int, List<int>> m) =>
      m.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

  List<RingHealthRecord> get heartRecords => [
        for (final e in _sorted(hr))
          RingHealthRecord(_at(e.key), e.value[0], e.value[1], e.value[2] / 10),
      ];

  List<RingStepRecord> get stepRecords => [
        for (final e in _sorted(steps))
          RingStepRecord(_at(e.key), e.value[3], e.value[0], e.value[1], e.value[2]),
      ];

  List<SleepSample> get sleepSamples => [
        for (final e in _sorted(sleep)) SleepSample(_at(e.key), e.value[0], e.value[1]),
      ];

  Map<String, Object> toJson() => {
        'hr': {for (final e in hr.entries) '${e.key}': e.value},
        'steps': {for (final e in steps.entries) '${e.key}': e.value},
        'sleep': {for (final e in sleep.entries) '${e.key}': e.value},
      };

  factory DayData.fromJson(DateTime day, Map<String, dynamic> j) {
    final d = DayData(day);
    void read(String key, Map<int, List<int>> into) {
      final m = j[key];
      if (m is! Map) return;
      for (final e in m.entries) {
        final k = int.tryParse('${e.key}');
        if (k != null && e.value is List) {
          into[k] = [for (final v in e.value as List) (v as num).toInt()];
        }
      }
    }

    read('hr', d.hr);
    read('steps', d.steps);
    read('sleep', d.sleep);
    return d;
  }
}

// -------------------------------------------------------------- summaries

class Stat {
  const Stat(this.avg, this.min, this.max, this.n);
  final int avg, min, max, n;

  static Stat? of(Iterable<int> values) {
    final v = values.toList();
    if (v.isEmpty) return null;
    return Stat((v.reduce((a, b) => a + b) / v.length).round(), v.reduce(math.min),
        v.reduce(math.max), v.length);
  }

  Map<String, int> toJson() => {'avg': avg, 'min': min, 'max': max, 'n': n};

  static Stat? fromJson(Object? j) => j is Map
      ? Stat((j['avg'] as num).toInt(), (j['min'] as num).toInt(),
          (j['max'] as num).toInt(), (j['n'] as num).toInt())
      : null;
}

/// A night, as the report needs it — SleepNight minus the raw samples.
class NightSummary {
  const NightSummary({
    required this.fellAsleep,
    required this.woke,
    required this.asleep,
    required this.deep,
    required this.light,
    required this.rem,
    required this.awake,
    required this.score,
    required this.bouts,
  });

  factory NightSummary.of(SleepNight n) => NightSummary(
        fellAsleep: n.fellAsleep,
        woke: n.woke,
        asleep: n.asleepMinutes,
        deep: n.deepMinutes,
        light: n.lightMinutes,
        rem: n.remMinutes,
        awake: n.awakeMinutes,
        score: n.score,
        bouts: n.awakeBouts,
      );

  final DateTime fellAsleep, woke;
  final int asleep, deep, light, rem, awake, score, bouts;

  String get label => sleepScoreLabel(score);

  Map<String, Object> toJson() => {
        'fellAsleep': fellAsleep.toIso8601String(),
        'woke': woke.toIso8601String(),
        'asleep': asleep,
        'deep': deep,
        'light': light,
        'rem': rem,
        'awake': awake,
        'score': score,
        'label': label,
        'bouts': bouts,
      };

  static NightSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return NightSummary(
      fellAsleep: DateTime.parse('${j['fellAsleep']}'),
      woke: DateTime.parse('${j['woke']}'),
      asleep: i('asleep'),
      deep: i('deep'),
      light: i('light'),
      rem: i('rem'),
      awake: i('awake'),
      score: i('score'),
      bouts: i('bouts'),
    );
  }
}

class DaySummary {
  const DaySummary({
    required this.day,
    this.steps,
    this.calories,
    this.distance,
    this.hr,
    this.spo2,
    this.night,
    this.stress,
    this.stressProvisional = true,
  });

  factory DaySummary.build({
    required DateTime day,
    required DayData today,
    SleepNight? night,
    StressDay? stress,
  }) {
    final steps = today.stepRecords;
    // Running totals: the biggest is the day's count.
    final top = steps.isEmpty ? null : steps.reduce((a, b) => a.steps >= b.steps ? a : b);
    final heart = today.heartRecords;
    return DaySummary(
      day: day,
      steps: top?.steps,
      calories: top?.calories,
      distance: top?.distance,
      hr: Stat.of(cleanHeartRate(heart).kept.map((r) => r.hr)),
      spo2: Stat.of([for (final r in heart) if (r.spo2 > 0) r.spo2]),
      night: night == null ? null : NightSummary.of(night),
      stress: stress?.score,
      stressProvisional: stress?.provisional ?? true,
    );
  }

  final DateTime day;
  final int? steps;
  final int? calories;

  /// Metres.
  final int? distance;
  final Stat? hr;
  final Stat? spo2;

  /// The night that ended on the morning of [day].
  final NightSummary? night;

  /// Estimated from heart rate — the ring has no HRV. Null if too little data.
  final int? stress;
  final bool stressProvisional;

  bool get isEmpty =>
      steps == null && hr == null && spo2 == null && night == null && stress == null;

  Map<String, Object?> toJson() => {
        'day': dayKey(day),
        if (steps != null) 'steps': steps,
        if (calories != null) 'calories': calories,
        if (distance != null) 'distance': distance,
        if (hr != null) 'hr': hr!.toJson(),
        if (spo2 != null) 'spo2': spo2!.toJson(),
        if (night != null) 'night': night!.toJson(),
        if (stress != null) 'stress': stress,
        'stressProvisional': stressProvisional,
      };

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
        day: DateTime.parse('${j['day']}'),
        steps: (j['steps'] as num?)?.toInt(),
        calories: (j['calories'] as num?)?.toInt(),
        distance: (j['distance'] as num?)?.toInt(),
        hr: Stat.fromJson(j['hr']),
        spo2: Stat.fromJson(j['spo2']),
        night: NightSummary.fromJson(j['night']),
        stress: (j['stress'] as num?)?.toInt(),
        stressProvisional: j['stressProvisional'] != false,
      );
}

// ---------------------------------------------------------------- reports

enum ReportPeriod { day, week, month, year }

/// Any span of days, reduced LoraFit's way.
class Aggregate {
  const Aggregate({
    required this.label,
    required this.from,
    required this.to,
    required this.days,
    this.steps,
    this.stepsPerDay,
    this.hrAvg,
    this.hrMin,
    this.hrMax,
    this.spo2Avg,
    this.spo2Min,
    this.spo2Max,
    this.nights = 0,
    this.sleepMinutes,
    this.sleepScore,
    this.stress,
  });

  factory Aggregate.of(String label, DateTime from, DateTime to, Iterable<DaySummary> days) {
    final list = days.toList();
    final walked = [for (final d in list) if ((d.steps ?? 0) > 0) d.steps!];
    final hr = [for (final d in list) if (d.hr != null) d.hr!];
    final spo2 = [for (final d in list) if (d.spo2 != null) d.spo2!];
    final nights = [for (final d in list) if ((d.night?.asleep ?? 0) > 0) d.night!];
    final stress = [for (final d in list) if (d.stress != null) d.stress!];
    int? avg(Iterable<int> v) =>
        v.isEmpty ? null : (v.reduce((a, b) => a + b) / v.length).round();
    return Aggregate(
      label: label,
      from: from,
      to: to,
      days: list.length,
      steps: walked.isEmpty ? null : walked.reduce((a, b) => a + b),
      stepsPerDay: avg(walked),
      hrAvg: avg(hr.map((s) => s.avg)),
      hrMin: hr.isEmpty ? null : hr.map((s) => s.min).reduce(math.min),
      hrMax: hr.isEmpty ? null : hr.map((s) => s.max).reduce(math.max),
      spo2Avg: avg(spo2.map((s) => s.avg)),
      spo2Min: spo2.isEmpty ? null : spo2.map((s) => s.min).reduce(math.min),
      spo2Max: spo2.isEmpty ? null : spo2.map((s) => s.max).reduce(math.max),
      nights: nights.length,
      sleepMinutes: avg(nights.map((n) => n.asleep)),
      sleepScore: avg(nights.map((n) => n.score)),
      stress: avg(stress),
    );
  }

  final String label;
  final DateTime from, to;

  /// Days that have any data at all.
  final int days;

  /// Total over the span, and the average over days that had steps.
  final int? steps, stepsPerDay;
  final int? hrAvg, hrMin, hrMax;
  final int? spo2Avg, spo2Min, spo2Max;

  /// Nights that had sleep; the averages are over those alone.
  final int nights;
  final int? sleepMinutes, sleepScore;
  final int? stress;

  Map<String, Object?> toJson() => {
        'label': label,
        'from': dayKey(from),
        'to': dayKey(to),
        'days': days,
        'steps': steps,
        'stepsPerDay': stepsPerDay,
        'hr': {'avg': hrAvg, 'min': hrMin, 'max': hrMax},
        'spo2': {'avg': spo2Avg, 'min': spo2Min, 'max': spo2Max},
        'sleep': {'nights': nights, 'minutes': sleepMinutes, 'score': sleepScore},
        'stress': stress,
      };
}

class HealthReport {
  const HealthReport(this.period, this.total, this.buckets);
  final ReportPeriod period;
  final Aggregate total;

  /// Days for a week or month; months for a year; none for a day.
  final List<Aggregate> buckets;

  Map<String, Object?> toJson() => {
        'period': period.name,
        'total': total.toJson(),
        'buckets': [for (final b in buckets) b.toJson()],
      };
}
