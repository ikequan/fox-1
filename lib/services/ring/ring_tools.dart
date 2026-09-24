import 'health_store.dart';
import 'ring_service.dart';
import 'stress_estimator.dart';

/// The ring as the wearer sees it, at one moment. A plain value, so the tools
/// below are tested without a service or a Bluetooth link.
class RingSnapshot {
  const RingSnapshot({
    required this.paired,
    required this.connected,
    this.name = '',
    this.battery,
    this.charging = false,
    this.syncing = false,
    this.lastSync,
    this.liveSteps,
    this.liveCalories,
    this.liveDistance,
    this.liveAt,
  });

  factory RingSnapshot.of(RingService r) => RingSnapshot(
        paired: r.paired,
        connected: r.ready,
        name: r.name,
        battery: r.battery,
        charging: r.charging,
        syncing: r.syncing,
        lastSync: r.lastSync,
        liveSteps: r.liveSteps,
        liveCalories: r.liveCalories,
        liveDistance: r.liveDistance,
        liveAt: r.liveStepsAt,
      );

  final bool paired, connected, charging, syncing;
  final String name;
  final int? battery, liveSteps, liveCalories, liveDistance;
  final DateTime? lastSync, liveAt;
}

/// What the assistant can say about the ring and the wearer's health.
///
/// Answers come from [HealthStore] — the device's own history — and the ring's
/// live step count, never from the ring itself, so they are instant and still
/// work with the ring out of range. Only `sync_ring` talks to the ring.
///
/// Stress is an estimate from heart rate (stress_estimator.dart). The ring has
/// no HRV, so every stress answer carries [stressNote], and the declaration
/// tells the model to say "estimate" and never to diagnose.
class RingTools {
  RingTools({
    required RingSnapshot Function() snapshot,
    required HealthStore store,
    required Future<String> Function() sync,
    DateTime Function()? now,
  })  : _snapshot = snapshot,
        _store = store,
        _sync = sync,
        _now = now ?? DateTime.now;

  factory RingTools.of(RingService ring) => RingTools(
        snapshot: () => RingSnapshot.of(ring),
        store: ring.store,
        sync: () => ring.sync(),
      );

  final RingSnapshot Function() _snapshot;
  final HealthStore _store;
  final Future<String> Function() _sync;
  final DateTime Function() _now;

  static const names = {
    'ring_status',
    'health_today',
    'health_report',
    'stress_estimate',
    'sync_ring',
  };

  static const stressNote =
      'An estimate from heart rate while the wearer is still, against their '
      'own baseline, plus overnight heart rate and sleep. The ring measures no '
      'HRV, so this is arousal, not a diagnosis — excitement, caffeine, heat, '
      'illness and talking raise it too. Call it an estimate; trends over '
      'several days mean more than a single day.';

  Future<Map<String, dynamic>> handle(String name, Map<String, dynamic> args) async {
    final s = _snapshot();
    if (!s.paired) {
      return {
        'success': false,
        'error': 'No ring is paired. The wearer can pair one in Settings → Smart Ring.',
      };
    }
    try {
      return switch (name) {
        'ring_status' => _status(s),
        'health_today' => await _today(s),
        'health_report' => await _report(args),
        'stress_estimate' => await _stress(args),
        'sync_ring' => await _syncNow(s),
        _ => {'success': false, 'error': 'Unknown ring tool: $name'},
      };
    } catch (e) {
      return {'success': false, 'error': 'Could not read the health history: $e'};
    }
  }

  // ------------------------------------------------------------------ tools

  Map<String, dynamic> _status(RingSnapshot s) => {
        'success': true,
        'result': {
          'ring': s.name.isEmpty ? 'smart ring' : s.name,
          'connected': s.connected,
          if (s.battery != null)
            (s.connected ? 'battery_percent' : 'battery_percent_last_known'): s.battery,
          if (s.connected) 'charging': s.charging,
          'last_synced': _ago(s.lastSync),
          if (!s.connected)
            'note': 'Not connected right now — out of range, or its battery is '
                'flat. The device keeps trying on its own.',
        },
      };

