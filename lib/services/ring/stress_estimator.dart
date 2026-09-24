import 'dart:math' as math;

import 'ring_protocol.dart';
import 'sleep_analysis.dart';

/// Estimated stress, from heart rate. **The ring has no HRV and no skin
/// conductance** — the signals every commercial moment-to-moment stress score
/// is built on (Garmin/Firstbeat, Oura, Samsung, Huawei, WHOOP). What it does
/// have supports the heart-rate-only half of that literature:
///
///  * **Heart rate while still, against the wearer's own baseline.** Heart
///    rate not explained by movement is the established way to separate
///    emotional from physical load ("additional heart rate"). A sample is only
///    scored when the wearer is awake, has barely moved, and is not in the
///    recovery tail of exercise. Baselines are per 3-hour block of the day,
///    because resting heart rate drifts through it.
///  * **Overnight load.** Sleeping heart rate above the wearer's usual (Oura
///    penalises +3–5 bpm), and a short or broken night — both predict next-day
///    stress within a person.
///
/// Scale and bands follow Garmin: 0–25 rest, 26–50 low, 51–75 medium,
/// 76–100 high. The wearer's usual still heart rate scores 25.
///
/// It measures arousal, not distress. Excitement, caffeine, heat, illness and
/// talking all raise it; even Garmin's HRV score cannot tell excitement from
/// stress. Present it as an estimate, never a diagnosis. Daily and weekly
/// trends are the trustworthy part — a single reading is weak.
///
/// Pure Dart so the arithmetic is tested without a ring. Every constant is in
/// [StressTuning]; they are starting points to tune, not findings.
class StressTuning {
  StressTuning._();

  /// Still = at most this many steps in the half hour before a sample.
  static const stillWindow = Duration(minutes: 30);
  static const maxStepsWhileStill = 60;

  /// Heart rate stays up for hours after hard exercise (WHOOP free-living
  /// data: 180–210 min after a run), so skip samples after a big step count.
  static const vigorousLookback = Duration(hours: 3);
  static const vigorousSteps = 3000;

  /// Baseline window and minimums.
  static const baselineSpan = Duration(days: 28);
  static const minBaselineSamples = 12;

  /// Below this many earlier days, a score is shown as provisional — Oura
  /// waits five days before showing daytime stress at all.
  static const minBaselineDays = 5;

  /// Spread floor, so a wearer with a very steady pulse does not swing to
  /// "high" on a 2 bpm change.
  static const madFloorBpm = 2.0;

  /// Trailing median that steadies the per-sample score.
  static const smoothing = Duration(minutes: 15);
  static const highFrom = 76;

  /// A day needs three hours of still, awake samples to be scored.
  static const minStillSamples = 36;

  /// One exact heart-rate value making up more than this share of all
  /// readings is the ring's "no reading", not a heartbeat.
  static const fillShare = 0.3;

  /// A reading this far from its neighbours' median is a spike.
  static const spikeBpm = 25;

  static const nightBaselineSpan = Duration(days: 14);
  static const minBaselineNights = 3;
  static const minSleepHrSamples = 6;
  static const sleepHrSdFloor = 1.5;
  static const minSleepMinutes = 240;
}

enum StressBand { rest, low, medium, high }

StressBand stressBand(int score) => score <= 25
    ? StressBand.rest
    : score <= 50
        ? StressBand.low
        : score <= 75
            ? StressBand.medium
            : StressBand.high;

typedef TimeWindow = ({DateTime from, DateTime to});

/// What [cleanHeartRate] found.
class HeartQuality {
  const HeartQuality({
    required this.readings,
    required this.fillValue,
    required this.filled,
    required this.spikes,
  });
  final int readings;

  /// The value treated as "no reading", if one dominated.
  final int? fillValue;
  final int filled;
  final int spikes;
}

