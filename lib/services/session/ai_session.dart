import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../config/constants.dart';
import '../agent/agent_bridge.dart';
import '../agent/native_tools_bridge.dart';
import '../audio/audio_manager.dart';
import 'preroll_buffer.dart';
import '../camera/watch_camera_service.dart';
import '../gemini/gemini_live_client.dart';
import '../platform/in_call_service.dart';
import '../platform/screen_automation_service.dart';
import '../platform/system_actions_service.dart';

/// The agent's handle on the world outside its own tool calls — the camera, and
/// the ability to be woken when something changes.
///
/// Gemini's loop only advances when it calls a tool, so a task that depends on a
/// FUTURE event (an ad's Skip button appearing, an upload finishing) would
/// otherwise stall forever: the model says "waiting", the turn ends, and nothing
/// ever re-enters it. The device methods below fix that by polling and then
/// injecting a message back into the conversation, the same way job polling
/// already does.
abstract class AgentEnvironment {
  /// Capture a single frame and deliver it to the model. Completes only once
  /// the frame has actually been sent, so the model never answers blind.
  Future<bool> lookOnce();

  /// Begin continuous frames. Auto-stops after [autoStopAfter] so a forgotten
  /// stream cannot drain the battery.
  Future<bool> startVision({Duration autoStopAfter});

  Future<void> stopVision();

  bool get isVisionActive;

  /// Watch the screen until [text] appears (or disappears, if [untilGone]).
  /// Returns immediately with a device id; when the condition is met the agent
  /// is messaged and can carry on. Non-blocking, so the user can still talk.
  String watchScreenFor({
    required String text,
    required Duration timeout,
    required bool untilGone,
  });

  /// Wake the agent after [delay] with [note], for waits with no visible
  /// condition ("check back when the video should be over").
  String scheduleFollowUp({required Duration delay, required String note});

  /// Cancel a pending watch or follow-up.
  bool cancelWatch(String id);

  /// Ids of everything currently pending.
  List<String> get pendingWatches;

  /// Stop listening and hand the screen back to the watch face, until the user
  /// deliberately returns to the agent.
  Future<void> standDown();

  /// Send the launcher to the watch face without changing the mic state.
  void requestHomeScreen();
}

/// Long-lived AI session for the device — camera (JPEG), mic (PCM16 16kHz) and
/// the Gemini Live WebSocket, each with an independent lifecycle so power can be
/// released without losing the conversation.
///
/// Power tiers:
///  * **active** — socket up, mic capturing, camera only if vision was requested
///  * **warm**   — socket up, mic and camera released ([goWarm])
///  * **cold**   — everything released, conversation preserved via the server's
///                 resumption handle ([goCold])
///
/// [wake] restores from any tier, resuming the previous conversation rather than
/// starting a new one. This is what makes leaving the screen — or the device
/// display switching off — cheap instead of destructive.
class AISession implements AgentEnvironment {
  final AudioManager audioManager;
  final WatchCameraService cameraService;
  final GeminiLiveClient gemini;
  final AgentBridge? agentBridge;

  /// Camera settings, refreshed from settings on each vision start.
  CameraConfig cameraConfig;

  bool _connected = false;
  bool _listening = false;
  bool _visionActive = false;
  bool _disposed = false;
  bool _geminiWired = false;
  bool _reconnecting = false;

  final List<StreamSubscription> _geminiSubs = [];
  StreamSubscription? _micSub;
  StreamSubscription? _cameraSub;

  final Map<String, Timer> _watchers = {};
  final Map<String, Timer> _jobPollers = {};

  /// True between the first audio chunk of a turn and turnComplete. Used to
  /// hold back injected updates so they never interrupt speech.
  bool _modelSpeaking = false;
  final List<String> _queuedNotes = [];
  final ScreenAutomationService _screenAutomation = ScreenAutomationService();
  int _watchSeq = 0;
  final InCallStateService _inCallService = InCallStateService();
  Timer? _callEndTimer;
  Timer? _visionTimeout;
  Timer? _idleTimer;
  Timer? _micWatchdog;
  Timer? _screenLockRelease;
  bool _agentCallActive = false;

  /// Last sign of a live conversation — user speech, agent audio, a tool call.
  /// Drives the idle watchdog instead of screen presence.
  DateTime _lastActivity = DateTime.now();

  static const _playChannel = MethodChannel('ai.fox1/audio_play');

  // All tunable durations live in AppConstants so they can be reasoned about
  // together rather than hunted across a dozen files.
  static const Duration defaultVisionTimeout = AppConstants.visionAutoStop;

  final _sessionState = StreamController<AISessionState>.broadcast();
  final _transcript = StreamController<TranscriptEntry>.broadcast();
  final _visionState = StreamController<bool>.broadcast();