  Future<Map<String, dynamic>> _today(RingSnapshot s) async {
    final now = _now();
    final day = await _store.summary(now);
    // The ring sends its own running count on every step — fresher than the
    // last sync, which can be half an hour old.
    final live = s.liveAt != null && dayOf(s.liveAt!) == dayOf(now);
    final steps = live ? s.liveSteps : day?.steps;
    final calories = live ? s.liveCalories : day?.calories;
    final distance = live ? s.liveDistance : day?.distance;
    final hr = day?.hr, spo2 = day?.spo2, night = day?.night, stress = day?.stress;
    final result = <String, Object?>{
      'date': dayKey(now),
      'steps': ?steps,
      'calories': ?calories,
      'distance_m': ?distance,
      if (hr != null) 'heart_rate_bpm': _stat(hr),
      if (spo2 != null) 'blood_oxygen_percent': _stat(spo2),
      'last_night': night == null ? 'no sleep recorded' : _night(night),
      if (stress != null)
        'stress_estimate': {
          'score': stress,
          'band': stressBand(stress).name,
          if (day!.stressProvisional) 'provisional': true,
        },
      'history_synced': _ago(s.lastSync),
      if (steps == null && hr == null && night == null)
        'note': 'Nothing recorded today yet — is the ring being worn?',
    };
    return {'success': true, 'result': result};
  }

  Future<Map<String, dynamic>> _report(Map<String, dynamic> args) async {
    final period =
        ReportPeriod.values.asNameMap()['${args['period']}'] ?? ReportPeriod.week;
    final date = DateTime.tryParse('${args['date'] ?? ''}');
    final r = await _store.report(period, date ?? _now());
    final filled = [for (final b in r.buckets) if (b.days > 0) _aggregate(b)];
    final result = <String, Object?>{
      'period': period.name,
      'from': dayKey(r.total.from),
      'to': dayKey(r.total.to),
      'total': _aggregate(r.total),
      if (filled.isNotEmpty)
        (period == ReportPeriod.year ? 'by_month' : 'by_day'): filled,
      if (r.total.days == 0)
        'note': 'Nothing recorded in this period. The device has only what it '
            'has synced since the ring was paired; the ring itself keeps about '
            'seven days.',
    };
    return {'success': true, 'result': result};
  }

  Future<Map<String, dynamic>> _stress(Map<String, dynamic> args) async {
    final n = ((args['days'] as num?)?.toInt() ?? 7).clamp(1, HealthStore.stressWindow);
    final to = dayOf(_now());
    final from = DateTime(to.year, to.month, to.day - (n - 1));
    final scored = [
      for (final d in await _store.between(from, to))
        if (d.stress != null) d,
    ];
    if (scored.isEmpty) {
      return {
        'success': true,
        'result': {
          'estimate': 'not enough data yet',
          'why': 'A day is only scored with about three hours of the ring worn '
              'while the wearer is awake and still.',
          'note': stressNote,
        },
      };
    }
    final avg =
        (scored.map((d) => d.stress!).reduce((a, b) => a + b) / scored.length).round();
    return {
      'success': true,
      'result': {
        'days': [
          for (final d in scored)
            {
              'date': dayKey(d.day),
              'score': d.stress,
              'band': stressBand(d.stress!).name,
              if (d.stressProvisional) 'provisional': true,
            },
        ],
        'average': avg,
        'average_band': stressBand(avg).name,
        if (scored.any((d) => d.stressProvisional))
          'provisional': 'Under five days of history — the personal baseline is '
              'still forming, so hold these loosely.',
        'scale': '0–25 rest, 26–50 low, 51–75 medium, 76–100 high',
        'note': stressNote,
      },
    };
  }

  Future<Map<String, dynamic>> _syncNow(RingSnapshot s) async {
    if (!s.connected) {
      return {
        'success': false,
        'error': 'The ring is not connected, so nothing can be pulled from it. '
            'The device has its data up to ${_ago(s.lastSync)}.',
      };
    }
    if (s.syncing) {
      return {
        'success': true,
        'result': 'A sync is already running; the figures will be current in a few seconds.',
      };
    }
    final r = await _sync();
    if (r.startsWith('sync failed') || r == 'not connected') {
      return {'success': false, 'error': r};
    }
    return {
      'success': true,
      'result': 'Synced ($r). Ask health_today or health_report again for the fresh figures.',
    };
  }

