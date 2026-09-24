import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../providers/providers.dart';
import '../services/bridge/call_bridge_service.dart';
import '../services/bridge/gemini_call_agent.dart';
import '../services/agent/call_tools_bridge.dart';
import '../services/call/call_briefing.dart';
import '../services/call/auto_answer.dart';
import '../services/call/call_history.dart';
import '../services/call/call_orchestrator.dart';
import '../services/call/crash_journal.dart';
import '../services/memory/memory_store.dart';
import '../services/call/call_report.dart';
import '../services/call/call_state.dart';
import '../services/call/fallback_audio.dart';
import '../main.dart' show globalContainer;
import '../services/call/call_agent_duty.dart';
import '../services/call/call_state_authority.dart';
import '../services/platform/phone_service.dart';
import '../services/platform/phone_ring_service.dart';
import '../services/call/call_state_source.dart';
import '../services/call/call_transfer.dart';
import '../services/platform/system_actions_service.dart';
import '../widgets/transfer_prompt.dart';
import '../services/session/ai_session_manager.dart';

/// Bring-up harness for the ESP32 call-audio bridge — the five stages in
/// `spp-app-integration.md` §7, run one at a time against the board.
///
/// Every stage has a pass criterion visible from the board's serial log; this
/// screen shows the device's half of the same picture, because there is no ADB
/// here and a failure otherwise localises nowhere.
class BridgeTestScreen extends ConsumerStatefulWidget {
  const BridgeTestScreen({super.key});

  @override
  ConsumerState<BridgeTestScreen> createState() => _BridgeTestScreenState();
}

class _Stage {
  final int n;
  final String title;
  final String action;
  final String pass;

  const _Stage(this.n, this.title, this.action, this.pass);
}

const _stages = <_Stage>[
  _Stage(1, 'Connect and stay connected',
      'Opens the socket and holds it. Reads nothing, writes nothing.',
      'Board logs SPP OPEN and the link survives 2 min idle. If HFP drops the moment you connect, the socket is insecure.'),
  _Stage(2, 'Receive and count',
      'Counts inbound bytes and discards them. No parsing.',
      '~8200 B/s while a call is up, nothing between calls. Board shows SPP up ~8160.'),
  _Stage(3, 'Parse frames, echo them back',
      'Parses the header, re-frames each audio payload and sends it straight back. No decoding.',
      'Caller hears their own voice, cleanly. resync stays 0 and dn matches up.'),
  _Stage(4, 'Decode to PCM and listen',
      'Decodes ADPCM to 16 kHz PCM and writes a WAV. Nothing is sent back.',
      'The WAV is clear speech. Harsh = nibble order. Noise growing over time = codec state.'),
  _Stage(5, 'Re-encode and close the loop',
      'Decodes to PCM, re-encodes with our encoder, sends it back.',
      'Echo still clean after 2 min, drop and resync both 0.'),
  _Stage(6, 'Play a signal to the caller',
      'Sends stored audio instead of the echo, paced off inbound frames. '
      'The caller hears the clip, not themselves — which is how the real '
      'sender works, with Gemini in place of the clip.',
      'The caller hears the tone unbroken, or the clip recognisably. '
      'Chopping means we are still short of 8000 B/s.'),
  _Stage(7, 'Live agent end to end',
      "Caller's voice goes to Gemini Live, its replies come back to the "
      'caller. Silence is sent while it is quiet, so the board never falls '
      'back to echoing the caller to themselves.',
      'A two-way conversation. Barge-in should cut the agent within about '
      'a second.'),
];

class _BridgeTestScreenState extends ConsumerState<BridgeTestScreen> {
  final _bridge = CallBridgeService();
  GeminiCallAgent? _agent;

  /// Step 1 of the call-agent integration, riding along on the harness.
  ///
  /// Merges the board's HFP indicators with the device's own telephony so that
  /// a hand-over — board HFP down, call still live on the device — does not
  /// read as the call ending. Observes only; it drives nothing yet. See
  /// docs/CALL_AGENT_INTEGRATION.md.
  late final CallStateAuthority _callState;
  CallState _call = const CallState(phase: CallPhase.idle);
  CallReport? _lastReport;
  late final CallTransferController _transfer;
  late final FallbackAudio _fallback;
  // Assigned in initState, never lazily. A `late final x = ref.read(...)`
  // initialiser fires on FIRST USE — and the first use can be inside dispose(),
  // where `ref` is already gone. That is exactly how this screen crashed with
  // "Cannot use ref after the widget was disposed": disposing _autoAnswer
  // forced _history, which called ref.read on a dead element.
  late final CallHistory _history;
  late final MemoryStore _memory;
  late final CrashJournal _journal;

  /// Everything this screen listens to. Not cancelling these left a disposed
  /// screen's listeners live: a later call state arrived, touched `ref`, and
  /// threw from a widget that no longer existed.
  final _subs = <StreamSubscription>[];

