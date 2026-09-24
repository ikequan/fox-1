import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../config/constants.dart';

/// Client for Gemini Live API (bidirectional WebSocket).
/// Sends: JPEG frames + PCM audio
/// Receives: PCM audio responses + tool calls + text transcripts
///
/// Uses the universal format from Google's official examples:
/// `setup` top-level key, camelCase fields, `realtimeInput.audio`/`video`.
class GeminiLiveClient {
  WebSocketChannel? _ws;
  final GeminiConfig config;
  StreamSubscription? _wsSubscription;

  final _audioResponse = StreamController<Uint8List>.broadcast();
  final _textResponse = StreamController<String>.broadcast();
  final _toolCall = StreamController<GeminiToolCall>.broadcast();
  final _connectionState = StreamController<GeminiConnectionState>.broadcast();
  final _turnComplete = StreamController<void>.broadcast();
  final _debugLog = StreamController<String>.broadcast();
  final _goAway = StreamController<Duration>.broadcast();
  final _interrupted = StreamController<void>.broadcast();
  final _speechStarted = StreamController<void>.broadcast();
  final _closed = StreamController<void>.broadcast();
  final _userTranscript = StreamController<String>.broadcast();
  final _busy = StreamController<bool>.broadcast();
  bool _inProgress = false;

  /// Extended thinking reasons in the background and runs tools without
  /// blocking the conversation: it needs `thinkingConfig`, NON_BLOCKING tool
  /// declarations, scheduled tool responses — and `turnComplete` no longer
  /// means it has finished (see [busy]).
  bool get thinks => config.model == AppConstants.geminiThinkingModel;

  /// The server's `interactionStatus` is IN_PROGRESS: still reasoning or
  /// waiting on a tool, even after `turnComplete`. Only extended thinking
  /// sends it, so on other models this stays false.
  bool get busy => _inProgress;
  Stream<bool> get busyChanges => _busy.stream;

  /// `interactionStatus` of a server message: true for IN_PROGRESS, false for
  /// IDLE, null when the message does not say.
  static bool? interactionBusy(Map<String, dynamic> msg) {
    final sc = msg['serverContent'];
    final status = msg['interactionStatus'] ?? (sc is Map ? sc['interactionStatus'] : null);
    return switch (status) {
      'IN_PROGRESS' => true,
      'IDLE' => false,
      _ => null,
    };
  }

  Stream<Uint8List> get audioResponses => _audioResponse.stream;
  Stream<String> get textResponses => _textResponse.stream;

  /// What the WEARER said, as the server heard it.
  ///
  /// Distinct from [textResponses], which is the model's own speech. Only this
  /// stream can answer "did a person actually reply" — which is what decides
  /// whether a queued message has been delivered or merely announced.
  Stream<String> get userTranscripts => _userTranscript.stream;
  Stream<GeminiToolCall> get toolCalls => _toolCall.stream;
  Stream<GeminiConnectionState> get connectionState =>
      _connectionState.stream;
  Stream<void> get turnComplete => _turnComplete.stream;
  Stream<String> get debugLog => _debugLog.stream;

  /// Fires when the server warns it is about to close the connection, carrying
  /// the time remaining. Reconnect with [resumptionHandle] to keep context.
  Stream<Duration> get goAway => _goAway.stream;

  /// The server detected the user speaking over the model and cancelled
  /// generation. Anything already buffered for playback must be dropped now.
  Stream<void> get interrupted => _interrupted.stream;

  /// Gemini's own voice-activity detector heard the wearer start speaking.
  Stream<void> get speechStarted => _speechStarted.stream;

  /// The socket closed — for any reason, announced by goAway or not.
  Stream<void> get closed => _closed.stream;

  /// `voiceActivity.type` of a server message: 'start', 'end' or null.
  static String? speechActivityOf(Map<String, dynamic> msg) {
    final va = msg['voiceActivity'];
    if (va is! Map) return null;
    return switch (va['type']) {
      'ACTIVITY_START' => 'start',
      'ACTIVITY_END' => 'end',
      _ => null,
    };
  }

