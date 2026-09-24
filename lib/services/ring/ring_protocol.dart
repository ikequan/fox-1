import 'dart:typed_data';

import 'sleep_analysis.dart';

/// The JY smart ring's BLE framing and payloads — docs/SMART_RING_PROTOCOL.md.
///
/// Pure Dart on purpose: framing is exactly the kind of thing that breaks
/// quietly, and this is the one layer that can be tested without a ring.
///
/// Every layout below matches how the vendor app (LoraFit) reads the ring,
/// checked on hardware. Where that leaves something open — units, what a
/// sleep-quality number means — it is left open here too.
///
/// Every packet, both directions, is a 10-byte little-endian header then the
/// payload. There is no checksum.
///
/// ```
/// 0  2  magic          0xFCFE  (FE FC on the wire)
/// 2  2  opcode
/// 4  2  totalPackets   1 when not fragmented; 0 for a live stream
/// 6  2  currentPacket  1-based
/// 8  2  payloadLength
/// 10 N  payload
/// ```
///
/// Opcodes are shared between request and response — send 0x2F, the reply is
/// also tagged 0x2F. Treat an opcode as a topic, not a direction.
class RingOp {
  RingOp._();

  static const setTime = 0x01;
  static const setUserInfo = 0x02;
  static const getMtu = 0x03;
  static const vibrateLed = 0x04;
  static const getBattery = 0x06;
  static const openHeartRate = 0x07;
  static const closeHeartRate = 0x08;
  static const getSportStatus = 0x09;
  static const sportPause = 0x0A;

  /// Live heart rate, pushed after [openHeartRate].
  static const hrLive = 0x0B;
  static const setTimeFormat = 0x0E;

  /// `[type, on/off]`. Built by LoraFit (openCloseBpBsHrv) but no reply to it
  /// is ever decoded there; on hardware the ring echoes the two bytes.
  static const openCloseBpBsHrv = 0x0F;

  /// Empty: a heart-rate measurement finished. Seen on hardware 2026-09-10;
  /// not in LoraFit's codec.
  static const hrDone = 0x11;
  static const openCloseTemperature = 0x14;

  /// Live temperature, pushed after [openCloseTemperature].
  static const tempLive = 0x15;

  /// Missing from the protocol doc's first pass; the vendor app sends it.
  static const openCloseSpo2 = 0x17;
  static const spo2Live = 0x18;

  /// The ring finished a SpO₂ measurement.
  static const spo2Done = 0x19;
  static const sportLive = 0x1B;
  static const getStepInfo = 0x1D;
  static const getStepCountInfo = 0x21;
  static const getSleepData = 0x22;
  static const getHealthRecord = 0x24;
  static const getDeviceInfo = 0x25;
  static const multiSportResult = 0x26;
  static const deviceOperation = 0x27;

  /// Ring → host only. See [decodeRingMessage] for the byte mapping — it is
  /// not what the protocol doc says.
  static const buttonEvent = 0x28;

  /// Sentinels: the query ran and the ring had nothing for that day. Each
  /// still carries a 6-byte timestamp.
  static const noData42 = 42;
  static const sleepEmpty = 43;
  static const healthEmpty = 45;

  static const queryAudioState = 0x2F;
  static const controlAudioMode = 0x30;
  static const pauseOrResumeAudio = 0x31;

  /// Audio packets — see ring_audio.dart. Never reassemble these: every
  /// packet carries its own timestamp and whole Opus frames.
  static const audioRecording = 0x32;
  static const audioDialog = 0x33;
  static const audioOffline = 0x34;

  /// The ring has no offline recording to send.
  static const offlineAudioEmpty = 0x35;

  /// Ring → host: a file finished sending (u16 files remaining). Host → ring
  /// with the same u16: acknowledged — the ring DELETES that file.
  static const offlineUploadDone = 0x36;
  static const queryDeviceFeature = 0x37;
  static const offlineFileCount = 0x3D;
  static const appHeartbeat = 0x3E;

  /// Abandon an offline transfer in progress.
  static const stopOfflineTransfer = 0x40;

  static bool isAudio(int op) => op >= audioRecording && op <= audioOffline;