  /// Set only while re-adopting a call the last run died in the middle of.
  CrashSnapshot? _adopting;
  late final AutoAnswerController _autoAnswer;

  /// Armed before the call, because during one the dialer owns the screen and
  /// neither our UI nor the quick-settings shade can be reached. Fires ten
  /// seconds after the next call connects.
  bool _dropLinkNextCall = false;

  /// Same reason: Settings → Force stop is unreachable mid-call, so the only
  /// way to exercise crash recovery is to arm the kill beforehand.
  bool _killNextCall = false;

  void _appendLog(String line) {
    debugPrint('[CALL-AGENT] $line');
    if (mounted) setState(() => _log.add(line));
  }

  List<PairedDevice> _devices = [];
  String? _address;
  int _stage = 1;
  String _source = 'tone';
  bool _killWifi = false;

  /// Where "the phone is ringing" comes from — the experiment behind
  /// docs/CALL_AGENT_INTEGRATION.md's arm-on-demand question.
  ///
  ///  * `board` — today's behaviour. Armed at connect, holds the device's one
  ///    HFP slot for the whole session, and reports the ring itself. Proven,
  ///    but it means the wearer's earbud can never have HFP and the assistant
  ///    is stuck on the device speaker.
  ///  * `phone` — the board stays disarmed and off the slot until a call
  ///    arrives. `ACTION_PHONE_STATE_CHANGED` supplies the ring and the number
  ///    instead, and the board is armed on the ring and disarmed on hang-up.
  ///
  /// Nothing is deleted for this: both paths are live, and this picks between
  /// them. Neither wins until the numbers below say so.
  String _ringSource = 'board';

  /// Set when arm-on-demand fires, so the log can say how long the board took
  /// to get the HFP slot. This is the number that decides the experiment: it
  /// has to fit inside the auto-answer ring delay.
  DateTime? _armAskedAt;

  /// Held so the toggle can switch ring watching on a source that is already
  /// constructed and running.
  late final TelephonyCallStateSource _telephony;
  bool _busy = false;
  String? _error;
  BridgeStats _stats = const BridgeStats();
  final List<String> _log = [];
  final _logScroll = ScrollController();

  /// Number for the dispatch button — the outbound half of the experiment.
  /// Prefilled with the test line so a dispatch is one tap.
  final _dispatchTo = TextEditingController(text: '0200000001');

