/// Sleep, read the way LoraFit reads it — stages, the night's edges, the score.
///
/// Every rule here follows the vendor app, not invented:
///
///  * stages and the score
///  * a night is trimmed to its first and last asleep sample
///  * which samples make "the night of day D": 18:00 the evening before to
///    noon on D
///
/// Confirmed against hardware: a LoraFit screenshot of 6h20 (deep 110, light
/// 205, REM 65 min) is exactly 22 / 41 / 13 samples of quality 4 / 3 / 2.
library;

/// Quality byte on the wire, one sample every five minutes.
enum SleepStage { deep, light, rem, awake }

SleepStage stageOf(int quality) => switch (quality) {
      4 => SleepStage.deep,
      3 => SleepStage.light,
      2 => SleepStage.rem,
      // 1 is LoraFit's AWAKE; 0 is the ring not tracking sleep at all. Both
      // count as awake, and neither adds to sleep time.
      _ => SleepStage.awake,
    };

class SleepSample {
  const SleepSample(this.t, this.quality, [this.move = 0]);
  final DateTime t;
  final int quality;
  final int move;

  SleepStage get stage => stageOf(quality);
  bool get asleep => stage != SleepStage.awake;
}

const sleepSampleMinutes = 5;

class SleepNight {
  const SleepNight({
    required this.fellAsleep,
    required this.woke,
    required this.deepMinutes,
    required this.lightMinutes,
    required this.remMinutes,
    required this.awakeMinutes,
    required this.score,
    required this.samples,
  });

  /// First asleep sample minus one sample, as LoraFit shows it.
  final DateTime fellAsleep;

  /// The last asleep sample.
  final DateTime woke;
  final int deepMinutes;
  final int lightMinutes;
  final int remMinutes;

  /// Awake time *inside* the night — between falling asleep and waking.
  final int awakeMinutes;
  final int score;

  /// The trimmed night, in time order.
  final List<SleepSample> samples;

  int get asleepMinutes => deepMinutes + lightMinutes + remMinutes;
  String get label => sleepScoreLabel(score);

  /// Stretches of two or more awake samples inside the night.
  int get awakeBouts {
    var bouts = 0, run = 0;
    for (final s in samples) {
      if (s.asleep) {
        if (run >= 2) bouts++;
        run = 0;
      } else {
        run++;
      }
    }
    return run >= 2 ? bouts + 1 : bouts;
  }

  @override
  String toString() => '${_hm(asleepMinutes)} '
      '(${_clock(fellAsleep)} → ${_clock(woke)}) · deep ${deepMinutes}m · '
      'light ${lightMinutes}m · REM ${remMinutes}m · awake ${awakeMinutes}m · '
      'score $score ($label)';
}

String _hm(int minutes) =>
    '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m';

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Trims to the first..last asleep sample and scores what is left. Null when
/// nothing in [samples] is asleep.
SleepNight? summarizeNight(List<SleepSample> samples) {
  final sorted = [...samples]..sort((a, b) => a.t.compareTo(b.t));
  final first = sorted.indexWhere((s) => s.asleep);
  if (first < 0) return null;
  final last = sorted.lastIndexWhere((s) => s.asleep);
  final night = sorted.sublist(first, last + 1);

  var deep = 0, light = 0, rem = 0, awake = 0;
  for (final s in night) {
    switch (s.stage) {
      case SleepStage.deep:
        deep += sleepSampleMinutes;
      case SleepStage.light:
        light += sleepSampleMinutes;
      case SleepStage.rem:
        rem += sleepSampleMinutes;
      case SleepStage.awake:
        awake += sleepSampleMinutes;
    }
  }
  return SleepNight(
    fellAsleep: night.first.t.subtract(const Duration(minutes: sleepSampleMinutes)),
    woke: night.last.t,
    deepMinutes: deep,
    lightMinutes: light,
    remMinutes: rem,
    awakeMinutes: awake,
    score: sleepScore(
        asleep: deep + light + rem, deep: deep, light: light, rem: rem, awake: awake),
    samples: night,
  );
}

/// The night that ends on the morning of [day]: 18:00 the evening before to
/// noon. A 13:00 nap is outside it, as in LoraFit, which shows naps apart.
SleepNight? nightEnding(DateTime day, List<SleepSample> all) {
  final d = DateTime(day.year, day.month, day.day);
  final from = d.subtract(const Duration(hours: 6));
  final to = d.add(const Duration(hours: 12));
  // Days overlap at the edges of their replies; one sample per timestamp.
  final byTime = <DateTime, SleepSample>{
    for (final s in all)
      if (!s.t.isBefore(from) && s.t.isBefore(to)) s.t: s,
  };
  return summarizeNight(byTime.values.toList());
}

/// LoraFit's weighted score, 0–100: duration 35 %, deep 30 %, light 20 %,
/// REM 15 %. Stage percentages are of everything inside the night, awake
/// included.
int sleepScore({
  required int asleep,
  required int deep,
  required int light,
  required int rem,
  required int awake,
}) {
  if (asleep <= 0) return 0;
  final byDuration = _durationPoints(asleep / 60);
  final all = deep + light + rem + awake;
  if (all <= 0) return (byDuration * 0.35).round().clamp(0, 100);
  final s = byDuration * 0.35 +
      _deepPoints(deep * 100 / all) * 0.30 +
      _lightPoints(light * 100 / all) * 0.20 +
      _remPoints(rem * 100 / all) * 0.15;
  return s.round().clamp(0, 100);
}

String sleepScoreLabel(int score) => score >= 90
    ? 'perfect'
    : score >= 80
        ? 'good'
        : score >= 60
            ? 'average'
            : score >= 40
                ? 'poor'
                : 'severe insomnia';

int _durationPoints(double hours) {
  if (hours < 4) return 0;
  if (hours < 5) return 60;
  if (hours < 6) return 80;
  if (hours < 9) return 100;
  if (hours < 10) return 80;
  if (hours < 11) return 70;
  // As the vendor app scores it: 11 h and over scores 80 again. Probably a vendor slip, kept
  // so our number matches the one LoraFit shows.
  return 80;
}

int _deepPoints(double pct) => pct < 5
    ? 0
    : pct < 10
        ? 60
        : pct < 15
            ? 80
            : 100;

int _lightPoints(double pct) {
  if (pct < 40) return 60;
  if (pct < 50) return 80;
  if (pct < 60) return 100;
  if (pct < 70) return 80;
  if (pct < 80) return 50;
  return 30;
}

int _remPoints(double pct) {
  if (pct < 5) return 0;
  if (pct < 10) return 60;
  if (pct < 15) return 80;
  if (pct < 25) return 100;
  if (pct < 30) return 80;
  // The vendor's value here is unknown; 60 mirrors the shape of the
  // light-sleep curve. Rare — REM above 30 % of a night.
  return 60;
}
