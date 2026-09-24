import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'health_store.dart';
import 'ring_ble.dart';
import 'ring_console.dart';
import 'ring_protocol.dart';
import 'sleep_analysis.dart';

enum RingLink {
  /// No ring chosen. Nothing runs.
  unpaired,

  /// Chosen but not connected — waiting to (re)connect.
  idle,
  connecting,

  /// Notifications on, commands accepted.
  ready,
}

/// Opcode 40 from the ring: the tap-and-hold gesture.
class RingButtonEvent {
  const RingButtonEvent(this.pressed, this.at, [this.held]);
  final bool pressed;
  final DateTime at;

  /// On a release, how long it was held.
  final Duration? held;
}

/// The smart ring, for the whole app: one link, all day.
///
/// Before this, the Smart Ring screen owned the link and let go of it in
/// `dispose`, so nothing — hold-to-talk, the 30-minute health sync — could
/// outlive a visit to Settings. Owned by `ringServiceProvider`, started at
/// boot, it now:
///
///  * connects to the paired ring and reconnects with backoff when it drops
///    (the channel already rebuilds a wedged GATT handle twice on its own);
///  * sets the ring's clock on every connect and runs LoraFit's 2 s heartbeat;
///  * syncs health, steps and sleep into [store] on connect and every
///    [syncEvery];
///  * publishes the hold gesture as [buttons] for hold-to-talk;
///  * keeps the process up with RingLinkService while a ring is paired.
///
/// The Smart Ring screen is now a view onto this. Pairing state lives in
/// SharedPreferences (`ring_device`, `ring_name`, `ring_last_sync`) — it is
/// device state, not a user setting, so it is not in the web settings form.
class RingService {
  RingService({HealthStore? store}) : store = store ?? HealthStore();

  final HealthStore store;

  static const heartbeatEvery = Duration(seconds: 2);
  static const syncEvery = Duration(minutes: 30);

  /// How often to check the ring still answers.
  static const probeEvery = Duration(minutes: 2);
  /// Generous: at boot the call agent's RFCOMM attempt at a switched-off
  /// board ties Bluetooth up for ~20 s, and the ring waits behind it.
  static const connectTimeout = Duration(seconds: 40);
  static const _kDevice = 'ring_device';
  static const _kName = 'ring_name';
  static const _kLastSync = 'ring_last_sync';

  // --------------------------------------------------------------- state

  String? _device;
  String _name = '';
  String? get device => _device;
  String get name => _name;
  bool get paired => _device != null;

  /// What the current or last connection was to — the paired ring, or a
  /// candidate the harness is trying.
  String? _target;
  String? get target => _target;

  RingLink _link = RingLink.unpaired;
  RingLink get link => _link;
  bool get ready => _link == RingLink.ready;

  int? battery;
  bool charging = false;
  String? deviceInfo;

  /// Latest live heart rate / SpO₂ / temperature line.
  String? live;

  /// The ring's own running count for today, which it sends on every step —
  /// fresher than the last sync. [liveStepsAt] says which day it is for.
  int? liveSteps, liveCalories, liveDistance;
  DateTime? liveStepsAt;

  /// True while recordings are coming off the ring (RingNotes). A sync then
  /// waits for its next round instead of sharing the command channel.
  bool Function()? transferring;
  int mtu = 23;
  DateTime? lastSync;
  String? lastSyncSummary;
  bool get heartbeatOn => _heartbeat != null;
  bool _syncing = false;
  bool get syncing => _syncing;
  final opCounts = <int, int>{};
  int get discardedBytes => _parser.discarded;

  final _changes = StreamController<void>.broadcast();
  final _messages = StreamController<RingMessage>.broadcast();
  final _audio = StreamController<RingFrame>.broadcast();
  final _buttons = StreamController<RingButtonEvent>.broadcast();
  final _log = StreamController<String>.broadcast();

  /// Something on this object changed — for a screen to rebuild.
  Stream<void> get changes => _changes.stream;