  @override
  void initState() {
    super.initState();
    _history = ref.read(callHistoryProvider);
    _memory = ref.read(memoryStoreProvider);
    _journal = ref.read(crashJournalProvider);
    _autoAnswer = AutoAnswerController(history: _history, log: _appendLog);

    _bridge.listen();
    _subs.add(_bridge.logs.listen((line) {
      if (!mounted) return;
      setState(() {
        _log.add(line);
        if (_log.length > 300) _log.removeRange(0, _log.length - 300);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }));
    _subs.add(_bridge.stats.listen((s) {
      final wasConnected = _stats.connected;
      final wasArmed = _stats.armed;
      if (mounted) setState(() => _stats = s);
      // How long the board took to take the HFP slot from a cold start. The
      // whole arm-on-demand question turns on this fitting inside the ring.
      if (!wasArmed && s.armed && _armAskedAt != null) {
        final ms = DateTime.now().difference(_armAskedAt!).inMilliseconds;
        _armAskedAt = null;
        _appendLog('[ON-DEMAND] board armed in ${ms}ms');
      }
      // The socket can go away without anyone pressing Stop — the board powers
      // off, or drops out of range mid-call. Nothing used to notice: the agent
      // kept its Gemini session and reconnected on a loop with no bridge left
      // to carry the audio, while the foreground service that was keeping this
      // process alive had already been torn down with the bridge.
      if (wasConnected && !s.connected && _agent != null) {
        _onBridgeLost();
      }
    }));

    _telephony = TelephonyCallStateSource();
    _callState = CallStateAuthority(
      bridge: BridgeCallStateSource(_bridge),
      telephony: _telephony,
    );
    _subs.add(_callState.states.listen((c) {
      if (mounted) setState(() => _call = c);
    }));
    _callState.start();

    // Step 3. The hand-over: board disarmed, wearer alerted, and the call given
    // back to the agent if nobody answers.
    // Step 4. What the caller hears when the agent cannot speak.
    _fallback = FallbackAudio(bridge: _bridge);
    _transfer = CallTransferController(
      bridge: _bridge,
      fallback: _fallback,
      onReturned: (prompt) => _agent?.endTransfer(prompt),
    );
    _subs.add(_transfer.states.listen((t) {
      ref.read(transferStateProvider.notifier).state = t;
      _appendLog('transfer: ${t.phase.name}'
          '${t.isWaiting ? ' (${t.secondsLeft}s)' : ''}');
    }));
    // The notification's buttons. This is the path that actually reaches the
    // wearer during a call — the in-app overlay below only works when FOX-1
    // happens to be foreground, which during a call it is not.
    _subs.add(SystemActionsService.transferActions.listen((a) async {
      _appendLog('wearer chose: $a');
      if (a == 'take') {
        await _transfer.accept();
        await _agent?.concludeForTransfer();
      } else {
        await _transfer.decline();
      }
    }));

    // The prompt is app-wide, so the wearer's answer comes back through a
    // provider rather than a callback.
    ref.listenManual<TransferAction?>(transferActionProvider, (_, action) async {
      if (action == null) return;
      ref.read(transferActionProvider.notifier).state = null;
      if (action == TransferAction.take) {
        await _transfer.accept();
        await _agent?.concludeForTransfer();
      } else {
        await _transfer.decline();
      }
    });

    // Step 7. Did the last run die in the middle of a call?
    unawaited(_recoverIfCrashed());

    // Covers both the prompt being up when the call dies, and the wearer's
    // own call ending — the second of which has to re-arm the bridge.
    _subs.add(_callState.states.listen((c) {
      // Arm-on-demand. Only in `phone` mode: in `board` mode the board is
      // already armed and holding the slot, and asking again would be noise.
      //
      // Ordering matters here. The arm goes out the instant the ring is seen,
      // in parallel with the auto-answer countdown below — the board has the
      // whole ring delay to get the slot, and the log says how much of it was
      // used.
      if (_ringSource == 'phone' && _stats.connected) {
        // Outgoing calls never ring. PHONE_STATE goes straight to `offhook`,
        // and the board cannot send its own `[0,2] dialling` while it is off
        // the slot — so an outbound call arrives here as plain `active`.
        //
        // But `active` alone must NOT arm. A number the wearer dialled
        // themselves is their call; taking the audio route would hand their
        // conversation to the agent mid-sentence. The thing that makes an
        // outgoing call the agent's is that we dispatched it — `make_call`
        // notes the number, and that note is the only honest signal that this
        // call was ours to answer.
        // `dialing` never stands alone — see the note in CallOrchestrator. A
        // board that still holds HFP reports our own MODE_IN_COMMUNICATION as
        // an outgoing call.
        final dispatched = ref.read(dialedNumbersProvider).recent().isNotEmpty;
        final ours = c.phase == CallPhase.ringing ||
            ((c.phase == CallPhase.dialing || c.isActive) && dispatched);
        if (ours) {
          // The board was off the slot when this rang, so it will never send
          // the [0,1] frame the agent uses to tell a real call from the phantom
          // one it invents out of our own audio route. Say so explicitly.
          _agent?.noteRing(number: c.number);
          if (!_stats.armed && _armAskedAt == null) {
            _armAskedAt = DateTime.now();
            _appendLog('[ON-DEMAND] ${c.phase.name}'
                '${dispatched && !c.isActive ? '' : dispatched ? ' (we dialled it)' : ''}'
                ' — arming the board');
            unawaited(_bridge.arm(true));
          }
        } else if (c.isActive && !_stats.armed) {
          _appendLog('[ON-DEMAND] a call we did not place — leaving it to you');
        } else if (c.isIdle && _stats.armed) {
          _armAskedAt = null;
          _appendLog('[ON-DEMAND] call over — disarming, slot back to the '
              'earbud/device');
          unawaited(_bridge.arm(false));
        }
      }
      // Step 8. Ringing is the only window where answering means anything, and
      // the two things that end it — the wearer picking up, the caller giving
      // up — both have to cancel the pending pickup.
      if (c.phase == CallPhase.ringing) {
        _autoAnswer.onRinging(c.number, _policy());
      } else if (c.isActive) {
        _autoAnswer.cancel('the call was answered');
      } else if (c.isIdle) {
        _autoAnswer.cancel('the caller rang off');
      }
      if (c.isIdle) _transfer.onCallEnded();
      if (c.isActive && _killNextCall) {
        _killNextCall = false;
        _appendLog('crash armed — killing this process in 12s');
        Timer(const Duration(seconds: 12), () async {
          _appendLog('!! killing the app now — it should relaunch and rejoin');
          await _bridge.killSelf();
        });
        if (mounted) setState(() {});
      }
      if (c.isActive && _dropLinkNextCall) {
        _dropLinkNextCall = false;
        _appendLog('link loss armed — dropping in 10s');
        Timer(const Duration(seconds: 10), () {
          _agent?.simulateOutage(const Duration(seconds: 60));
        });
        if (mounted) setState(() {});
      }
    }));

    // Claim the bridge on ENTRY, not on Start.
    //
    // If the wearer left the agent on duty, `main.dart` brings it up at boot
    // and it holds the socket. Setting this in _start() was too late: opening
    // the playground and tapping Start raced the on-duty agent for one SPP
    // socket and one HFP slot, which is what "connect failed: read failed,
    // socket might closed" was. Standing production down here means Start is
    // the only thing that ever opens a socket while this screen is up.
    CallOrchestrator.harnessActive = true;
    unawaited(() async {
      if (ref.read(callOrchestratorProvider).isRunning) {
        _appendLog('call agent was on duty — standing it down for the '
            'playground. It comes back when you leave this screen.');
      }
      await ref.read(callOrchestratorProvider).stop();
    }());

    _loadDevices();
  }

  @override
  void dispose() {
    CallOrchestrator.harnessActive = false;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _autoAnswer.dispose();
    _agent?.dispose();
    _fallback.dispose();
    _transfer.dispose();
    _callState.dispose();
    _bridge.stop();
    _bridge.dispose();
    _logScroll.dispose();
    _dispatchTo.dispose();
    super.dispose();

    // Give production back what the playground borrowed. Read through
    // globalContainer, never `ref` — this widget is gone by now, and the
    // restart has to outlive it.
    final c = globalContainer;
    if (c.read(callAgentOnDutyProvider)) {
      final addr = c.read(callAgentDeviceProvider);
      if (addr.isNotEmpty) {
        unawaited(Future.delayed(const Duration(seconds: 2), () async {
          // The board needs a moment: the bridge stop above drops HFP and the
          // socket, and reconnecting on top of a teardown is what produces
          // "read failed, socket might closed".
          if (CallOrchestrator.harnessActive) return;
          final err = await startCallAgent(addr);
          debugPrint(err == null
              ? '[CALL-AGENT] back on duty after the playground'
              : '[CALL-AGENT] could not resume duty: $err');
        }));
      }
    }
  }

  Future<void> _loadDevices() async {
    final list = await _bridge.listPaired();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _address ??= list
          .where((d) => d.looksLikeBoard)
          .map((d) => d.address)
          .firstOrNull ??
          (list.isNotEmpty ? list.first.address : null);
    });
  }

