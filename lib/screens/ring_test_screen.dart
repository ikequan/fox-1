import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/providers.dart';
import '../services/notes/ring_notes.dart';
import '../services/ring/health_store.dart';
import '../services/ring/ring_audio.dart';
import '../services/ring/ring_ble.dart';
import '../services/ring/ring_input.dart';
import '../services/ring/ring_console.dart';
import '../services/ring/ring_protocol.dart';
import '../services/ring/ring_service.dart';
import '../services/ring/stress_estimator.dart';

/// Bring-up harness for the JY smart ring — a view onto [RingService].
///
/// The link belongs to the service, not to this screen: a paired ring stays
/// connected after you leave. A ring you only connect to here (not "Use this
/// ring") is let go when the screen closes, as before.
///
///  1. **HID** — the ring is also a Bluetooth touchscreen that injects one of
///     two canned swipes (tap/swipe → up, double-tap → down). FOX-1 can
///     swallow them while it is in front.
///  2. **BLE** — connect, pair, and see what the link is doing. The hold
///     gesture arrives as opcode 40, 1 = press, 2 = release.
///  3. **Commands** — every opcode that has been tried on hardware.
///  4. **Recordings** — move quadruple-tap recordings to the device.
///  5. **Health** — sync the seven days the ring keeps into the device's own
///     store, and see last night, each day, and the week.
///
/// Every command is also a button at `http://<device-ip>:8080/ring`.
class RingTestScreen extends ConsumerStatefulWidget {
  const RingTestScreen({super.key});

  @override
  ConsumerState<RingTestScreen> createState() => _RingTestScreenState();
}

class _Candidate {
  _Candidate(this.id, this.origin);
  final String id;
  String origin;
  String name = '';
  int? rssi;

  /// Advertises the `56FF` command service — the strongest sign this is it.
  bool has56ff = false;

  String get label => name.isEmpty ? '(no name)' : name;

  bool get looksLikeRing =>
      has56ff ||
      RegExp(r'ring|jy|lora|sr\d{3}|r\d{2}', caseSensitive: false).hasMatch(name);
}

class _ButtonHit {
  _ButtonHit(this.at, this.pressed, this.meaning);
  final DateTime at;
  final bool pressed;
  final String meaning;
}

class _RingTestScreenState extends ConsumerState<RingTestScreen> {
  late RingService _ring;
  final _subs = <StreamSubscription>[];
  final _log = <String>[];
  final _logScroll = ScrollController();
  final _stamp = DateFormat('HH:mm:ss.SSS');

  // --- HID ---
  List<Map<String, dynamic>> _inputDevices = [];
  bool _blockTouches = false;

  /// Ring HID gestures by kind — tap the ring a few times, then double-tap,
  /// then swipe, and watch which counter moves. That is the mapping.
  final _hidCounts = <String, int>{};
  String _deviceSig = '';

  // --- BLE ---
  final _found = <String, _Candidate>{};
  String? _selected;
  bool _scanning = false;
  int _day = 0;
  final _buttons = <_ButtonHit>[];
  DateTime? _lastReleaseAt;
  final _customOp = TextEditingController(text: '25');
  final _customPayload = TextEditingController();

  // --- Recordings ---
  /// Production's pipeline (RingNotes) moves and transcribes recordings; this
  /// screen shows it, and can start a pull by hand.
  late RingNotes _notes;
  int _liveAudioFrames = 0;
  final _saved = <String>[];

  // --- Health ---
  NightSummary? _lastNight;
  List<DaySummary> _days = const [];
  HealthReport? _week;
  bool _wasSyncing = false;

  @override
  void initState() {
    super.initState();
    _ring = ref.read(ringServiceProvider);
    _notes = ref.read(ringNotesProvider);
    unawaited(_ring.start());
    _subs.addAll([
      // The shared stream, not a second one of our own: both would sit on the
      // one native sink, and closing this screen would cut production's
      // gestures off with it.
      RingInput.events.listen(_onInput,
          onError: (e) => _append('!! input stream: $e')),
      RingBle.events.listen(_onScanEvent),
      _ring.log.listen(_panel),
      _ring.changes.listen((_) => _onRingChanged()),
      _ring.messages.listen(_onMessage),
      _ring.audio.listen(_onAudio),
      _ring.buttons.listen(_onButton),
      _notes.puller.changes.listen((_) {
        if (mounted) setState(() {});
      }),
      _notes.store.changes.listen((_) => unawaited(_loadSaved())),
    ]);
    RingConsole.setScreenActions({'moveAll': _moveAll});
    unawaited(_loadInputDevices());
    unawaited(_startBle());
    unawaited(_loadSaved());
    unawaited(_loadHealth());
  }

