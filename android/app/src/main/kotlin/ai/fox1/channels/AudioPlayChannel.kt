package ai.fox1.channels

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Process
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * PCM playback via Android AudioTrack.
 *
 * USAGE_VOICE_COMMUNICATION, because the agent's voice has to reach a
 * Bluetooth earbud and SCO is the only transport that carries it there.
 *
 * The old comment claimed this usage also reached the telephony uplink;
 * CALL_AUDIO_FINDINGS.md established it never did, and the caller hears Gemini
 * over SPP instead. That does not make the usage wrong — it makes the
 * justification wrong. Moving to USAGE_MEDIA to dodge the SCO contention with
 * the bridge cost the earbud mic and, on this device, produced no audio at all.
 *
 * The contention is real but it is not solved here. See AudioChannel.
 *
 * **Writes happen on a thread of their own.** They used to run in the method
 * handler — Android's main thread — with a blocking `write()`. The model
 * generates far faster than real time, so for most of every reply the main
 * thread sat blocked waiting for room in the track, and everything else that
 * lives there queued behind her voice: ring events, vibration, and the `stop`
 * that is supposed to cut her off.
 *
 * **Speech goes through a small jitter buffer.** When the track has run dry —
 * a reply starting, or the network falling behind — speech is held until
 * [targetMs] of it is in hand (or that long has passed), then played. Each time
 * a reply runs dry part-way the target grows, so a poor connection costs a
 * little latency instead of a stutter every few words; clean replies shrink it
 * back. Tones skip the buffer.
 *
 * **Each reply is summed up** on AudioChannel's event stream ("type":
 * "playback"): how much speech, how long it took to arrive, how often it ran
 * dry. Gaps there are late audio — network or Gemini. Choppy sound with no gaps
 * is the Bluetooth link to the earbud, not the stream.
 */
object AudioPlayChannel {
    private const val CHANNEL = "ai.fox1/audio_play"

    private const val SPEECH = 0
    private const val SOUND = 1
    private const val TURN_END = 2
    private const val WAKE = 3

    /** Jitter buffer: ms of speech held before playing from dry. */
    private const val START_MS = 200
    private const val STEP_MS = 150
    private const val MAX_MS = 900
    /** Writes are sliced so a `stop` lands within one slice, not one chunk. */
    private const val SLICE_MS = 10
    /** Less than this left in the track counts as dry. */
    private const val DRY_MS = 5.0
    /** A reply that never got its turnDone is closed off after this much quiet. */
    private const val IDLE_END_MS = 2000L
    /** Longer silences are the model pausing (a tool call), not jitter. */
    private const val JITTER_MAX_MS = 1000L
    /** Written audio that has not started playing for this long is pushed out. */
    private const val STALL_MS = 250L

    private class Chunk(val data: ByteArray, val epoch: Int, val kind: Int) {
        val at: Long = SystemClock.uptimeMillis()
    }

    private val NOTHING = ByteArray(0)

    @Volatile private var track: AudioTrack? = null
    @Volatile private var bytesPerFrame = 2
    @Volatile private var framesPerMs = 24.0
    /** Frames the track must hold before AudioFlinger starts it (see init). */
    @Volatile private var startFrames = 4800
    /** The jitter buffer never holds less than the track needs to start. */
    @Volatile private var floorMs = START_MS

    private val queue = LinkedBlockingQueue<Chunk>()
    /** Bumped by `stop`: anything queued under an older epoch is dropped. */
    private val epoch = AtomicInteger()
    @Volatile private var flushWanted = false
    private var writer: Thread? = null

    // ---- writer thread only -------------------------------------------------
    private var targetMs = START_MS
    private var priming = true
    private var dryAt = 0L
    private var writtenTo: AudioTrack? = null
    private var framesWritten = 0L
    private var headBase = 0L
    private var lastHead = -1L
    private var lastMoveAt = 0L
    private var kicked = false
    private val reply = Reply()

    private class Reply {
        var stalls = 0
        var active = false
        var first = 0L
        var last = 0L
        var bytes = 0L
        var gaps = 0
        var gapMax = 0L
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                        val channels = call.argument<Int>("channels") ?: 1
                        // VOICE_COMMUNICATION by default: it is the only usage
                        // that reaches a Bluetooth headset over SCO, and the
                        // earbud IS the product. USAGE_MEDIA was tried and did
                        // not play at all on this device under
                        // MODE_IN_COMMUNICATION. "media" stays available for a
                        // deliberate non-headset path.
                        val usage = if (call.argument<String>("usage") == "media")
                            AudioAttributes.USAGE_MEDIA
                        else
                            AudioAttributes.USAGE_VOICE_COMMUNICATION

                        closeTrack()

                        val channelConfig = if (channels == 1)
                            AudioFormat.CHANNEL_OUT_MONO
                        else
                            AudioFormat.CHANNEL_OUT_STEREO

                        val bufSize = AudioTrack.getMinBufferSize(
                            sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT
                        )

