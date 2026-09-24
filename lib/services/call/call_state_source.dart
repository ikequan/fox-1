import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bridge/call_bridge_service.dart';
import '../platform/in_call_service.dart';
import '../platform/phone_ring_service.dart';
import 'call_state.dart';

/// Something that can say where a call is.
///
/// There are two, and neither is sufficient alone — see
/// [CallStateAuthority] for why.
abstract class CallStateSource {
  String get name;

  /// Observations. A source that cannot currently see anything emits nothing
  /// rather than guessing [CallPhase.idle] — an unheard call is not an ended
  /// call, and that distinction is the whole point.
  Stream<CallState> get states;

  /// Whether this source can currently see the call at all.
  bool get isLive;

  Future<void> start();
  Future<void> stop();
}

/// The board's HFP indicators, relayed over SPP.
///
/// Authoritative while the bridge is connected and armed, and blind the moment
/// it is not: `spp_send_call_state()` in the firmware is only ever called from
/// `ESP_HF_CLIENT_CIND_CALL_EVT` and `..._CALL_SETUP_EVT`. With no SLC the
/// board receives no indicator events and sends nothing — and on SLC loss it
/// silently zeroes its own state without telling us, so a later frame would be
/// actively wrong.
class BridgeCallStateSource implements CallStateSource {
  BridgeCallStateSource(this.bridge);

  final CallBridgeService bridge;

  @override
  String get name => 'board';

  final _out = StreamController<CallState>.broadcast();
  final _subs = <StreamSubscription>[];

  /// Set the instant the bridge says it is closing.
  ///
  /// [BridgeStats] cannot carry this: the teardown notice is emitted before the
  /// final stats tick, so for ~100 ms `lastStats` still reads connected+armed.
  /// That window is not academic — it is exactly when the board goes blind, and
  /// reading a stale "live" there let a teardown notice end a call that was
  /// still running on the device.
  bool _blind = false;

  /// Last phase we reported, so a late caller ID can be re-announced against
  /// it. The board sends CALLER-ID as a separate frame a beat *after* the
  /// ringing indicator, so the first ring of a session carries no number —
  /// and the number is the key everything downstream is filed under.
  CallPhase _lastPhase = CallPhase.idle;
  String _lastNumber = '';

  @override
  Stream<CallState> get states => _out.stream;

  @override
  bool get isLive =>
      !_blind && bridge.lastStats.connected && bridge.lastStats.armed;

  @override
  Future<void> start() async {
    if (_subs.isNotEmpty) return;

    // Clears [_blind] when a new session genuinely comes up.
    _subs.add(bridge.stats.listen((st) {
      if (st.connected && st.armed) _blind = false;
      // A caller ID arriving after the ring is still news.
      final id = st.callerId;
      if (id.isNotEmpty && id != _lastNumber && _lastPhase != CallPhase.idle) {
        _lastNumber = id;
        _out.add(CallState(phase: _lastPhase, number: id, source: name));
      }
    }));

    _subs.add(bridge.callStates.listen((s) {
      // The board replays its existing indicators just after arm; those are a
      // status dump, not a call.
      if (s.initial) return;

      // Teardown. The board is about to lose HFP, so its view of the call ends
      // here — but the call may not. Say nothing and stand down; telephony
      // owns the question from now on.
      if (s.closing) {
        _blind = true;
        debugPrint('[CALL] board going blind (bridge closing)');
        return;
      }

      final phase = s.active
          ? CallPhase.active
          : (s.setup == 1
              ? CallPhase.ringing
              : (s.setup == 2 || s.setup == 3
                  ? CallPhase.dialing
                  : CallPhase.idle));
      _lastPhase = phase;
      _lastNumber = bridge.lastStats.callerId;
      if (phase == CallPhase.idle) _lastNumber = '';
      _out.add(CallState(
        phase: phase,
        number: bridge.lastStats.callerId,
        source: name,
      ));
    }));
  }

  @override
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _blind = false;
    _lastPhase = CallPhase.idle;
    _lastNumber = '';
  }

  void dispose() {
    stop();
    _out.close();
  }
}

/// The device's own telephony.
///
/// Two implementations in one, because which is available depends on a decision
/// that has not been made yet (see the plan's "Default dialer" section):
///
///  - **Default dialer** — `InCallService` gives real state, including ringing
///    and the number.
///  - **Otherwise** — poll `AudioManager.mode`. That only answers "is a call
///    up", which is exactly and only what the hand-over case needs: enough to
///    dismiss the wearer prompt and stop the vibration.
class TelephonyCallStateSource implements CallStateSource {
  TelephonyCallStateSource({
    InCallStateService? inCall,
    bool watchRinging = false,
  })  : _inCall = inCall ?? InCallStateService(),
        _watchRinging = watchRinging;