  static const _probe = MethodChannel('ai.fox1/hfp_probe');

  Future<void> _probeHfp() async {
    try {
      final r = await _probe.invokeMethod<String>('probe');
      for (final line in (r ?? '').trimRight().split('\n')) {
        debugPrint('[HFP] $line');
      }
    } catch (e) {
      debugPrint('[HFP] probe failed: $e');
    }
  }

  /// Drop or raise the SELECTED device's HFP link. On 8.1 the most recently
  /// SLC-connected headset is the one that gets SCO, so this is the lever —
  /// raise the board's link last and call audio goes to the board; leave it
  /// down and the earbud keeps the agent.
  Future<void> _hfp(String action) async {
    try {
      final r = await _probe
          .invokeMethod<String>(action, {'mac': _address});
      debugPrint('[HFP] $r');
    } catch (e) {
      debugPrint('[HFP] $action failed: $e');
    }
  }

  /// The production move, as one button each way: hand the single HFP slot to
  /// the board (call audio to the caller) or back to the earbud (agent audio to
  /// the wearer). `AISession` will drive these on make_call / hang up; here they
  /// are manual so the transition can be watched.
  Future<void> _route(String action) async {
    try {
      final r = await _probe.invokeMethod<String>(action, {'mac': _address});
      debugPrint('[HFP] $r');
    } catch (e) {
      debugPrint('[HFP] $action failed: $e');
    }
  }

  /// Send the agent to make a call — the outbound path, by hand.
  ///
  /// This is what `make_call` does in production: note the number and why,
  /// then dial. The note is what tells the arm rule above that this call is
  /// the agent's rather than the wearer's, and it is also what briefs the
  /// agent before it speaks — the board sends no caller ID for an outgoing
  /// call, because from its side there is nobody to identify.
  Future<void> _dispatch() async {
    final number = _dispatchTo.text.trim();
    if (number.isEmpty) {
      setState(() => _error = 'Enter a number to dispatch to');
      return;
    }
    ref.read(dialedNumbersProvider).note(number, task: 'bridge test dispatch');
    _appendLog('[ON-DEMAND] dispatching a call to $number');
    final res = await PhoneService().makeCall(number);
    if (res['success'] != true) {
      _appendLog('!! dial failed: ${res['error'] ?? res['result'] ?? res}');
    }
  }

