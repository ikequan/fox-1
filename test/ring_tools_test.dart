import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/health_store.dart';
import 'package:fox1/services/ring/ring_protocol.dart';
import 'package:fox1/services/ring/ring_tools.dart';
import 'package:fox1/services/ring/sleep_analysis.dart';

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
  late RingSnapshot snap;
  late int syncs;

  // 2026-09-07 is a Monday.
  final tue = DateTime(2026, 9, 8), wed = DateTime(2026, 9, 9);
  final noon = wed.add(const Duration(hours: 12));

  RingTools tools() => RingTools(
        snapshot: () => snap,
        store: store,
        sync: () async {
          syncs++;
          return '3 heart · 2 step · 0 sleep records over 2 day(s) · 1 day(s) updated';
        },
        now: () => noon,
      );

  Future<Map> result(String tool, [Map<String, dynamic> args = const {}]) async {
    final r = await tools().handle(tool, args);
    expect(r['success'], isTrue, reason: '$r');
    return r['result'] as Map;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ring_tools');
    store = HealthStore(directory: () async => tmp);
    snap = const RingSnapshot(paired: true, connected: true, name: 'SR116-0767');
    syncs = 0;
  });
  tearDown(() => tmp.delete(recursive: true));

  test('every declared tool is one the tools answer', () {
    expect({for (final d in RingTools.declarations) d['name']}, RingTools.names);
  });

  test('ring status: battery while connected, last known when not', () async {
    snap = RingSnapshot(
        paired: true,
        connected: true,
        battery: 95,
        lastSync: noon.subtract(const Duration(minutes: 12)));
    var r = await result('ring_status');
    expect(r['battery_percent'], 95);
    expect(r['last_synced'], '12 min ago');
    expect(r.containsKey('note'), isFalse);

    snap = const RingSnapshot(paired: true, connected: false, battery: 40);
    r = await result('ring_status');
    expect(r['battery_percent_last_known'], 40);
    expect(r['last_synced'], 'never');
    expect(r['note'], contains('Not connected'));
  });

  test("today takes the ring's live step count, and last night's sleep", () async {
    await store.add(
      steps: [st(wed.add(const Duration(hours: 9)), 800)],
      sleep: night(tue.add(const Duration(hours: 23)), wed.add(const Duration(hours: 6))),
    );
    snap = RingSnapshot(paired: true, connected: true, liveSteps: 1500, liveAt: noon);
    var r = await result('health_today');
    expect(r['steps'], 1500);
    final n = r['last_night'] as Map;
    expect(n['asleep'], '7 h 5 min');
    expect(n['woke'], '06:00');

    // A live count from yesterday is yesterday's: the synced one stands.
    snap = RingSnapshot(paired: true, connected: true, liveSteps: 9999, liveAt: tue);
    r = await result('health_today');
    expect(r['steps'], 800);
  });

  test('today with nothing recorded says so', () async {
    final r = await result('health_today');
    expect(r['last_night'], 'no sleep recorded');
    expect(r['note'], contains('worn'));
  });

  test('a week lists only the days that have data', () async {
    await store.add(steps: [
      st(tue.add(const Duration(hours: 18)), 1200),
      st(wed.add(const Duration(hours: 9)), 800),
    ]);
    final r = await result('health_report', {'period': 'week'});
    expect(r['from'], '2026-09-07');
    expect(r['to'], '2026-09-13');
    expect((r['total'] as Map)['steps_total'], 2000);
    expect(r['by_day'], hasLength(2));
  });

  test('an empty period explains why it is empty', () async {
    final r = await result('health_report', {'period': 'month', 'date': '2025-01-15'});
    expect(r['from'], '2025-01-01');
    expect(r['note'], contains('seven days'));
  });

  test('stress without enough data says so, and is still called an estimate', () async {
    final r = await result('stress_estimate', {'days': 99});
    expect(r['estimate'], 'not enough data yet');
    expect(r['note'], RingTools.stressNote);
    expect(RingTools.stressNote, contains('estimate'));
  });

  test('sync refuses without a link, and runs with one', () async {
    snap = const RingSnapshot(paired: true, connected: false);
    final refused = await tools().handle('sync_ring', {});
    expect(refused['success'], isFalse);
    expect(syncs, 0);

    snap = const RingSnapshot(paired: true, connected: true);
    expect((await tools().handle('sync_ring', {}))['success'], isTrue);
    expect(syncs, 1);
  });

  test('with no ring paired, every tool says where to pair one', () async {
    snap = const RingSnapshot(paired: false, connected: false);
    for (final name in RingTools.names) {
      final r = await tools().handle(name, {});
      expect(r['success'], isFalse);
      expect(r['error'], contains('Settings'));
    }
  });
}
