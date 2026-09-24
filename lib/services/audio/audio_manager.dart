import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../config/constants.dart';

/// Manages device mic input and AI response playback.
/// Handles echo gating — mutes mic while AI is speaking.
///
/// Playback uses Android AudioTrack via platform channel. The native side
/// writes from its own thread behind a small adaptive jitter buffer, and
/// reports how each reply was delivered (see [_logPlayback]).
class AudioManager {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _micSubscription;

  final _micStream = StreamController<Uint8List>.broadcast();
  final _userSpeaking = StreamController<bool>.broadcast();
  bool _aiSpeaking = false;
  bool _recording = false;
  bool _disposed = false;
  bool _lastSpeakingState = false;
  Timer? _silenceTimer;
  Timer? _resetTimer;

  static const double _speechRmsThreshold = 800.0;

  /// While the agent is speaking on the DEVICE SPEAKER, the mic hears it. If we
  /// forward that, the server reads it as the user barging in, cancels the
  /// turn, and the agent restarts — a feedback loop that chops the audio about
  /// once a second and makes it talk to itself.
  ///
  /// With AcousticEchoCanceler now actually enabled, residual echo should be
  /// small — so this is a low safety net rather than the primary defence, and
  /// barge-in works at normal speaking volume. Raise it if the agent still
  /// interrupts itself on the device speaker; lower it toward
  /// [_speechRmsThreshold] if quiet interruptions are being missed.
  /// Bluetooth has no acoustic path back, so no gate applies there at all.
  static const double _bargeInRmsThreshold = 1500.0;

  bool _onBluetooth = false;
  static const Duration _silenceTimeout = AppConstants.userSilenceTimeout;

  static const _audioChannel =
      MethodChannel('ai.fox1/audio');
  static const _playChannel =
      MethodChannel('ai.fox1/audio_play');
  static const _audioEvents =
      EventChannel('ai.fox1/audio_events');

  StreamSubscription? _routeSub;

  Stream<Uint8List> get micStream => _micStream.stream;
  Stream<bool> get userSpeakingState => _userSpeaking.stream;
  bool get isRecording => _recording;
  bool get aiSpeaking => _aiSpeaking;

  /// While the wearer holds the ring, their voice passes whatever else is
  /// happening. Without this the echo gate below drops quiet speech while she
  /// is talking on the device speaker — which is exactly the moment they are
  /// holding the ring to interrupt her.
  bool _holdOpen = false;
  bool get holdOpen => _holdOpen;
  void setHoldOpen(bool on) {
    if (_holdOpen == on) return;
    _holdOpen = on;
    debugPrint('[AUDIO] hold-to-talk ${on ? 'open — mic forced through' : 'released'}');
  }