  /// Pick a call back up after the process died under it.
  ///
  /// FOX-1 is the HOME launcher, so a kill is followed by a restart within
  /// seconds — and the caller is still there, now talking to nothing. Either we
  /// rejoin them or, if they have given up, we at least file what happened
  /// instead of losing the conversation silently.
  Future<void> _recoverIfCrashed() async {
    final snap = await _journal.findUnfinished();
    if (snap == null) return;

    // Telephony, not the board: the board is precisely what we lost, so asking
    // it whether a call is up would be circular.
    final live = await _journal.callStillLive();
    final what = CrashJournal.decide(snap, callLive: live);

    switch (what) {
      case Recovery.nothing:
        _appendLog('found a stale in-flight call from '
            '${snap.number} — too old to act on, discarding');
        await _journal.callEnded();
        return;

      case Recovery.fileOnly:
        // The caller hung up while we were dead. Nothing to rejoin, but the
        // call still happened and the wearer should hear about it.
        _appendLog('the app died during a call with ${snap.number} — '
            'the call is over, filing it');
        await _history.load();
        await _history.record(CallReport.unavailable(
          number: snap.number,
          startedAt: snap.startedAt,
          durationS: snap.durationS,
        ));
        await _journal.callEnded();
        return;

      case Recovery.readopt:
        _appendLog('the app died during a call with ${snap.number} — '
            'it is STILL UP, reconnecting');
        if (snap.deviceAddress.isEmpty) {
          _appendLog('...but no board was recorded, so nothing to reconnect to');
          await _journal.callEnded();
          return;
        }
        _adopting = snap;
        if (mounted) {
          setState(() {
            _address = snap.deviceAddress;
            _stage = snap.stage;
          });
        }
        // Same path as a manual start. Nothing about re-adoption should take
        // a shortcut the normal path does not, or it becomes a second way for
        // the bridge to come up that nobody tests.
        await _start();
        return;
    }
  }

  /// Read fresh each ring, so a change in Settings takes effect on the next
  /// call rather than the next bridge restart.
  AutoAnswerPolicy _policy() => AutoAnswerPolicy(
        mode: ref.read(autoAnswerModeProvider),
        blocked: AutoAnswerPolicy.parseList(ref.read(autoAnswerBlockedProvider)),
        always: AutoAnswerPolicy.parseList(ref.read(autoAnswerAlwaysProvider)),
        ringFirst: Duration(seconds: ref.read(autoAnswerDelayProvider)),
      );

  Future<void> _start() async {
    final addr = _address;
    if (addr == null) {
      setState(() => _error = 'No paired device selected');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _log.clear();
    });

    // The main session holds MODE_IN_COMMUNICATION and an app-owned SCO while
    // it is warm, and it stays warm for two minutes after standing down. That
    // ran straight through a live bridged call once, and only let go because an
    // idle timer happened to expire mid-call. Audio ownership has to be handed
    // over deliberately, not left to whichever timer fires first.
    await ref.read(aiSessionManagerProvider).goCold();

    // So a restart knows which board and which stage to come back to.
    // The playground and the on-duty agent cannot both hold the socket.
    // Remembered so the on-duty agent knows which board to use without the
    // wearer having to type a MAC address into Settings.
    ref.read(callAgentDeviceProvider.notifier).state = addr;
    SharedPreferences.getInstance()
        .then((p) => p.setString('call_agent_device', addr));
    _journal.bridgeStarted(addr, _stage);

    // The two halves of the choice, and they must agree: telephony only starts
    // watching for rings when the board is not going to report them, and the
    // board is only left disarmed when something else will.
    final onDemand = _ringSource == 'phone';
    _telephony.setWatchRinging(onDemand);
    if (onDemand) {
      final canSeeNumbers = await PhoneRingService.hasPermission();
      _appendLog(canSeeNumbers
          ? '[ON-DEMAND] ring from telephony; board armed per call'
          : '[ON-DEMAND] READ_PHONE_STATE missing — rings will arrive with no '
              'number, so history and auto-answer rules cannot match');
    }
    var err = await _bridge.start(
        address: addr, stage: _stage, source: _source, autoArm: !onDemand);

