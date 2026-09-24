import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_protocol.dart';

RingReading? decode(int op, List<int> payload) =>
    decodeRingMessage(RingMessage(op, parseRingPacket(buildRingPacket(op, payload))!.payload));

void main() {
  group('framing', () {
    test('getBattery encodes as the doc says', () {
      expect(buildRingPacket(RingOp.getBattery, [0, 0]), [
        0xFE, 0xFC, // magic, little-endian
        0x06, 0x00, // opcode
        0x01, 0x00, // totalPackets
        0x01, 0x00, // currentPacket
        0x02, 0x00, // payloadLength
        0x00, 0x00,
      ]);
    });

    test('round-trips', () {
      final f = parseRingPacket(buildRingPacket(RingOp.buttonEvent, [1]))!;
      expect(f.opcode, RingOp.buttonEvent);
      expect(f.payload, [1]);
      expect(f.fragmented, isFalse);
    });

    test('rejects what LoraFit rejects', () {
      expect(parseRingPacket([0xFE, 0xFC, 0, 0]), isNull, reason: 'short');
      final bad = buildRingPacket(6, [0, 0])..[0] = 0x00;
      expect(parseRingPacket(bad), isNull, reason: 'magic');
      final long = [...buildRingPacket(6, [0, 0]), 0x99];
      expect(parseRingPacket(long), isNull, reason: 'length mismatch');
    });
  });

  group('notifications do not have to line up with packets', () {
    test('two packets in one notification', () {
      final p = RingStreamParser();
      final out = p.add([
        ...buildRingPacket(RingOp.buttonEvent, [1]),
        ...buildRingPacket(RingOp.buttonEvent, [2]),
      ]);
      expect(out.map((f) => f.payload.first), [1, 2]);
    });

    test('one packet split across notifications', () {
      final p = RingStreamParser();
      final pkt = buildRingPacket(RingOp.getSleepData, List.filled(30, 7));
      expect(p.add(pkt.sublist(0, 7)), isEmpty);
      expect(p.add(pkt.sublist(7, 20)), isEmpty);
      final out = p.add(pkt.sublist(20));
      expect(out.single.payload.length, 30);
    });

    test('garbage ahead of the magic is skipped and counted', () {
      final p = RingStreamParser();
      final out = p.add([0x11, 0x22, ...buildRingPacket(6, [0x55])]);
      expect(out.single.payload, [0x55]);
      expect(p.discarded, 2);
    });

    test('a magic split across notifications survives', () {
      final p = RingStreamParser();
      final pkt = buildRingPacket(6, [9]);
      expect(p.add([0x00, pkt.first]), isEmpty);
      expect(p.add(pkt.sublist(1)).single.payload, [9]);
    });
  });

  group('multi-packet responses', () {
    test('fragments are stitched in order', () {
      final r = RingReassembler();
      RingFrame part(int n, List<int> body) => parseRingPacket(
          buildRingPacket(RingOp.getSleepData, body, 3, n))!;
      expect(r.add(part(1, [1, 2])), isNull);
      expect(r.add(part(2, [3])), isNull);
      final m = r.add(part(3, [4, 5]))!;
      expect(m.payload, [1, 2, 3, 4, 5]);
      expect(m.parts, 3);
    });

    test('a restarted transfer does not inherit the abandoned one', () {
      final r = RingReassembler();
      RingFrame part(int n, List<int> body) => parseRingPacket(
          buildRingPacket(RingOp.getHealthRecord, body, 2, n))!;
      r.add(part(1, [0xAA]));
      r.add(part(1, [1]));
      expect(r.add(part(2, [2]))!.payload, [1, 2]);
    });

    test('a live stream is not held back waiting for a last fragment', () {
      final r = RingReassembler();
      final f = parseRingPacket(buildRingPacket(0x33, [1, 2, 3], 0, 0))!;
      expect(f.streaming, isTrue);
      expect(r.add(f)!.payload, [1, 2, 3]);
    });
  });

  group('time', () {
    test('wall-clock survives a round trip in any zone', () {
      final when = DateTime(2026, 9, 10, 23, 15, 7);
      final back = readRingTime(ringTimestampBytes(when), 0);
      expect(back, when);
    });

    test('setTime is six time bytes then a zero', () {
      final p = setTimePayload(DateTime(2026, 1, 1));
      expect(p.length, 7);
      expect(p.last, 0);
    });
  });

  group('payloads, as the vendor app reads them', () {
    test('button: 1 on the wire is press, 2 is release — not double-click', () {
      expect(decode(RingOp.buttonEvent, [1])!.fields, {'raw': 1, 'event': 1});
      expect(decode(RingOp.buttonEvent, [2])!.fields, {'raw': 2, 'event': 0});
      // Anything else LoraFit throws away. We keep the raw value.
      expect(decode(RingOp.buttonEvent, [3])!.fields, {'raw': 3, 'event': -1});
    });

    test('battery is percent then a charging flag', () {
      expect(decode(RingOp.getBattery, [80, 1])!.fields,
          {'percent': 80, 'charging': 1});
    });

    test('health records are 14 bytes and empty slots are skipped', () {
      final ts = ringTimestampBytes(DateTime(2026, 9, 10, 8, 0));
      final rec = [...ts, 72, 98, 0x6D, 0x01, 0, 0, 0, 0]; // 36.5 °C
      final r = decode(RingOp.getHealthRecord, [...rec, ...List.filled(14, 0xFF)])!;
      expect(r.fields['records'], 1);
      expect(r.lines.single, contains('HR 72'));
      expect(r.lines.single, contains('SpO₂ 98%'));
      expect(r.lines.single, contains('36.5 °C'));
    });

    test('sleep records are 8 bytes: time, quality, movement', () {
      final a = [...ringTimestampBytes(DateTime(2026, 9, 10, 1, 0)), 2, 5];
      final b = [...ringTimestampBytes(DateTime(2026, 9, 10, 1, 5)), 2, 0];
      final c = [...ringTimestampBytes(DateTime(2026, 9, 10, 1, 10)), 3, 1];
      final r = decode(RingOp.getSleepData, [...a, ...b, ...c])!;
      expect(r.fields['samples'], 3);
      expect(r.fields['quality_counts'], {2: 2, 3: 1});
    });

    test('step history records are 16 bytes', () {
      final rec = [
        ...ringTimestampBytes(DateTime(2026, 9, 10, 9, 0)),
        30, 0, // duration
        0xDC, 0x05, 0, 0, // 1500 steps
        60, 0, // calories
        0x4C, 0x04, // 1100 distance
      ];
      expect(decode(RingOp.getStepCountInfo, rec)!.fields['steps'], 1500);
    });

    test('step history is a running total — the last record is the day', () {
      List<int> rec(int steps) => [
            ...ringTimestampBytes(DateTime(2026, 9, 10, 9, 0)),
            60, 0,
            steps & 0xff, (steps >> 8) & 0xff, 0, 0,
            1, 0,
            1, 0,
          ];
      // Summing would say 350.
      expect(decode(RingOp.getStepCountInfo, [...rec(100), ...rec(250)])!
          .fields['steps'], 250);
    });

    test('sleep quality 0 counts as awake', () {
      List<int> rec(int minute, int q) =>
          [...ringTimestampBytes(DateTime(2026, 9, 10, 1, minute)), q, 0];
      final r = decode(RingOp.getSleepData, [...rec(0, 0), ...rec(5, 3), ...rec(10, 4)])!;
      expect(r.fields['asleep_minutes'], 10);
    });

    test('sleep quality 1 is awake too — LoraFit counts only 2, 3, 4', () {
      List<int> rec(int minute, int q) =>
          [...ringTimestampBytes(DateTime(2026, 9, 10, 1, minute)), q, 0];
      final r = decode(RingOp.getSleepData,
          [...rec(0, 4), ...rec(5, 1), ...rec(10, 2), ...rec(15, 3)])!;
      expect(r.fields['asleep_minutes'], 15);
      expect(r.fields['awake_minutes'], 5);
      expect(r.fields['deep_minutes'], 5);
      expect(r.fields['rem_minutes'], 5);
      expect(r.summary, contains('score'));
    });

    test('offline recordings: count, file done, nothing to send', () {
      expect(decode(RingOp.offlineFileCount, [3, 0])!.fields['count'], 3);
      expect(decode(RingOp.offlineUploadDone, [2, 0])!.fields['remaining'], 2);
      expect(decode(RingOp.offlineAudioEmpty, [])!.summary,
          contains('no offline recordings'));
    });

    test('audio state names the offline-recording bits', () {
      expect(decode(RingOp.queryAudioState, [16, 0])!.summary,
          contains('offline recording in progress'));
      expect(decode(RingOp.queryAudioState, [64, 0])!.summary,
          contains('offline recording finished'));
      expect(decode(RingOp.queryAudioState, [32, 0])!.summary,
          contains('sending an offline file'));
    });

    test('0x0F is acknowledged by echoing type and on/off', () {
      expect(decode(RingOp.openCloseBpBsHrv, [2, 1])!.fields,
          {'type': 2, 'on': 1});
    });

    test('device name is length-prefixed ASCII', () {
      expect(decode(RingOp.deviceName, [0x0a, ...'SR116-0767'.codeUnits])!
          .fields['name'], 'SR116-0767');
    });

    test('device info: firmware, mac, maker, model', () {
      final r = decode(RingOp.getDeviceInfo, [
        0x05, 0x01,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x34, 0x12,
        0x78, 0x56,
      ])!;
      expect(r.fields['firmware'], 0x0105);
      expect(r.fields['maker'], '1234');
      expect(r.fields['model'], '5678');
    });

    test('a payload too short for its layout is left undecoded', () {
      expect(decode(RingOp.getBattery, [80]), isNull);
      expect(decode(0x99, [1, 2]), isNull);
    });
  });

  test('hex input accepts the forms people type', () {
    expect(parseHex('01 02'), [1, 2]);
    expect(parseHex('0x01,0xff'), [1, 255]);
    expect(parseHex(''), isEmpty);
    expect(parseHex('0'), isNull);
    expect(parseHex('zz'), isNull);
  });
}