  /// Device name, length-prefixed ASCII, sent unprompted after connect
  /// (`0a` + "SR116-0767"). Seen on hardware; not in LoraFit's codec.
  static const deviceName = 0x44;

  static const _names = <int, String>{
    setTime: 'time',
    setUserInfo: 'userInfo',
    getMtu: 'mtu',
    vibrateLed: 'vibrate',
    getBattery: 'battery',
    openHeartRate: 'hrOn',
    closeHeartRate: 'hrOff',
    getSportStatus: 'sportStatus',
    sportPause: 'sportPause',
    hrLive: 'hr:live',
    setTimeFormat: 'timeFormat',
    openCloseBpBsHrv: 'bpBsHrv',
    hrDone: 'hr:done',
    openCloseTemperature: 'tempOnOff',
    tempLive: 'temp:live',
    openCloseSpo2: 'spo2OnOff',
    spo2Live: 'spo2:live',
    spo2Done: 'spo2:done',
    sportLive: 'sport:live',
    getStepInfo: 'stepInfo',
    getStepCountInfo: 'stepHistory',
    getSleepData: 'sleep',
    getHealthRecord: 'health',
    getDeviceInfo: 'deviceInfo',
    multiSportResult: 'sportResult',
    deviceOperation: 'deviceOp',
    buttonEvent: 'BUTTON',
    noData42: 'none42',
    sleepEmpty: 'sleep:none',
    healthEmpty: 'health:none',
    queryAudioState: 'audioState',
    controlAudioMode: 'audioMode',
    pauseOrResumeAudio: 'audioPause',
    audioRecording: 'audio:recording',
    audioDialog: 'audio:dialog',
    audioOffline: 'audio:offline',
    offlineAudioEmpty: 'offline:empty',
    offlineUploadDone: 'offline:done',
    queryDeviceFeature: 'features',
    offlineFileCount: 'offlineFiles',
    appHeartbeat: 'heartbeat',
    stopOfflineTransfer: 'offline:stop',
    deviceName: 'name',
  };

  static String name(int op) =>
      _names[op] ?? 'op$op/0x${op.toRadixString(16).padLeft(2, '0')}';
}

const ringMagic = 0xFCFE;
const ringHeaderLength = 10;

class RingFrame {
  const RingFrame({
    required this.opcode,
    required this.totalPackets,
    required this.currentPacket,
    required this.payload,
  });

  final int opcode;
  final int totalPackets;
  final int currentPacket;
  final Uint8List payload;

  /// Live audio modes send an unbounded stream tagged `totalPackets = 0`.
  bool get streaming => totalPackets == 0;

  bool get fragmented => totalPackets > 1;

  @override
  String toString() => '${RingOp.name(opcode)}'
      '${fragmented ? ' [$currentPacket/$totalPackets]' : ''}'
      ' ${hex(payload)}';
}

/// Host → ring. Written to the `33F3` characteristic.
Uint8List buildRingPacket(
  int opcode, [
  List<int> payload = const [],
  int totalPackets = 1,
  int currentPacket = 1,
]) {
  final b = ByteData(ringHeaderLength + payload.length);
  b.setUint16(0, ringMagic, Endian.little);
  b.setUint16(2, opcode, Endian.little);
  b.setUint16(4, totalPackets, Endian.little);
  b.setUint16(6, currentPacket, Endian.little);
  b.setUint16(8, payload.length, Endian.little);
  final out = b.buffer.asUint8List();
  out.setRange(ringHeaderLength, out.length, payload);
  return out;
}

/// One complete packet, validated the way LoraFit validates it: too short,
/// wrong magic, or a length that disagrees with the header — all dropped.
RingFrame? parseRingPacket(List<int> bytes) {
  if (bytes.length < ringHeaderLength) return null;
  final b = ByteData.sublistView(Uint8List.fromList(bytes));
  if (b.getUint16(0, Endian.little) != ringMagic) return null;
  final len = b.getUint16(8, Endian.little);
  if (bytes.length != len + ringHeaderLength) return null;
  return RingFrame(
    opcode: b.getUint16(2, Endian.little),
    totalPackets: b.getUint16(4, Endian.little),
    currentPacket: b.getUint16(6, Endian.little),
    payload: Uint8List.fromList(bytes.sublist(ringHeaderLength)),
  );
}