  bool _connected = false;
  bool _disposed = false;
  bool _setupComplete = false;
  Completer<void>? _setupCompleter;
  bool get isConnected => _connected && _setupComplete;

  /// When a message last arrived. A Live session that has stalled still reports
  /// [isConnected] — the socket is open, nothing is coming through it — so this
  /// is the only way to tell the difference from outside.
  DateTime? get lastMessageAt => _lastMessageAt;
  DateTime? _lastMessageAt;
  int _msgCount = 0;

  String? _resumptionHandle;
  bool _resumable = false;
  String? _pendingResumeHandle;

  /// When the server last sent a handle — while connected, about once a
  /// second, so this is effectively when the session last lived.
  DateTime? _handleAt;
  bool _handleLogged = false;

  /// Cleared permanently if the server won't accept sessionResumption /
  /// contextWindowCompression, so one bad handshake can't break the session.
  bool _sessionFeaturesEnabled = true;

  /// True once the server has actually issued a resumption handle — i.e. the
  /// feature is confirmed working, not assumed.
  bool get sessionResumptionConfirmed => _resumptionHandle != null;

  /// Server-side handle for resuming this conversation after a disconnect.
  /// Null until the server issues one, and once Google no longer keeps it.
  String? get resumptionHandle =>
      _resumable && resumeHandleFresh(_handleAt, DateTime.now())
          ? _resumptionHandle
          : null;

  /// Google keeps a handle for two hours after the session ends. One from
  /// 3 h 40 m earlier was refused on hardware — the socket closed 0.7 s after
  /// setup — and the setup timeout then took that for the model rejecting
  /// session features. A little under two hours, to stay clear of the edge.
  static const handleLifetime = Duration(minutes: 110);

  static bool resumeHandleFresh(DateTime? issued, DateTime now) =>
      issued != null && now.difference(issued) < handleLifetime;

  void _log(String msg) {
    debugPrint('[GEMINI] $msg');
    if (!_disposed) _debugLog.add(msg);
  }

  GeminiLiveClient({required this.config});

  /// Opens the session. Pass [resumeHandle] (from a previous connection's
  /// [resumptionHandle]) to restore that conversation's context server-side
  /// instead of starting fresh.
  Future<void> connect({String? resumeHandle}) {
    // Single-flight. Two overlapping connects share `_ws`: one replaces it
    // while the other is still listening, and the loser throws
    //   Bad state: Stream has already been listened to.
    //
    // That was not a rare race. The call agent gives up on a connect after 30 s
    // and tries again, while this method's own worst case is 8 s ready + 8 s
    // setup, then the whole thing retried without session features — over 30 s,
    // every time. The abandoned attempt was always still running.
    //
    // A second caller now joins the attempt already in flight instead of
    // starting a rival one.
    final inFlight = _connecting;
    if (inFlight != null) {
      _log('connect already in flight — joining it');
      return inFlight;
    }
    final f = _connectOnce(resumeHandle: resumeHandle);
    _connecting = f;
    return f.whenComplete(() {
      if (identical(_connecting, f)) _connecting = null;
    });
  }

  Future<void>? _connecting;

  /// Three tries, each only for the failure it can fix:
  ///
  /// 1. Resume on the handle.
  /// 2. The server refused the handle → a fresh conversation, session
  ///    features still on. The handle was the problem, not the features.
  /// 3. A fresh setup refused too → without session features, recorded for
  ///    the life of the client.
  ///
  /// A socket that never opens is [GeminiUnreachable] and is thrown at once:
  /// no retry fixes a missing network. It used to count as a refused setup,
  /// which switched session features off for good the first time the device
  /// had no signal.
  Future<void> _connectOnce({String? resumeHandle}) async {
    try {
      if (resumeHandle != null) {
        try {
          await _openSocket(resumeHandle);
          return;
        } on GeminiSetupRefused catch (e) {
          _log('resume refused ($e) — starting a fresh conversation');
          _forgetHandle();
          await _quietDisconnect();
        }
      }
      try {
        await _openSocket(null);
        return;
      } on GeminiSetupRefused catch (e) {
        if (!_sessionFeaturesEnabled) rethrow;
        _log('setup refused ($e) — retrying WITHOUT sessionResumption/compression');
        _sessionFeaturesEnabled = false;
        await _quietDisconnect();
      }
      await _openSocket(null);
      _log('setup OK without session features — this model rejects them');
    } catch (e) {
      await _quietDisconnect();
      _connected = false;
      _setupComplete = false;
      _setupCompleter = null;
      _connectionState.add(GeminiConnectionState.error);
      rethrow;
    }
  }