  Future<void> init() async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetooth,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
    ));

    await _applyAudioRoute();
    await _initPlaybackTrack();
    _listenForRouteChanges();
    unawaited(_preloadEarcons());
  }

  Future<void> _initPlaybackTrack() async {
    try {
      await _playChannel.invokeMethod('init', {
        'sampleRate': 24000,
        'channels': 1,
      });
    } catch (e) {
      debugPrint('[AUDIO] AudioTrack init error: $e');
    }
  }

  /// React to the earbud appearing or disappearing mid-session.
  ///
  /// The platform side re-picks the route; this side has to rebuild the
  /// AudioTrack, because a track opened against a device that has since gone
  /// away does not reliably follow the new output — which is why the agent went
  /// silent instead of falling back to the device speaker.
  void _listenForRouteChanges() {
    _routeSub ??= _audioEvents.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        if (event['type'] == 'playback') {
          _logPlayback(event);
          return;
        }
        if (event['type'] == 'track') {
          debugPrint('[AUDIO] track: starts playing once ${event['startMs']} ms '
              'is buffered (system minimum ${event['minMs']} ms)');
          return;
        }
        if (event['type'] != 'route') return;
        _onBluetooth = event['bluetooth'] == true;
        debugPrint('[AUDIO] device change (${event['reason']})'
            ' -> ${_onBluetooth ? 'bluetooth' : 'device speaker'}'
            ' (barge-in gate ${_onBluetooth ? 'off' : 'on'})');
        _initPlaybackTrack();
      },
      onError: (e) => debugPrint('[AUDIO] route event error: $e'),
    );
  }

  void resetForNewSession() {
    _aiSpeaking = false;
    _lastSpeakingState = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _resetTimer?.cancel();
    _resetTimer = null;
    try {
      _playChannel.invokeMethod('stop');
    } catch (_) {}
  }

  /// Hand the communication route back to the system.
  ///
  /// Every acquire needs one of these. Without it MODE_IN_COMMUNICATION and any
  /// SCO link outlive the session, and the next thing that wants audio inherits
  /// a route pointed somewhere it did not choose.
  Future<void> releaseAudioRoute() async {
    try {
      await _audioChannel.invokeMethod('releaseRoute');
      _onBluetooth = false;
      debugPrint('[AUDIO] route released');
    } catch (e) {
      debugPrint('[AUDIO] route release failed: $e');
    }
  }

  /// Single source of truth for output routing.
  ///
  /// Asks for the MEDIA route, never SCO. SCO belongs to the call bridge: it is
  /// device-ambiguous below API 31, so starting it here handed the agent's voice
  /// to whichever HFP device the system picked — which, with the ESP32 paired,
  /// was frequently the ESP32. Media follows A2DP or the speaker and cannot
  /// reach a board that has no A2DP profile.
  Future<void> _applyAudioRoute() async {
    try {
      final bt = await _audioChannel
          .invokeMethod<bool>('setRoute', {'route': 'media'});
      _onBluetooth = bt == true;
      debugPrint('[AUDIO] route -> ${_onBluetooth ? 'bluetooth' : 'device speaker'}'
          ' (barge-in gate ${_onBluetooth ? 'off' : 'on'})');
    } catch (e) {
      debugPrint('[AUDIO] routing failed: $e');
    }
  }

  Future<bool> startMicCapture() async {
    if (_recording) return true;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return false;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
        audioInterruption: AudioInterruptionMode.none,
        // THE echo fix. These default to false, so AcousticEchoCanceler was
        // created on the mic session and then explicitly DISABLED
        // (PCMReader.enableEchoSuppressor sets `enabled = config.echoCancel`).
        // Selecting VOICE_COMMUNICATION picks the source and tuning but does
        // NOT attach the canceller — that is this flag. Without it the mic
        // heard the speaker, the server read it as barge-in, and the agent
        // interrupted itself roughly once a second.
        echoCancel: true,
        noiseSuppress: true,
        // Left off deliberately: AGC boosts gain during silence, which lifts
        // whatever echo survives back above the noise floor.
        autoGain: false,
        androidConfig: AndroidRecordConfig(
          // Source + tuning for two-way voice. The canceller itself is
          // echoCancel above.
          audioSource: AndroidAudioSource.voiceCommunication,
          audioManagerMode: AudioManagerMode.modeInCommunication,
          // MUST stay false. record's AudioRecorder does
          //   if (conf.speakerphone) audioManager.isSpeakerphoneOn = true
          // on every start, which overrides Bluetooth routing and yanks audio
          // to the device speaker — mid-conversation, whenever the mic
          // restarts. Output routing is decided solely by _applyAudioRoute().
          speakerphone: false,
        ),
      ),
    );

    _micSubscription = stream.listen(
      (data) {
        final pcm = Uint8List.fromList(data);
        final rms = _rms(pcm);

        // Never fully mute — that made barge-in impossible. Instead, while the
        // agent is audible on the device speaker, demand clearly louder-than-
        // echo input. Bluetooth has no acoustic path back, so pass everything.
        if (_aiSpeaking &&
            !_onBluetooth &&
            !_holdOpen &&
            rms < _bargeInRmsThreshold) {
          return;
        }

        _micStream.add(pcm);
        _trackSpeech(rms);
      },
      onError: (e) {
        debugPrint('[AUDIO] Mic stream error: $e');
        _restartMic();
      },
      onDone: () {
        debugPrint('[AUDIO] Mic stream closed unexpectedly');
        _restartMic();
      },
    );

    _recording = true;
    // Re-assert routing after the recorder starts: it manages Bluetooth SCO
    // itself, which can move the output underneath us.
    await _applyAudioRoute();
    return true;
  }

  void _restartMic() {
    if (_disposed) return;
    _recording = false;
    _micSubscription?.cancel();
    _micSubscription = null;
    Future.delayed(AppConstants.micRestartBackoff, () {
      if (!_disposed) startMicCapture();
    });
  }

  Future<void> stopMicCapture() async {
    _micSubscription?.cancel();
    _micSubscription = null;
    if (_recording) {
      await _recorder.stop();
      _recording = false;
    }
  }

  double _rms(Uint8List pcm) {
    if (pcm.length < 2) return 0;
    final samples = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.length ~/ 2);
    double sumSquares = 0;
    for (final s in samples) {
      sumSquares += s * s;
    }
    return math.sqrt(sumSquares / samples.length);
  }

  void _trackSpeech(double rms) {
    if (rms > _speechRmsThreshold) {
      _silenceTimer?.cancel();
      _silenceTimer = Timer(_silenceTimeout, () {
        if (_lastSpeakingState) {
          _lastSpeakingState = false;
          _userSpeaking.add(false);
        }
      });
      if (!_lastSpeakingState) {
        _lastSpeakingState = true;
        _userSpeaking.add(true);
      }
    }
  }

  /// True once this turn has been cut off: her remaining audio is discarded
  /// instead of played. Flushing the AudioTrack is not enough — the model
  /// generates far faster than real time, so on hardware a 20 s interruption
  /// was followed by another 50 s of speech that was already on its way.
  bool _dropTurn = false;

  /// A new turn from the model: play it again.
  void onTurnStart() => _dropTurn = false;

  /// Write PCM chunk directly to AudioTrack — plays immediately.
  void addAiAudioChunk(Uint8List pcm) {
    if (_disposed || _dropTurn) return;
    _aiSpeaking = true;
    try {
      _playChannel.invokeMethod('write', pcm);
    } catch (e) {
      debugPrint('[AUDIO] AudioTrack write error: $e');
    }
  }

  void onAiSpeechStart() {
    _aiSpeaking = true;
  }

  /// Drop everything already queued for playback. Called when the server
  /// reports the user interrupted — without this the agent's buffered speech
  /// keeps playing over them for seconds after they cut in.
  void interruptPlayback() {
    _aiSpeaking = false;
    _dropTurn = true;
    _resetTimer?.cancel();
    _resetTimer = null;
    try {
      _playChannel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[AUDIO] interrupt flush failed: $e');
    }
  }

  /// One line per reply, from the native player: how much speech, how fast it
  /// came, and whether it ran dry waiting for more. "ran dry" is audio that
  /// arrived late — network or Gemini. Choppy sound with no gaps here is the
  /// Bluetooth link to the earbud, not the stream.
  void _logPlayback(Map event) {
    final audio = (event['audioMs'] as num? ?? 0) / 1000;
    final span = (event['arrivalMs'] as num? ?? 0) / 1000;
    final gaps = (event['gaps'] as num? ?? 0).toInt();
    final longest = (event['gapMaxMs'] as num? ?? 0).toInt();
    // "stuck": audio sat in the track unplayed and had to be pushed out. It
    // should be rare now; if it is not, the start threshold is still too high.
    final stalls = (event['stalls'] as num? ?? 0).toInt();
    debugPrint('[AUDIO] reply: ${audio.toStringAsFixed(1)} s of speech, '
        'arrived over ${span.toStringAsFixed(1)} s · '
        '${gaps == 0 ? 'no gaps' : 'ran dry $gaps× (longest $longest ms)'}'
        '${stalls == 0 ? '' : ' · stuck in the track $stalls×'}'
        ' · buffer ${event['bufferMs']} ms'
        '${event['cutOff'] == true ? ' · cut off' : ''}');
  }

  /// Sounds straight to the AudioTrack — the wearer holding the ring cannot
  /// see the screen, so this is how they know the mic is live.
  /// [Earcon.ready] is the one that matters: it means Gemini is connected and
  /// hearing them, not merely that the button went down.
  Future<void> playEarcon(Earcon e) async {
    if (_disposed) return;
    try {
      final pcm = await _earconPcm(e);
      // Straight into the existing track. Calling init() here — as the first
      // build did — releases and rebuilds the AudioTrack, and on the earbud the
      // new track was still waiting for the Bluetooth voice link when the tone
      // arrived, so no tone was ever heard.
      // A little silence first absorbs the route waking up. 'sound', not
      // 'write': a tone skips the jitter buffer and the reply statistics.
      // One write, so the track sees one sound long enough to start on.
      const lead = 24000 * 2 * 120 ~/ 1000;
      final out = Uint8List(lead + pcm.length)..setRange(lead, lead + pcm.length, pcm);
      _playChannel.invokeMethod('sound', out);
    } catch (err) {
      debugPrint('[AUDIO] earcon failed: $err');
    }
  }

  /// Original sounds made by `tool/make_earcons.py` — two rising notes when
  /// she is listening, one falling note on release — in the track's format:
  /// 24 kHz mono PCM16. The failure tone stays synthetic.
  static const _earconAssets = {
    Earcon.ready: 'assets/sounds/ring_press.pcm',
    Earcon.done: 'assets/sounds/ring_release.pcm',
  };
  static final Map<Earcon, Uint8List> _earcons = {};

  Future<void> _preloadEarcons() async {
    for (final e in Earcon.values) {
      await _earconPcm(e);
    }
  }

  Future<Uint8List> _earconPcm(Earcon e) async {
    final cached = _earcons[e];
    if (cached != null) return cached;
    Uint8List? pcm;
    final asset = _earconAssets[e];
    if (asset != null) {
      try {
        final data = await rootBundle.load(asset);
        pcm = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (err) {
        debugPrint('[AUDIO] $asset missing, using a tone: $err');
      }
    }
    pcm ??= switch (e) {
      Earcon.ready => _tone(880, 70, then: 1320, thenMs: 90),
      Earcon.done => _tone(660, 60),
      Earcon.failed => _tone(440, 120, then: 300, thenMs: 160),
    };
    return _earcons[e] = pcm;
  }

  /// One or two sine bursts at the AudioTrack's 24 kHz, with short fades so
  /// they do not click.
  Uint8List _tone(double hz, int ms, {double? then, int thenMs = 0, double gain = 0.22}) {
    const rate = 24000;
    final total = ((ms + thenMs) * rate / 1000).round();
    final out = Int16List(total);
    var i = 0;
    void burst(double f, int lengthMs) {
      final n = (lengthMs * rate / 1000).round();
      final fade = (rate * 0.006).round();
      for (var k = 0; k < n && i < total; k++, i++) {
        final env = k < fade
            ? k / fade
            : (k > n - fade ? (n - k) / fade : 1.0);
        out[i] = (math.sin(2 * math.pi * f * k / rate) * gain * env * 32767).round();
      }
    }

    burst(hz, ms);
    if (then != null) burst(then, thenMs);
    return out.buffer.asUint8List();
  }

  Future<void> onAiSpeechEnd() async {
    // Marks the end of her reply in the native queue, so how it was delivered
    // is summed up once its last chunk has gone out.
    try {
      _playChannel.invokeMethod('turnDone');
    } catch (_) {}
    // Safety reset after a delay to let remaining audio drain
    _resetTimer?.cancel();
    _resetTimer = Timer(AppConstants.aiSpeechResetDelay, () {
      if (_aiSpeaking) {
        _aiSpeaking = false;
        unawaited(_recoverMicAfterPlayback());
      }
    });
  }

  Future<void> _recoverMicAfterPlayback() async {
    if (_disposed || !_recording) return;
    try {
      if (await _recorder.isPaused()) {
        await _recorder.resume();
        return;
      }
      if (!await _recorder.isRecording()) {
        _restartMic();
      }
    } catch (e) {
      debugPrint('[AUDIO] Recorder recovery failed: $e');
      _restartMic();
    }
  }

  void dispose() {
    _disposed = true;
    _aiSpeaking = false;
    _routeSub?.cancel();
    _routeSub = null;
    _resetTimer?.cancel();
    _silenceTimer?.cancel();
    stopMicCapture();
    _micStream.close();
    _userSpeaking.close();
    _recorder.dispose();
    try {
      _playChannel.invokeMethod('release');
    } catch (_) {}
  }
}

/// What a tone means to someone who cannot see the screen.
enum Earcon {
  /// Gemini is connected and listening — speak now. ("Select - 03")
  ready,

  /// The hold ended; what you said is on its way. ("Select - 02")
  done,

  /// Nothing is listening — the session could not be woken.
  failed,
}