/// Turns raw notifications into packets.
///
/// LoraFit assumes one notification is exactly one packet, which only holds if
/// the negotiated MTU is big enough. A packet split across notifications, two
/// packets in one, or a stray byte ahead of the magic would all be silently
/// dropped by that assumption — so this buffers, resyncs on the magic, and
/// reports what it had to throw away instead of losing it without trace.
class RingStreamParser {
  final _buf = <int>[];

  /// Bytes discarded while hunting for a magic. Non-zero means the link or
  /// the framing is not what the protocol doc says.
  int discarded = 0;

  List<RingFrame> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <RingFrame>[];
    while (true) {
      final start = _findMagic();
      if (start < 0) {
        // Keep a trailing FE — it may be the first half of a magic.
        final keep = _buf.isNotEmpty && _buf.last == 0xFE ? 1 : 0;
        discarded += _buf.length - keep;
        _buf.removeRange(0, _buf.length - keep);
        break;
      }
      if (start > 0) {
        discarded += start;
        _buf.removeRange(0, start);
      }
      if (_buf.length < ringHeaderLength) break;
      final len = _buf[8] | (_buf[9] << 8);
      if (_buf.length < ringHeaderLength + len) break;
      final f = parseRingPacket(_buf.sublist(0, ringHeaderLength + len));
      _buf.removeRange(0, ringHeaderLength + len);
      if (f != null) out.add(f);
    }
    return out;
  }

  int _findMagic() {
    for (var i = 0; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0xFE && _buf[i + 1] == 0xFC) return i;
    }
    return -1;
  }

  void reset() {
    _buf.clear();
    discarded = 0;
  }
}

/// A logical message: one packet, or several fragments stitched together.
class RingMessage {
  const RingMessage(this.opcode, this.payload, {this.parts = 1});
  final int opcode;
  final Uint8List payload;
  final int parts;
}

/// Stitches `totalPackets > 1` responses — sleep, health history, offline
/// audio — back into one payload before anything tries to read it.
class RingReassembler {
  final _parts = <int, List<Uint8List>>{};

  RingMessage? add(RingFrame f) {
    if (!f.fragmented) {
      _parts.remove(f.opcode);
      return RingMessage(f.opcode, f.payload);
    }
    // A fragment 1 always starts over: a half-finished message from a
    // dropped transfer must not have a new one appended to it.
    if (f.currentPacket <= 1) _parts[f.opcode] = [];
    final list = _parts.putIfAbsent(f.opcode, () => []);
    list.add(f.payload);
    if (f.currentPacket < f.totalPackets) return null;
    _parts.remove(f.opcode);
    final all = BytesBuilder(copy: false);
    for (final p in list) {
      all.add(p);
    }
    return RingMessage(f.opcode, all.toBytes(), parts: list.length);
  }
}

// ------------------------------------------------------------------ time

/// The ring keeps LOCAL wall-clock time as seconds since 1970, written as
/// though it were UTC — the vendor app adds the zone offset before sending
/// it. So reading those seconds as a UTC epoch
/// yields the wall-clock fields directly, and a local DateTime is rebuilt from
/// them. Six bytes, little-endian.
List<int> ringTimestampBytes(DateTime local) {
  final wall = DateTime.utc(local.year, local.month, local.day, local.hour,
              local.minute, local.second)
          .millisecondsSinceEpoch ~/
      1000;
  return [for (var i = 0; i < 6; i++) (wall >> (8 * i)) & 0xff];
}

DateTime readRingTime(List<int> b, int offset) {
  var s = 0;
  for (var i = 0; i < 6; i++) {
    s |= b[offset + i] << (8 * i);
  }
  final u = DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
  return DateTime(u.year, u.month, u.day, u.hour, u.minute, u.second);
}

/// `setTime` (0x01): the 6-byte time, then a zero byte, as the vendor app sends it.
List<int> setTimePayload(DateTime now) => [...ringTimestampBytes(now), 0];

// -------------------------------------------------------------- decoding