  // --------------------------------------------------------------- shaping

  Map<String, Object?> _aggregate(Aggregate a) => {
        'label': a.label,
        'days_with_data': a.days,
        if (a.steps != null) 'steps_total': a.steps,
        if (a.stepsPerDay != null) 'steps_per_day': a.stepsPerDay,
        if (a.hrAvg != null)
          'heart_rate_bpm': {'average': a.hrAvg, 'lowest': a.hrMin, 'highest': a.hrMax},
        if (a.spo2Avg != null)
          'blood_oxygen_percent': {
            'average': a.spo2Avg,
            'lowest': a.spo2Min,
            'highest': a.spo2Max,
          },
        if (a.nights > 0)
          'sleep': {
            'nights': a.nights,
            'average': _hm(a.sleepMinutes ?? 0),
            'average_score': a.sleepScore,
          },
        if (a.stress != null)
          'stress_estimate': {'average': a.stress, 'band': stressBand(a.stress!).name},
      };

  Map<String, Object> _night(NightSummary n) => {
        'asleep': _hm(n.asleep),
        'fell_asleep': _clock(n.fellAsleep),
        'woke': _clock(n.woke),
        'deep': _hm(n.deep),
        'light': _hm(n.light),
        'rem': _hm(n.rem),
        'awake': _hm(n.awake),
        'score': n.score,
        'rating': n.label,
      };

  Map<String, int> _stat(Stat s) => {'average': s.avg, 'lowest': s.min, 'highest': s.max};

  /// Spoken, not parsed: "7 h 5 min" reads out better than 425.
  static String _hm(int minutes) {
    final h = minutes ~/ 60, m = minutes % 60;
    if (h == 0) return '$m min';
    return m == 0 ? '$h h' : '$h h $m min';
  }

  static String _clock(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

  String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = _now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return 'on ${dayKey(t)}';
  }

  // ---------------------------------------------------------- declarations

  static const List<Map<String, dynamic>> declarations = [
    {
      'name': 'ring_status',
      'description':
          "The wearer's smart ring: connected or not, battery, charging, and "
              'when it last synced. Use for "how\'s my ring battery", "is my ring '
              'connected".',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'health_today',
      'description':
          'Today from the smart ring: steps, calories, distance, heart rate, '
              "blood oxygen, last night's sleep, and today's stress estimate. Use "
              'for "how did I sleep", "how many steps have I done", "what\'s my '
              'heart rate been". Answer the question asked in a sentence or two — '
              'do not read out every field.',
      'parameters': {'type': 'object', 'properties': {}},
    },
    {
      'name': 'health_report',
      'description':
          'A summary over a day, week (Monday to Sunday), month or year from the '
              'ring history the device keeps: steps, heart rate, blood oxygen, sleep '
              'and stress, broken down by day (by month for a year). Use for "how '
              'was my week", "how much have I slept this month". To compare with '
              'an earlier period, call it again with a date in that period.',
      'parameters': {
        'type': 'object',
        'properties': {
          'period': {
            'type': 'string',
            'enum': ['day', 'week', 'month', 'year'],
          },
          'date': {
            'type': 'string',
            'description':
                'Any day inside the period, as YYYY-MM-DD. Omit for the current '
                    'one. For "last week", a date seven days ago.',
          },
        },
        'required': ['period'],
      },
    },
    {
      'name': 'stress_estimate',
      'description':
          "Estimated stress for each day, from the ring's heart rate. The ring "
              'measures no HRV, so always call it an estimate and never a '
              'diagnosis, and say what else raises it if the number is high. Use '
              'for "am I stressed", "how stressed have I been this week".',
      'parameters': {
        'type': 'object',
        'properties': {
          'days': {
            'type': 'integer',
            'description': 'How many days back, today included. Default 7, at most 28.',
          },
        },
      },
    },
    {
      'name': 'sync_ring',
      'description':
          'Pull the latest data from the ring into the device. Takes about 15 '
              'seconds, so say you are checking first. Only when the wearer wants '
              'up-to-the-minute figures, or health_today shows the history synced '
              'more than an hour ago. The device already syncs every 30 minutes on '
              'its own.',
      'parameters': {'type': 'object', 'properties': {}},
    },
  ];
}
