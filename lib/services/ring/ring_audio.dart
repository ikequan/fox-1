import 'dart:typed_data';

import 'ring_protocol.dart';

/// The ring's audio, as LoraFit handles it.
///
/// Opcodes 0x32 (online recording), 0x33 (AI dialog) and 0x34 (offline
/// recording) all carry the same payload: a 6-byte ring timestamp, then bare
/// Opus packets of exactly 40 bytes. Each packet is 20 ms of 16 kHz mono and
/// decodes to 640 bytes of PCM16 — 16 kbit/s, ~120 KB per minute on the wire.
///
/// Offline recordings (quadruple tap) come off the ring one file at a time:
///
/// ```
/// → 0x3D                    how many files?
/// ← 0x3D  u16 count
/// → 0x34                    send the next file
/// ← 0x34  × N               packets 1..N of that file
/// ← 0x35                    (instead, when there is nothing to send)
/// ← 0x36  u16 remaining     that file is complete
/// → 0x36  u16 remaining     ack — THE RING DELETES THE FILE
/// ```
///
/// Only acknowledge once our copy is safely on disk: the ack is the delete.
const ringOpusFrameBytes = 40;
const ringOpusFrameMs = 20;

class RingAudioPacket {
  const RingAudioPacket(this.time, this.frames, this.leftover);
  final DateTime? time;
  final List<Uint8List> frames;

  /// Bytes after the last whole frame. LoraFit logs a warning and drops them;
  /// non-zero means the frame size is not what we think.
  final int leftover;
}

RingAudioPacket parseRingAudioPayload(List<int> p) {
  if (p.length < 6) return const RingAudioPacket(null, [], 0);
  final body = p.length - 6;
  final n = body ~/ ringOpusFrameBytes;
  return RingAudioPacket(
    readRingTime(p, 0),
    [
      for (var i = 0; i < n; i++)
        Uint8List.fromList(p.sublist(
            6 + i * ringOpusFrameBytes, 6 + (i + 1) * ringOpusFrameBytes)),
    ],
    body % ringOpusFrameBytes,
  );
}

/// The first byte of every Opus packet says how it was encoded (RFC 6716
/// §3.1). Logged so the 16 kHz / 20 ms assumption is checked, not trusted.
String describeOpusToc(int toc) {
  final config = toc >> 3;
  final stereo = (toc & 0x04) != 0;
  final code = toc & 0x03;
  final String mode;
  final List<num> sizes;
  if (config < 12) {
    mode = 'SILK ${const ['NB', 'MB', 'WB'][config ~/ 4]}';
    sizes = const [10, 20, 40, 60];
  } else if (config < 16) {
    mode = 'Hybrid ${config < 14 ? 'SWB' : 'FB'}';
    sizes = const [10, 20];
  } else {
    mode = 'CELT ${const ['NB', 'WB', 'SWB', 'FB'][(config - 16) ~/ 4]}';
    sizes = const [2.5, 5, 10, 20];
  }
  final ms = sizes[config < 12 ? config % 4 : config < 16 ? config % 2 : config % 4];
  final frames = const ['1 frame', '2 frames', '2 frames (unequal)', 'n frames'][code];
  return 'config $config · $mode · $ms ms · ${stereo ? 'stereo' : 'mono'} · $frames';
}

/// One offline file being pulled off the ring.
class OfflinePull {
  OfflinePull(this.startedAt);

  final DateTime startedAt;

  /// The ring's timestamp on the first packet — when it was recorded.
  DateTime? recordedAt;
  int totalPackets = 0;
  int lastPacket = 0;
  int packets = 0;
  int duplicates = 0;
  int missing = 0;
  int leftoverBytes = 0;
  int frameCount = 0;
  final _frames = BytesBuilder(copy: false);

  /// Adds one 0x34 packet. Returns true when it was the last one.
  bool add(RingFrame f) {
    if (f.currentPacket != 0 && f.currentPacket <= lastPacket) {
      duplicates++;
      return false;
    }
    if (lastPacket > 0 && f.currentPacket > lastPacket + 1) {
      missing += f.currentPacket - lastPacket - 1;
    }
    totalPackets = f.totalPackets;
    lastPacket = f.currentPacket;
    packets++;
    final a = parseRingAudioPayload(f.payload);
    recordedAt ??= a.time;
    for (final fr in a.frames) {
      _frames.add(fr);
    }
    frameCount += a.frames.length;
    leftoverBytes += a.leftover;
    return complete;
  }

  bool get complete => totalPackets > 0 && lastPacket >= totalPackets;

  /// Every Opus packet so far, back to back.
  Uint8List get frames => _frames.toBytes();

  Duration get audio => Duration(milliseconds: frameCount * ringOpusFrameMs);

  /// A file name from when it was recorded, falling back to when we pulled it.
  String get baseName {
    final t = recordedAt ?? startedAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return 'ring_${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

/// A playable WAV around PCM16 little-endian samples.
Uint8List wavFromPcm16(Uint8List pcm, int sampleRate, {int channels = 1}) {
  final b = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * channels * 2, Endian.little);
  b.setUint16(32, channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(b.buffer.asUint8List())
        ..add(pcm))
      .toBytes();
}