/// The ring's 5-minute heart-rate history is not clean. On hardware
/// (2026-09-10) 75 bpm recurred all day and all night — through deep sleep —
/// and single 103–119 bpm readings sat between neighbours in the 60s and 70s.
/// Averaged raw, that put "sleeping heart rate" at 86.
///
/// Two filters, neither tied to the number 75:
///  * a single exact value making up more than [StressTuning.fillShare] of all
///    readings is a fill value — a real pulse is never that repetitive;
///  * a reading more than [StressTuning.spikeBpm] above — or below — BOTH its
///    neighbours (each within 20 min) is a spike. A real rise, like the start
///    of a walk, has a neighbour that rises with it. (A median of two
///    neighbours each side was tried first and threw away the last normal
///    reading before every genuine rise.)
({List<RingHealthRecord> kept, HeartQuality quality}) cleanHeartRate(
    List<RingHealthRecord> records) {
  final byTime = <DateTime, RingHealthRecord>{
    for (final r in records)
      if (r.hr > 0) r.t: r,
  };
  final valid = byTime.values.toList()..sort((a, b) => a.t.compareTo(b.t));
  int? fill;
  if (valid.isNotEmpty) {
    final counts = <int, int>{};
    for (final r in valid) {
      counts[r.hr] = (counts[r.hr] ?? 0) + 1;
    }
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (top.value > valid.length * StressTuning.fillShare) fill = top.key;
  }
  final real = fill == null ? valid : valid.where((r) => r.hr != fill).toList();
  final kept = <RingHealthRecord>[];
  var spikes = 0;
  const gap = Duration(minutes: 20);
  for (var i = 0; i < real.length; i++) {
    if (i > 0 && i < real.length - 1) {
      final r = real[i], prev = real[i - 1], next = real[i + 1];
      final up = r.hr - prev.hr, down = r.hr - next.hr;
      if (r.t.difference(prev.t) <= gap &&
          next.t.difference(r.t) <= gap &&
          up.sign == down.sign &&
          up.abs() > StressTuning.spikeBpm &&
          down.abs() > StressTuning.spikeBpm) {
        spikes++;
        continue;
      }
    }
    kept.add(real[i]);
  }
  return (
    kept: kept,
    quality: HeartQuality(
      readings: valid.length,
      fillValue: fill,
      filled: valid.length - real.length,
      spikes: spikes,
    ),
  );
}

class StressDay {
  const StressDay({
    required this.day,
    required this.score,
    required this.awake,
    required this.overnight,
    required this.stillSamples,
    required this.highSamples,
    required this.night,
    required this.sleepingHr,
    required this.priorDays,
    required this.notes,
  });

  final DateTime day;

  /// Null when there was not enough still, awake time to score the day.
  final int? score;

  /// Mean smoothed score over the day's still, awake samples.
  final double? awake;

  /// 0–100 from the night that ended this morning.
  final int? overnight;
  final int stillSamples;
  final int highSamples;
  final SleepNight? night;
  final double? sleepingHr;

  /// Earlier days the baseline was drawn from.
  final int priorDays;
  final List<String> notes;

  StressBand? get band => score == null ? null : stressBand(score!);
  bool get provisional => priorDays < StressTuning.minBaselineDays;
  double get highShare => stillSamples == 0 ? 0 : highSamples / stillSamples;
}

