package ai.fox1.channels

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Captures call audio via VOICE_DOWNLINK (caller's voice) on Android 8.
 *
 * - `start` — begins capturing the call downlink audio as PCM 16-bit 16kHz mono
 * - `stop` — stops capture
 *
 * Audio is streamed back to Dart via an EventChannel.
 * VOICE_DOWNLINK works on Android 8 (blocked on 9+).
 */
object CallAudioChannel {
    private const val METHOD_CHANNEL = "ai.fox1/call_audio"
    private const val EVENT_CHANNEL = "ai.fox1/call_audio_stream"

    private var audioRecord: AudioRecord? = null
    private var capturing = false
    private var captureThread: Thread? = null

    fun register(flutterEngine: FlutterEngine) {
        var eventSink: EventChannel.EventSink? = null

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val ok = startCapture { pcmBytes ->
                            eventSink?.success(pcmBytes)
                        }
                        result.success(mapOf<String, Any>("success" to ok,
                            "result" to if (ok) "Call audio capture started" else "Failed to start — VOICE_DOWNLINK may not be supported"))
                    }
                    "stop" -> {
                        stopCapture()
                        result.success(mapOf<String, Any>("success" to true, "result" to "Call audio capture stopped"))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun startCapture(onAudio: (ByteArray) -> Unit): Boolean {
        if (capturing) return true

        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val bufSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)

        if (bufSize == AudioRecord.ERROR_BAD_VALUE || bufSize == AudioRecord.ERROR) {
            return false
        }

        // Try VOICE_DOWNLINK first (caller's voice only)
        // Fall back to VOICE_CALL (both directions) if not supported
        val sources = listOf(
            MediaRecorder.AudioSource.VOICE_DOWNLINK,
            MediaRecorder.AudioSource.VOICE_CALL,
        )

        var record: AudioRecord? = null
        for (source in sources) {
            try {
                val r = AudioRecord(source, sampleRate, channelConfig, encoding, bufSize * 2)
                if (r.state == AudioRecord.STATE_INITIALIZED) {
                    record = r
                    break
                } else {
                    r.release()
                }
            } catch (_: Exception) {
                continue
            }
        }

        if (record == null) return false

        audioRecord = record
        capturing = true

        record.startRecording()

        captureThread = Thread {
            val buffer = ByteArray(bufSize)
            while (capturing) {
                val read = record.read(buffer, 0, buffer.size)
                if (read > 0) {
                    onAudio(buffer.copyOf(read))
                }
            }
        }.apply {
            name = "CallAudioCapture"
            start()
        }

        return true
    }

    private fun stopCapture() {
        capturing = false
        captureThread?.join(1000)
        captureThread = null
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
    }
}