  /// Every decoded-or-not reply, after this service has handled it.
  Stream<RingMessage> get messages => _messages.stream;

  /// Audio packets (0x32–0x34), never reassembled.
  Stream<RingFrame> get audio => _audio.stream;
  Stream<RingButtonEvent> get buttons => _buttons.stream;

  /// Log lines this service writes (they also go to debugPrint).
  Stream<String> get log => _log.stream;

  final _parser = RingStreamParser();
  final _reassembler = RingReassembler();
  final _waiters = <int, Completer<RingMessage?>>{};
  StreamSubscription? _sub;
  Timer? _heartbeat, _syncTimer, _firstSync, _retry, _connectTimer, _probeTimer;
  int _deafProbes = 0;
  int _retries = 0;
  bool _started = false;
  bool _wantConnected = false;
  DateTime? _pressedAt;
  int _heartbeatFailures = 0;

  void _say(String line) {
    debugPrint('[RING] $line');
    if (!_log.isClosed) _log.add(line);
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ----------------------------------------------------------- lifecycle

  /// Idempotent. Called at boot and by the Smart Ring screen.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final p = await SharedPreferences.getInstance();
    _device = p.getString(_kDevice);
    _name = p.getString(_kName) ?? '';
    lastSync = DateTime.tryParse(p.getString(_kLastSync) ?? '');
    _sub = RingBle.events.listen(_onEvent, onError: (e) => _say('!! ble stream: $e'));
    RingConsole.attach(
      send: _consoleSend,
      connected: () => ready,
      actions: {
        'setTime': () async => setTime(),
        'sync': () async => sync(),
        'syncWeek': () async => sync(days: 7),
        'heartbeat': () async => toggleHeartbeat(),
      },
    );
    if (_device == null) {
      _setLink(RingLink.unpaired);
      if (!(p.getBool(_kDeclined) ?? false)) unawaited(_autoSetup());
      return;
    }
    _say('paired with ${_name.isEmpty ? _device : _name} — connecting');
    await connect();
  }