  void _forgetHandle() {
    _resumptionHandle = null;
    _resumable = false;
    _handleAt = null;
  }

  /// Guarded: a throw here escaped as an unhandled zone error rather than
  /// reaching the caller, which is how "[CRASH] zone: disconnected" appeared
  /// one millisecond after the retry line — and why the awaiting reconnect
  /// loop was left hanging instead of being told it had failed.
  Future<void> _quietDisconnect() async {
    try {
      await disconnect();
    } catch (_) {}
  }

  Future<void> _openSocket(String? resumeHandle) async {
    _connectionState.add(GeminiConnectionState.connecting);
    _setupComplete = false;
    _setupCompleter = Completer<void>();
    _pendingResumeHandle = resumeHandle;
    _handleLogged = false;

    final ws = WebSocketChannel.connect(Uri.parse(config.wsUrl));
    _ws = ws;
    try {
      await ws.ready.timeout(AppConstants.wsReadyTimeout);
    } catch (e) {
      _ws = null;
      unawaited(ws.sink.close().catchError((_) => null));
      throw GeminiUnreachable(e);
    }

    _wsSubscription = ws.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );

    _log('connecting model=${config.model}'
        '${resumeHandle != null ? ' (resuming)' : ''}');
    ws.sink.add(jsonEncode(buildSetupMessage()));

    // Must actually complete. Previously a timeout was swallowed and the client
    // reported itself connected, which hid a rejected setup behind a dead socket.
    // A socket closed during setup fails this at once (see [_failSetup]).
    try {
      await _setupCompleter!.future.timeout(AppConstants.geminiSetupTimeout);
    } on TimeoutException {
      throw GeminiSetupRefused(
          'no setupComplete in ${AppConstants.geminiSetupTimeout.inSeconds} s');
    }