                        val t = AudioTrack.Builder()
                            .setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(usage)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build()
                            )
                            .setAudioFormat(
                                AudioFormat.Builder()
                                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                    .setSampleRate(sampleRate)
                                    .setChannelMask(channelConfig)
                                    .build()
                            )
                            .setBufferSizeInBytes(bufSize * 4)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .build()

                        t.play()
                        bytesPerFrame = 2 * channels
                        framesPerMs = sampleRate / 1000.0
                        // AudioFlinger will not start a streaming track — at
                        // first, after a flush, or after it underran long
                        // enough to be disabled (about a second) — until its
                        // whole buffer is full. At bufSize × 4, a short tail
                        // after a pause sat unplayed until the next reply
                        // pushed it out: "you hear something, then it pauses,
                        // and half of that speech comes later". So the start
                        // threshold is cut to what the jitter buffer holds
                        // anyway, and a batch short of it is padded with
                        // silence (padToStart).
                        val minFrames = bufSize / bytesPerFrame
                        val wanted = maxOf(minFrames, (framesPerMs * START_MS).toInt())
                        val capacity = bufSize * 4 / bytesPerFrame
                        startFrames = if (Build.VERSION.SDK_INT >= 24) {
                            try {
                                t.setBufferSizeInFrames(wanted)
                                t.bufferSizeInFrames
                            } catch (_: Exception) {
                                capacity
                            }
                        } else capacity
                        floorMs = maxOf(START_MS, (startFrames / framesPerMs).toInt())
                        AudioChannel.emit(mapOf(
                            "type" to "track",
                            "minMs" to (minFrames / framesPerMs).toInt(),
                            "startMs" to (startFrames / framesPerMs).toInt(),
                        ))
                        // Whatever is still queued plays on the new track: a
                        // route change mid-reply should move her voice, not
                        // drop it.
                        track = t
                        ensureWriter()
                        result.success(true)
                    }
                    // Her voice: jitter-buffered and counted.
                    "write" -> {
                        (call.arguments as? ByteArray)?.let { enqueue(it, SPEECH) }
                        result.success(true)
                    }
                    // Tones: straight out, not counted.
                    "sound" -> {
                        (call.arguments as? ByteArray)?.let { enqueue(it, SOUND) }
                        result.success(true)
                    }
                    // Her turn is over; sum it up once its last chunk is out.
                    "turnDone" -> {
                        enqueue(NOTHING, TURN_END)
                        result.success(true)
                    }
                    "stop" -> {
                        epoch.incrementAndGet()
                        queue.clear()
                        flushWanted = true
                        // Wakes the writer if it is waiting for audio.
                        queue.offer(Chunk(NOTHING, -1, WAKE))
                        result.success(true)
                    }
                    "release" -> {
                        epoch.incrementAndGet()
                        queue.clear()
                        closeTrack()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enqueue(data: ByteArray, kind: Int) {
        queue.offer(Chunk(data, epoch.get(), kind))
    }

    /** stop() before release(): it also frees a write blocked on the old track. */
    private fun closeTrack() {
        val old = track
        track = null
        try { old?.stop() } catch (_: Exception) {}
        try { old?.release() } catch (_: Exception) {}
    }

    private fun ensureWriter() {
        if (writer != null) return
        writer = Thread({ runWriter() }, "fox1-voice-out").apply {
            isDaemon = true
            start()
        }
    }

    private fun runWriter() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        while (true) {
            try {
                step()
            } catch (e: Exception) {
                android.util.Log.w("AudioPlay", "writer: $e")
            }
        }
    }

    private fun step() {
        val c = queue.poll(20, TimeUnit.MILLISECONDS)
        if (flushWanted) flush()
        val now = SystemClock.uptimeMillis()
        if (!priming && bufferedMs() < DRY_MS) {
            priming = true
            dryAt = now
        }
        if (c == null) {
            kickIfStuck(now)
            if (reply.active && priming && now - dryAt > IDLE_END_MS) finishReply(cutOff = false)
            return
        }
        if (c.epoch != epoch.get()) return
        when (c.kind) {
            SOUND -> {
                writeOut(c)
                if (priming) padToStart(c.data.size.toLong() / bytesPerFrame)
            }
            TURN_END -> finishReply(cutOff = false)
            SPEECH -> speech(c)
        }
    }

    private fun speech(first: Chunk) {
        val late = if (priming && reply.active && dryAt > 0)
            (first.at - dryAt).coerceAtLeast(0L) else 0L
        noteArrival(first, late)
        if (!priming) {
            writeOut(first)
            return
        }
        // Dry: hold back until there is enough in hand to ride out the
        // network's hiccups, or until waiting longer would cost more than it
        // saves.
        val batch = arrayListOf(first)
        var heldMs = first.data.size / bytesPerFrame / framesPerMs
        val target = maxOf(targetMs, floorMs)
        val deadline = first.at + target
        while (heldMs < target && !flushWanted) {
            val wait = deadline - SystemClock.uptimeMillis()
            if (wait <= 0) break
            val next = queue.poll(wait, TimeUnit.MILLISECONDS) ?: break
            if (next.epoch != epoch.get()) continue
            batch.add(next)
            if (next.kind == TURN_END) break
            if (next.kind == SPEECH) {
                noteArrival(next, 0L)
                heldMs += next.data.size / bytesPerFrame / framesPerMs
            }
        }
        if (flushWanted) return
        priming = false
        var frames = 0L
        for (b in batch) {
            if (b.kind == TURN_END) {
                finishReply(cutOff = false)
            } else {
                writeOut(b)
                frames += b.data.size / bytesPerFrame
            }
        }
        // The wait ran out with less than the track needs to start — a tail,
        // or a trickle. Without this it waits, silent, for the next reply.
        padToStart(frames)
    }

    /** After a dry spell the track plays nothing until [startFrames] are in. */
    private fun padToStart(written: Long) {
        val short = startFrames - written
        if (short <= 0) return
        val frames = short + (framesPerMs * SLICE_MS).toLong()
        writeOut(Chunk(ByteArray((frames * bytesPerFrame).toInt()), epoch.get(), SOUND))
    }

    /**
     * Safety net for the same rule: audio written but not started for
     * [STALL_MS], with nothing more coming, is pushed out with silence. Once
     * per stall; counted in the reply's summary so the log shows it happening.
     */
    private fun kickIfStuck(now: Long) {
        val t = track ?: return
        if (t !== writtenTo) return
        val h = head(t) ?: return
        if (h != lastHead) {
            lastHead = h
            lastMoveAt = now
            kicked = false
            return
        }
        if (kicked || now - lastMoveAt < STALL_MS) return
        if (framesWritten - (h - headBase) <= 0) return
        kicked = true
        if (reply.active) reply.stalls++
        writeOut(Chunk(ByteArray(startFrames * bytesPerFrame), epoch.get(), SOUND))
    }

    private fun head(t: AudioTrack): Long? = try {
        t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    } catch (_: Exception) {
        null
    }

    private fun writeOut(c: Chunk) {
        val t = track ?: return
        if (t !== writtenTo) {
            writtenTo = t
            framesWritten = 0
            headBase = 0
            lastHead = -1
        }
        val slice = ((framesPerMs * SLICE_MS).toInt() * bytesPerFrame).coerceAtLeast(bytesPerFrame)
        var off = 0
        while (off < c.data.size) {
            if (flushWanted || c.epoch != epoch.get() || t !== track) return
            val w = try {
                t.write(c.data, off, minOf(slice, c.data.size - off))
            } catch (_: Exception) {
                -1
            }
            if (w <= 0) return
            off += w
            framesWritten += w / bytesPerFrame
            // A write restarts the stall clock: the track gets its chance to start.
            lastMoveAt = SystemClock.uptimeMillis()
        }
    }

    /**
     * What is written but not yet played. The head is read against a baseline
     * taken after each flush rather than assumed to reset: if it does not, this
     * over-reads, which only means "never dry" — the old, unbuffered behaviour.
     */
    private fun bufferedMs(): Double {
        val t = track ?: return 0.0
        if (t !== writtenTo) return 0.0
        val head = head(t) ?: return 0.0
        return (framesWritten - (head - headBase)).coerceAtLeast(0L) / framesPerMs
    }

    private fun flush() {
        flushWanted = false
        val t = track
        if (t != null) {
            try { t.pause(); t.flush() } catch (_: Exception) {}
            try { t.play() } catch (_: Exception) {}
            headBase = try { t.playbackHeadPosition.toLong() and 0xFFFFFFFFL } catch (_: Exception) { 0L }
        }
        framesWritten = 0
        lastHead = -1
        kicked = false
        priming = true
        dryAt = 0
        finishReply(cutOff = true)
    }

    private fun noteArrival(c: Chunk, late: Long) {
        val r = reply
        if (!r.active) {
            r.active = true
            r.first = c.at
            r.bytes = 0
            r.gaps = 0
            r.gapMax = 0
            r.stalls = 0
        } else if (late > 0) {
            r.gaps++
            if (late > r.gapMax) r.gapMax = late
            if (late < JITTER_MAX_MS) targetMs = minOf(targetMs + STEP_MS, MAX_MS)
        }
        r.last = c.at
        r.bytes += c.data.size
    }

    private fun finishReply(cutOff: Boolean) {
        val r = reply
        if (!r.active) return
        r.active = false
        if (r.gaps == 0 && !cutOff) targetMs = maxOf(targetMs - 50, START_MS)
        AudioChannel.emit(mapOf(
            "type" to "playback",
            "audioMs" to (r.bytes / bytesPerFrame / framesPerMs).toLong(),
            "arrivalMs" to (r.last - r.first),
            "gaps" to r.gaps,
            "gapMaxMs" to r.gapMax,
            "stalls" to r.stalls,
            "bufferMs" to maxOf(targetMs, floorMs),
            "cutOff" to cutOff,
        ))
    }
}
