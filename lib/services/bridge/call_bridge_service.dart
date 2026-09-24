import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the ESP32 call-audio bridge bring-up harness.
///
/// This drives the five test stages in `spp-app-integration.md` §7 and nothing
/// else — it is deliberately not wired into the AI session. Everything the
/// Kotlin side observes arrives here as events and is pushed through
/// `debugPrint` so it lands in LogBuffer and is readable at
/// `http://<device-ip>:8080/logs` — there is no ADB on this device.
class CallBridgeService {
  static const _method = MethodChannel('ai.fox1/call_bridge');
  static const _events = EventChannel('ai.fox1/call_bridge_events');

  final _logs = StreamController<String>.broadcast();
  final _stats = StreamController<BridgeStats>.broadcast();
  final _callerPcm = StreamController<Uint8List>.broadcast();
  StreamSubscription? _sub;

  Stream<String> get logs => _logs.stream;
  Stream<BridgeStats> get stats => _stats.stream;

  /// Stage 7 only: the caller's voice, PCM16 mono @16 kHz — already the rate
  /// Gemini Live wants, so it needs no resampling on the way in.
  Stream<Uint8List> get callerPcm => _callerPcm.stream;

  /// Call-state transitions as they happen, rather than up to a second late
  /// via [stats]. A call ending is the moment stale agent speech has to be
  /// dropped, so it cannot wait for the next stats tick.
  Stream<BridgeCallState> get callStates => _callStates.stream;
  final _callStates = StreamController<BridgeCallState>.broadcast();

  BridgeStats _last = const BridgeStats();
  BridgeStats get lastStats => _last;