  /// Also listen to `ACTION_PHONE_STATE_CHANGED`, which reports ringing and
  /// the caller's number without FOX-1 being the default dialer.
  ///
  /// Off by default because it is not needed while the board holds HFP — the
  /// board already reports the ring, and has done so across every test call.
  /// On, it is the signal that makes arm-on-demand possible: with the board
  /// off the HFP slot it sees nothing, so the ring has to come from here.
  bool _watchRinging;
  bool get watchRinging => _watchRinging;

  /// Switchable while running, because the harness toggle is flipped after
  /// this source has already been constructed and started.
  void setWatchRinging(bool on) {
    if (on == _watchRinging) return;
    _watchRinging = on;
    if (!_running) return;
    if (on) {
      _listenForRings();
    } else {
      _ringSub?.cancel();
      _ringSub = null;
      _ringing = false;
    }
  }

  static const _audio = MethodChannel('ai.fox1/audio');
  static const _pollInterval = Duration(seconds: 2);

  /// `AudioManager.MODE_IN_CALL`.
  static const _modeInCall = 2;

  final InCallStateService _inCall;

  final _out = StreamController<CallState>.broadcast();
  StreamSubscription? _sub;
  StreamSubscription? _ringSub;
  Timer? _poll;
  bool _defaultDialer = false;
  bool _running = false;
  CallPhase _lastPolled = CallPhase.idle;

  /// The phone is ringing but nothing has been answered. `AudioManager.mode`
  /// is still MODE_NORMAL here, and letting the poll call that "idle" would
  /// cancel the pending auto-answer before it ever fired.
  bool _ringing = false;

  @override
  String get name => _defaultDialer
      ? 'telephony'
      : (_watchRinging ? 'phone' : 'audio-mode');

  @override
  Stream<CallState> get states => _out.stream;

  /// Always live. This is the source of last resort; if it cannot answer, no
  /// one can.
  @override
  bool get isLive => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;

    _defaultDialer = await _inCall.isDefaultDialer();
    if (_defaultDialer) {
      _sub = _inCall.callStateChanges.listen((e) {
        final phase = switch (e['state']?.toString()) {
          'active' => CallPhase.active,
          'ringing' => CallPhase.ringing,
          'dialing' => CallPhase.dialing,
          _ => CallPhase.idle,
        };
        _out.add(CallState(
          phase: phase,
          number: e['phoneNumber']?.toString() ?? '',
          source: name,
        ));
      });
    }

    // PHONE_STATE. Kept alongside the poll rather than replacing it: this is
    // the only source below default-dialer that can say "ringing" and name the
    // caller, but a broadcast that never arrives fails silently, and the poll
    // still notices a call is up.
    if (_watchRinging) _listenForRings();

    // Polled even when InCallService is available: it is cheap, and it is the
    // backstop if the service is unbound without us noticing.
    _poll = Timer.periodic(_pollInterval, (_) => _pollMode());
    await _pollMode();
  }

  void _listenForRings() {
    _ringSub?.cancel();
    _ringSub = PhoneRingService.ringEvents.listen((e) {
      final phase = switch (e['state']?.toString()) {
        'ringing' => CallPhase.ringing,
        'offhook' => CallPhase.active,
        _ => CallPhase.idle,
      };
      final number = e['number']?.toString() ?? '';
      debugPrint('[RING] ${e['state']}'
          '${number.isEmpty ? ' (no number)' : ' $number'}');
      _ringing = phase == CallPhase.ringing;
      _lastPolled = _ringing ? _lastPolled : phase;
      _out.add(CallState(phase: phase, number: number, source: 'phone'));
    }, onError: (e) => debugPrint('[RING] stream error: $e'));
  }

  Future<void> _pollMode() async {
    try {
      final mode = await _audio.invokeMethod<int>('audioMode');
      final phase =
          mode == _modeInCall ? CallPhase.active : CallPhase.idle;
      // Only speak when it changes; the authority is idempotent anyway, but a
      // 2 s heartbeat of "still the same" is noise in the log.
      if (phase == _lastPolled) return;
      // A ring is not yet a call, and MODE_NORMAL during one must not be
      // read as "no call" and cancel it.
      if (_watchRinging && phase == CallPhase.idle && _ringing) return;
      _lastPolled = phase;
      _out.add(CallState(phase: phase, source: 'audio-mode'));
    } catch (e) {
      debugPrint('[CALL] audioMode poll failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _poll?.cancel();
    _poll = null;
    await _sub?.cancel();
    _sub = null;
    await _ringSub?.cancel();
    _ringSub = null;
    _lastPolled = CallPhase.idle;
    _ringing = false;
  }

  void dispose() {
    stop();
    _out.close();
  }
}