/// A decoded reply. [summary] is one line for a log; [lines] holds one entry
/// per record for history replies; [fields] carries the numbers themselves.
class RingReading {
  const RingReading(this.summary,
      {this.fields = const {}, this.lines = const []});
  final String summary;
  final Map<String, Object?> fields;
  final List<String> lines;
}

class _Reader {
  _Reader(this._bytes) : _b = ByteData.sublistView(Uint8List.fromList(_bytes));
  final List<int> _bytes;
  final ByteData _b;
  int _pos = 0;

  int u8() => _b.getUint8(_pos++);
  int u16() {
    final v = _b.getUint16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int i16() {
    final v = _b.getInt16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int u32() {
    final v = _b.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  DateTime time() {
    final t = readRingTime(_bytes, _pos);
    _pos += 6;
    return t;
  }

  List<int> take(int n) {
    final v = _bytes.sublist(_pos, _pos + n);
    _pos += n;
    return v;
  }
}

/// Fixed-size history records. A record of all 0xFF is an empty slot and is
/// skipped, exactly as the vendor app skips it.
List<T> _records<T>(List<int> p, int size, T Function(_Reader r) parse) => [
      for (var off = 0; off + size <= p.length; off += size)
        if (!p.sublist(off, off + size).every((b) => b == 0xFF))
          parse(_Reader(p.sublist(off, off + size))),
    ];

String _t(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// One `0x24` record: heart rate and SpO₂ (0 = not measured) and skin
/// temperature in °C.
class RingHealthRecord {
  const RingHealthRecord(this.t, this.hr, this.spo2, this.temp);
  final DateTime t;
  final int hr;
  final int spo2;
  final double temp;
}

/// One `0x21` record. [steps] is the day's RUNNING total at [t], not the steps
/// in that slot — see the step-history decoder.
class RingStepRecord {
  const RingStepRecord(this.t, this.duration, this.steps, this.calories, this.distance);
  final DateTime t;
  final int duration;
  final int steps;
  final int calories;

  /// Metres.
  final int distance;
}

/// 14-byte records: time, HR, SpO₂, temperature in tenths, 4 unused.
List<RingHealthRecord> parseHealthRecords(List<int> p) => _records(p, 14, (r) {
      final t = r.time(), hr = r.u8(), spo2 = r.u8(), temp = r.i16();
      r.take(4);
      return RingHealthRecord(t, hr, spo2, temp / 10);
    });

/// 16-byte records: time, duration, steps, calories, distance.
List<RingStepRecord> parseStepRecords(List<int> p) => _records(
    p, 16, (r) => RingStepRecord(r.time(), r.u16(), r.u32(), r.u16(), r.u16()));

/// 8-byte records: time, sleep quality, movement.
List<SleepSample> parseSleepSamples(List<int> p) =>
    _records(p, 8, (r) => SleepSample(r.time(), r.u8(), r.u8()));

/// Audio-state bits as LoraFit reads them.
String audioStateMeaning(int s) {
  if (s == 0) return 'idle';
  final parts = <String>[
    if (s & 0x10 != 0) 'offline recording in progress',
    if (s & 0x40 != 0) 'offline recording finished',
    // Not named in LoraFit; on hardware the ring reports 32 while it is
    // sending an offline file, between each 0x34 request and its packets.
    if (s & 0x20 != 0) 'sending an offline file',
    if (s & 0x0C != 0) 'AI dialog',
    if (s & 0x03 != 0) 'online recording',
  ];
  return parts.isEmpty ? 'unknown' : parts.join(' + ');
}

/// Decodes a reply using LoraFit's own layouts. Null for an opcode it does
/// not know or a payload too short to hold what that layout needs — both are
/// still worth logging as hex.
RingReading? decodeRingMessage(RingMessage m) {
  final p = m.payload;
  final r = _Reader(p);
  switch (m.opcode) {
    case RingOp.setTime when p.length >= 7:
      final y = r.u16(), mo = r.u8(), d = r.u8();
      final h = r.u8(), mi = r.u8(), s = r.u8();
      return RingReading('ring clock $y-$mo-$d $h:$mi:$s',
          fields: {'year': y, 'month': mo, 'day': d, 'hour': h, 'minute': mi, 'second': s});

    case RingOp.getBattery when p.length >= 2:
      final pct = r.u8(), charging = r.u8();
      return RingReading('battery $pct%${charging != 0 ? ' · charging' : ''}',
          fields: {'percent': pct, 'charging': charging});

    case RingOp.hrLive when p.length >= 7:
      final t = r.time(), hr = r.u8();
      return RingReading('heart rate $hr bpm (${_t(t)})',
          fields: {'time': t, 'heart_rate': hr});

    case RingOp.tempLive when p.length >= 13:
      final t = r.time(), raw = r.i16();
      return RingReading(
          'temperature ${(raw / 100).toStringAsFixed(2)} °C (${_t(t)})',
          fields: {'time': t, 'celsius': raw / 100});

    case RingOp.spo2Live when p.length >= 7:
      final t = r.time(), v = r.u8();
      return RingReading('SpO₂ $v% (${_t(t)})', fields: {'time': t, 'spo2': v});

    case RingOp.sportLive when p.length >= 26:
      final start = r.time(), type = r.u8(), now = r.time();
      final dur = r.u16(), steps = r.u32(), cal = r.u16(), dist = r.u16();
      final hr = r.u8(), temp = r.i16() / 10, spo2 = r.u8();
      return RingReading(
          'sport $type since ${_t(start)} · ${dur}s · $steps steps · '
          'cal $cal · dist $dist · HR $hr · ${temp.toStringAsFixed(1)} °C · SpO₂ $spo2%',
          fields: {'start': start, 'now': now, 'steps': steps, 'heart_rate': hr});

    case RingOp.getStepInfo when p.length >= 14:
      final t = r.time(), steps = r.u32(), cal = r.u16(), dist = r.u16();
      // Units from real data: 1069 steps → 828 m and 28 kcal (0.77 m a step).
      return RingReading('today: $steps steps · $cal kcal · $dist m (${_t(t)})',
          fields: {'time': t, 'steps': steps, 'calories': cal, 'distance': dist});

    case RingOp.getStepCountInfo:
      final recs = parseStepRecords(p);
      // Each record is the day's RUNNING total, not the steps in that slot:
      // on hardware they climbed 28, 50, 91 … 1069 and the last one matched
      // today's count. Summing them reported 9,676 steps for a 1,069-step day.
      final total = recs.isEmpty
          ? 0
          : recs.map((e) => e.steps).reduce((a, b) => a > b ? a : b);
      return RingReading('step history: ${recs.length} records · $total steps today',
          fields: {'records': recs.length, 'steps': total},
          lines: [
            for (final e in recs)
              '${_t(e.t)}  ${e.steps} steps so far · ${e.duration}s · '
                  '${e.calories} kcal · ${e.distance} m'
          ]);

    case RingOp.getSleepData:
      // Stages: 4 deep, 3 light, 2 REM, 1 and 0 awake — LoraFit's mapping,
      // matched to one of its screenshots to the minute. See sleep_analysis.
      final recs = parseSleepSamples(p);
      final counts = <int, int>{};
      for (final e in recs) {
        counts[e.quality] = (counts[e.quality] ?? 0) + 1;
      }
      final night = summarizeNight(recs);
      return RingReading(
          night == null
              ? 'sleep: ${recs.length} samples · no sleep · counts $counts'
              : 'sleep: $night · counts $counts',
          fields: {
            'samples': recs.length,
            'quality_counts': counts,
            'asleep_minutes': night?.asleepMinutes ?? 0,
            if (night != null) ...{
              'deep_minutes': night.deepMinutes,
              'light_minutes': night.lightMinutes,
              'rem_minutes': night.remMinutes,
              'awake_minutes': night.awakeMinutes,
              'score': night.score,
            },
          },
          lines: [
            for (final e in recs)
              '${_t(e.t)}  ${e.stage.name} (quality ${e.quality}) · move ${e.move}'
          ]);

    case RingOp.getHealthRecord:
      final recs = parseHealthRecords(p);
      final hrs = [for (final e in recs) if (e.hr > 0) e.hr];
      final range = hrs.isEmpty
          ? ''
          : ' · HR ${hrs.reduce((a, b) => a < b ? a : b)}–${hrs.reduce((a, b) => a > b ? a : b)}';
      return RingReading('health: ${recs.length} records$range',
          fields: {'records': recs.length},
          lines: [
            for (final e in recs)
              '${_t(e.t)}  HR ${e.hr} · SpO₂ ${e.spo2}% · ${e.temp.toStringAsFixed(1)} °C'
          ]);

    case RingOp.getDeviceInfo when p.length >= 12:
      final fw = r.u16();
      final mac = r.take(6).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final maker = r.u16().toRadixString(16).padLeft(4, '0').toUpperCase();
      final model = r.u16().toRadixString(16).padLeft(4, '0').toUpperCase();
      return RingReading('firmware $fw · mac ${mac.toUpperCase()} · maker $maker · model $model',
          fields: {'firmware': fw, 'mac': mac, 'maker': maker, 'model': model});

    case RingOp.deviceName when p.isNotEmpty:
      final n = p[0] < p.length ? p[0] : p.length - 1;
      final name = String.fromCharCodes(p.sublist(1, 1 + n));
      return RingReading('name "$name"', fields: {'name': name});

    case RingOp.multiSportResult when p.isNotEmpty:
      return RingReading('result ${r.u8()}');

    case RingOp.buttonEvent when p.isNotEmpty:
      // Byte 0 on the wire is 1 for PRESS and 2 for RELEASE.
      // LoraFit remaps that to button_event 1/0 and turns every other value
      // into −1, which it then ignores. The protocol doc read the remapped
      // numbers and called 2 a double-click; on the wire 2 is a release.
      final raw = r.u8();
      final event = raw == 1 ? 1 : raw == 2 ? 0 : -1;
      return RingReading('button raw=$raw', fields: {'raw': raw, 'event': event});

    case RingOp.noData42 || RingOp.sleepEmpty || RingOp.healthEmpty
        when p.length >= 6:
      return RingReading('${RingOp.name(m.opcode)} — nothing for that day '
          '(${_t(r.time())})');

    case RingOp.queryAudioState when p.length >= 2:
      final s = r.u8(), ext = r.u8();
      return RingReading(
          'audio state $s (${audioStateMeaning(s)}) ext $ext',
          fields: {'state': s, 'ext': ext});

    case RingOp.offlineUploadDone when p.length >= 2:
      final remaining = r.u16();
      return RingReading('offline file sent · $remaining on the ring',
          fields: {'remaining': remaining});

    case RingOp.offlineAudioEmpty:
      return const RingReading('no offline recordings to send');

    case RingOp.openCloseBpBsHrv when p.length >= 2:
      final type = r.u8(), on = r.u8();
      return RingReading('BP/BS/HRV type $type ${on == 1 ? 'on' : 'off'} (ack)',
          fields: {'type': type, 'on': on});

    case RingOp.controlAudioMode || RingOp.pauseOrResumeAudio when p.length >= 2:
      return RingReading('${RingOp.name(m.opcode)} action ${r.u8()} → ${r.u8()}');

    case RingOp.queryDeviceFeature when p.length >= 2:
      final remote = r.u8() != 0, storage = r.u8() != 0;
      return RingReading('features: remote recording $remote · storage $storage',
          fields: {'remote_recording': remote, 'storage': storage});

    case RingOp.offlineFileCount when p.length >= 2:
      final count = r.u16();
      return RingReading('offline recordings: $count', fields: {'count': count});

    case RingOp.sportPause when p.length >= 2:
      return RingReading('sport ${r.u8()} paused=${r.u8()}');
  }
  return null;
}

// ------------------------------------------------------------------ misc

String hex(List<int> bytes, {int max = 48}) {
  final shown = bytes.length > max ? bytes.sublist(0, max) : bytes;
  final s = shown.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return bytes.length > max ? '$s … (+${bytes.length - max})' : s;
}

/// Accepts "01 02", "0102", "0x01,0x02". Null if it is not hex.
List<int>? parseHex(String s) {
  final clean = s.replaceAll(RegExp(r'0x|[\s,]', caseSensitive: false), '');
  if (clean.isEmpty) return const [];
  if (clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean)) {
    return null;
  }
  return [
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}