  /// Connects to [id], or to the paired ring. Keeps trying if it is the
  /// paired ring; a harness candidate gets one attempt.
  Future<bool> connect([String? id]) async {
    final target = id ?? _device;
    if (target == null) return false;
    _retry?.cancel();
    _target = target;
    _wantConnected = true;
    _setLink(RingLink.connecting);
    bool ok;
    try {
      ok = await RingBle.connect(target);
    } catch (e) {
      _say('!! connect failed: $e');
      ok = false;
    }
    if (!ok) {
      _say('!! connect refused — Bluetooth off, or no such device');
      _lost();
      return false;
    }
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (ready) return;
      _say('!! no usable link after ${connectTimeout.inSeconds} s — if LoraFit on '
          'a phone holds the ring, disconnect it there');
      RingBle.disconnect();
      _lost();
    });
    return true;
  }

  /// Lets go of the ring until [connect] is called again.
  Future<void> disconnect() async {
    _wantConnected = false;
    _retry?.cancel();
    await RingBle.disconnect();
    _dropLink();
    _setLink(paired ? RingLink.idle : RingLink.unpaired);
  }

  /// Makes [id] the ring this device keeps connected.
  Future<void> pair(String id, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDevice, id);
    await p.setString(_kName, name);
    await p.remove(_kDeclined);
    _device = id;
    _name = name;
    _say('paired with ${name.isEmpty ? id : name} — kept connected from now on');
    if (_target != id || _link == RingLink.idle) {
      await connect(id);
    } else {
      _setLink(_link); // refresh the keep-alive notification
    }
  }

  Future<void> forget() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kDevice);
    await p.remove(_kName);
    await p.remove(_kLastSync);
    // Forgotten on purpose: boot must not pair it straight back. "Pair ring"
    // clears this.
    await p.setBool(_kDeclined, true);
    _device = null;
    _name = '';
    lastSync = null;
    await disconnect();
    await RingBle.keepAlive(on: false);
    _say('ring forgotten');
  }

  void dispose() {
    _sub?.cancel();
    _dropLink();
    _retry?.cancel();
    RingConsole.detach();
    _changes.close();
    _messages.close();
    _audio.close();
    _buttons.close();
    _log.close();
  }

  void _setLink(RingLink l) {
    _link = l;
    _changed();
    if (!paired) return;
    final text = switch (l) {
      RingLink.ready =>
        'Connected${battery == null ? '' : ' · $battery%${charging ? ' charging' : ''}'}',
      RingLink.connecting => 'Connecting…',
      RingLink.idle => 'Waiting for the ring…',
      RingLink.unpaired => '',
    };
    unawaited(RingBle.keepAlive(on: true, text: text).catchError((Object e) {
      _say('!! keep-alive: $e');
    }));
  }

  /// The link is gone. The paired ring is retried; a harness candidate is not.
  void _lost() {
    _probeDone(false);
    _dropLink();
    final retry = _wantConnected && paired && _target == _device;
    _setLink(paired ? RingLink.idle : RingLink.unpaired);
    if (!retry) return;
    final wait = reconnectDelay(_retries++);
    _say('reconnecting in ${wait.inSeconds} s');
    _retry = Timer(wait, () {
      if (_wantConnected && !ready) connect();
    });
  }

  void _dropLink() {
    _probeTimer?.cancel();
    _probeTimer = null;
    _deafProbes = 0;
    _connectTimer?.cancel();
    _heartbeat?.cancel();
    _heartbeat = null;
    _syncTimer?.cancel();
    _firstSync?.cancel();
    for (final w in _waiters.values.toSet()) {
      if (!w.isCompleted) w.complete(null);
    }
    _waiters.clear();
    _parser.reset();
  }

  // -------------------------------------------------------------- events

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'state':
        switch (e['state']) {
          case 'connected':
            _say('connected (status ${e['status']})');
          case 'reconnecting':
            _say('!! ${e['reason']} — the channel is reconnecting '
                '(attempt ${e['attempt']})');
            _heartbeat?.cancel();
            _heartbeat = null;
            _setLink(RingLink.connecting);
          default:
            if (_link == RingLink.unpaired && !_wantConnected) return;
            final was = ready || _link == RingLink.connecting;
            if (was) {
              _say('!! ring disconnected (status ${e['status']})');
            }
            _lost();
        }
      case 'mtu':
        mtu = e['mtu'] as int? ?? mtu;
        _say('MTU $mtu — ${e['ours'] == true ? 'our request' : 'the ring\'s own exchange'}');
      case 'services':
        if (e['repeat'] == true) return;
        _say('services: 33F3 ${e['cmd'] == true ? '✓' : 'MISSING'} · '
            '33F4 ${e['notify'] == true ? '✓' : 'MISSING'} · '
            '2A19 ${e['battery'] == true ? '✓' : 'MISSING'} · '
            '${(e['services'] as List? ?? const []).length} services');
      case 'ready':
        _connectTimer?.cancel();
        if (e['cmd'] != true) {
          _say('!! connected, but no 33F3 command characteristic');
          _probeDone(false);
          return;
        }
        _retries = 0;
        _parser.reset();
        _setLink(RingLink.ready);
        _probeDone(true);
        _say(e['notify'] == true
            ? 'READY — listening on 33F4'
            : '!! 33F4 notifications not confirmed — replies may not arrive');
        unawaited(_opening());
      case 'notify':
        final v = e['value'] as Uint8List;
        if (e['char'] == '2a19') {
          _setBattery(v.isEmpty ? null : v.first);
        } else {
          _onNotify(v);
        }
      case 'read':
        final v = e['value'] as Uint8List;
        if (e['char'] == '2a19' && v.isNotEmpty) _setBattery(v.first);
      case 'error':
        _say('!! ${e['message']}');
    }
  }

  /// LoraFit's opening moves, then our clock and the first sync.
  Future<void> _opening() async {
    await send(RingOp.getDeviceInfo);
    await send(RingOp.getBattery, [0, 0]);
    await send(RingOp.queryDeviceFeature, [0, 0]);
    await setTime();
    _firstSync?.cancel();
    _firstSync = Timer(const Duration(seconds: 3), () => sync());
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncEvery, (_) => sync());
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(probeEvery, (_) => unawaited(probeNow()));
  }

  void _setBattery(int? pct) {
    if (pct == null || pct == battery) return;
    battery = pct;
    if (ready) _setLink(RingLink.ready); // notification text
    _changed();
  }

  void _onNotify(List<int> raw) {
    final before = _parser.discarded;
    final frames = _parser.add(raw);
    if (frames.isEmpty && _parser.discarded > before) {
      _say('RX unframed ${hex(raw)}');
    }
    for (final f in frames) {
      if (RingOp.isAudio(f.opcode)) {
        opCounts[f.opcode] = (opCounts[f.opcode] ?? 0) + 1;
        if (!_audio.isClosed) _audio.add(f);
        continue;
      }
      final m = _reassembler.add(f);
      if (m != null) _onMessage(m);
    }
  }

  DateTime? _stepsLoggedAt;

  void _onMessage(RingMessage m) {
    opCounts[m.opcode] = (opCounts[m.opcode] ?? 0) + 1;
    final w = _waiters.remove(m.opcode);
    if (w != null) {
      _waiters.removeWhere((_, v) => identical(v, w));
      if (!w.isCompleted) w.complete(m);
    }
    final r = decodeRingMessage(m);
    if (m.opcode == RingOp.buttonEvent) {
      _onButton(r?.fields['raw'] as int? ?? -1);
    } else if (r == null) {
      _say('RX ${RingOp.name(m.opcode)}'
          '${m.parts > 1 ? ' (${m.parts} parts)' : ''} len=${m.payload.length}  '
          '${hex(m.payload)}');
    } else {
      switch (m.opcode) {
        case RingOp.getBattery:
          charging = r.fields['charging'] != 0;
          _setBattery(r.fields['percent'] as int?);
        case RingOp.getDeviceInfo:
          deviceInfo = r.summary;
        case RingOp.hrLive || RingOp.spo2Live || RingOp.tempLive:
          live = r.summary;
        case RingOp.getStepInfo:
          liveSteps = r.fields['steps'] as int?;
          liveCalories = r.fields['calories'] as int?;
          liveDistance = r.fields['distance'] as int?;
          final t = r.fields['time'];
          liveStepsAt = t is DateTime ? t : DateTime.now();
        case RingOp.queryDeviceFeature:
          // LoraFit starts its heartbeat on this reply.
          if (_heartbeat == null) toggleHeartbeat();
      }
      // The ring re-reports the day's steps on every step while walking — a
      // line a second that pushed everything else out of the log.
      final steps = r.summary.startsWith('today:');
      final now = DateTime.now();
      if (!steps ||
          _stepsLoggedAt == null ||
          now.difference(_stepsLoggedAt!) >= const Duration(minutes: 1)) {
        if (steps) _stepsLoggedAt = now;
        _say('RX ${r.summary}');
      }
    }
    _changed();
    if (!_messages.isClosed) _messages.add(m);
  }

  /// 1 is press, 2 is release; the vendor app drops anything else.
  void _onButton(int raw) {
    final now = DateTime.now();
    switch (raw) {
      case 1:
        _pressedAt = now;
        _say('BUTTON press');
        if (!_buttons.isClosed) _buttons.add(RingButtonEvent(true, now));
      case 2:
        final held = _pressedAt == null ? null : now.difference(_pressedAt!);
        _pressedAt = null;
        _say('BUTTON release${held == null ? '' : ' — held ${held.inMilliseconds} ms'}');
        if (!_buttons.isClosed) _buttons.add(RingButtonEvent(false, now, held));
      default:
        _say('BUTTON unknown raw=$raw — LoraFit would drop this');
    }
  }

  // ------------------------------------------------------------ commands

  /// True once the ring's stack accepted the write.
  Future<bool> send(int op, [List<int> payload = const [], bool quiet = false]) async {
    if (!ready) {
      if (!quiet) _say('!! not connected — ${RingOp.name(op)} not sent');
      return false;
    }
    final pkt = buildRingPacket(op, payload);
    bool ok;
    try {
      ok = await RingBle.write(pkt);
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      if (!quiet) _say('!! TX ${RingOp.name(op)} failed — not sent');
      return false;
    }
    if (!quiet) _say('TX ${RingOp.name(op)}  ${hex(pkt)}');
    return true;
  }

  /// Sends [op] and waits for its reply — or for any of [replies], which
  /// covers the "nothing for that day" sentinels. Null on timeout or no link.
  Future<RingMessage?> ask(int op, List<int> payload, Set<int> replies,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final c = Completer<RingMessage?>();
    for (final r in replies) {
      _waiters[r] = c;
    }
    if (!await send(op, payload, true)) {
      _waiters.removeWhere((_, v) => identical(v, c));
      return null;
    }
    final m = await c.future.timeout(timeout, onTimeout: () => null);
    _waiters.removeWhere((_, v) => identical(v, c));
    return m;
  }

  /// Local wall-clock seconds, then a zero — as the vendor app sets it.
  Future<bool> setTime() => send(RingOp.setTime, setTimePayload(DateTime.now()));

  void toggleHeartbeat() {
    if (_heartbeat != null) {
      _heartbeat!.cancel();
      _heartbeat = null;
      _say('heartbeat OFF');
    } else {
      _heartbeatFailures = 0;
      _heartbeat = Timer.periodic(heartbeatEvery, (_) async {
        final ok = await send(RingOp.appHeartbeat, const [], true);
        _heartbeatFailures = ok ? 0 : _heartbeatFailures + 1;
        if (_heartbeatFailures == 3) _say('!! heartbeat writes are failing');
      });
      _say('heartbeat ON — 0x3E every ${heartbeatEvery.inSeconds} s, as LoraFit does');
    }
    _changed();
  }

  Future<String> _consoleSend(int op, List<int> payload) async {
    if (!ready) return 'ring not connected';
    _say('WEB → ${RingOp.name(op)}  ${hex(payload)}');
    return await send(op, payload) ? RingConsole.sent : 'not sent — see the log';
  }

  // --------------------------------------------------------------- setup

  static const _kDeclined = 'ring_setup_declined';

  bool _searching = false;

  /// A search for a ring is running (boot's, or the Settings card's).
  bool get searching => _searching;

  /// What that search is doing, in words for the Settings card.
  String? setupStatus;
  Completer<bool>? _probe;

  void _probeDone(bool ok) {
    final c = _probe;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  /// Zero-touch setup. The SR116 pairs with Android as a touch device, so the
  /// ring is usually already in the device's Bluetooth list: try what is there
  /// and keep the first that turns out to speak the ring protocol. No scan —
  /// at boot there is nobody to grant a location permission.
  Future<void> _autoSetup() async {
    final found = await _knownRings();
    if (found.isEmpty || paired) return;
    _say('setup: ${found.length} ring-like device(s) already known to Android — trying');
    _searching = true;
    _changed();
    try {
      await _tryAll(found);
    } finally {
      _searching = false;
      setupStatus = null;
      _changed();
    }
  }

  /// Settings → Smart Ring → Pair ring: what Android knows first, then a
  /// 10-second scan. Returns a sentence for the wearer.
  Future<String> findAndPair() async {
    if (_searching) return 'Already looking…';
    if (paired) return 'Already paired with $_nameOrId';
    _searching = true;
    setupStatus = 'Looking for your ring…';
    _changed();
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kDeclined);
      if (await _tryAll(await _knownRings())) return 'Connected to $_nameOrId';
      setupStatus = 'Scanning nearby…';
      _changed();
      final nearby = await _scanRings(const Duration(seconds: 10));
      if (nearby.isEmpty) {
        return 'No ring found — make sure it is charged and close to the device.';
      }
      if (await _tryAll(nearby)) return 'Connected to $_nameOrId';
      return 'Found a ring but could not connect. If LoraFit on a phone is '
          'connected to it, disconnect it there and try again.';
    } finally {
      _searching = false;
      setupStatus = null;
      _changed();
    }
  }

  String get _nameOrId => _name.isEmpty ? (_device ?? '') : _name;

  /// Ring-like devices Android already knows; ones connected right now first.
  Future<List<({String id, String name})>> _knownRings() async {
    try {
      final all = await RingBle.known();
      all.sort((a, b) => (a['origin'] == 'connected' ? 0 : 1)
          .compareTo(b['origin'] == 'connected' ? 0 : 1));
      return [
        for (final d in all)
          if (looksLikeRing('${d['name'] ?? ''}'))
            (id: '${d['id']}', name: '${d['name'] ?? ''}'),
      ];
    } catch (e) {
      _say('!! setup: could not list devices: $e');
      return const [];
    }
  }

  /// Rings advertising nearby, strongest signal first.
  Future<List<({String id, String name})>> _scanRings(Duration d) async {
    final seen = <String, ({String name, int rssi, bool ring})>{};
    final sub = RingBle.events.listen((e) {
      if (e['type'] != 'scan') return;
      final name = '${e['name'] ?? ''}';
      seen['${e['id']}'] = (
        name: name,
        rssi: e['rssi'] as int? ?? -999,
        ring: e['has56ff'] == true || looksLikeRing(name),
      );
    });
    try {
      if (!await RingBle.startScan(seconds: d.inSeconds)) return const [];
      await Future<void>.delayed(d);
    } catch (e) {
      _say('!! setup: scan failed: $e');
      return const [];
    } finally {
      await sub.cancel();
      try {
        await RingBle.stopScan();
      } catch (_) {}
    }
    final rings = seen.entries.where((e) => e.value.ring).toList()
      ..sort((a, b) => b.value.rssi.compareTo(a.value.rssi));
    return [for (final e in rings) (id: e.key, name: e.value.name)];
  }

  /// Connects to each in turn; pairs the first that really is a ring.
  Future<bool> _tryAll(List<({String id, String name})> found) async {
    for (final c in found) {
      if (paired) return true;
      final label = c.name.isEmpty ? c.id : c.name;
      setupStatus = 'Connecting to $label…';
      _changed();
      _probe = Completer<bool>();
      final started = await connect(c.id);
      final ok = started &&
          await _probe!.future.timeout(connectTimeout + const Duration(seconds: 5),
              onTimeout: () => false);
      _probe = null;
      if (ok) {
        await pair(c.id, c.name);
        _say('setup: paired with $label automatically');
        return true;
      }
      _say('setup: $label is not a ring this device can talk to — next');
      if (_link != RingLink.unpaired) await disconnect();
    }
    return false;
  }

  // ---------------------------------------------------------------- sync

  /// Pulls health, steps and sleep into [store]. [days] forces how many
  /// (today first); otherwise [syncOffsets] decides from the last sync.
  /// Is the ring still actually talking to us?
  ///
  /// A GATT link can go one-way: writes are accepted and nothing ever comes
  /// back, so the app shows "connected" while gestures and health quietly stop
  /// arriving. Asking for the battery is the cheapest question with an answer;
  /// two unanswered in a row and the link is rebuilt.
  Future<bool> probeNow() async {
    if (!ready || _syncing) return true;
    final reply = await ask(RingOp.getBattery, const [0, 0], {RingOp.getBattery},
        timeout: const Duration(seconds: 6));
    if (reply != null) {
      _deafProbes = 0;
      return true;
    }
    _deafProbes++;
    _say('!! the ring did not answer ($_deafProbes)');
    if (_deafProbes < 2) return false;
    _say('!! connected but deaf — rebuilding the link');
    _deafProbes = 0;
    await disconnect();
    if (paired) await connect();
    return false;
  }

  Future<String> sync({int? days}) async {
    if (_syncing) return 'already syncing';
    if (!ready) return 'not connected';
    if (transferring?.call() ?? false) {
      return 'moving recordings off the ring — the next sync picks this up';
    }
    _syncing = true;
    _changed();
    final now = DateTime.now();
    final offsets = days != null
        ? [for (var d = 0; d < days.clamp(1, 7); d++) d]
        : syncOffsets(lastSync, now);
    final heart = <RingHealthRecord>[];
    final steps = <RingStepRecord>[];
    final sleep = <SleepSample>[];
    var complete = true;
    try {
      for (final d in offsets) {
        final h = await ask(RingOp.getHealthRecord, [d],
            {RingOp.getHealthRecord, RingOp.healthEmpty, RingOp.noData42});
        final s = await ask(RingOp.getStepCountInfo, [d],
            {RingOp.getStepCountInfo, RingOp.noData42});
        final z = await ask(RingOp.getSleepData, [d],
            {RingOp.getSleepData, RingOp.sleepEmpty, RingOp.noData42});
        if (!ready) {
          complete = false;
          break;
        }
        if (h?.opcode == RingOp.getHealthRecord) heart.addAll(parseHealthRecords(h!.payload));
        if (s?.opcode == RingOp.getStepCountInfo) steps.addAll(parseStepRecords(s!.payload));
        if (z?.opcode == RingOp.getSleepData) sleep.addAll(parseSleepSamples(z!.payload));
      }
      final touched = await store.add(heart: heart, steps: steps, sleep: sleep);
      final summary = '${heart.length} heart · ${steps.length} step · '
          '${sleep.length} sleep records over ${offsets.length} day(s) · '
          '${touched.length} day(s) updated';
      if (complete) {
        lastSync = now;
        final p = await SharedPreferences.getInstance();
        await p.setString(_kLastSync, now.toIso8601String());
      }
      lastSyncSummary = summary;
      _say('SYNC ${complete ? 'done' : 'cut short by the link'}: $summary');
      return summary;
    } catch (e) {
      _say('!! sync failed: $e');
      return 'sync failed: $e';
    } finally {
      _syncing = false;
      _changed();
    }
  }
}

/// Which day offsets to fetch: all seven the ring keeps the first time; after
/// that, every day since the last sync plus one, and never fewer than today
/// and yesterday — last night's sleep starts on yesterday's page.
List<int> syncOffsets(DateTime? lastSync, DateTime now) {
  if (lastSync == null) return [for (var d = 0; d < 7; d++) d];
  final since = dayOf(now).difference(dayOf(lastSync)).inDays;
  final n = (since + 2).clamp(2, 7);
  return [for (var d = 0; d < n; d++) d];
}

/// Back off, but never give up on a paired ring: 5 s, 15 s, 30 s, then every
/// minute.
Duration reconnectDelay(int attempt) =>
    Duration(seconds: const [5, 15, 30, 60][attempt.clamp(0, 3)]);

/// Worth trying as a ring: JY/LoraFit rings name themselves like
/// `SR116-0767` or `R02_1A2B`. Earbuds, the call board and the device's own
/// devices must not match — every match costs a connection attempt.
bool looksLikeRing(String name) => RegExp(
      r'^(SR|R)\d{2,3}(?!\d)|smart ?ring|\bring\b|\blora|\bjy\b',
      caseSensitive: false,
    ).hasMatch(name.trim());
