import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Captures the call downlink audio (caller's voice) via VOICE_DOWNLINK.
/// Only works on Android 8 — blocked on Android 9+.
/// Streams PCM 16-bit 16kHz mono back to Dart.
class CallAudioService {
  static const _methodChannel =
      MethodChannel('ai.fox1/call_audio');
  static const _eventChannel =
      EventChannel('ai.fox1/call_audio_stream');

  StreamSubscription? _eventSub;
  final _audioStream = StreamController<Uint8List>.broadcast();
  bool _capturing = false;

  /// PCM audio from the call downlink (caller's voice).
  Stream<Uint8List> get audioStream => _audioStream.stream;
  bool get isCapturing => _capturing;

  /// Start capturing call downlink audio.
  /// Returns true if VOICE_DOWNLINK is supported and capture started.
  Future<bool> start() async {
    if (_capturing) return true;
    try {
      _eventSub = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (data is Uint8List) {
            _audioStream.add(data);
          }
        },
        onError: (e) {
          debugPrint('[CALL_AUDIO] Stream error: $e');
        },
      );

      final result = await _methodChannel.invokeMethod('start');
      final success = (result as Map)['success'] == true;
      _capturing = success;
      if (!success) {
        _eventSub?.cancel();
        _eventSub = null;
        debugPrint('[CALL_AUDIO] Failed to start: ${result['result']}');
      }
      return success;
    } catch (e) {
      debugPrint('[CALL_AUDIO] Start error: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!_capturing) return;
    _capturing = false;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      await _methodChannel.invokeMethod('stop');
    } catch (_) {}
  }

  void dispose() {
    stop();
    _audioStream.close();
  }
}
