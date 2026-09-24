import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../config/constants.dart';
import '../agent/call_tools_bridge.dart';
import '../call/call_history.dart';
import '../call/crash_journal.dart';
import '../call/dialed_numbers.dart';
import '../call/call_report.dart';
import '../call/fallback_audio.dart';
import '../gemini/gemini_live_client.dart';
import 'call_bridge_service.dart';

/// Stage 7: joins the call-audio bridge to a Gemini Live session.
///
/// Deliberately thin, and deliberately not [AISession] — this is still the
/// bring-up harness. It exists to answer one question: does the agent hold a
/// two-way conversation with a real caller over the bridge?
///
/// ```
/// caller --SCO--> board --SPP--> bridge --16k PCM--> Gemini
/// caller <-SCO--- board <-SPP--- bridge <-24k->16k-- Gemini
/// ```
class GeminiCallAgent {
  GeminiCallAgent({
    required this.bridge,
    required this.config,
    this.tools,
    this.fallback,
    this.history,
    this.dialed,
    this.journal,
  });

  final CallBridgeService bridge;
  final GeminiConfig config;

  /// The call agent's allowlist. Null keeps the old tool-less behaviour, which
  /// is what stages 1-6 of the harness want.
  final CallToolsBridge? tools;

  /// What the caller hears when the agent cannot speak. Null means silence,
  /// which is what used to happen.
  final FallbackAudio? fallback;

  /// Who has called before and what was said. Null means every caller is a
  /// stranger, which is the behaviour this replaces.
  final CallHistory? history;

  /// Written while a call is up so a restart can find it. Null disables
  /// crash recovery entirely, which is what the earlier stages want.
  final CrashJournal? journal;

  /// Who an *outgoing* call is to. The board never sends a caller ID for one,
  /// so without this every outbound call is anonymous and nothing said on it
  /// can be filed — which breaks the dispatch loop the history exists for:
  /// ring the printer, they promise a callback, they ring in, and the agent
  /// has to already know why.
  final DialedNumbers? dialed;

  /// The caller briefing, held until there is a session to send it down.
  ///
  /// A call can be answered while the socket is still coming up — the wearer
  /// picks up in three seconds, a reconnect takes four — and the briefing is
  /// worthless if it arrives after the agent has already introduced itself.
  String? _pendingBriefing;

  /// Reports, one per call. Emitted even when the caller hangs up abruptly.
  Stream<CallReport> get reports => _reports.stream;
  final _reports = StreamController<CallReport>.broadcast();

  StreamSubscription? _toolSub;
  Completer<Map<String, dynamic>>? _awaitingReport;
  String _callNumber = '';
  DateTime? _callStartedAt;

  /// Kept after the call so a report that arrives late still has its context.
  String _lastNumber = '';
  DateTime? _lastStartedAt;
  int _lastDuration = 0;

  GeminiLiveClient? _gemini;
  StreamSubscription? _callerSub;
  StreamSubscription? _audioSub;
  StreamSubscription? _interruptSub;
  StreamSubscription? _textSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _callSub;
  Timer? _watchdog;
  bool _stopping = false;
  bool _callActive = false;

  /// True while the wearer has the call.
  ///
  /// The board is disarmed for the duration, so no call audio reaches us and
  /// none of ours reaches the caller — privacy comes free with the disarm, and
  /// the session is kept alive only so the hand-back is instant rather than a
  /// cold reconnect in front of a waiting caller.
  bool _transferred = false;

  /// The wearer took the call for good.
  ///
  /// Distinct from [_transferred], which is the offer being open. Once handed
  /// off, the call is still genuinely active — so the stats backstop would keep
  /// insisting the agent is on a call it has left, and the watchdog would
  /// reconnect against a session with no audio path, every 20 seconds, for as
  /// long as the conversation lasted.
  bool _handedOff = false;
  bool _reconnecting = false;
  DateTime? _callActiveSince;
  int _reconnects = 0;
  int _stalls = 0;
  final _pending = StringBuffer();
  Timer? _flushText;

  /// How long a call may go without a single message from Gemini before the
  /// session is treated as dead.
  ///
  /// Ten seconds was too tight. Healthy calls show gaps of up to nine seconds
  /// while nobody is talking, and one such gap triggered a reconnect that cost
  /// ten seconds of real dead air — the cure being worse than the disease. The
  /// stall this exists for lasted 78 seconds, so twenty leaves margin on both
  /// sides.
  static const _stallTimeout = Duration(seconds: 20);

  /// When to stop pretending it is coming back.
  ///
  /// Past this the agent has been mute for the better part of a minute with a
  /// person on the line. Apologising and hanging up cleanly is kinder than
  /// leaving them listening to nothing — and unlike the reply itself, the
  /// apology does not need the network.
  static const _giveUpAfter = Duration(seconds: 45);

  bool _playedHolding = false;
  bool _givingUp = false;

  final _uplink = <Uint8List>[];
  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;

  bool get connected => _gemini?.isConnected == true;