    _connected = true;
    _setupComplete = true;
    _setupCompleter = null;
    _connectionState.add(GeminiConnectionState.connected);
    _log('setup OK');
  }

  int _frameSendCount = 0;

  void sendFrame(Uint8List jpeg) {
    if (!isConnected || _ws == null) return;
    try {
      final b64 = base64Encode(jpeg);
      _ws!.sink.add(jsonEncode({
        'realtimeInput': {
          'video': {
            'data': b64,
            'mimeType': 'image/jpeg',
          }
        }
      }));
      _frameSendCount++;
      if (_frameSendCount <= 3 || _frameSendCount % 10 == 0) {
        _log('frame#$_frameSendCount ${jpeg.length}B');
      }
    } catch (e) {
      _log('sendFrame err: $e');
    }
  }

  void sendAudio(Uint8List pcm) {
    if (!isConnected || _ws == null) return;
    try {
      _ws!.sink.add(jsonEncode({
        'realtimeInput': {
          'audio': {
            'data': base64Encode(pcm),
            'mimeType': 'audio/pcm;rate=16000',
          }
        }
      }));
    } catch (e) {
      _log('sendAudio err: $e');
    }
  }

  void sendText(String text) {
    if (!isConnected || _ws == null) return;
    try {
      _ws!.sink.add(jsonEncode({
        'realtimeInput': {
          'text': text,
        }
      }));
    } catch (e) {
      _log('sendText err: $e');
    }
  }

  void sendToolResponse(String functionCallId, Map<String, dynamic> result,
      {String? name}) {
    if (!isConnected || _ws == null) return;
    try {
      _ws!.sink.add(jsonEncode({
        'toolResponse': {
          'functionResponses': [
            {
              'id': functionCallId,
              'name': ?name,
              // A non-blocking result is spoken once she has finished the
              // sentence she is on, rather than cutting herself off.
              'response': thinks ? {...result, 'scheduling': 'WHEN_IDLE'} : result,
            }
          ]
        }
      }));
    } catch (e) {
      _log('sendToolResponse err: $e');
    }
  }

  Future<void> disconnect() async {
    _connected = false;
    _setupComplete = false;
    _inProgress = false;
    if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
      // Nobody may still be awaiting this: _openSocket's own timeout has
      // usually given up already. An unobserved completeError then surfaces as
      // an unhandled zone error — that is the whole of "[CRASH] zone:
      // disconnected", which looked like a crash and was only bookkeeping.
      _setupCompleter!.future.catchError((_) {});
      _setupCompleter!.completeError('disconnected');
    }
    _setupCompleter = null;
    _wsSubscription?.cancel();
    _wsSubscription = null;
    // close() waits for the peer's closing handshake. On a socket whose network
    // has gone — a cellular bind that lost data — that wait never returns, and
    // it took the retry with it: "setup timed out — retrying WITHOUT
    // sessionResumption" was the last line in three sessions, with no error and
    // no agent, while a caller talked to nobody.
    try {
      await _ws?.sink
          .close()
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {
      // A socket that is already broken cannot be closed politely.
    }
    _ws = null;
    if (!_disposed) {
      _connectionState.add(GeminiConnectionState.disconnected);
    }
  }

  /// Top-level `setup`, camelCase fields, generationConfig nesting — Google's
  /// format for the Gemini 3.8 Live models. Neither accepts
  /// `enableAffectiveDialog` or `proactivity: false`, so neither is sent.
  @visibleForTesting
  Map<String, dynamic> buildSetupMessage() {
    return {
      'setup': {
        'model': config.model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': config.voice}
            }
          },
          // Plain 3.8 Live refuses any thinking setting.
          if (thinks)
            'thinkingConfig': {'thinkingLevel': AppConstants.geminiThinkingLevel},
        },
        'systemInstruction': {
          'parts': [
            {'text': config.systemPrompt}
          ]
        },
        // Both sides as text. The 3.8 models send none unless asked, and
        // conversation history, "the wearer replied" and call reports all
        // read them.
        'inputAudioTranscription': <String, dynamic>{},
        'outputAudioTranscription': <String, dynamic>{},
        if (config.toolDeclarations != null) 'tools': [
          {
            // 3.8 Live runs tools NON_BLOCKING unless told otherwise, and the
            // session's tool loop — screen automation chains, job polling —
            // relies on her waiting for each result. Extended thinking allows
            // NON_BLOCKING only.
            'functionDeclarations': [
              for (final d in config.toolDeclarations!)
                {...d, 'behavior': thinks ? 'NON_BLOCKING' : 'BLOCKING'},
            ],
          }
        ],
        // Ask the server to issue resumption handles. With a handle we can drop
        // the socket when idle (saving radio/battery) and later restore the same
        // conversation instead of starting over.
        if (_sessionFeaturesEnabled)
          'sessionResumption': {
            if (_pendingResumeHandle != null) 'handle': _pendingResumeHandle,
          },
        // Without this, sessions hard-stop at 15 min (audio) or 2 min (audio+video).
        // A sliding window keeps long conversations alive.
        if (_sessionFeaturesEnabled)
          'contextWindowCompression': {
            'slidingWindow': <String, dynamic>{},
          },
      }
    };
  }

  void _onMessage(dynamic raw) {
    try {
      final String text;
      if (raw is String) {
        text = raw;
      } else if (raw is Uint8List) {
        text = utf8.decode(raw);
      } else {
        return;
      }
      final msg = jsonDecode(text) as Map<String, dynamic>;
      _msgCount++;
      _lastMessageAt = DateTime.now();

      // Log first 10 messages + every 20th — shows keys only to keep it short
      if (_msgCount <= 10 || _msgCount % 20 == 0) {
        final keys = msg.keys.toList();
        final preview = text.length > 200 ? '${text.substring(0, 200)}…' : text;
        _log('RX#$_msgCount keys=$keys $preview');
      }

      // IMPORTANT: a single server frame can carry SEVERAL of these at once —
      // a resumption handle arrives bundled with the audio or tool call it was
      // issued alongside. Each block therefore falls through to the next
      // instead of returning. Returning early here silently discarded whatever
      // else was in the frame, which chopped playback into single words and
      // dropped tool calls mid-task.

      if (msg.containsKey('setupComplete')) {
        _log('setupComplete received'
            '${_pendingResumeHandle != null ? ' (resumed)' : ''}');
        if (_setupCompleter != null && !_setupCompleter!.isCompleted) {
          _setupCompleter!.complete();
        }
      }

      // Server hands us a fresh handle periodically; keep the latest.
      final resumptionUpdate =
          msg['sessionResumptionUpdate'] as Map<String, dynamic>?;
      if (resumptionUpdate != null) {
        final handle = resumptionUpdate['newHandle'] as String?;
        final resumable = resumptionUpdate['resumable'] as bool? ?? false;
        if (handle != null && handle.isNotEmpty) {
          _resumptionHandle = handle;
          _resumable = resumable;
          _handleAt = DateTime.now();
          // A new handle arrives about once a second, and logging each one
          // was most of the log. The first per connection says it works.
          if (!_handleLogged) {
            _handleLogged = true;
            _log('resumption handle issued (resumable=$resumable)');
          }
        }
      }

      // Connection is about to be closed — surface the deadline so the session
      // can reconnect on the handle before we lose the turn.
      final goAwayMsg = msg['goAway'] as Map<String, dynamic>?;
      if (goAwayMsg != null) {
        final timeLeft = _parseDuration(goAwayMsg['timeLeft']);
        _log('goAway: ${timeLeft.inSeconds}s left');
        if (!_disposed) _goAway.add(timeLeft);
      }

      if (speechActivityOf(msg) == 'start' && !_disposed) {
        _speechStarted.add(null);
      }

      final busy = interactionBusy(msg);
      if (busy != null && busy != _inProgress) {
        _inProgress = busy;
        if (!_disposed) _busy.add(busy);
      }

      final serverContent = msg['serverContent'] as Map<String, dynamic>?;
      if (serverContent != null) {
        // Barge-in: the model stopped generating because the user spoke. Audio
        // already queued locally would otherwise keep playing over them.
        if (serverContent['interrupted'] == true) {
          _log('interrupted by user');
          if (!_disposed) _interrupted.add(null);
        }

        final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
        if (modelTurn != null) {
          final parts = modelTurn['parts'] as List?;
          if (parts != null) {
            for (final part in parts) {
              _handlePart(part as Map<String, dynamic>);
            }
          }
        }

        // What the wearer said. The server sends it; nothing here read it,
        // so `TranscriptRole.user` was never emitted and every listener for
        // "the wearer replied" was dead code. The queue of undelivered call
        // reports could therefore never be cleared: ten messages were read out
        // ten times, each one re-queued as unheard.
        final inputTranscription =
            serverContent['inputTranscription'] as Map<String, dynamic>?;
        if (inputTranscription != null) {
          final text = inputTranscription['text'] as String?;
          if (text != null && text.trim().isNotEmpty) {
            _userTranscript.add(text);
          }
        }

        // Output transcription (new API)
        final outputTranscription =
            serverContent['outputTranscription'] as Map<String, dynamic>?;
        if (outputTranscription != null) {
          final text = outputTranscription['text'] as String?;
          if (text != null && text.isNotEmpty) {
            _textResponse.add(text);
          }
        }

        final turnComplete = serverContent['turnComplete'] as bool?;
        if (turnComplete == true) {
          _turnComplete.add(null);
        }
      }

      final toolCall = msg['toolCall'] as Map<String, dynamic>?;
      if (toolCall != null) {
        final functionCalls = toolCall['functionCalls'] as List?;
        if (functionCalls != null) {
          for (final fc in functionCalls) {
            // RX logging samples every 20th message, so a tool call would
            // otherwise only appear by coincidence. These always log.
            _log('toolCall ${fc['name']} ${fc['args'] ?? {}}');
            _toolCall.add(GeminiToolCall(
              id: fc['id'] as String,
              name: fc['name'] as String,
              args: fc['args'] as Map<String, dynamic>? ?? {},
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('[GEMINI] Message parse error: $e');
    }
  }

  /// Protobuf Duration arrives as JSON in seconds-with-suffix form, e.g. "12.5s".
  Duration _parseDuration(dynamic raw) {
    if (raw is num) {
      return Duration(milliseconds: (raw * 1000).round());
    }
    if (raw is String) {
      final seconds = double.tryParse(raw.replaceAll('s', '').trim());
      if (seconds != null) {
        return Duration(milliseconds: (seconds * 1000).round());
      }
    }
    return Duration.zero;
  }

  int _audioChunks = 0;
  int _audioBytes = 0;

  void _handlePart(Map<String, dynamic> part) {
    final inlineData = part['inlineData'] as Map<String, dynamic>?;
    if (inlineData != null) {
      final mimeType = inlineData['mimeType'] as String?;
      if (mimeType != null && mimeType.startsWith('audio/')) {
        final data = base64Decode(inlineData['data'] as String);
        _audioChunks++;
        _audioBytes += data.length;
        if (_audioChunks % 50 == 0) {
          _log('audio: $_audioChunks chunks, '
              '${(_audioBytes / 1024).toStringAsFixed(0)}KB, '
              'avg ${(_audioBytes / _audioChunks).round()}B/chunk');
        }
        // base64Decode already returns a fresh Uint8List; fromList would
        // re-copy every byte through the slow list interface.
        _audioResponse.add(data);
      }
    }

    final text = part['text'] as String?;
    // A thought is the model reasoning, not something she said — and the
    // transcript is kept as conversation history.
    if (text != null && text.isNotEmpty && part['thought'] != true) {
      _textResponse.add(text);
    }
  }

  void _onError(dynamic error) {
    _log('WS error: $error');
    _connected = false;
    _failSetup(GeminiSetupRefused('socket error during setup: $error'));
    _connectionState.add(GeminiConnectionState.error);
    if (!_disposed) _closed.add(null);
  }

  void _onDone() {
    final code = _ws?.closeCode;
    final reason = _ws?.closeReason;
    // The code and reason are the server's own account of why it hung up.
    _log('WS closed (msgs=$_msgCount'
        '${code == null ? '' : ', code $code'}'
        '${reason == null || reason.isEmpty ? '' : ', "$reason"'})');
    _connected = false;
    _failSetup(GeminiSetupRefused('socket closed during setup',
        code: code, reason: reason));
    if (!_disposed) {
      _connectionState.add(GeminiConnectionState.disconnected);
      _closed.add(null);
    }
  }

  /// The socket went away before setupComplete. Say so now: waiting out the
  /// setup timeout cost 8 s on hardware, with the wearer talking into nothing.
  void _failSetup(Object error) {
    final pending = _setupCompleter;
    if (pending == null || pending.isCompleted) return;
    // Nobody may be awaiting it any more; an unobserved error would surface
    // as an unhandled zone error.
    pending.future.catchError((_) {});
    pending.completeError(error);
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _audioResponse.close();
    _textResponse.close();
    _userTranscript.close();
    _toolCall.close();
    _connectionState.close();
    _turnComplete.close();
    _busy.close();
    _debugLog.close();
    _goAway.close();
    _interrupted.close();
    _speechStarted.close();
    _closed.close();
  }
}

enum GeminiConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class GeminiToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  GeminiToolCall({required this.id, required this.name, required this.args});
}

/// The socket opened but the server would not finish the setup handshake —
/// it closed, errored, or never sent setupComplete.
class GeminiSetupRefused implements Exception {
  GeminiSetupRefused(this.why, {this.code, this.reason});

  final String why;
  final int? code;
  final String? reason;

  @override
  String toString() => [
        why,
        if (code != null) 'code $code',
        if (reason != null && reason!.isNotEmpty) '"$reason"',
      ].join(', ');
}

/// The socket never opened: no network, or Android is withholding it while
/// the device idles (battery optimisation).
class GeminiUnreachable implements Exception {
  GeminiUnreachable(this.cause);

  final Object cause;

  @override
  String toString() => 'could not reach Gemini — no network, or Android is '
      'holding it back while the device idles ($cause)';
}