/// Scores every day that has heart-rate data, oldest first.
///
/// [exclude] removes windows known to raise heart rate for reasons that are
/// not stress — conversations with the assistant, phone calls. The device
/// knows exactly when those happened, which a plain wearable does not.
List<StressDay> estimateStress({
  required List<RingHealthRecord> heart,
  required List<RingStepRecord> steps,
  required List<SleepSample> sleep,
  List<TimeWindow> exclude = const [],
}) {
  final hr = <DateTime, int>{
    for (final r in cleanHeartRate(heart).kept) r.t: r.hr,
  };
  final times = hr.keys.toList()..sort();
  if (times.isEmpty) return const [];
  final days = <DateTime>{for (final t in times) _dayOf(t)}.toList()..sort();

  // Nights keyed by the morning they end on — including tomorrow's, which
  // holds tonight's late-evening samples.
  final nights = <DateTime, SleepNight?>{
    for (final d in [...days, days.last.add(const Duration(days: 1))])
      d: nightEnding(d, sleep),
  };
  bool asleepAt(DateTime t) => nights.values.any((n) =>
      n != null &&
      !t.isBefore(n.fellAsleep) &&
      t.isBefore(n.woke.add(const Duration(minutes: sleepSampleMinutes))));

  final curve = _StepCurve(steps);
  final still = <DateTime, int>{};
  final unverified = <DateTime, int>{};
  for (final t in times) {
    if (asleepAt(t)) continue;
    if (exclude.any((w) => !t.isBefore(w.from) && t.isBefore(w.to))) continue;
    final recent = curve.between(t.subtract(StressTuning.stillWindow), t);
    if (recent == null) {
      unverified[_dayOf(t)] = (unverified[_dayOf(t)] ?? 0) + 1;
    } else if (recent > StressTuning.maxStepsWhileStill) {
      continue;
    }
    final before = curve.between(t.subtract(StressTuning.vigorousLookback),
        t.subtract(StressTuning.stillWindow));
    if (before != null && before > StressTuning.vigorousSteps) continue;
    still[t] = hr[t]!;
  }

  // Strictly between the first and last asleep samples. The displayed
  // "fell asleep" is one sample earlier, and the heart-rate reading there is
  // still the evening's.
  double? sleepingHr(SleepNight? n) {
    if (n == null) return null;
    final start = n.samples.first.t;
    final v = [
      for (final t in times)
        if (!t.isBefore(start) && !t.isAfter(n.woke)) hr[t]!.toDouble(),
    ];
    // Median, not mean: one missed spike should not move a whole night.
    return v.length < StressTuning.minSleepHrSamples ? null : _median(v);
  }

  final nightHr = {for (final d in days) d: sleepingHr(nights[d])};

  final out = <StressDay>[];
  for (final d in days) {
    final notes = <String>[];
    final todays = still.entries.where((e) => _dayOf(e.key) == d).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final from = d.subtract(StressTuning.baselineSpan);
    final prior = still.entries
        .where((e) => _dayOf(e.key).isBefore(d) && !_dayOf(e.key).isBefore(from))
        .toList();
    final priorDays = {for (final e in prior) _dayOf(e.key)}.length;

    // ---- daytime
    double? awake;
    var highs = 0;
    if (todays.isNotEmpty) {
      var pooled = prior.length >= StressTuning.minBaselineSamples * 2
          ? _Baseline.of(prior.map((e) => e.value))
          : null;
      if (pooled == null) {
        notes.add('no earlier days to compare with — scored against itself');
        pooled = _Baseline.of(still.values);
      }
      final byBlock = <int, _Baseline>{};
      for (var b = 0; b < 8; b++) {
        final v = [
          for (final e in prior)
            if (e.key.hour ~/ 3 == b) e.value,
        ];
        if (v.length >= StressTuning.minBaselineSamples) {
          byBlock[b] = _Baseline.of(v);
        }
      }
      final raw = [
        for (final e in todays)
          (t: e.key, s: (byBlock[e.key.hour ~/ 3] ?? pooled).score(e.value)),
      ];
      final smooth = <double>[];
      for (var i = 0; i < raw.length; i++) {
        final w = <double>[
          for (var j = i;
              j >= 0 && raw[i].t.difference(raw[j].t) < StressTuning.smoothing;
              j--)
            raw[j].s,
        ];
        smooth.add(_median(w));
      }
      for (var i = 1; i < smooth.length; i++) {
        // "High" needs two in a row, so one spike is not a stressful moment.
        if (smooth[i] >= StressTuning.highFrom &&
            smooth[i - 1] >= StressTuning.highFrom &&
            raw[i].t.difference(raw[i - 1].t) <= const Duration(minutes: 10)) {
          highs++;
        }
      }
      awake = _mean(smooth);
    }

    // ---- overnight
    int? overnight;
    final night = nights[d];
    final shr = nightHr[d];
    if (night != null) {
      final earlier = [
        for (final p in days)
          if (p.isBefore(d) &&
              !p.isBefore(d.subtract(StressTuning.nightBaselineSpan)) &&
              nightHr[p] != null)
            nightHr[p]!,
      ];
      double? hrTerm;
      if (shr != null && earlier.length >= StressTuning.minBaselineNights) {
        final m = _mean(earlier);
        final sd = math.max(_sd(earlier, m), StressTuning.sleepHrSdFloor);
        hrTerm = (25 * ((shr - m) / sd + 1)).clamp(0, 100).toDouble();
      } else {
        notes.add('sleeping heart rate has no baseline yet');
      }
      final sleepTerm =
          (100 - night.score + 5 * math.max(0, night.awakeBouts - 2))
              .clamp(0, 100)
              .toDouble();
      overnight =
          (hrTerm == null ? sleepTerm : 0.5 * hrTerm + 0.5 * sleepTerm).round();
      if (night.asleepMinutes < StressTuning.minSleepMinutes) {
        notes.add('short night (${night.asleepMinutes} min)');
      }
    } else {
      notes.add('no sleep recorded');
    }

    // ---- the day
    int? score;
    if (todays.length >= StressTuning.minStillSamples && awake != null) {
      score = (overnight == null ? awake : 0.6 * awake + 0.4 * overnight)
          .round()
          .clamp(0, 100);
    } else {
      notes.add('only ${todays.length * 5} min still and awake — '
          'need ${StressTuning.minStillSamples * 5}');
    }
    final u = unverified[d] ?? 0;
    if (u > 0) notes.add('$u samples had no step data to confirm stillness');

    out.add(StressDay(
      day: d,
      score: score,
      awake: awake,
      overnight: overnight,
      stillSamples: todays.length,
      highSamples: highs,
      night: night,
      sleepingHr: shr,
      priorDays: priorDays,
      notes: notes,
    ));
  }
  return out;
}

DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

double _mean(Iterable<num> v) => v.fold<double>(0, (a, b) => a + b) / v.length;

double _sd(List<double> v, double mean) => v.length < 2
    ? 0
    : math.sqrt(v.fold<double>(0, (a, b) => a + (b - mean) * (b - mean)) /
        (v.length - 1));

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Median and median absolute deviation — robust to the odd bad reading.
class _Baseline {
  _Baseline(this.median, this.mad);

  factory _Baseline.of(Iterable<int> values) {
    final v = [for (final x in values) x.toDouble()];
    final m = _median(v);
    return _Baseline(m, _median([for (final x in v) (x - m).abs()]));
  }

  final double median;
  final double mad;

  /// 25 at the wearer's usual, +25 per robust standard deviation above it.
  double score(int bpm) {
    final z = (bpm - median) /
        (1.4826 * math.max(mad, StressTuning.madFloorBpm));
    return (25 * (z + 1)).clamp(0, 100).toDouble();
  }
}

/// The ring's step records are running totals for the day. This turns them
/// into "steps between two moments", interpolating between records.
class _StepCurve {
  _StepCurve(List<RingStepRecord> records) {
    final byDay = <DateTime, Map<DateTime, int>>{};
    for (final r in records) {
      (byDay[_dayOf(r.t)] ??= {})[r.t] = r.steps;
    }
    for (final e in byDay.entries) {
      _days[e.key] = e.value.entries.map((x) => (x.key, x.value)).toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
    }
  }

  final _days = <DateTime, List<(DateTime, int)>>{};

  /// Steps so far that day at [t]; null when the ring had nothing that day.
  double? at(DateTime t) {
    final list = _days[_dayOf(t)];
    if (list == null || list.isEmpty) return null;
    var prevT = _dayOf(t);
    var prevV = 0.0;
    for (final (rt, v) in list) {
      if (!t.isAfter(rt)) {
        final span = rt.difference(prevT).inSeconds;
        if (span <= 0) return v.toDouble();
        return prevV + (v - prevV) * t.difference(prevT).inSeconds / span;
      }
      prevT = rt;
      prevV = v.toDouble();
    }
    return prevV;
  }

  double? between(DateTime a, DateTime b) {
    final x = at(a), y = at(b);
    if (x == null || y == null) return null;
    if (_dayOf(a) == _dayOf(b)) return math.max(0, y - x).toDouble();
    // Across midnight: the rest of a's day, then b's day so far.
    final endOfA = at(DateTime(a.year, a.month, a.day, 23, 59, 59))!;
    return (math.max(0, endOfA - x) + y).toDouble();
  }
}