  /// [resumeHandle] continues a Gemini session across a process restart, so a
  /// re-adopted call picks the conversation up instead of meeting the caller
  /// as a stranger halfway through.
  Future<String?> start({String? resumeHandle}) async {
    if (config.apiKey.isEmpty) return 'No Gemini API key — set one in Settings';

    final gemini = GeminiLiveClient(
      config: tools == null
          ? config
          : GeminiConfig(
              apiKey: config.apiKey,
              model: config.model,
              voice: config.voice,
              systemPrompt: config.systemPrompt,
              toolDeclarations: tools!.toolDeclarations,
            ),
    );
    _gemini = gemini;

    try {
      await gemini.connect(resumeHandle: resumeHandle);
    } catch (e) {
      // The process is bound to cellular so Wi-Fi and BT do not fight over the
      // radio, and bound sockets fail HARD rather than falling back — by
      // design. The failure mode that design has is total: a SIM with no
      // working data does not degrade the agent, it removes it, and the bridge
      // then answers a caller with nothing behind it. Every part worked except
      // the one nobody could see.
      //
      // A coexistence glitch beats no agent at all.
      _emit('Gemini setup failed on the cellular route ($e)');
      _emit('falling back to the default network — check cellular data');
      await bridge.unbindNetwork();
      try {
        await gemini.connect(resumeHandle: resumeHandle);
        _emit('connected on the default route; cellular is not carrying data');
      } catch (e2) {
        _gemini = null;
        // Emitted as well as returned: the caller shows this on a screen, and
        // a screen is exactly what nobody is looking at when it matters.
        _emit('!! could not reach Gemini on either route: $e2');
        return 'Gemini connect failed: $e2';
      }
    }

    // Caller -> Gemini. 16 kHz both ends, so this is a straight pass-through;
    // the resampling the build guide warns about only applies the other way.
    //
    // Batched to ~180 ms. Each send costs a base64 encode, a jsonEncode and a
    // TLS record on the Dart main isolate, and that isolate runs at an elevated
    // priority — every wakeup there is CPU the Bluetooth stack process does not
    // get, and that process is what actually moves bytes on the SPP link.
    // Gemini is indifferent to 60 ms versus 180 ms chunks.
    _callerSub = bridge.callerPcm.listen((pcm) {
      if (!gemini.isConnected || _transferred) return;
      _uplink.add(pcm);
      if (_uplink.length >= 3) {
        final b = BytesBuilder(copy: false);
        for (final c in _uplink) {
          b.add(c);
        }
        _uplink.clear();
        gemini.sendAudio(b.takeBytes());
      }
    });

    // Gemini -> caller. 24 kHz down to the 16 kHz the call runs at.
    //
    // Gated on a call actually being up. A reply generated during a stall
    // arrives whenever the socket unblocks, and without this gate it goes to
    // whoever is on the line then — which is how one caller got the previous
    // caller's answer 900 ms before their own call was even answered.
    _audioSub = gemini.audioResponses.listen((pcm) {
      if (!_callActive || _transferred) return;
      _lastAudioAt = DateTime.now();
      final out = _resample24to16(pcm);
      _noteSpeech(out.length);
      bridge.sendPcm(out);
    });

    // Call boundaries. Everything buffered belongs to the call that just
    // ended, on both sides of the link.
    _callSub = bridge.callStates.listen((st) {
      if (st.initial) return;
      // A real transition means the board is tracking this call now, so its
      // stats can be trusted again.
      _adoptedWithoutBoard = false;

      // An inbound call always rings first, and an outbound one we placed
      // ourselves. Anything else the board calls a "call" is not one.
      //
      // The device is the HFP audio gateway, so when the device assistant wakes
      // and sets MODE_IN_COMMUNICATION the board sees call indicators and
      // reports [0,2] dialling → [1,3] active. Believing it took the audio
      // route away from the assistant a second after it woke, killed it before
      // it could speak, and looped.
      if (!st.active && st.setup == 1) _sawRingOrDispatch = true;
      if (st.active && !_sawRingOrDispatch &&
          (dialed?.recent() ?? '').isEmpty && !_adoptedWithoutBoard) {
        _emit('ignoring a call the board reports — nothing rang and we '
            'dialled nothing');
        return;
      }
      // Ringing. Warm the session now rather than at answer — a reconnect takes
      // a couple of seconds, and those are seconds a real person spends
      // listening to nothing after saying hello.
      if (!st.active && st.setup == 1) _ensureSession('a call is ringing');
      if (st.active) {
        // A fresh call after a hand-off: we are back in. Reset before asking
        // for a session — _ensureSession honours _givingUp, so doing it the
        // other way round refused the reconnect on the first active frame.
        _handedOff = false;
        _playedHolding = false;
        _givingUp = false;
        _ensureSession('a call was answered');
        _briefOnCaller();
        _callActive = true;
        _callActiveSince ??= DateTime.now();
        _callStartedAt ??= DateTime.now();
        _reportedFor = '';
        if (bridge.lastStats.callerId.isNotEmpty) {
          _callNumber = bridge.lastStats.callerId;
        } else {
          // No caller ID means an outgoing call. We dialled it, so we know who
          // it is to — and knowing now, rather than at the end, is what lets
          // the agent be briefed before it speaks.
          final out = dialed?.recent() ?? '';
          if (out.isNotEmpty) {
            _callNumber = out;
            _emit('outgoing call to $out');
          } else if (_ringNumber.isNotEmpty) {
            // Arm-on-demand: the board joined after the ring, so its caller ID
            // may not have arrived yet. Telephony already named them.
            _callNumber = _ringNumber;
          }
        }
        // The scope of every recall the call agent can make. Set per call and
        // cleared when it ends: a stale number here would let one caller read
        // the previous caller's file.
        tools?.callerNumber = _callNumber;
        // Journalled the moment the call is real, not when it ends — the whole
        // point is to survive not reaching the end.
        unawaited(journal?.callStarted(
            _callNumber, _callStartedAt ?? DateTime.now()));
      } else if ((st.idle || st.closing) && _callActive) {
        // The errand ended with the call it was for. See DialedNumbers.
        dialed?.noteCallEnded(_callNumber);
        _callActive = false;
        _callActiveSince = null;
        _uplink.clear();
        _flushText?.cancel();
        _flushText = null;
        _pending.clear();
        bridge.flush();
        // These describe the call that just ended. Carried into the next one
        // they suppress its reconnect and its holding line — a second caller
        // was refused a session three times on a flag set by the first.
        _givingUp = false;
        _playedHolding = false;
        // Undelivered context belongs to the call that is over. Sending it into
        // the next one would brief the agent on the wrong person.
        _pendingBriefing = null;
        _lastAudioAt = null;
        _speechEndsAt = DateTime.fromMillisecondsSinceEpoch(0);
        _briefedFor = '';
        _adoptedWithoutBoard = false;
        _sawRingOrDispatch = false;
        _ringNumber = '';
        tools?.callerNumber = '';
        unawaited(journal?.callEnded());
        _emit('call ended — dropped buffered audio');
        // Ask now, while the session is still up. A caller who hangs up
        // mid-sentence never gives the model a chance to wrap up on its own,
        // and that is the common case, not the exception.
        _requestReport(abrupt: st.closing || !_endedByAgent);
      }
    });

    // Tool calls. Everything is refused by default — see CallToolsBridge.
    final bridgeTools = tools;
    if (bridgeTools != null) {
      _toolSub = gemini.toolCalls.listen((tc) async {
        if (tc.name == CallReport.toolName) {
          final w = _awaitingReport;
          if (w != null && !w.isCompleted) {
            w.complete(tc.args);
          } else if (_reportedFor == _lastNumber && _lastNumber.isNotEmpty) {
            // The model sometimes summarises twice for one call. The second
            // arrives after the waiter is gone and lands as a "late report",
            // so the wearer gets two cards for one conversation.
            _emit('ignoring a duplicate report');
          } else if (_callActive) {
            // The model sometimes summarises unprompted, mid-call, before it
            // has hung up. Filing that would be wrong twice over: the call is
            // not over, and _lastNumber is still empty, so it lands as
            // "unknown caller · 0s" and cannot be filed against anyone. The
            // real report arrives when the call actually ends.
            _emit('ignoring an unprompted report — the call is still up');
          } else {
            // Arrived after we gave up waiting. On a slow link the model has
            // taken 25 s to answer; emitting the real summary late beats
            // keeping the "unavailable" placeholder that replaced it.
            _emitReport(tc.args, abrupt: true, late: true);
          }
        }
        if (tc.name == 'end_call') noteAgentEndedCall();
        final result = await bridgeTools.handleToolCall(tc.name, tc.args);
        gemini.sendToolResponse(tc.id, result, name: tc.name);
      });
    }

    // Barge-in. Dropping our own queue is not enough — the board has up to
    // half a second buffered, and without the flush the caller hears the tail
    // of a sentence they already interrupted.
    _interruptSub = gemini.interrupted.listen((_) {
      _emit('interrupted — flushing');
      // The queue is discarded, so nothing is left to play out. Leaving the
      // clock set would make the next letHerFinish wait for audio the caller
      // will never hear.
      _speechEndsAt = DateTime.fromMillisecondsSinceEpoch(0);
      bridge.flush();
    });

    // Fragments arrive several times a second and each one drove a setState
    // and a text relayout on the raster thread. Collect them and emit once a
    // second; the point is to see what it said, not to watch it type.
    _textSub = gemini.textResponses.listen((t) {
      if (t.trim().isEmpty) return;
      _pending.write('${t.trim()} ');
      _flushText ??= Timer(const Duration(seconds: 1), () {
        _flushText = null;
        final s = _pending.toString().trim();
        _pending.clear();
        if (s.isNotEmpty) _emit('agent: $s');
      });
    });

    // A Live session has a time limit. It warns with goAway and then closes,
    // and until now nothing acted on that: the socket shut at ten minutes and
    // the caller carried on talking to an agent that was no longer there.
    // The resumption handle carries the conversation across, so the caller
    // should not be able to tell.
    _stateSub = gemini.connectionState.listen((st) {
      if (_stopping) return;
      // Same reason as the watchdog: a session with no bridge under it has
      // nothing left to reconnect for.
      if (!bridge.lastStats.connected) return;
      if (st == GeminiConnectionState.disconnected ||
          st == GeminiConnectionState.error) {
        _reconnect();
      }
    });

    // A socket that has stopped carrying anything still reports connected, so
    // connectionState alone never fires. One call sat like that for 78 seconds
    // with the caller talking into a blocked pipe, and nothing noticed.
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) => _checkAlive());

    _emit('Gemini connected');
    _flushBriefing();
    return null;
  }

  /// When the agent last produced a sound.
  DateTime? _lastAudioAt;

  /// When the audio we have already handed over finishes *playing*.
  ///
  /// This is the number that matters, and it is not the same as when the model
  /// stopped generating. Gemini emits a turn far faster than real time — four
  /// seconds of speech can arrive in one and a half — so "no new chunk for
  /// 600 ms" routinely means the model has finished while seconds of her voice
  /// are still queued to play. Hanging up on that signal cut the goodbye every
  /// time.
  ///
  /// The board consumes at a fixed 16 kHz, 16-bit mono, so bytes convert
  /// straight to time: 32000 bytes = one second.
  DateTime _speechEndsAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _noteSpeech(int bytes) {
    final now = DateTime.now();
    // Playback resumes where the last chunk ends, unless we have already
    // fallen silent — then it starts now.
    final from = _speechEndsAt.isAfter(now) ? _speechEndsAt : now;
    _speechEndsAt = from.add(Duration(microseconds: bytes * 1000000 ~/ 32000));
  }

  /// How long without a chunk counts as "she has stopped talking".
  ///
  /// Chunks arrive several times a second while she speaks. This does not wait
  /// on `turnComplete` alone: on a call that ends with a tool call the turn is
  /// often closed by an `interrupted` instead, and a wait that only watched
  /// turnComplete would sit there until its cap every time.
  static const _quietFor = Duration(milliseconds: 600);

  /// Let the agent finish the sentence she is in the middle of.
  ///
  /// `end_call` and `transfer_to_human` both used to take effect the instant
  /// the tool call arrived, while she was still speaking. The caller heard
  /// "Alright, I will pass that message on. Have a good d—" and then silence;
  /// on a transfer they never heard "please hold" at all, because the audio
  /// gate shut 130 ms before she said it.
  ///
  /// Two things have to settle: the model has to stop producing audio, and the
  /// board's send queue has to actually empty. Skipping the second leaves ~240
  /// ms of her voice in a queue that teardown then discards.
  Future<void> letHerFinish({
    Duration cap = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(cap);
    while (DateTime.now().isBefore(deadline)) {
      // Nobody left to hear it.
      if (_stopping || !_callActive) return;
      final last = _lastAudioAt;
      // Null means she has not spoken on this call at all — the outage path,
      // where the apology is a fallback clip and no Gemini audio ever arrived.
      // Treating that as "still talking" sat here for the whole cap.
      if (last == null) break;
      if (DateTime.now().difference(last) >= _quietFor) break;
      await Future.delayed(const Duration(milliseconds: 80));
    }
    if (_stopping) return;

    // Generation has stopped. Now wait for the audio itself to play out.
    if (_playoutLeft > 0.2) {
      _emit('letting her finish — ${_playoutLeft.toStringAsFixed(1)}s '
          'of speech still to play');
    }
    while (DateTime.now().isBefore(deadline) &&
        DateTime.now().isBefore(_speechEndsAt)) {
      if (_stopping || !_callActive) return;
      await Future.delayed(const Duration(milliseconds: 80));
    }
    // Whether she actually got to the end, or we ran out of patience. The
    // drain result cannot answer this: the queue dips empty under jitter, so a
    // successful drain after the cap still reported "finished speaking".
    final ranOut = DateTime.now().isBefore(_speechEndsAt);

    final left = deadline.difference(DateTime.now());
    await bridge.drain(
        cap: left.isNegative ? const Duration(milliseconds: 500) : left);

    // Our queue being empty is not the caller having heard it. The board keeps
    // its own jitter buffer — it logs "pacing primed with 4 frames (240 ms)" —
    // and SCO adds more on top. Hanging up here still cut the last word off,
    // because ending the call discards everything downstream of us.
    if (_stopping || !_callActive) return;
    await Future.delayed(_pipelineTail);
    _emit(ranOut
        ? 'cut her off after ${cap.inSeconds}s — ${_playoutLeft.toStringAsFixed(1)}s'
            ' of speech was still unplayed'
        : 'agent finished speaking');
  }

  /// Seconds of her voice still waiting to be heard. For the log only.
  double get _playoutLeft {
    final ms = _speechEndsAt.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : ms / 1000;
  }

  /// How long the agent's voice lives past our own send queue.
  ///
  /// The board's primed buffer is 240 ms and SCO carries several frames beyond
  /// that. 700 ms covers both without being audible as a pause before the line
  /// drops — the caller is being said goodbye to, so a beat there is natural.
  static const _pipelineTail = Duration(milliseconds: 700);

  /// The wearer is being offered the call. Go quiet.
  void beginTransfer() {
    _transferred = true;
    _uplink.clear();
    // Same reason as an interruption: the queue goes, so there is nothing left
    // to play out and the clock would otherwise stall the next wait.
    _speechEndsAt = DateTime.fromMillisecondsSinceEpoch(0);
    bridge.flush();
    _emit('transferred to the wearer — agent silent');
  }

  /// Nobody took it. Speak: the caller has been listening to nothing.
  Future<void> endTransfer(String recoveryPrompt) async {
    _transferred = false;
    _emit('call back from the wearer — agent speaking again');
    _gemini?.sendText(recoveryPrompt);
  }

  /// The wearer took the call. The agent's part is over even though the call
  /// is not, so the report covers what the agent itself handled.
  Future<void> concludeForTransfer() async {
    _transferred = false;
    _handedOff = true;
    _callActive = false;
    _callActiveSince = null;
    await _requestReport(abrupt: false);
  }

  /// True when the agent itself hung up, so the report can say whether the
  /// call was wrapped up or cut short.
  bool _endedByAgent = false;
  void noteAgentEndedCall() => _endedByAgent = true;

  /// How long to wait for the model to answer with a report before giving up.
  /// It has to be short — the session is being torn down behind it.
  /// The model regularly takes longer than this looks like it should — one
  /// summary arrived at 14 s. Past the timeout a placeholder is filed and then
  /// replaced when the real one lands, so overshooting is cheap; undershooting
  /// puts "Call ended before a summary could be produced" in front of the
  /// wearer for a call that summarised itself perfectly well.
  static const _reportTimeout = Duration(seconds: 20);

  /// Ask the model to summarise the call it has just been on.
  ///
  /// Done as a request into the *live* session rather than by having the model
  /// volunteer a report before hanging up. A caller who hangs up mid-sentence
  /// never gives it that chance, and an abrupt end is the normal case — so the
  /// report has to be pulled after the fact, from a session that still holds
  /// the conversation.
  Future<void> _requestReport({required bool abrupt}) async {
    final t = tools;
    final gemini = _gemini;
    final startedAt = _callStartedAt;
    // Last chance to give this call a name. A number the wearer dialled by
    // hand never reaches us live, but Android writes the call log entry when
    // the call ends — which is now. It is too late to brief this call, and
    // exactly in time to file it, so the next one is briefed.
    if (_callNumber.isEmpty) {
      final late = await dialed?.lastOutgoing() ?? '';
      if (late.isNotEmpty) {
        _callNumber = late;
        _emit('outgoing call was to $late (from the call log)');
      }
    }
    final number = _callNumber;
    _callStartedAt = null;
    _endedByAgent = false;

    final duration = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds;
    _lastNumber = number;
    _lastStartedAt = startedAt;
    _lastDuration = duration;

    void fallback() {
      if (_reports.isClosed) return;
      _publish(CallReport.unavailable(
        number: number,
        startedAt: startedAt,
        durationS: duration,
      ));
      _emit('call report unavailable');
    }

    if (t == null || gemini == null || !gemini.isConnected) {
      fallback();
      return;
    }

    final waiter = Completer<Map<String, dynamic>>();
    _awaitingReport = waiter;
    gemini.sendText(
      'The call has ended${abrupt ? ' (the caller hung up)' : ''}. '
      'Do not speak. Call ${CallReport.toolName} now to summarise it.',
    );

    try {
      final args = await waiter.future.timeout(_reportTimeout);
      _emitReport(args, abrupt: abrupt);
    } on TimeoutException {
      fallback();
    } finally {
      _awaitingReport = null;
    }
  }

  void _emitReport(
    Map<String, dynamic> args, {
    required bool abrupt,
    bool late = false,
  }) {
    if (_reports.isClosed) return;
    final report = CallReport.fromToolArgs(
      args,
      number: _lastNumber,
      startedAt: _lastStartedAt,
      durationS: _lastDuration,
      endedAbruptly: abrupt,
    );
    _reportedFor = _lastNumber;
    _publish(report);
    _emit('${late ? 'late report' : 'report'}: ${report.headline}');
  }

  /// Tell the agent who it is about to speak to.
  ///
  /// Sent as an injected message rather than baked into the system prompt: the
  /// prompt goes out once, in the `setup` frame, and we do not know the caller
  /// until the phone rings.
  String _briefedFor = '';

  /// True between adopting a call and the board reporting its first real
  /// transition. While set, the board's stats cannot end the call — it does not
  /// know about it yet — so telephony is asked instead.
  bool _adoptedWithoutBoard = false;

  /// This call began with a ring, or with a number we dialled. Without one of
  /// those, the board is describing our own audio route, not a call.
  bool _sawRingOrDispatch = false;

  /// The number a ring arrived with when the board was not there to say it.
  /// Used only as a fallback for an empty caller ID.
  String _ringNumber = '';

  /// A ring seen by something other than the board.
  ///
  /// In arm-on-demand the board is off the HFP slot while the phone rings, so
  /// it never sends `[0,1]` and [_sawRingOrDispatch] never gets set. Its first
  /// frame is `[1,x] active`, straight after arming — which is indistinguishable
  /// from the phantom "call" the board invents out of our own audio route, and
  /// the guard below rightly rejected it. The caller then heard nothing: no
  /// briefing, no recall scope, and `_callActive` false gating her audio off.
  ///
  /// So the ring has to be declared. Telephony saw it; this says so.
  void noteRing({String number = ''}) {
    if (_sawRingOrDispatch) return;
    _sawRingOrDispatch = true;
    if (number.isNotEmpty) _ringNumber = number;
    _emit('ring reported by telephony${number.isEmpty ? '' : ' — $number'}');
    _ensureSession('a call is ringing');
  }

  /// The caller whose report has already gone out, so a second summary for the
  /// same call is dropped rather than shown again.
  String _reportedFor = '';

  /// Has the call we adopted actually ended?
  Future<void> _checkAdopted() async {
    if (!_adoptedWithoutBoard || _stopping) return;
    final live = await journal?.callStillLive();
    // No journal means no way to ask; leave it to the board catching up.
    if (live == null || live) return;
    _adoptedWithoutBoard = false;
    if (!_callActive) return;
    _emit('the adopted call has ended (telephony)');
    _callActive = false;
    _callActiveSince = null;
    _uplink.clear();
    bridge.flush();
    _requestReport(abrupt: true);
  }

  void _briefOnCaller() {
    final h = history;
    final number = _callNumber;
    if (h == null || number.isEmpty) return;
    // The board announces an answered call twice — [1,1] then [1,0] — and both
    // land here. Briefing twice sends the same context message down the socket
    // a second time, at full token cost.
    if (_briefedFor == number) return;
    _briefedFor = number;
    final text = h.briefing(number);
    // Why we rang them, when we rang them. Without this an outbound call opens
    // with the agent asking how it can help — which is backwards, because it
    // is the one that wanted something.
    final task = dialed?.taskFor(number) ?? '';
    if (text.isEmpty && task.isEmpty) {
      _emit('caller $number has not called before');
      return;
    }
    _pendingBriefing = [
      '[Context — not spoken by the caller. Do not read it aloud.]',
      if (task.isNotEmpty)
        'YOU placed this call. What you were asked to do: $task\n'
            'Open by saying who you are and why you are calling, then get on '
            'with it. Do not ask them how you can help.',
      if (text.isNotEmpty)
        'Use this: greet them as someone you already know and pick up where '
            'you left off.\n$text',
    ].join('\n');
    _emit('briefing the agent on $number '
        '(${h.threadFor(number)?.calls.length ?? 0} prior call(s)'
        '${task.isEmpty ? '' : ', dispatched'})');
    _flushBriefing();
  }

  /// Take over a call that was already in progress when we started.
  ///
  /// The board reports an in-progress call only in its post-arm `initial`
  /// dump, which is deliberately ignored — those are a status readout, not a
  /// transition. So nothing here fires on its own: without this the agent
  /// would come up with no caller number, no briefing, no recall scope, and
  /// `_callActive` false, which gates its audio off entirely. The watchdog
  /// would eventually correct the last of those and nothing else.
  void adoptCall({required String number, required DateTime startedAt}) {
    _adoptedWithoutBoard = true;
    _sawRingOrDispatch = true;
    _callActive = true;
    _callActiveSince ??= DateTime.now();
    _callStartedAt ??= startedAt;
    _handedOff = false;
    _givingUp = false;
    _playedHolding = false;
    if (number.isNotEmpty) {
      _callNumber = number;
      tools?.callerNumber = number;
    }
    final gap = DateTime.now().difference(startedAt).inSeconds;
    _emit('adopted a call already in progress'
        '${number.isEmpty ? '' : ' with $number'} (${gap}s in)');

    final history = this.history?.briefing(number) ?? '';
    _pendingBriefing =
        '[Context — not spoken by the caller. Do not read it aloud.]\n'
        'You were cut off mid-call: this device restarted under you and the '
        'caller heard silence for a few seconds. They are still on the line. '
        'Apologise briefly for the break in ONE short sentence, then carry on '
        'from where you were.'
        '${history.isEmpty ? '' : '\n$history'}';
    _flushBriefing();
  }

  void _flushBriefing() {
    final text = _pendingBriefing;
    final g = _gemini;
    if (text == null || g == null || !g.isConnected) return;
    _pendingBriefing = null;
    g.sendText(text);
  }

  /// The one door every report leaves by, so filing it cannot be forgotten on
  /// whichever path is added next.
  void _publish(CallReport r) {
    _reports.add(r);
    unawaited(history?.record(r));

    // Everything the caller asserted goes into quarantine, never into memory.
    // This is the only route by which a call can add to what the device knows,
    // and it lands marked, attributed and waiting for the wearer to rule on
    // it. "Remember that Alex agreed to pay me 500" is a sentence anybody can
    // say out loud; it gets kept, and it stays a claim until a human says
    // otherwise.
    // A call with no caller ID — an outgoing one, or a withheld number — still
    // gets its claims kept. Not filing an anonymous *thread* is right, because
    // a shared "unknown" bucket would brief one stranger with another's
    // history; throwing the claims away is not. One such call ran 195 seconds
    // and produced a commitment, an action item and a claim, and every word of
    // it was discarded.
    //
    // Filed with no subject, they reach `review_claims` on the main agent and
    // no scoped `recall` on the call agent — an empty subject matches no
    // caller key, so nothing leaks sideways.
    final mem = tools?.memory;
    if (mem != null) {
      final who = r.number.isEmpty
          ? 'an unidentified caller'
          : 'the caller on ${r.number}';
      for (final claim in r.callerAsserted) {
        unawaited(mem.claim(claim, about: r.number, source: who));
      }
    }
  }

  void _checkAlive() {
    if (_stopping) return;
    // No bridge, no call. Reconnecting to Gemini when the socket that carries
    // the audio has gone achieves nothing, and does it forever.
    if (!bridge.lastStats.connected) return;
    _reconcileCallState();
    unawaited(_checkAdopted());
    if (!_callActive || _handedOff) return;

    final gemini = _gemini;
    // Keep the resumption handle on disk so a restart resumes the
    // conversation rather than starting a new one mid-sentence.
    unawaited(journal?.noteHandle(gemini?.resumptionHandle));

    // Measure from the later of "last heard from Gemini" and "this call
    // started". Otherwise a session that sat idle before the phone rang looks
    // stalled the instant the call connects — which fired a needless reconnect
    // two seconds into a call, reporting 27s of quiet that all predated it.
    final since = _latest(gemini?.lastMessageAt, _callActiveSince);
    if (since == null) return;
    final quiet = DateTime.now().difference(since);
    if (quiet < _stallTimeout) {
      // It is talking again; forget the outage.
      _playedHolding = false;
      return;
    }

    // ---- What the caller hears.
    //
    // Deliberately above every remaining guard. These two used to sit below
    // `_reconnecting` and `gemini.isConnected`, so they could only fire while
    // the socket was up but quiet. In a real outage the socket is *down* and
    // the retry loop runs for a minute — which made the fallback unreachable
    // in precisely the situation it exists for.

    // Long past the point of waiting. Say so, then hang up.
    if (quiet >= _giveUpAfter && !_givingUp) {
      _givingUp = true;
      _emit('no agent for ${quiet.inSeconds}s — apologising and ending the call');
      _apologiseAndEnd();
      return;
    }
    if (_givingUp) return;

    // First thing the caller hears is not silence.
    final f = fallback;
    if (f != null && !_playedHolding && !f.isPlaying) {
      _playedHolding = true;
      f.play(f.holding, what: 'holding line');
    }

    // ---- Getting the agent back. This half may legitimately be busy already.
    if (_reconnecting) return;
    if (gemini == null || !gemini.isConnected) return;

    _stalls++;
    _emit('no reply for ${quiet.inSeconds}s during a call'
        ' — forcing reconnect (#$_stalls)');
    // Only close it. The connectionState listener owns reconnecting; calling
    // _reconnect() here as well produced two concurrent connects on one client
    // and "Bad state: Stream has already been listened to".
    gemini.disconnect();
  }

  // ---------------------------------------------------------------- testing

  DateTime? _outageUntil;
  bool get _inSimulatedOutage =>
      _outageUntil != null && DateTime.now().isBefore(_outageUntil!);

  /// Pretend the data link died, for [d].
  ///
  /// The honest test — flight mode mid-call — cannot be run on this device: the
  /// dialer owns the screen and the quick-settings shade will not open over it,
  /// the same wall the hand-over prompt hit. This closes the socket and refuses
  /// reconnects for the window, which drives the same escalation.
  void simulateOutage(Duration d) {
    _outageUntil = DateTime.now().add(d);
    _emit('SIMULATED link loss for ${d.inSeconds}s');
    _gemini?.disconnect();
  }

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Backstop for [_callActive].
  ///
  /// The flag gates the agent's voice, so a transition we fail to see would
  /// mute the agent for a whole call — a worse failure than the stale-audio bug
  /// the gate exists to prevent. The stats tick carries the same state once a
  /// second, so disagreement can never last more than one watchdog period.
  void _reconcileCallState() {
    // A handed-off call is still a call; it is just not ours.
    if (_handedOff) return;
    final active =
        bridge.lastStats.connected && bridge.lastStats.callState == 1;
    // An adopted call is one the board never announced — we restarted into it,
    // so its tracked indicators are still zero. Letting this backstop read
    // that as "idle" gated the agent's audio off three seconds after every
    // re-adoption: she carried on talking and the caller heard nothing.
    // Telephony decides when an adopted call has ended; see _checkAdopted.
    if (_adoptedWithoutBoard && !active) return;
    // The same rule the transition listener uses. Without it this backstop
    // walked straight past the guard: the board invents a call from our own
    // audio route, the listener ignores it, and three seconds later the stats
    // tick turned it on anyway.
    if (active && !_callActive && !_sawRingOrDispatch && !_adoptedWithoutBoard) {
      return;
    }
    if (active == _callActive) return;
    _callActive = active;
    if (active) _callActiveSince ??= DateTime.now();
    _emit('call state corrected from stats — ${active ? "active" : "idle"}');
    if (!active) {
      _callActiveSince = null;
      _uplink.clear();
      bridge.flush();
    }
  }

  /// Play the apology, let it finish, then hang up.
  ///
  /// The wait matters: cutting the line mid-apology is worse than not
  /// apologising at all.
  Future<void> _apologiseAndEnd() async {
    final f = fallback;
    var wait = const Duration(seconds: 1);
    if (f != null && f.apology.isNotEmpty) {
      f.play(f.apology, what: 'apology');
      wait = FallbackAudio.lengthOf(f.apology) + const Duration(milliseconds: 600);
    }
    await Future.delayed(wait);
    if (_stopping) return;
    await tools?.handleToolCall(
        'end_call', {'reason': 'lost the connection to the agent'});
  }

  /// Bring the session back if it is down.
  ///
  /// The retry loop is driven by the socket *closing*, so once it exits — given
  /// up after 20 attempts, or abandoned because we were already apologising —
  /// nothing re-triggers it and the session stays dead for the rest of the
  /// bridge run. A second caller then got the full 45-second escalation on a
  /// link that had been healthy again for twenty seconds. A call arriving is
  /// the trigger that was missing.
  void _ensureSession(String why) {
    final g = _gemini;
    if (g == null || _stopping || _reconnecting || g.isConnected) return;
    _emit('session is down and $why — reconnecting');
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    final gemini = _gemini;
    if (gemini == null || _stopping || _reconnecting || gemini.isConnected) {
      return;
    }
    _reconnecting = true;
    try {
      await _reconnectOnce(gemini);
    } finally {
      _reconnecting = false;
    }
  }

  /// Give up only when there is nothing left to reconnect *for*.
  static const _maxReconnectAttempts = 20;

  /// Hard ceiling on one connect attempt.
  ///
  /// `connect()` has internal timeouts (8 s socket + 8 s setup), and a fallback
  /// path that repeats both once without session features — but that path hung
  /// on a live call and never returned. `_reconnecting` stayed true for the
  /// rest of the session, so `_ensureSession` bailed instantly on the next
  /// call and the caller heard the apology instead of an agent. A single stuck
  /// future must not be able to end the agent's life.
  ///
  /// 30 s covers the legitimate double path with slack; the escalation timers
  /// run independently, so the caller is not sitting in silence while we wait.
  /// Longer than [GeminiLiveClient.connect]'s own worst case — 8 s ready +
  /// 8 s setup, then the whole thing retried without session features. At 30 s
  /// this fired while that retry was still running, and the next attempt
  /// collided with it. The single-flight guard now makes a collision harmless,
  /// but abandoning an attempt that was about to succeed is still waste a
  /// caller pays for in silence.
  static const _connectTimeout = Duration(seconds: 40);

  Future<void> _reconnectOnce(GeminiLiveClient gemini) async {
    _reconnects++;
    final handle = gemini.resumptionHandle;
    _emit('session closed — reconnecting (#$_reconnects)'
        '${handle == null ? '' : ' with context'}');

    // Keep trying. One attempt was not enough: a setup timeout leaves the
    // client disconnected with no further state change to trigger another go,
    // so a single failure left the agent mute for the rest of the call while a
    // real person waited on the line. Only a stop, a closed bridge, or an ended
    // call are reasons to give up.
    for (var attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
      if (_stopping || gemini.isConnected) return;
      // The apology is already playing and the hang-up is scheduled. Carrying
      // on logged four more attempts and then "the caller is hearing silence"
      // over the top of the apology they were actually hearing.
      if (_givingUp) {
        _emit('reconnect abandoned — already apologising');
        return;
      }
      if (!bridge.lastStats.connected) {
        _emit('reconnect abandoned — bridge is gone');
        return;
      }
      // Backoff, capped: a caller is waiting, so do not crawl.
      await Future.delayed(
          Duration(milliseconds: (400 * attempt).clamp(400, 3000)));
      if (_stopping || gemini.isConnected) return;
      if (_inSimulatedOutage) {
        _emit('reconnect attempt $attempt failed: simulated outage');
        continue;
      }
      try {
        await gemini.connect(resumeHandle: handle).timeout(_connectTimeout);
        _emit('reconnected after $attempt attempt${attempt == 1 ? '' : 's'}');
        _flushBriefing();
        return;
      } on TimeoutException {
        _emit('reconnect attempt $attempt timed out'
            ' after ${_connectTimeout.inSeconds}s');
        // Do not leave a half-open client for the next attempt to trip over.
        try {
          await gemini.disconnect();
        } catch (_) {}
      } catch (e) {
        _emit('reconnect attempt $attempt failed: $e');
      }
    }
    _emit('gave up reconnecting after $_maxReconnectAttempts attempts — '
        'the caller is hearing silence');
  }

  void _emit(String msg) {
    debugPrint('[CALL-AGENT] $msg');
    if (!_events.isClosed) _events.add(msg);
  }

  Future<void> stop() async {
    _stopping = true;
    _transferred = false;
    _handedOff = false;
    _givingUp = false;
    _outageUntil = null;
    fallback?.stop();
    _watchdog?.cancel();
    _watchdog = null;
    _callActive = false;
    await _callSub?.cancel();
    _callSub = null;
    await _toolSub?.cancel();
    _toolSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    await _callerSub?.cancel();
    await _audioSub?.cancel();
    await _interruptSub?.cancel();
    await _textSub?.cancel();
    _callerSub = _audioSub = _interruptSub = _textSub = null;
    _flushText?.cancel();
    _flushText = null;
    _callActiveSince = null;
    _uplink.clear();
    _gemini?.dispose();
    _gemini = null;
  }

  void dispose() {
    stop();
    _events.close();
    _reports.close();
  }

  /// 24 kHz -> 16 kHz, linear interpolation: 2 output samples per 3 input.
  ///
  /// [_phase] and [_lastSample] carry across calls on purpose. Resetting them
  /// per chunk puts a discontinuity at every block boundary Gemini sends —
  /// a click every few tens of milliseconds for the whole reply.
  double _phase = 0.0;
  int _lastSample = 0;

  Uint8List _resample24to16(Uint8List input) {
    final n = input.length ~/ 2;
    if (n == 0) return Uint8List(0);
    final src = ByteData.view(input.buffer, input.offsetInBytes, n * 2);
    int at(int i) => i < 0 ? _lastSample : src.getInt16(i * 2, Endian.little);

    const step = 1.5; // 24000 / 16000

    // Preallocated. The growable list plus a second packing pass ran per sample
    // on the main isolate during exactly the burst that must not stall the
    // Bluetooth stack.
    final count = _outCount(_phase, n, step);
    final bytes = Uint8List(count * 2);
    final view = ByteData.view(bytes.buffer);

    var pos = _phase;
    var o = 0;
    while (o < count) {
      final i = pos.floor();
      final frac = pos - i;
      final a = at(i);
      final b = at(i + 1);
      view.setInt16(o * 2, (a + (b - a) * frac).round().clamp(-32768, 32767),
          Endian.little);
      o++;
      pos += step;
    }

    // Next chunk's index 0 is this chunk's index n.
    _phase = pos - n;
    _lastSample = at(n - 1);
    return bytes;
  }

  /// Output samples produced from [n] input samples starting at [phase].
  static int _outCount(double phase, int n, double step) {
    if (phase >= n - 1) return 0;
    return ((n - 1 - phase) / step).ceil();
  }
}