  void listen() {
    _sub ??= _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final map = Map<String, dynamic>.from(event);
        switch (map['type']) {
          case 'log':
            final msg = map['msg']?.toString() ?? '';
            debugPrint('[BRIDGE] $msg');
            _logs.add(msg);
            break;
          case 'pcm':
            final pcm = map['pcm'];
            if (pcm is Uint8List) _callerPcm.add(pcm);
            break;
          case 'callstate':
            _callStates.add(BridgeCallState(
              call: _asInt(map['call']),
              setup: _asInt(map['setup']),
              initial: map['initial'] == true,
              closing: map['closing'] == true,
            ));
            break;
          case 'stats':
            _last = BridgeStats.fromMap(map);
            _stats.add(_last);
            break;
        }
      },
      onError: (e) => debugPrint('[BRIDGE] event error: $e'),
    );
  }

  Future<List<PairedDevice>> listPaired() async {
    try {
      final res = await _method.invokeListMethod<dynamic>('listPaired');
      return (res ?? [])
          .map((e) => PairedDevice.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      debugPrint('[BRIDGE] listPaired failed: $e');
      return [];
    }
  }

  /// Returns null on success, or the reason it failed.
  /// [autoArm] false leaves the board off the HFP slot until something calls
  /// [arm] — the arm-on-demand experiment. The board then reports no call
  /// state at all, so the ring has to come from telephony instead.
  Future<String?> start({
    required String address,
    required int stage,
    String source = 'tone',
    bool autoArm = true,
  }) async {
    try {
      final res = await _method.invokeMapMethod<String, dynamic>(
        'start',
        {
          'address': address,
          'stage': stage,
          'source': source,
          'autoArm': autoArm,
        },
      );
      if (res?['success'] == true) return null;
      return res?['error']?.toString() ?? 'start failed';
    } catch (e) {
      return '$e';
    }
  }

  /// Stage 7: put this process's traffic on cellular before Gemini connects.
  ///
  /// Must be awaited BEFORE opening the WebSocket — binding does not move
  /// sockets that are already open.
  Future<bool> prepareNetwork({bool disableWifi = false}) async {
    try {
      final res = await _method.invokeMapMethod<String, dynamic>(
          'prepareNetwork', {'disableWifi': disableWifi});
      return res?['cellular'] == true;
    } catch (e) {
      debugPrint('[BRIDGE] prepareNetwork failed: $e');
      return false;
    }
  }

  /// Undo [prepareNetwork].
  ///
  /// The bind is process-wide, so it also captures anything else this app
  /// listens on — the settings web server included, which is how it became
  /// unreachable from the LAN once the agent started binding at boot.
  Future<void> unbindNetwork() async {
    try {
      await _method.invokeMethod('unbindNetwork');
    } catch (e) {
      debugPrint('[BRIDGE] unbindNetwork failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _method.invokeMethod('stop');
    } catch (e) {
      debugPrint('[BRIDGE] stop failed: $e');
    }
  }

  /// The board boots disarmed and takes no call audio until armed. An unarmed
  /// board looks exactly like a broken reader.
  Future<void> arm(bool on) async {
    try {
      await _method.invokeMethod('arm', {'on': on});
    } catch (e) {
      debugPrint('[BRIDGE] arm failed: $e');
    }
  }

  /// Stage 7: hand the agent's voice to the bridge. PCM16 mono @16 kHz — the
  /// board's frame clock drains it, so this may be called in bursts.
  Future<void> sendPcm(Uint8List pcm) async {
    try {
      await _method.invokeMethod('sendPcm', {'pcm': pcm});
    } catch (e) {
      debugPrint('[BRIDGE] sendPcm failed: $e');
    }
  }

  /// Wait until the agent's voice has actually gone to the board.
  ///
  /// Returns false if it timed out with audio still queued. Hanging up or
  /// muting before this returns cuts the agent off mid-word — the queue holds
  /// about 240 ms, and `stop` discards it.
  Future<bool> drain({Duration cap = const Duration(seconds: 6)}) async {
    try {
      final r = await _method
          .invokeMethod<bool>('drain', {'capMs': cap.inMilliseconds});
      return r ?? false;
    } catch (e) {
      debugPrint('[BRIDGE] drain failed: $e');
      return false;
    }
  }

  /// Test only. Kills this process the way the system does.
  ///
  /// There is no other way to reach crash recovery on this device: during a call
  /// the dialer owns the screen, so Settings → Force stop cannot be reached.
  Future<void> killSelf() async {
    try {
      await _method.invokeMethod('killSelf');
    } catch (e) {
      debugPrint('[BRIDGE] killSelf failed: $e');
    }
  }

  Future<void> flush() async {
    try {
      await _method.invokeMethod('flush');
    } catch (e) {
      debugPrint('[BRIDGE] flush failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> recordings() async {
    try {
      final res = await _method.invokeListMethod<dynamic>('recordings');
      return (res ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      return [];
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _logs.close();
    _stats.close();
    _callerPcm.close();
    _callStates.close();
  }
}

/// One call-state transition reported by the board.
class BridgeCallState {
  const BridgeCallState({
    required this.call,
    required this.setup,
    required this.initial,
    this.closing = false,
  });

  final int call;
  final int setup;

  /// The board replaying its existing indicators just after arm, not a call.
  final bool initial;

  /// The bridge is tearing down. The call's state is now *unknown*, not idle —
  /// the board is about to lose HFP and a call may well still be running on
  /// the device.
  final bool closing;

  bool get active => call == 1;
  bool get idle => call == 0 && setup == 0;
}

int _asInt(dynamic v) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

class PairedDevice {
  final String name;
  final String address;

  const PairedDevice({required this.name, required this.address});

  factory PairedDevice.fromMap(Map<String, dynamic> m) => PairedDevice(
        name: m['name']?.toString() ?? '(unnamed)',
        address: m['address']?.toString() ?? '',
      );

  /// The board advertises under this name; matching it saves picking from a
  /// list of every headset the device has ever seen.
  bool get looksLikeBoard => name.toLowerCase().contains('ai-call-agent');
}

@immutable
class BridgeStats {
  final bool connected;
  final bool armed;
  final int stage;
  final int elapsedMs;
  final int rxBytes;
  final int txBytes;
  final int rxFrames;
  final int txFrames;
  final int rxAudio;
  final int resync;

  /// Frames waiting to go to the board. ~60 ms each.
  final int queued;
  final int dropped;
  final int callState;
  final int callSetup;
  final String callerId;
  final String wav;

  const BridgeStats({
    this.connected = false,
    this.armed = false,
    this.stage = 0,
    this.elapsedMs = 0,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxFrames = 0,
    this.txFrames = 0,
    this.rxAudio = 0,
    this.resync = 0,
    this.queued = 0,
    this.dropped = 0,
    this.callState = 0,
    this.callSetup = 0,
    this.callerId = '',
    this.wav = '',
  });

  factory BridgeStats.fromMap(Map<String, dynamic> m) => BridgeStats(
        connected: m['connected'] == true,
        armed: m['armed'] == true,
        stage: _int(m['stage']),
        elapsedMs: _int(m['elapsedMs']),
        rxBytes: _int(m['rxBytes']),
        txBytes: _int(m['txBytes']),
        rxFrames: _int(m['rxFrames']),
        txFrames: _int(m['txFrames']),
        rxAudio: _int(m['rxAudio']),
        resync: _int(m['resync']),
        queued: _int(m['queued']),
        dropped: _int(m['dropped']),
        callState: _int(m['callState']),
        callSetup: _int(m['callSetup']),
        callerId: m['callerId']?.toString() ?? '',
        wav: m['wav']?.toString() ?? '',
      );

  static int _int(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  /// Average bytes/sec since the socket opened. The spec's expectation is
  /// ~8200 B/s inbound while a call is up.
  int get avgRxRate =>
      elapsedMs < 1000 ? 0 : (rxBytes * 1000 ~/ elapsedMs);

  int get avgTxRate =>
      elapsedMs < 1000 ? 0 : (txBytes * 1000 ~/ elapsedMs);

  String get callDescription {
    if (callState == 1) return 'active';
    switch (callSetup) {
      case 1:
        return 'incoming — ringing';
      case 2:
        return 'outgoing — dialling';
      case 3:
        return 'outgoing — alerting';
      default:
        return 'idle';
    }
  }
}