    if (err == null && _stage == 7) {
      // Before Gemini opens its socket, not after: binding does not move
      // connections that already exist.
      final onCellular =
          await _bridge.prepareNetwork(disableWifi: _killWifi);
      if (!mounted) return;
      setState(() => _log.add(onCellular
          ? 'Gemini will use cellular'
          : 'Gemini on default route — audio may chop'));

      // Step 2: the call agent gets tools — and only these. See
      // CallToolsBridge for what is deliberately absent and why.
      final callTools = CallToolsBridge(
        memory: _memory,
        onEndCall: (reason) async {
          _appendLog('agent hung up: $reason');
          // The model emits the tool call before it has finished speaking, so
          // the goodbye is still in flight at this point.
          await _agent?.letHerFinish();
        },
        onTransfer: (reason) async {
          _appendLog('transfer requested: $reason');
          // Before beginTransfer, not after: that closes the audio gate, and
          // "please hold while I connect you" arrives just after the tool call.
          await _agent?.letHerFinish(cap: const Duration(seconds: 6));
          _agent?.beginTransfer();
          await _transfer.start(number: _call.number);
        },
      );
      // Step 5. Read before the agent is built so a first-time caller and a
      // caller we have no file on are told apart in the log.
      await _history.load();
      await _memory.load();
      final agent = GeminiCallAgent(
        tools: callTools,
        fallback: _fallback,
        bridge: _bridge,
        history: _history,
        dialed: ref.read(dialedNumbersProvider),
        journal: _journal,
        config: GeminiConfig(
          apiKey: ref.read(geminiApiKeyProvider),
          // Calls always run on plain 3.8 Live — see call_agent_duty.dart.
          model: AppConstants.geminiModel,
          voice: ref.read(geminiVoiceProvider),
          // Persona, not the system prompt. The system prompt is on-device
          // instructions — screen automation, camera, stand_down — which are
          // wrong on a call. See composeCallPrompt.
          systemPrompt: composeCallPrompt(
            persona: ref.read(aiPersonaProvider),
            userProfile: ref.read(userProfileProvider),
            callInstructions: ref.read(callAgentPromptProvider),
            name: ref.read(assistantNameProvider),
          ),
        ),
      );
      agent.events.listen((m) {
        if (mounted) setState(() => _log.add(m));
      });
      agent.reports.listen((r) {
        _appendLog('REPORT ${r.headline}');
        for (final c in r.commitments) {
          _appendLog('  promised: $c');
        }
        for (final a in r.actionItems) {
          _appendLog('  todo: $a');
        }
        for (final c in r.callerAsserted) {
          _appendLog('  caller claims: $c');
        }
        if (mounted) setState(() => _lastReport = r);
      });
      err = await agent.start(resumeHandle: _adopting?.resumeHandle);
      if (err == null) {
        _agent = agent;
        // The board only mentions an in-progress call in its post-arm `initial`
        // dump, which we ignore on purpose, so nothing else will tell the agent
        // it is already on a call.
        final adopt = _adopting;
        if (adopt != null) {
          _adopting = null;
          agent.adoptCall(
              number: adopt.number, startedAt: adopt.startedAt);
          await _journal.callStarted(adopt.number, adopt.startedAt);
        }
        // Now, while the link is demonstrably working — not at the moment they
        // are needed, which is by definition the moment it is not. Cached, so
        // this only actually generates once.
        unawaited(_fallback.ensureClips(GeminiConfig(
          apiKey: ref.read(geminiApiKeyProvider),
          model: AppConstants.geminiModel,
          voice: ref.read(geminiVoiceProvider),
          systemPrompt: '',
        )));
      } else {
        await _bridge.stop();
      }
    }