  @override
  void dispose() {
    RingConsole.setScreenActions(null);
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    RingBle.stopScan();
    // A ring that was only being tried is let go, so LoraFit on a phone can
    // have it back. A paired ring stays with the service.
    if (!_ring.paired && _ring.link != RingLink.unpaired) _ring.disconnect();
    if (!_ring.paired && _ring.link == RingLink.connecting) _ring.disconnect();
    _customOp.dispose();
    _customPayload.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// A line from this screen: to the log buffer and the panel.
  void _append(String line) {
    debugPrint('[RING] $line');
    _panel(line);
  }

  /// Onto the panel only — the service already debugPrinted it.
  void _panel(String line) {
    _log.add('${_stamp.format(DateTime.now())}  $line');
    if (_log.length > 400) _log.removeRange(0, _log.length - 400);
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void _onRingChanged() {
    if (_wasSyncing && !_ring.syncing) unawaited(_loadHealth());
    _wasSyncing = _ring.syncing;
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ HID

  Future<void> _loadInputDevices() async {
    try {
      final list = await RingInput.listInputDevices();
      if (!mounted) return;
      setState(() => _inputDevices = list);
      final physical = _inputDevices.where((d) => d['virtual'] != true).toList();
      final sig = physical.map((d) => '${d['name']}|${d['sources']}').join(',');
      if (sig != _deviceSig) {
        _deviceSig = sig;
        for (final d in physical) {
          _append('input device: ${d['name']} · ${d['sources']}'
              ' · vendor ${d['vendor']} product ${d['product']}');
        }
      }
    } catch (e) {
      _append('!! input devices: $e');
    }
  }

  /// Only EXTERNAL devices reach here — RingInputChannel drops the device's
  /// own touchscreen, buttons and virtual keyboard.
  void _onInput(dynamic raw) {
    if (raw is! Map) return;
    final e = raw.map((k, v) => MapEntry(k.toString(), v));
    switch (e['type']) {
      case 'key':
        _append('RING HID KEY ${e['action']} ${e['name']} code=${e['code']}'
            '  [${e['device']} · ${e['source']}]');
      case 'motion':
        _append('RING HID MOTION ${e['action']}'
            ' x=${(e['x'] as num).toStringAsFixed(0)} y=${(e['y'] as num).toStringAsFixed(0)}'
            '  [${e['device']} · ${e['source']}]');
      case 'touch':
        // The UP carries the whole gesture.
        if (!e.containsKey('ms')) return;
        final x = (e['x'] as num).toDouble(), y = (e['y'] as num).toDouble();
        final dx = (e['dx'] as num).toDouble(), dy = (e['dy'] as num).toDouble();
        final ms = (e['ms'] as num).toInt();
        final g = _gesture(dx, dy, ms);
        _hidCounts[g] = (_hidCounts[g] ?? 0) + 1;
        _append('RING HID $g  (${(x - dx).toStringAsFixed(0)},${(y - dy).toStringAsFixed(0)}'
            '→${x.toStringAsFixed(0)},${y.toStringAsFixed(0)}, ${ms}ms)'
            '${e['blocked'] == true ? ' — BLOCKED' : ''}  [${e['device']}]');
      case 'device':
        if (e['id'] == -1 || e['name'] == 'Virtual') return;
        _append('input device ${e['change']}: ${e['name']} (id ${e['id']})');
        unawaited(_loadInputDevices());
    }
  }

  String _gesture(double dx, double dy, int ms) {
    if (dx.abs() < 24 && dy.abs() < 24) return ms < 350 ? 'TAP' : 'HOLD';
    if (dx.abs() > dy.abs()) return dx > 0 ? 'SWIPE right' : 'SWIPE left';
    return dy > 0 ? 'SWIPE down' : 'SWIPE up';
  }

  Future<void> _setBlocking(bool on) async {
    try {
      _blockTouches = await RingInput.setBlockExternal(on);
      _append(_blockTouches
          ? 'BLOCKING the ring\'s HID touches inside FOX-1'
          : 'ring HID touches pass through again');
    } catch (e) {
      _append('!! block: $e');
    }
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ BLE

  Future<void> _startBle() async {
    final res = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final denied = [
      for (final e in res.entries)
        if (!e.value.isGranted) e.key.toString().split('.').last,
    ];
    if (denied.isNotEmpty) {
      _append('!! not granted: ${denied.join(', ')} — scanning may find nothing');
    }
    await _loadKnown();
  }

  /// A ring paired in Android settings is connected as an HID device and may
  /// not advertise at all; the system list finds it without a scan.
  Future<void> _loadKnown() async {
    try {
      for (final d in await RingBle.known()) {
        final c = _addCandidate(d['id'].toString(), d['origin'].toString());
        if ((d['name']?.toString() ?? '').isNotEmpty) c.name = d['name'].toString();
        _selected ??= c.looksLikeRing ? c.id : null;
      }
    } catch (e) {
      _append('!! known devices: $e');
    }
    if (mounted) setState(() {});
  }

  _Candidate _addCandidate(String id, String origin) {
    final c = _found.putIfAbsent(id, () => _Candidate(id, origin));
    if (origin == 'connected') c.origin = origin;
    return c;
  }

  void _onScanEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'scanState':
        if (mounted) setState(() => _scanning = e['scanning'] == true);
      case 'scan':
        final c = _addCandidate(e['id'].toString(), 'scan');
        c.rssi = e['rssi'] as int?;
        final n = e['name']?.toString() ?? '';
        if (n.isNotEmpty) c.name = n;
        if (e['has56ff'] == true) c.has56ff = true;
        if (_selected == null && c.looksLikeRing) _selected = c.id;
        if (mounted) setState(() {});
    }
  }

  Future<void> _scan() async {
    if (_scanning) {
      await RingBle.stopScan();
      return;
    }
    _append('scanning 10 s…');
    if (!await RingBle.startScan(seconds: 10)) {
      _append('!! scan could not start — Bluetooth off?');
    }
  }

  Future<void> _connect() async {
    final id = _selected ?? _ring.device;
    if (id == null) return;
    _append('connecting to ${_found[id]?.label ?? id}…');
    await _ring.connect(id);
  }

  String get _ringLabel {
    final id = _ring.target ?? _ring.device;
    if (id == null) return '—';
    final c = _found[id];
    if (c != null && c.name.isNotEmpty) return c.name;
    return id == _ring.device && _ring.name.isNotEmpty ? _ring.name : id;
  }

  Future<void> _pairCurrent() async {
    final id = _ring.target;
    if (id == null) return;
    await _ring.pair(id, _found[id]?.name ?? '');
  }

  void _onButton(RingButtonEvent b) {
    String meaning;
    if (b.pressed) {
      final gap = _lastReleaseAt == null
          ? null
          : b.at.difference(_lastReleaseAt!).inMilliseconds;
      meaning = gap != null && gap < 450 ? 'PRESS — ${gap}ms after release' : 'PRESS';
    } else {
      _lastReleaseAt = b.at;
      meaning = b.held == null ? 'RELEASE' : 'RELEASE — held ${b.held!.inMilliseconds}ms';
    }
    _buttons.insert(0, _ButtonHit(b.at, b.pressed, meaning));
    if (_buttons.length > 12) _buttons.removeLast();
    if (mounted) setState(() {});
  }

  /// The service logs each reply's summary; the harness adds the records of
  /// a history reply it asked for. Recordings are RingNotes' business.
  void _onMessage(RingMessage m) {
    if (_ring.syncing) return;
    final r = decodeRingMessage(m);
    if (r == null) return;
    for (final line in r.lines.take(24)) {
      _panel('    $line');
    }
    if (r.lines.length > 24) _panel('    … ${r.lines.length - 24} more');
  }

  // ----------------------------------------------------------- recordings

  void _onAudio(RingFrame f) {
    // Offline files (0x34) are RingNotes' — it moves and acknowledges them.
    if (f.opcode == RingOp.audioOffline) return;
    // Live audio (0x32 online recording, 0x33 AI dialog). Counted, not
    // played, for now.
    final a = parseRingAudioPayload(f.payload);
    if (_liveAudioFrames == 0 && a.frames.isNotEmpty) {
      _append('LIVE AUDIO ${RingOp.name(f.opcode)} started — '
          '${describeOpusToc(a.frames.first.first)}');
    }
    _liveAudioFrames += a.frames.length;
    if (_liveAudioFrames % 250 < a.frames.length) {
      _append('live audio: ${_liveAudioFrames * ringOpusFrameMs ~/ 1000} s so far');
    }
  }

  /// Production's pull, started by hand. Progress shows in the panel above
  /// and as [NOTES] lines in the log.
  Future<void> _moveAll() async {
    if (_notes.puller.busy) return;
    _append('moving recordings to the device — see the [NOTES] lines');
    await _notes.puller.pullAll();
  }

  Future<void> _stopTransfer() async {
    await _ring.send(RingOp.stopOfflineTransfer);
    _notes.puller.abandon('stopped by hand');
    _append('transfer stopped; the file in progress stays on the ring');
  }

  Future<void> _loadSaved() async {
    final notes = await _notes.store.all();
    _saved
      ..clear()
      ..addAll([
        for (final n in notes) '${n.id} · ${n.title ?? n.status.name}',
      ]);
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- health

  Future<void> _loadHealth() async {
    final now = DateTime.now();
    final store = _ring.store;
    final today = await store.summary(now);
    final days = await store.between(DateTime(now.year, now.month, now.day - 6), now);
    final week = await store.report(ReportPeriod.week, now);
    if (!mounted) return;
    setState(() {
      _lastNight = today?.night;
      _days = days;
      _week = week;
    });
  }

  /// All seven days the ring keeps, into the store, then what the store makes
  /// of them.
  Future<void> _syncWeek() async {
    if (_ring.syncing) return;
    await _ring.sync(days: 7);
    await _loadHealth();
    final now = DateTime.now();
    final heart = <RingHealthRecord>[];
    for (var d = 0; d < 7; d++) {
      heart.addAll((await _ring.store.raw(DateTime(now.year, now.month, now.day - d)))
          .heartRecords);
    }
    final q = cleanHeartRate(heart).quality;
    _append('HR quality: ${q.readings} readings'
        '${q.fillValue == null ? '' : ' · ${q.fillValue} bpm is '
            '${(q.filled * 100 / q.readings).round()}% of them — the ring\'s '
            '"no reading", dropped'}'
        ' · ${q.spikes} isolated spikes dropped');
    final n = _lastNight;
    _append(n == null
        ? 'LAST NIGHT: no sleep between 18:00 yesterday and noon today'
        : 'LAST NIGHT: ${_nightLine(n)} — compare with LoraFit');
    for (final d in _days.reversed) {
      _append('DAY ${dayKey(d.day)}: ${d.steps ?? '—'} steps · '
          'HR ${d.hr == null ? '—' : '${d.hr!.avg} (${d.hr!.min}–${d.hr!.max})'} · '
          'sleep ${d.night == null ? '—' : _hm(d.night!.asleep)} · '
          'stress ${d.stress ?? '—'}${d.stress != null && d.stressProvisional ? ' provisional' : ''}');
    }
  }

  String _hm(int m) => '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}';

  String _nightLine(NightSummary n) {
    final t = DateFormat('HH:mm');
    return '${_hm(n.asleep)} (${t.format(n.fellAsleep)} → ${t.format(n.woke)}) · '
        'deep ${n.deep}m · light ${n.light}m · REM ${n.rem}m · awake ${n.awake}m · '
        'score ${n.score} (${n.label})';
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final cands = _found.values.toList()
      ..sort((a, b) {
        if (a.looksLikeRing != b.looksLikeRing) return a.looksLikeRing ? -1 : 1;
        return (b.rssi ?? -999).compareTo(a.rssi ?? -999);
      });
    final hid = _inputDevices.where((d) => d['virtual'] != true).toList();
    final ready = _ring.ready;
    final linked = _ring.link == RingLink.ready || _ring.link == RingLink.connecting;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Smart Ring', style: TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () {
              _loadInputDevices();
              _loadKnown();
              _loadHealth();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          // --- 1 · HID ---
          _label('1 · Touch as a key (HID)'),
          _panelBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stat('ring HID', _hidCounts.isEmpty
                    ? 'nothing yet'
                    : _hidCounts.entries.map((e) => '${e.key} ×${e.value}').join('   ')),
                const SizedBox(height: 4),
                if (hid.isEmpty)
                  const Text('no physical input devices',
                      style: TextStyle(color: Colors.white38, fontSize: 10))
                else
                  for (final d in hid)
                    Text('${d['name']} · ${d['sources']}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _chip(_blockTouches ? 'Block ring touches: ON' : 'Block ring touches: off',
                  () => _setBlocking(!_blockTouches),
                  on: _blockTouches),
            ],
          ),
          _hint('Tap and swipe → a canned swipe up; double-tap → down. Only inside '
              'FOX-1 — other apps still receive the ring\'s swipes.'),

          // --- 2 · BLE ---
          const SizedBox(height: 12),
          _label('2 · Ring over BLE'),
          _panelBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stat('paired', _ring.paired
                    ? '${_ring.name.isEmpty ? _ring.device : _ring.name} — kept connected'
                    : 'no ring paired'),
                _stat('link', switch (_ring.link) {
                  RingLink.unpaired => 'off',
                  RingLink.idle => 'waiting to reconnect',
                  RingLink.connecting => 'connecting…',
                  RingLink.ready => 'ready',
                }, bad: _ring.link == RingLink.idle),
                if (_ring.lastSync != null)
                  _stat('synced', '${DateFormat('MM-dd HH:mm').format(_ring.lastSync!)}'
                      '${_ring.syncing ? ' · syncing now' : ''}'),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _button(_scanning ? 'Stop scan' : 'Scan 10 s', _scan,
                    enabled: !linked),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: linked
                    ? _button(ready ? 'Disconnect' : 'Connecting… (cancel)',
                        () => _ring.disconnect(),
                        danger: true)
                    : _button('Connect', _connect,
                        enabled: _selected != null || _ring.paired),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (!linked)
            for (final c in cands.take(8)) _candidateTile(c),
          if (!linked && cands.isEmpty)
            _hint('Nothing yet. A paired ring may not advertise — it should '
                'show as "paired" or "connected" without a scan.'),
          if (linked)
            _panelBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _stat('ring', _ringLabel),
                  _stat('MTU', '${_ring.mtu}'),
                  _stat('battery', _ring.battery == null
                      ? '—'
                      : '${_ring.battery}%${_ring.charging ? ' · charging' : ''}'),
                  _stat('device', _ring.deviceInfo ?? '—'),
                  _stat('live', _ring.live ?? 'tap HR on'),
                  _stat('opcodes', _ring.opCounts.isEmpty
                      ? 'none received'
                      : _ring.opCounts.entries
                          .map((e) => '${RingOp.name(e.key)}×${e.value}')
                          .join('  ')),
                  if (_ring.discardedBytes > 0)
                    _stat('discard', '${_ring.discardedBytes} bytes', bad: true),
                ],
              ),
            ),
          if (ready) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (_ring.target != _ring.device)
                  _chip('Use this ring', _pairCurrent, on: true),
                if (_ring.paired) _chip('Forget ring', () => _ring.forget()),
              ],
            ),
            _hint('"Use this ring" keeps it connected all day — through screen-off '
                'and restarts — and syncs its health every 30 minutes.'),
          ],

          // --- 3 · Commands ---
          if (ready) ...[
            const SizedBox(height: 12),
            _label('3 · Ask the ring'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip('Battery', () => _ring.send(RingOp.getBattery, [0, 0])),
                _chip('Device info', () => _ring.send(RingOp.getDeviceInfo)),
                _chip('Features', () => _ring.send(RingOp.queryDeviceFeature, [0, 0])),
                _chip('Set time', () => _ring.setTime()),
                _chip('Steps', () => _ring.send(RingOp.getStepCountInfo, [_day])),
                _chip('Step info', () => _ring.send(RingOp.getStepInfo)),
                _chip('Sleep', () => _ring.send(RingOp.getSleepData, [_day])),
                _chip('Health', () => _ring.send(RingOp.getHealthRecord, [_day])),
                _chip('HR on', () => _ring.send(RingOp.openHeartRate)),
                _chip('HR off', () => _ring.send(RingOp.closeHeartRate)),
                _chip('SpO₂ on', () => _ring.send(RingOp.openCloseSpo2, [1])),
                _chip('SpO₂ off', () => _ring.send(RingOp.openCloseSpo2, [0])),
                _chip('Audio state', () => _ring.send(RingOp.queryAudioState, [0, 0])),
                _chip(_ring.heartbeatOn ? 'Heartbeat: ON' : 'Heartbeat: off',
                    () => _ring.toggleHeartbeat(),
                    on: _ring.heartbeatOn),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('day ', style: TextStyle(color: Colors.white38, fontSize: 10)),
                for (var d = 0; d <= 6; d++)
                  _chip(d == 0 ? 'today' : '-$d', () => setState(() => _day = d),
                      on: _day == d),
              ],
            ),
            const SizedBox(height: 8),
            _label('Custom command'),
            Row(
              children: [
                SizedBox(width: 52, child: _field(_customOp, 'op hex')),
                const SizedBox(width: 6),
                Expanded(child: _field(_customPayload, 'payload hex')),
                const SizedBox(width: 6),
                _chip('Send', _sendCustom),
              ],
            ),
            _hint('Every command is also a button at http://<device-ip>:8080/ring.'),

            // --- 4 · Recordings ---
            const SizedBox(height: 12),
            _label('4 · Recordings (quadruple tap)'),
            _panelBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _stat('on ring',
                      _notes.puller.onRing == null ? '—' : '${_notes.puller.onRing}'),
                  _stat('transfer', _notes.puller.status ?? 'idle'),
                  for (final s in _saved.take(4)) _stat('saved', s),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip('Count', () => _ring.send(RingOp.offlineFileCount)),
                _chip(_notes.puller.busy ? 'Moving…' : 'Move all to device',
                    _notes.puller.busy ? () {} : _moveAll),
                if (_notes.puller.busy) _chip('Stop', _stopTransfer),
              ],
            ),
            _hint('Recordings come over on their own when the ring reports one '
                'finished, then get transcribed as voice notes. This moves them now. '
                'Read and listen at http://<device-ip>:8080/api/ring/recordings.'),

            // --- 5 · Health ---
            const SizedBox(height: 12),
            _label('5 · Health (the device\'s own history)'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(_ring.syncing ? 'Syncing…' : 'Sync 7 days',
                    _ring.syncing ? () {} : _syncWeek,
                    on: _ring.syncing),
                _chip('Sync now', () => _ring.sync()),
              ],
            ),
          ],
          if (_lastNight != null) ...[
            const SizedBox(height: 6),
            _panelBox(child: _nightView(_lastNight!)),
          ],
          if (_days.isNotEmpty) ...[
            const SizedBox(height: 6),
            _panelBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Last 7 days — stress is estimated from heart rate, not HRV',
                      style: TextStyle(color: Colors.white38, fontSize: 10)),
                  const SizedBox(height: 4),
                  for (final d in _days.reversed) _dayRow(d),
                  if (_week != null) ...[
                    const Divider(color: Colors.white12, height: 12),
                    _weekRow(_week!.total),
                  ],
                ],
              ),
            ),
          ],
          _hint('Kept on the device — the ring only holds seven days. JSON for every '
              'period at http://<device-ip>:8080/api/ring/health.'),

          // --- Gestures ---
          const SizedBox(height: 12),
          _label('Gestures received (BLE opcode 40)'),
          _panelBox(
            child: _buttons.isEmpty
                ? const Text('hold the ring',
                    style: TextStyle(color: Colors.white38, fontSize: 10))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final b in _buttons)
                        Text('${DateFormat('HH:mm:ss').format(b.at)}  ${b.meaning}',
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontFamily: 'monospace')),
                    ],
                  ),
          ),

          // --- Log ---
          const SizedBox(height: 12),
          _label('Log'),
          Container(
            height: 240,
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(6),
            child: ListView.builder(
              controller: _logScroll,
              itemCount: _log.length,
              itemBuilder: (_, i) {
                final l = _log[i];
                return Text(l,
                    style: TextStyle(
                        color: l.contains('!!')
                            ? Colors.redAccent
                            : l.contains('BUTTON') ||
                                    l.contains('RING HID') ||
                                    l.contains('SAVED') ||
                                    l.contains('SYNC') ||
                                    l.contains('READY') ||
                                    l.contains('LAST NIGHT')
                                ? const Color(0xFF00E5CC)
                                : Colors.white60,
                        fontSize: 9,
                        fontFamily: 'monospace'));
              },
            ),
          ),
        ],
      ),
    );
  }

  void _sendCustom() {
    final op = int.tryParse(_customOp.text.trim().replaceAll('0x', ''), radix: 16);
    final payload = parseHex(_customPayload.text);
    if (op == null || payload == null) {
      _append('!! custom: opcode and payload must be hex');
      return;
    }
    _ring.send(op, payload);
  }

  Widget _nightView(NightSummary n) {
    final t = DateFormat('HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_hm(n.asleep), style: const TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(width: 8),
            Text('${t.format(n.fellAsleep)} → ${t.format(n.woke)}',
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
            const Spacer(),
            Text('${n.score} ${n.label}',
                style: const TextStyle(color: Color(0xFF00E5CC), fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        _stat('deep', '${n.deep} min'),
        _stat('light', '${n.light} min'),
        _stat('REM', '${n.rem} min'),
        _stat('awake', '${n.awake} min · ${n.bouts} bouts'),
      ],
    );
  }

  Widget _dayRow(DaySummary d) {
    final band = d.stress == null ? null : stressBand(d.stress!);
    final color = switch (band) {
      StressBand.rest => const Color(0xFF4FC3F7),
      StressBand.low => const Color(0xFF81C784),
      StressBand.medium => const Color(0xFFFFB74D),
      StressBand.high => const Color(0xFFE57373),
      null => Colors.white38,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(DateFormat('MM-dd').format(d.day),
                style: const TextStyle(
                    color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
          ),
          Expanded(
            child: Text(
                '${d.steps ?? '—'} steps · HR ${d.hr?.avg ?? '—'} · '
                'sleep ${d.night == null ? '—' : _hm(d.night!.asleep)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ),
          Text(d.stress == null ? '—' : '${d.stress} ${band!.name}${d.stressProvisional ? '*' : ''}',
              style: TextStyle(color: color, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _weekRow(Aggregate w) => Text(
        'Week: ${w.stepsPerDay ?? '—'} steps/day · HR ${w.hrAvg ?? '—'} · '
        'sleep ${w.sleepMinutes == null ? '—' : _hm(w.sleepMinutes!)} over ${w.nights} '
        'night(s), score ${w.sleepScore ?? '—'} · stress ${w.stress ?? '—'}'
        '   (* provisional)',
        style: const TextStyle(color: Colors.white54, fontSize: 10),
      );

  Widget _candidateTile(_Candidate c) {
    final sel = _selected == c.id;
    return GestureDetector(
      onTap: () => setState(() => _selected = c.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF1A3A2A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${c.looksLikeRing ? '★ ' : ''}${c.label}'
                      '${c.id == _ring.device ? '  (paired)' : ''}',
                      style: TextStyle(
                          color: sel ? const Color(0xFF00E5CC) : Colors.white,
                          fontSize: 11)),
                  Text('${c.id} · ${c.origin}${c.has56ff ? ' · 56FF' : ''}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 9, fontFamily: 'monospace')),
                ],
              ),
            ),
            if (c.rssi != null)
              Text('${c.rssi}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _button(String text, VoidCallback onTap,
          {bool enabled = true, bool danger = false}) =>
      ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: danger ? const Color(0xFF3A1A1A) : const Color(0xFF1A1A1A),
          foregroundColor: danger ? Colors.redAccent : const Color(0xFF00E5CC),
          padding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onPressed: enabled ? onTap : null,
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );

  Widget _chip(String text, VoidCallback onTap, {bool on = false}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF1A3A2A) : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(text,
              style: TextStyle(
                  color: on ? const Color(0xFF00E5CC) : Colors.white70, fontSize: 11)),
        ),
      );

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true,
          fillColor: const Color(0xFF1A1A1A),
          border: InputBorder.none,
        ),
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 2),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 9,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
      );

  Widget _panelBox({required Widget child}) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: child,
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: const TextStyle(color: Colors.white38, fontSize: 10, height: 1.3)),
      );

  Widget _stat(String k, String v, {bool bad = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 60,
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10, fontFamily: 'monospace')),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      color: bad ? Colors.orangeAccent : Colors.white,
                      fontSize: 11,
                      fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