  Stream<AISessionState> get sessionState => _sessionState.stream;
  Stream<TranscriptEntry> get transcript => _transcript.stream;

  /// Whether the camera is live. The UI must show this — the agent can turn the
  /// camera on by itself, so the wearer needs to see when it is watching.
  Stream<bool> get visionState => _visionState.stream;

  bool get isActive => _connected;
  bool get isListening => _listening;

  /// Latest state, for observers that attach after an event has already fired.
  /// [sessionState] is a broadcast stream and does not replay.
  AISessionState get currentState => _currentState;
  AISessionState _currentState = AISessionState.stopped;
  @override
  bool get isVisionActive => _visionActive;

  /// Called when the agent should hand the screen back to the watch face.
  final void Function()? onRequestHome;

  AISession({
    required this.audioManager,
    required this.cameraService,
    required this.gemini,
    this.agentBridge,
    this.cameraConfig = const CameraConfig(),
    this.onRequestHome,
    Duration Function()? idleLimit,
    this.onConversationEnded,
  }) : idleLimit = idleLimit ?? (() => AppConstants.idleBeforeCold);

  /// How long a quiet conversation lasts before it ends — the wearer's
  /// "Stand down after" setting, read each time so a change applies at once.
  final Duration Function() idleLimit;

  /// Called once a quiet conversation has ended (gone cold for being idle),
  /// so it can be remembered and the next one started fresh.
  final void Function()? onConversationEnded;

  /// "Stand down" — the user is done. Mic off, camera off, back to the device
  /// face. The socket and the conversation are kept, so returning to the agent
  /// screen resumes rather than restarts.
  @override
  Future<void> standDown() async {
    debugPrint('[AI_SESSION] standing down');
    // A ring double-tap stops helper work too, not only her own stand_down.
    final bridge = agentBridge;
    if (bridge is NativeToolsBridge) bridge.cancelHelper();
    unawaited(SystemActionsService.holdForConversation(false));
    // The release sound, so a wearer with the wrist down knows she has stopped
    // listening — whether they double-tapped or she stood down herself. It is
    // queued behind whatever she is still saying, so it follows her last words.
    unawaited(audioManager.playEarcon(Earcon.done));
    await stopListening();
    await stopVision();
    _queuedNotes.clear();
    _releaseScreenAwake();
    _emitState(AISessionState.warm);
    _armIdleWatchdog();
    onRequestHome?.call();
  }

  /// Send the launcher back to the watch face without changing the mic state.
  @override
  void requestHomeScreen() => onRequestHome?.call();

  void _emitState(AISessionState state) {
    _currentState = state;
    if (!_disposed) _sessionState.add(state);
  }

  // ---------------------------------------------------------------- lifecycle

  /// Bring the session to full readiness: socket connected, mic capturing.
  /// Resumes the previous conversation when a handle is available.
  Future<void> wake() async {
    if (_disposed) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _markActivity();

    try {
      if (!_connected) {
        _emitState(AISessionState.starting);
        // The mic first: the wearer is already talking when they hold the ring
        // down, and the socket takes a second or two. What they say in the
        // meantime is buffered by [_sendMic], not lost.
        unawaited(startListening());
        await _connect();
      }
      await startListening();
      _emitState(AISessionState.active);
      // The countdown runs from the start, not only after leaving the agent
      // screen: a hold from the watch face changes no screen, and that
      // conversation never ended by itself.
      _armIdleWatchdog();
      // And the screen stays up while she is listening — if it is on.
      unawaited(SystemActionsService.holdForConversation(true));
    } catch (e) {
      debugPrint('[AI_SESSION] wake failed: $e');
      _emitState(AISessionState.error);
      await goCold();
      rethrow;
    }
  }

  /// Developer measurement (`/api/dev/task`): [text] as a typed request in a
  /// **fresh** conversation with the microphone off, so what it costs is the
  /// task alone — no resumed history, no room noise. Every turn's tokens land
  /// in `gemini.usage`.
  Future<void> runTypedTask(String text) async {
    if (_disposed) return;
    if (_connected) await goCold();
    gemini.forgetResumption();
    gemini.usage.clear();
    _markActivity();
    _emitState(AISessionState.starting);
    await _connect();
    _emitState(AISessionState.active);
    debugPrint('[AI_SESSION] typed task: $text');
    gemini.sendText(text);
  }

  Future<void> _connect() async {
    // A handle from the previous connection restores that conversation instead
    // of starting a blank one.
    await gemini.connect(resumeHandle: gemini.resumptionHandle);
    _wireGeminiStreams();
    _connected = true;
  }

  /// Leaving the agent screen. The camera is released, but **listening
  /// continues** — the conversation is not over just because you swiped away or
  /// the agent opened another app to work in. An idle watchdog reclaims the
  /// power once the conversation actually goes quiet.
  Future<void> goWarm() async {
    if (_disposed || !_connected) return;
    await stopVision();
    _armIdleWatchdog();
  }