    // Into the log as well as onto the screen. The saved session log is what
    // actually gets read afterwards, and a start failure that only ever
    // appeared in red text was invisible in every log of it.
    if (err != null) _appendLog('!! start failed: $err');

    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  /// The bridge went away on its own. Take the agent down with it.
  Future<void> _onBridgeLost() async {
    final agent = _agent;
    _agent = null;
    if (agent == null) return;
    // debugPrint as well as the on-screen list: this one has to survive the
    // screen going away, and the saved session log is the only place it can.
    debugPrint('[BRIDGE] bridge lost — stopping the agent');
    if (mounted) setState(() => _log.add('bridge lost — stopping the agent'));
    await agent.stop();
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _agent?.stop();
    _agent = null;
    await _bridge.stop();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final stage = _stages.firstWhere((s) => s.n == _stage);
    final live = _stats.connected;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Call Bridge', style: TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: live ? null : _loadDevices,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          _label('Board'),
          _panel(
            child: DropdownButton<String>(
              value: _address,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              hint: const Text('No paired devices',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              items: _devices
                  .map((d) => DropdownMenuItem(
                        value: d.address,
                        child: Text(
                          d.looksLikeBoard ? '${d.name}  ◀' : d.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged:
                  live ? null : (v) => setState(() => _address = v),
            ),
          ),
          if (_devices.isEmpty)
            _hint('Pair the board in Android Bluetooth settings first — '
                'it appears as AI-Call-Agent.'),

          const SizedBox(height: 12),
          _label('Stage'),
          Row(
            children: _stages
                .map((s) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: _stageChip(s.n, live),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 8),
          _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${stage.n}. ${stage.title}',
                    style: const TextStyle(
                        color: Color(0xFF00E5CC),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(stage.action,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11, height: 1.3)),
                const SizedBox(height: 6),
                Text('PASS  ${stage.pass}',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10, height: 1.3)),
              ],
            ),
          ),

          if (_stage == 7) ...[
            const SizedBox(height: 8),
            _label('Ring detected by'),
            Row(
              children: [
                Expanded(child: _ringChip('board', 'Board', live)),
                const SizedBox(width: 6),
                Expanded(child: _ringChip('phone', 'Phone', live)),
              ],
            ),
            _hint(_ringSource == 'board'
                ? 'Today\'s behaviour. Armed at connect and holds the device\'s '
                    'one HFP slot for the whole session — so no earbud, and the '
                    'assistant is stuck on the device speaker between calls.'
                : 'Arm-on-demand. Board stays off the HFP slot until a call; '
                    'the ring comes from ACTION_PHONE_STATE_CHANGED instead. '
                    'Watch for "[ON-DEMAND] board armed in Nms" — it has to fit '
                    'inside the ring delay.'),
            if (live && _ringSource == 'phone') ...[
              const SizedBox(height: 8),
              _label('Dispatch a call'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _dispatchTo,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(
                        hintText: 'number',
                        hintStyle:
                            TextStyle(color: Colors.white24, fontSize: 12),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        filled: true,
                        fillColor: Color(0xFF1A1A1A),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A3A2A),
                      foregroundColor: const Color(0xFF00E5CC),
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 12),
                    ),
                    onPressed: _dispatch,
                    child: const Text('Dial',
                        style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              _hint('The agent\'s own outbound path. Dialling from the device '
                  'dialer instead is YOUR call — it will not arm, by design.'),
            ],

            const SizedBox(height: 8),
            _label('Wi-Fi'),
            Row(
              children: [
                Expanded(child: _wifiChip(false, 'Leave on', live)),
                const SizedBox(width: 6),
                Expanded(child: _wifiChip(true, 'Turn off', live)),
              ],
            ),
            _hint(_killWifi
                ? 'Belt and braces, but setWifiEnabled is a no-op on Android '
                    '10+ — this path will not exist on newer hardware.'
                : 'The robust path: Gemini moves to cellular, Wi-Fi stays up. '
                    'If this is clean, the design works on modern Android.'),
          ],

          if (_stage == 6) ...[
            const SizedBox(height: 8),
            _label('Signal'),
            Row(
              children: [
                Expanded(child: _sourceChip('tone', '1 kHz tone', live)),
                const SizedBox(width: 6),
                Expanded(child: _sourceChip('file', 'Last recording', live)),
              ],
            ),
            _hint(_source == 'tone'
                ? 'A steady tone makes a rate shortfall audible at once — '
                    'speech just sounds vaguely wrong.'
                : 'Uses the newest stage-4 WAV. Have the caller stay quiet so '
                    'they do not confuse it with hearing themselves.'),
          ],

          const SizedBox(height: 12),
          // Answers one question before we build anything on top of it: does
          // this device's Bluetooth stack let us steer which HFP device gets
          // SCO? Reflection into BluetoothHeadset.connect/disconnect is the
          // API 27 lever; a manufacturer-patched build would take it away.
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _probeHfp,
                  child: const Text('HFP probe',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      (_busy || _address == null) ? null : () => _hfp('disconnect'),
                  child: const Text('SLC down',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      (_busy || _address == null) ? null : () => _hfp('connect'),
                  child: const Text('SLC up',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),
          // Same lever, but as the whole transition: free the slot from whoever
          // holds it, give it to the other side, and wait for it to land.
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      (_busy || _address == null) ? null : () => _route('acquire'),
                  child: const Text('→ bridge',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _route('release'),
                  child: const Text('→ earbud',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        _dropLinkNextCall ? const Color(0xFFFF6B6B) : null,
                  ),
                  onPressed: () {
                    setState(() => _dropLinkNextCall = !_dropLinkNextCall);
                    _appendLog(_dropLinkNextCall
                        ? 'next call: link will drop 10s in'
                        : 'next call: link drop cancelled');
                  },
                  child: Text(_dropLinkNextCall ? 'drop ARMED' : 'drop link',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        _killNextCall ? const Color(0xFFFF6B6B) : null,
                  ),
                  onPressed: () {
                    setState(() => _killNextCall = !_killNextCall);
                    _appendLog(_killNextCall
                        ? 'next call: app will be killed 12s in'
                        : 'next call: crash cancelled');
                  },
                  child: Text(_killNextCall ? 'crash ARMED' : 'crash app',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              // One-time grant. Without it the hand-over prompt has nowhere to
              // draw on this device — see TransferOverlay.
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    if (await SystemActionsService.canOverlay()) {
                      _appendLog('overlay permission: granted');
                    } else {
                      _appendLog('overlay permission: opening settings…');
                      await SystemActionsService.requestOverlay();
                    }
                  },
                  child: const Text('overlay?',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        live ? const Color(0xFF3A1A1A) : const Color(0xFF00E5CC),
                    foregroundColor: live ? Colors.redAccent : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _busy ? null : (live ? _stop : _start),
                  child: Text(live ? 'Stop' : 'Start stage $_stage',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              if (live && _stage >= 2) ...[
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _stats.armed
                        ? const Color(0xFF1A3A2A)
                        : const Color(0xFF1A1A1A),
                    foregroundColor:
                        _stats.armed ? const Color(0xFF00E5CC) : Colors.white54,
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 12),
                  ),
                  onPressed: () => _bridge.arm(!_stats.armed),
                  child: Text(_stats.armed ? 'ARMED' : 'disarmed',
                      style: const TextStyle(fontSize: 11)),
                ),
              ],
            ],
          ),

          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
          ],

          if (live && _stage >= 2 && !_stats.armed)
            _hint(_ringSource == 'phone'
                ? 'Disarmed on purpose — the slot is free for the earbud until '
                    'a call arrives. It will arm itself on the ring.'
                : 'Board is disarmed — it will report call state but send zero '
                    'audio. That looks exactly like a broken reader.'),

          const SizedBox(height: 12),
          _label('Link'),
          _panel(
            child: Column(
              children: [
                _stat('state', live ? 'open  ${_stats.elapsedMs ~/ 1000}s' : 'closed'),
                _stat('call', '${_call.phase.name}  via ${_callState.authority}'),
                if (_lastReport != null)
                  _stat('report', _lastReport!.headline),
                _stat(
                    'call',
                    _stats.callerId.isEmpty
                        ? _stats.callDescription
                        : '${_stats.callDescription}   ${_stats.callerId}'),
                if (_stage >= 2) ...[
                  _stat('up', '${_stats.rxBytes} B   ${_stats.avgRxRate} B/s'),
                  _stat('dn', '${_stats.txBytes} B   ${_stats.avgTxRate} B/s'),
                ],
                if (_stage >= 3) ...[
                  _stat('frames', '${_stats.rxFrames} in / ${_stats.txFrames} out'),
                  _stat('audio', '${_stats.rxAudio} frames'),
                  _stat('resync', '${_stats.resync}',
                      bad: _stats.resync > 0),
                  _stat('dropped', '${_stats.dropped}',
                      bad: _stats.dropped > 0),
                ],
                if (_stage == 4 && _stats.wav.isNotEmpty)
                  _stat('wav', _stats.wav.split('/').last),
              ],
            ),
          ),

          if (_stage == 4)
            _hint('Fetch the WAV from the settings web server: '
                'http://<device-ip>:8080/api/bridge/recordings'),

          const SizedBox(height: 12),
          _label('Log'),
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.all(8),
            child: _log.isEmpty
                ? const Center(
                    child: Text('nothing yet',
                        style:
                            TextStyle(color: Colors.white24, fontSize: 11)))
                : ListView.builder(
                    controller: _logScroll,
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        _log[i],
                        style: TextStyle(
                          color: _log[i].startsWith('!!')
                              ? Colors.redAccent
                              : _log[i].startsWith('CALL') ||
                                      _log[i].startsWith('ARM')
                                  ? const Color(0xFF00E5CC)
                                  : Colors.white60,
                          fontSize: 10,
                          fontFamily: 'monospace',
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Also mirrored to http://<device-ip>:8080/logs',
            style: TextStyle(color: Colors.white24, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _ringChip(String value, String label, bool live) {
    final selected = _ringSource == value;
    return GestureDetector(
      onTap: live ? null : () => setState(() => _ringSource = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1A3A2A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: selected ? const Color(0xFF00E5CC) : Colors.white54,
                fontSize: 11,
              )),
        ),
      ),
    );
  }

  Widget _wifiChip(bool value, String label, bool live) {
    final selected = _killWifi == value;
    return GestureDetector(
      onTap: live ? null : () => setState(() => _killWifi = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1A3A2A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: selected ? const Color(0xFF00E5CC) : Colors.white54,
                fontSize: 11,
              )),
        ),
      ),
    );
  }

  Widget _sourceChip(String value, String label, bool live) {
    final selected = _source == value;
    return GestureDetector(
      onTap: live ? null : () => setState(() => _source = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1A3A2A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                color: selected ? const Color(0xFF00E5CC) : Colors.white54,
                fontSize: 11,
              )),
        ),
      ),
    );
  }

  Widget _stageChip(int n, bool live) {
    final selected = n == _stage;
    return GestureDetector(
      onTap: live ? null : () => setState(() => _stage = n),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00E5CC) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text('$n',
              style: TextStyle(
                color: selected
                    ? Colors.black
                    : (live ? Colors.white24 : Colors.white70),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              )),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 2),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: Colors.white38,
                fontSize: 9,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
      );

  Widget _panel({required Widget child}) => Container(
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
            style: const TextStyle(
                color: Colors.white38, fontSize: 10, height: 1.3)),
      );

  Widget _stat(String k, String v, {bool bad = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 60,
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontFamily: 'monospace')),
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

/// Deliberately terse. This is a bring-up harness, not the product prompt —
/// the aim is to hear whether the loop works, not to showcase the agent.
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
