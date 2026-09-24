import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_audio.dart';
import 'package:fox1/services/ring/ring_protocol.dart';

List<int> frame(int fill) => List.filled(ringOpusFrameBytes, fill);

RingFrame packet(int n, int total, List<int> payload) =>
    parseRingPacket(buildRingPacket(RingOp.audioOffline, payload, total, n))!;

void main() {
  final when = DateTime(2026, 9, 10, 8, 15);

  test('an audio payload is a timestamp then whole 40-byte Opus frames', () {
    final a = parseRingAudioPayload(
        [...ringTimestampBytes(when), ...frame(0x48), ...frame(0x49), 1, 2, 3]);
    expect(a.time, when);
    expect(a.frames, hasLength(2));
    expect(a.frames[1].first, 0x49);
    expect(a.leftover, 3, reason: 'LoraFit warns and drops these');
  });

  test('a payload too short for a timestamp is empty, not an error', () {
    final a = parseRingAudioPayload([1, 2, 3]);
    expect(a.time, isNull);
    expect(a.frames, isEmpty);
  });

  test('a pull collects packets in order and ignores repeats', () {
    final p = OfflinePull(DateTime(2026, 9, 10, 9));
    final ts = ringTimestampBytes(when);
    expect(p.add(packet(1, 3, [...ts, ...frame(1), ...frame(2)])), isFalse);
    expect(p.add(packet(2, 3, [...ts, ...frame(3)])), isFalse);
    expect(p.add(packet(2, 3, [...ts, ...frame(3)])), isFalse);
    expect(p.add(packet(3, 3, [...ts, ...frame(4)])), isTrue);
    expect(p.frameCount, 4);
    expect(p.duplicates, 1);
    expect(p.missing, 0);
    expect(p.frames.length, 4 * ringOpusFrameBytes);
    expect(p.audio, const Duration(milliseconds: 80));
    expect(p.recordedAt, when);
    expect(p.baseName, 'ring_20260910_081500');
  });

  test('a gap in the packet numbers is counted as missing', () {
    final p = OfflinePull(DateTime(2026, 9, 10));
    final ts = ringTimestampBytes(when);
    p.add(packet(1, 4, [...ts, ...frame(1)]));
    p.add(packet(3, 4, [...ts, ...frame(1)]));
    expect(p.missing, 1);
  });

  test('the TOC byte is described per RFC 6716', () {
    // config 9 = SILK wideband (16 kHz) 20 ms — what LoraFit's 640-byte
    // decode implies.
    expect(describeOpusToc(0x48), 'config 9 · SILK WB · 20 ms · mono · 1 frame');
    expect(describeOpusToc(0xB8), 'config 23 · CELT WB · 20 ms · mono · 1 frame');
    expect(describeOpusToc(0x7D), contains('Hybrid FB'));
  });

  test('WAV header describes the samples that follow it', () {
    final pcm = Uint8List.fromList(List.filled(320, 0));
    final wav = wavFromPcm16(pcm, 16000);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint32(4, Endian.little), 36 + 320);
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint32(28, Endian.little), 32000);
    expect(b.getUint32(40, Endian.little), 320);
    expect(wav.length, 44 + 320);
  });
}