  /// The app went to background — display timeout, or the agent launched
  /// another app. Never tear down a live conversation here: the wearer may be
  /// mid-sentence with the screen off, and agentic app control depends on the
  /// session surviving while FOX-1 is not foreground.
  Future<void> onBackgrounded() async {
    if (_disposed || !_connected) return;
    if (_conversationIsLive) {
      _armIdleWatchdog();
      return;
    }
    debugPrint('[AI_SESSION] backgrounded while idle -> cold');
    await goCold();
  }

  /// A conversation counts as live while the agent is on a call, running a job,
  /// or there has been recent speech either way — regardless of what is on
  /// screen. Deliberately does NOT test [_listening]: the mic now stays open
  /// across screen changes, so that would never become false.
  bool get _conversationIsLive =>
      _agentCallActive ||
      _toolsRunning > 0 ||
      _jobPollers.isNotEmpty ||
      _watchers.isNotEmpty ||
      gemini.busy ||
      DateTime.now().difference(_lastActivity) < idleLimit();

  void _markActivity() => _lastActivity = DateTime.now();

  /// Periodic rather than one-shot, so any activity naturally defers the drop
  /// instead of needing the timer rescheduled from a dozen call sites.
  void _armIdleWatchdog() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(AppConstants.idleWatchdogTick, (t) {
      if (_disposed || !_connected) {
        t.cancel();
        return;
      }
      // Talking, listening or working: the screen stays up. Refreshed here
      // so the native hold's safety timeout never cuts in mid-conversation.
      if (isListening || _toolsRunning > 0) {
        unawaited(SystemActionsService.holdForConversation(true));
      }
      if (_agentCallActive || _toolsRunning > 0 || _watchers.isNotEmpty || gemini.busy) {
        return;
      }
      final limit = idleLimit();
      if (DateTime.now().difference(_lastActivity) >= limit) {
        debugPrint('[AI_SESSION] quiet for ${limit.inMinutes}m -> conversation over');
        t.cancel();
        goCold().then((_) => onConversationEnded?.call());
      }
    });
  }

  /// Release everything including the socket. The conversation survives in the
  /// server-side resumption handle, which stays valid for two hours.
  Future<void> goCold() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _releaseScreenAwake();
    // Idle: the ordinary screen timeout applies again.
    unawaited(SystemActionsService.holdForConversation(false));

    await stopListening();
    await stopVision();
    _stopAllWatchers();
    _stopAllJobWatchers();
    // Stale progress notes must not surface in a later conversation.
    _queuedNotes.clear();
    _modelSpeaking = false;
    _callEndTimer?.cancel();
    _callEndTimer = null;
    await _teardownAgentCall();

    if (_connected) {
      _connected = false;
      await gemini.disconnect();
    }
    audioManager.resetForNewSession();
    await audioManager.releaseAudioRoute();

    if (!_disposed) _sessionState.add(AISessionState.stopped);
  }

  /// Full teardown. Use [goCold] for ordinary idling — this abandons the
  /// conversation entirely.
  Future<void> stop() => goCold();

  // -------------------------------------------------------------------- mic

  /// What the wearer said while the socket was still coming up.
  final _preroll = PrerollBuffer();

  void _sendMic(Uint8List pcm) {
    if (!_connected) {
      _preroll.add(pcm);
      return;
    }
    if (!_preroll.isEmpty) {
      debugPrint('[AI_SESSION] sending ${_preroll.duration.inMilliseconds}ms '
          'captured while connecting');
      for (final c in _preroll.takeAll()) {
        gemini.sendAudio(c);
      }
    }
    gemini.sendAudio(pcm);
  }

  Future<void> startListening() async {
    if (_disposed) return;

    // Trust the recorder, not the flag. The mic can die underneath us when
    // another app takes audio focus — and a stale _listening flag used to make
    // this return early, so returning to the screen could never recover it.
    if (_listening && audioManager.isRecording) return;
    if (_listening) {
      debugPrint('[AI_SESSION] mic died underneath — restarting');
      await stopListening();
    }

    await audioManager.init();
    final ok = await audioManager.startMicCapture();
    if (!ok) {
      debugPrint('[AI_SESSION] mic failed to start');
      return;
    }
    _micSub = audioManager.micStream.listen(
      _sendMic,
      onError: (e) => debugPrint('[AI_SESSION] mic stream error: $e'),
    );
    _listening = true;
    _armMicWatchdog();
  }

  Future<void> stopListening() async {
    _micWatchdog?.cancel();
    _micWatchdog = null;
    if (!_listening) return;
    _listening = false;
    await _micSub?.cancel();
    _micSub = null;
    await audioManager.stopMicCapture();
  }

  /// The UI reporting "Listening..." while the recorder is dead is the worst
  /// failure mode — you talk and nothing happens. Check periodically and repair.
  void _armMicWatchdog() {
    _micWatchdog?.cancel();
    _micWatchdog = Timer.periodic(AppConstants.micWatchdogTick, (t) async {
      if (_disposed || !_listening) {
        t.cancel();
        return;
      }
      if (!audioManager.isRecording) {
        debugPrint('[AI_SESSION] mic watchdog: recorder stopped — restarting');
        await startListening();
      }
    });
  }

  // ----------------------------------------------------------------- vision

  @override
  Future<bool> startVision({
    Duration autoStopAfter = defaultVisionTimeout,
  }) async {
    if (_disposed) return false;
    _visionTimeout?.cancel();
    _visionTimeout = Timer(autoStopAfter, () {
      debugPrint('[AI_SESSION] vision timeout -> stopping camera');
      stopVision();
    });

    if (_visionActive) return true;

    try {
      await cameraService.start(config: cameraConfig);
      _cameraSub = cameraService.frames.listen(
        (jpeg) => gemini.sendFrame(jpeg),
        onError: (e) => debugPrint('[AI_SESSION] camera stream error: $e'),
      );
      _visionActive = true;
      if (!_disposed) _visionState.add(true);
      return true;
    } catch (e) {
      debugPrint('[AI_SESSION] startVision failed: $e');
      _visionTimeout?.cancel();
      _visionTimeout = null;
      return false;
    }
  }

  @override
  Future<void> stopVision() async {
    _visionTimeout?.cancel();
    _visionTimeout = null;
    if (!_visionActive) return;
    _visionActive = false;
    await _cameraSub?.cancel();
    _cameraSub = null;
    await cameraService.stop();
    if (!_disposed) _visionState.add(false);
  }

  @override
  Future<bool> lookOnce() async {
    if (_disposed) return false;

    // Already streaming — the model is receiving frames, nothing to do.
    if (_visionActive) return true;

    try {
      await cameraService.start(config: cameraConfig);
      _visionActive = true;
      if (!_disposed) _visionState.add(true);

      // Hold the tool call open until a frame has genuinely been delivered,
      // otherwise the model answers before it can see anything.
      final delivered = Completer<bool>();
      final sub = cameraService.frames.listen((jpeg) {
        gemini.sendFrame(jpeg);
        if (!delivered.isCompleted) delivered.complete(true);
      }, onError: (e) {
        if (!delivered.isCompleted) delivered.complete(false);
      });

      final ok = await delivered.future.timeout(
        AppConstants.firstFrameTimeout,
        onTimeout: () => false,
      );
      await sub.cancel();
      return ok;
    } catch (e) {
      debugPrint('[AI_SESSION] lookOnce failed: $e');
      return false;
    } finally {
      // Single shot: release the camera immediately.
      _visionActive = false;
      await cameraService.stop();
      if (!_disposed) _visionState.add(false);
    }
  }

  // ------------------------------------------------------- environment watches

  @override
  List<String> get pendingWatches => _watchers.keys.toList();

  @override
  bool cancelWatch(String id) {
    final t = _watchers.remove(id);
    t?.cancel();
    return t != null;
  }

  void _stopAllJobWatchers() {
    for (final t in _jobPollers.values) {
      t.cancel();
    }
    _jobPollers.clear();
  }

  /// Watches a background job and NUDGES the model when there is something to
  /// fetch.
  ///
  /// Two failed designs preceded this. Injecting the progress text itself made
  /// the agent converse with its own updates, because sendText is
  /// realtimeInput.text and the API reads it as the user talking. Leaving the
  /// model to poll on its own failed differently: after generationComplete the
  /// turn ends and nothing ever wakes it, so it shipped the job and forgot it.
  ///
  /// So: poll silently here, and when there IS new output send a bare
  /// imperative — no content. The model then calls check_job itself and
  /// receives the delta through the tool channel, which cannot interrupt it and
  /// which it will not try to hold a conversation with.
  void _watchJob(String jobId) {
    if (_jobPollers.containsKey(jobId)) return;

    final startedAt = DateTime.now();
    var lastProgressAt = DateTime.now();
    var lastSeen = 0;
    var seenAtLastNotify = 0;
    var heartbeats = 0;
    DateTime? lastNotifiedAt;
    var inFlight = false;

    void finish(Timer t) {
      t.cancel();
      _jobPollers.remove(jobId);
    }

    _jobPollers[jobId] =
        Timer.periodic(AppConstants.jobPollInterval, (timer) async {
      if (_disposed || !_connected || agentBridge == null) {
        finish(timer);
        return;
      }
      // Keeps the session out of the idle watchdog's hands while work is live.
      _markActivity();
      if (!_modelSpeaking && !audioManager.aiSpeaking) _flushQueuedNotes();

      final now = DateTime.now();
      if (now.difference(lastProgressAt) > AppConstants.jobStallTimeout ||
          now.difference(startedAt) > AppConstants.jobPollMaxAge) {
        finish(timer);
        _notifyAgent(
          '[Stopped tracking job $jobId after '
          '${now.difference(startedAt).inMinutes} minutes with no new output. '
          'Call check_job with job_id "$jobId" if you still need the result.]',
        );
        return;
      }

      if (inFlight) return;
      inFlight = true;
      try {
        // Peek with _stream so we can see progress. This does NOT consume the
        // delta — only the model's own check_job advances that cursor.
        final peek = await agentBridge!.handleToolCall(
          'check_job',
          {'job_id': jobId, '_stream': true},
        );

        final status = (peek['status'] as String? ?? '').toLowerCase();
        final done = status == 'completed' ||
            status == 'failed' ||
            status == 'error' ||
            status == 'cancelled';

        final stream = peek['stream_response'];
        final available = stream is List
            ? stream.length
            : (stream is String ? stream.length : 0);

        if (available > lastSeen) {
          lastSeen = available;
          lastProgressAt = now;
        }

        if (done) {
          finish(timer);
          final failed = status == 'failed' || status == 'error';
          _notifyAgent(
            failed
                ? '[The background job FAILED. Call check_job with job_id '
                    '"$jobId" to see why, then tell the user plainly that it '
                    'failed and what went wrong.]'
                : status == 'cancelled'
                    ? '[The background job was CANCELLED. Tell the user in one '
                        'short line.]'
                    : '[The background job has FINISHED. Call check_job with '
                        'job_id "$jobId" now to get the result, then report it '
                        'to the user.]',
          );
          return;
        }

        // Heartbeat. Every wake is a barge-in as far as the Live API is
        // concerned — sendText is realtimeInput.text — so these are spaced in
        // MINUTES and never sent while the agent is audible. Nudging per output
        // chunk is what interrupted it every 5 seconds; silence for the whole
        // job is no good either on a voice device.
        final due = heartbeats == 0
            ? AppConstants.jobHeartbeatFirst
            : AppConstants.jobHeartbeatInterval;
        final sinceLast = lastNotifiedAt == null
            ? now.difference(startedAt)
            : now.difference(lastNotifiedAt!);
        final gapOk = lastNotifiedAt == null ||
            now.difference(lastNotifiedAt!) >= AppConstants.jobNotifyMinGap;

        if (sinceLast >= due && gapOk) {
          heartbeats++;
          lastNotifiedAt = now;
          final elapsed = now.difference(startedAt);
          final howLong = elapsed.inMinutes >= 1
              ? '${elapsed.inMinutes} minute${elapsed.inMinutes == 1 ? '' : 's'}'
              : '${elapsed.inSeconds} seconds';
          final hasNew = available > seenAtLastNotify;
          seenAtLastNotify = available;

          _notifyAgent(
            hasNew
                // Content still travels the tool channel, never this one.
                ? '[Background job still running, $howLong so far, and there '
                    'IS new progress. Call check_job with job_id "$jobId" and '
                    'relay only what it returns, in one short line.]'
                : '[Background job still running, $howLong so far, with no new '
                    'output yet. Tell the user in ONE short line that it is '
                    'taking longer than usual. Do not call check_job. Say '
                    'nothing else.]',
          );
        }
      } catch (e) {
        debugPrint('[AI_SESSION] job watch error ($jobId): $e');
      } finally {
        inFlight = false;
      }
    });
  }

  void _stopAllWatchers() {
    for (final t in _watchers.values) {
      t.cancel();
    }
    _watchers.clear();
  }

  /// Re-enter the model with an observation it did not ask for. This is the
  /// whole mechanism: without it the agent has no way to learn that the world
  /// changed after its last tool call.
  ///
  /// Injected text is treated as user input and CANCELS an in-flight
  /// generation, so anything arriving mid-sentence used to cut the agent off
  /// and make it start over. Updates are therefore held until the turn ends,
  /// then merged into one message.
  void _notifyAgent(String message, {bool urgent = false}) {
    _markActivity();
    // audioManager.aiSpeaking stays true for a few seconds after the last
    // chunk, covering the tail that is still draining out of the AudioTrack —
    // _modelSpeaking alone clears at turnComplete, while audio is still
    // audible. Interrupting there is what chopped words in half.
    if ((_modelSpeaking || audioManager.aiSpeaking) && !urgent) {
      _queuedNotes.add(message);
      // Its own flush. The job poller used to be the only one, so a screen
      // watch that fired while she spoke, with no job running, was never
      // delivered: Spotify's "Search" appeared and she waited for ever.
      _noteFlusher ??= Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (_modelSpeaking || audioManager.aiSpeaking) return;
        t.cancel();
        _noteFlusher = null;
        if (!_disposed && _connected) _flushQueuedNotes();
      });
      return;
    }
    gemini.sendText(message);
  }

  Timer? _noteFlusher;

  /// Say something to the agent from outside the conversation.
  ///
  /// Used to hand it a call report so it can pass the message on. Goes through
  /// the same queue as job updates, so it cannot cut the agent off mid-sentence.
  void tell(String message, {bool urgent = false}) =>
      _notifyAgent(message, urgent: urgent);

  void _flushQueuedNotes() {
    if (_queuedNotes.isEmpty) return;
    final merged = _queuedNotes.join('\n');
    _queuedNotes.clear();
    gemini.sendText(merged);
  }

  @override
  String watchScreenFor({
    required String text,
    required Duration timeout,
    required bool untilGone,
  }) {
    final id = 'w${++_watchSeq}';
    final needle = text.toLowerCase();
    final deadline = DateTime.now().add(timeout);

    // The condition is a UI change we must be able to see and then act on, so
    // the display has to stay awake for the duration of the device.
    _holdScreenAwake();

    _watchers[id] = Timer.periodic(AppConstants.screenWatchInterval, (t) async {
      if (_disposed || !_connected) {
        t.cancel();
        _watchers.remove(id);
        return;
      }

      // keep: false — polling must not renumber the ids the model is holding.
      final screen = await _screenAutomation.getScreen(keep: false);
      final present = screen['success'] == true &&
          '${screen['screen']}'.toLowerCase().contains(needle);
      final matched = untilGone ? !present : present;

      if (matched) {
        t.cancel();
        _watchers.remove(id);
        // Refresh the wake lock: the agent is about to act on this screen.
        _holdScreenAwake();
        _notifyAgent(
          '[Screen watch fired: "$text" '
          '${untilGone ? 'is no longer on screen' : 'has appeared on screen'}. '
          'Resume the task now — call get_screen and continue.]',
        );
        return;
      }

      if (DateTime.now().isAfter(deadline)) {
        t.cancel();
        _watchers.remove(id);
        _notifyAgent(
          '[Screen watch timed out after ${timeout.inSeconds}s waiting for '
          '"$text" to ${untilGone ? 'disappear' : 'appear'}. '
          'Decide what to do next — do not just report failure.]',
        );
      }
    });

    return id;
  }

  @override
  String scheduleFollowUp({required Duration delay, required String note}) {
    final id = 'f${++_watchSeq}';
    _watchers[id] = Timer(delay, () {
      _watchers.remove(id);
      _notifyAgent(
        '[Follow-up timer fired. Your note was: "$note". '
        'Resume the task now.]',
      );
    });
    return id;
  }

  // ------------------------------------------------------------------ wiring

  /// Gemini's streams outlive individual connections — the client keeps its
  /// broadcast controllers across reconnects, so this runs once.
  void _wireGeminiStreams() {
    if (_geminiWired) return;
    _geminiWired = true;

    void onStreamError(dynamic e, String source) {
      debugPrint('[AI_SESSION] Stream error ($source): $e');
    }

    _geminiSubs.add(
      gemini.audioResponses.listen(
        (pcm) {
          _markActivity();
          if (!_modelSpeaking) audioManager.onTurnStart();
          _modelSpeaking = true;
          audioManager.onAiSpeechStart();
          audioManager.addAiAudioChunk(pcm);
        },
        onError: (e) => onStreamError(e, 'audioResponses'),
      ),
    );

    _geminiSubs.add(
      gemini.turnComplete.listen(
        (_) {
          _markActivity();
          _modelSpeaking = false;
          audioManager.onAiSpeechEnd();
          // Deferred until the audio tail has drained; the job watcher's tick
          // flushes it once aiSpeaking clears.
        },
        onError: (e) => onStreamError(e, 'turnComplete'),
      ),
    );

    // Extended thinking carries on after turnComplete — reasoning, or waiting
    // on a tool. While it does, the conversation is not quiet.
    _geminiSubs.add(
      gemini.busyChanges.listen(
        (_) => _markActivity(),
        onError: (e) => onStreamError(e, 'busy'),
      ),
    );

    // The wearer speaking counts even before the agent has replied.
    _geminiSubs.add(
      audioManager.userSpeakingState.listen(
        (speaking) {
          if (speaking) _markActivity();
        },
        onError: (e) => onStreamError(e, 'userSpeaking'),
      ),
    );

    _geminiSubs.add(
      gemini.userTranscripts.listen(
        (text) {
          _transcript.add(TranscriptEntry(
            role: TranscriptRole.user,
            text: text,
            timestamp: DateTime.now(),
          ));
        },
        onError: (e) => onStreamError(e, 'userTranscripts'),
      ),
    );

    _geminiSubs.add(
      gemini.textResponses.listen(
        (text) {
          _transcript.add(TranscriptEntry(
            role: TranscriptRole.assistant,
            text: text,
            timestamp: DateTime.now(),
          ));
        },
        onError: (e) => onStreamError(e, 'textResponses'),
      ),
    );

    // User spoke over the agent: flush queued speech immediately so it stops
    // talking, rather than finishing its buffered sentence.
    _geminiSubs.add(
      gemini.interrupted.listen(
        (_) {
          _markActivity();
          _modelSpeaking = false;
          audioManager.interruptPlayback();
        },
        onError: (e) => onStreamError(e, 'interrupted'),
      ),
    );

    // Hands-free barge-in. By the time the wearer talks over her, the model
    // has usually finished generating — the reply is already in the AudioTrack
    // — so the server has nothing left to interrupt and never says so. Its
    // voice-activity detector still hears them (ACTIVITY_START at 10:32:27 on
    // hardware, with her voice playing on for another half minute), and that
    // is the cue to stop playing what is already here.
    _geminiSubs.add(
      gemini.speechStarted.listen(
        (_) {
          if (!_modelSpeaking && !audioManager.aiSpeaking) return;
          debugPrint('[AI_SESSION] wearer started talking — she stops');
          audioManager.interruptPlayback();
        },
        onError: (e) => onStreamError(e, 'speechStarted'),
      ),
    );

    // A socket that simply closes — idle timeout, dropped network — was only
    // handled when the server sent goAway first. Otherwise the session went
    // on believing it was connected, and every later hold "woke" it into
    // silence until the app was relaunched.
    _geminiSubs.add(
      gemini.closed.listen(
        (_) {
          if (_disposed || _reconnecting || !_connected) return;
          _connected = false;
          debugPrint('[AI_SESSION] socket closed under us'
              '${_listening ? ' mid-conversation — reconnecting' : ' — the next wake reconnects'}');
          if (_listening) unawaited(_reconnectPreservingContext());
        },
        onError: (e) => onStreamError(e, 'closed'),
      ),
    );

    // The server warns before closing. Reconnect on the handle so the turn
    // survives instead of dying mid-sentence.
    _geminiSubs.add(
      gemini.goAway.listen(
        (timeLeft) => _reconnectPreservingContext(),
        onError: (e) => onStreamError(e, 'goAway'),
      ),
    );

    _geminiSubs.add(
      gemini.toolCalls.listen(
        _handleToolCall,
        onError: (e) => onStreamError(e, 'toolCalls'),
      ),
    );
  }

  Future<void> _reconnectPreservingContext() async {
    if (_disposed || _reconnecting) return;
    _reconnecting = true;
    // The mic stops for the reconnect, and with it the audio that kept the CPU
    // up. On hardware a reconnect with the screen off then sat stalled for
    // 53 s, until the wearer's next press woke the device.
    unawaited(SystemActionsService.keepCpuAwake(const Duration(seconds: 20)));
    try {
      final wasListening = _listening;

      await stopListening();
      await gemini.disconnect();
      _connected = false;

      await gemini.connect(resumeHandle: gemini.resumptionHandle);
      _connected = true;

      if (wasListening) await startListening();
      // Vision needs no attention: the camera subscription forwards into the
      // same client object, which is now reconnected.
      debugPrint('[AI_SESSION] reconnected on resumption handle');
    } catch (e) {
      debugPrint('[AI_SESSION] reconnect failed: $e');
      _emitState(AISessionState.error);
    } finally {
      _reconnecting = false;
    }
  }

  // -------------------------------------------------------------- tool calls

  /// Tools that drive the device UI. These only work on an interactive display,
  /// so the screen must be held awake while they run.
  static const Set<String> _uiAutomationTools = {
    'launch_app', 'get_screen', 'tap', 'swipe',
    'type_text', 'press_back', 'press_enter', 'press_home', 'scroll',
    'wait_for_screen', 'app_shortcut', 'do_on_device',
  };

  /// Tool calls still working. `do_on_device` can take minutes; that is the
  /// agent busy, not the conversation quiet.
  int _toolsRunning = 0;

  /// Keep the display up for a grace period after each automation step — the
  /// gap between steps is a Gemini round trip, and a timeout mid-task strands
  /// the agent with gestures landing nowhere.
  static const Duration screenAwakeGrace = AppConstants.screenAwakeGrace;

  Future<void> _holdScreenAwake() async {
    await SystemActionsService.acquireScreenLock();
    _screenLockRelease?.cancel();
    _screenLockRelease = Timer(screenAwakeGrace, () {
      SystemActionsService.releaseScreenLock();
    });
  }

  void _releaseScreenAwake() {
    _screenLockRelease?.cancel();
    _screenLockRelease = null;
    SystemActionsService.releaseScreenLock();
  }

  Future<void> _handleToolCall(GeminiToolCall call) async {
    _markActivity();
    if (_uiAutomationTools.contains(call.name)) {
      await _holdScreenAwake();
    }
    if (agentBridge == null) {
      gemini.sendToolResponse(call.id, {
        'success': false,
        'error': 'Agent not configured',
      }, name: call.name);
      return;
    }

    _transcript.add(TranscriptEntry(
      role: TranscriptRole.system,
      text: '${agentBridge!.providerName}: ${call.name}(${call.args})',
      timestamp: DateTime.now(),
    ));

    final ui = _uiAutomationTools.contains(call.name);
    // The screen stays up for as long as the tool works — the grace timer
    // counts from when it finishes, not from when it started.
    if (ui) _screenLockRelease?.cancel();
    _toolsRunning++;
    final Map<String, dynamic> result;
    try {
      result = await agentBridge!.handleToolCall(call.name, call.args);
    } finally {
      _toolsRunning--;
      _markActivity();
    }
    if (ui) unawaited(_holdScreenAwake());
    gemini.sendToolResponse(call.id, result, name: call.name);

    if (call.name == 'make_call' && result['success'] == true) {
      await _setupAgentCallAudio();
    } else if (call.name == 'end_call') {
      await _teardownAgentCall();
    }

    _transcript.add(TranscriptEntry(
      role: TranscriptRole.system,
      text: result['success'] == true
          ? 'Done: ${result['result'] ?? result['status'] ?? 'OK'}'
          : 'Error: ${result['error']}',
      timestamp: DateTime.now(),
    ));

    final jobId = result['job_id'] as String?;
    if (jobId != null && jobId.isNotEmpty) {
      _watchJob(jobId);
    }
  }

  // ------------------------------------------------------------------- calls

  /// Setup for phone call. Keep everything running as-is:
  /// - VOICE_COMMUNICATION AudioTrack → routes Gemini's voice to the caller
  /// - Device mic stays on → picks up caller's voice from speaker
  /// Poll for call end to show proper status and recover if needed.
  Future<void> _setupAgentCallAudio() async {
    if (_agentCallActive) return;
    _agentCallActive = true;
    _emitState(AISessionState.onCall);

    await Future.delayed(AppConstants.callConnectWait);
    if (!_agentCallActive || !_connected) return;

    gemini.sendText(
      '[You are now on a live phone call. The caller can hear you through '
      'the phone. Their voice comes through the speaker — you can hear them. '
      'Speak naturally to the caller. Use end_call when the conversation is done.]',
    );

    _callEndTimer?.cancel();
    _callEndTimer = Timer.periodic(AppConstants.callEndPollInterval, (t) async {
      if (!_agentCallActive || !_connected) {
        t.cancel();
        return;
      }
      final state = await _inCallService.getCallState();
      if (state == null) {
        t.cancel();
        await _teardownAgentCall();
      }
    });
  }

  Future<void> _teardownAgentCall() async {
    if (!_agentCallActive) return;
    _agentCallActive = false;

    _callEndTimer?.cancel();
    _callEndTimer = null;

    try {
      await _playChannel.invokeMethod('init', {
        'sampleRate': 24000,
        'channels': 1,
      });
    } catch (_) {}

    try {
      // Back to the user after a call: media route, never SCO.
      await const MethodChannel('ai.fox1/audio')
          .invokeMethod('setRoute', {'route': 'media'});
    } catch (_) {}

    if (_listening && !audioManager.isRecording) {
      await audioManager.startMicCapture();
    }

    if (_connected) {
      _emitState(AISessionState.active);
      gemini.sendText('[Phone call ended. You are back to normal mode.]');
    }
  }

  // -------------------------------------------------------------- job poller

  void dispose() {
    _disposed = true;
    unawaited(SystemActionsService.holdForConversation(false));
    _stopAllWatchers();
    _stopAllJobWatchers();
    _idleTimer?.cancel();
    _visionTimeout?.cancel();
    _micWatchdog?.cancel();
    _releaseScreenAwake();
    for (final sub in _geminiSubs) {
      sub.cancel();
    }
    _geminiSubs.clear();
    goCold();
    _sessionState.close();
    _transcript.close();
    _visionState.close();
  }
}

enum AISessionState { stopped, starting, active, warm, onCall, error }

enum TranscriptRole { user, assistant, system }

class TranscriptEntry {
  final TranscriptRole role;
  final String text;
  final DateTime timestamp;

  TranscriptEntry({
    required this.role,
    required this.text,
    required this.timestamp,
  });
}
