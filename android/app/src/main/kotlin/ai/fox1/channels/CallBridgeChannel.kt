package ai.fox1.channels

import android.app.Activity
import android.app.ActivityManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import ai.fox1.services.CallBridgeService
import ai.fox1.services.HfpRouter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Bring-up harness for the ESP32 HFP call-audio bridge (see
 * `spp-app-integration.md` §7). Implements the five test stages against the
 * board over Bluetooth SPP; it is deliberately NOT wired to [AISession].
 *
 * There is no ADB on this device, so every observation this makes has to travel
 * back to Dart over the event channel and into the on-screen log / LogBuffer.
 */
object CallBridgeChannel {
    private const val METHOD_CHANNEL = "ai.fox1/call_bridge"
    private const val EVENT_CHANNEL = "ai.fox1/call_bridge_events"

    // Serial Port Profile — the board registers its server under this UUID.
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private const val MAGIC0 = 0xA7.toByte()
    private const val MAGIC1 = 0xC3.toByte()

    private const val TYPE_AUDIO = 0
    private const val TYPE_FLUSH = 1
    private const val TYPE_CALL_STATE = 2
    private const val TYPE_ARM = 3
    private const val TYPE_CALLER_ID = 4

    private const val HEADER_LEN = 8
    private const val MAX_PAYLOAD = 4096

    /** A gap this long means SCO went away and came back — reset codec state. */
    private const val AUDIO_GAP_RESET_MS = 500L

    /** Poll interval while the jitter buffer is still filling. */
    private const val PACE_NS = 20_000_000L

    /** One inbound frame carries 60 ms of audio, and the board plays it at that rate. */
    private const val FRAME_NS = 60_000_000L

    /**
     * Frames per socket write.
     *
     * A write costs ~47 ms here, and that is not a syscall — it is RFCOMM
     * credit-based flow control blocking until the peer grants more. The cost
     * is therefore per write, not per byte. One frame per write spends 47 of
     * every 60 ms blocked, leaving no slack for anything else; two frames per
     * write (2 x 488 = 976 B, inside the ~990 B RFCOMM MTU, so still one
     * un-torn packet) halves the duty cycle and buys back 73 ms per period.
     */
    private const val BATCH_FRAMES = 2

    /**
     * Frames held back before the first send, and thereafter permanently.
     *
     * Our queue and the board's ring are buffers in series: whatever we hold,
     * the board does not, which leaves its ring room to absorb a delivery lump.
     * Holding this only works if the send clock matches consumption — see the
     * writer loop.
     */
    private const val PRIME_FRAMES = 4

    /**
     * Stop encoding once the outbound queue is this deep.
     *
     * Skipping BEFORE the encoder is a time-skip; the board's decoder simply
     * continues from the last byte we actually sent, and our encoder state
     * still matches it. Dropping an already-encoded frame out of the queue is
     * the opposite — it removes nibbles the peer needed and desyncs the
     * predictor for the rest of the call.
     *
     * This also bounds latency, and that is now its main job.
     *
     * The sender is arrival-driven — one frame out per frame in — so a backlog
     * is a PERMANENT offset: there is no mechanism that sends faster to catch
     * up. A single 500 ms stall pushed the queue to 24 frames and it stayed
     * there for the following fifteen minutes, adding 1.4 s to every reply on
     * top of Gemini's own latency. The caller experiences that as the agent
     * not answering.
     *
     * 8 frames caps the backlog at ~480 ms. It was briefly set here before and
     * fired constantly, but that was when each socket write cost ~47 ms and the
     * queue was permanently deep; with writes now at 10 ms the queue only fills
     * during a genuine stall, so this should fire once to recover and then
     * stay quiet.
     */
    private const val TX_SKIP_DEPTH = 8

    /** Depth to trim back down to once [TX_SKIP_DEPTH] is hit. */
    private const val TX_TRIM_TO = PRIME_FRAMES

    /**
     * Cap on the agent's audio held here, in samples (12 s at 16 kHz).
     *
     * This must hold a WHOLE reply. Gemini does not speak in real time — it
     * delivers a four-second utterance in about one second — so a buffer sized
     * for a real-time source silently discards most of every reply. At the
     * 400 ms this used to be, the caller heard the tail of a sentence and then
     * nothing, which is precisely what it sounded like.
     *
     * Latency is not the reason to keep this small: the caller has to hear the
     * reply at speaking rate regardless, and barge-in is handled by flush.
     */
    private const val OUT_PCM_MAX = 16000 * 12



    private var activity: Activity? = null

    /**
     * This object is process-scoped and outlives the Activity, so everything
     * that only needs a Context uses this one. Holding the Activity for those
     * leaked it across the very destroy-and-recreate this service now guards.
     */
    private var appContext: Context? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val connecting = java.util.concurrent.atomic.AtomicBoolean(false)

    private var socket: BluetoothSocket? = null
    private var readerThread: Thread? = null
    private var writerThread: Thread? = null
    private var statsThread: Thread? = null
    private val running = AtomicBoolean(false)

    private var stage = 1
    private val seq = AtomicInteger(0)

    /**
     * Stage 7: PCM16 @16 kHz from Gemini, waiting to go to the caller.
     *
     * Four seconds. The agent produces far faster than real time, so this
     * absorbs a whole utterance; the frame clock below drains it at 60 ms per
     * frame regardless, and emits silence when it is empty. Silence is not
     * optional — go quiet for a second and the board starts echoing the caller
     * to themselves.
     */
    private val outPcm = ShortArray(16000 * 16)
    private var outW = 0
    private var outR = 0
    private val outLock = Any()

    /** Stage 6 only: "tone" or "file". */
    private var source = "tone"

    /** Arm as soon as the socket opens. See the gate in start(). */
    private var autoArm = true
    private var sourcePcm: ShortArray = ShortArray(0)
    private var sourcePos = 0

    /** Bounded so a congested link drops frames instead of stalling the reader. */
    private val txQueue = ArrayBlockingQueue<ByteArray>(48)

    /** Control frames (arm, flush) bypass the pacing clock entirely. */
    private val ctrlQueue = ArrayBlockingQueue<ByteArray>(8)

    /** Stage 4 only. Keeps file writes off the reader thread. */
    private val wavQueue = ArrayBlockingQueue<ShortArray>(64)

    private val rxBytes = AtomicLong(0)
    private val txBytes = AtomicLong(0)
    private val rxFrames = AtomicLong(0)
    private val txFrames = AtomicLong(0)
    private val rxAudio = AtomicLong(0)
    private val resyncs = AtomicLong(0)
    private val dropped = AtomicLong(0)
    private var startedAt = 0L
    private var lastAudioAt = 0L
    private var lastRxSeq = -1
    private var wifiWasOn = false
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private var priming = true

    /** True while working the queue back down to [TX_TRIM_TO]. */
    private var trimming = false
    private var lastSentAt = 0L
    private var nextSendAt = 0L
    private val starved = AtomicLong(0)
    private val skipped = AtomicLong(0)
    private val pcmTrimmed = AtomicLong(0)
    private val writeNs = AtomicLong(0)
    private val writeMaxNs = AtomicLong(0)
    private val writeCount = AtomicLong(0)

    private var callState = 0
    private var callSetup = 0
    private var callerId = ""
    private var armed = false

    /** When ARM(1) went out. The board replays its current AG indicators right
     *  after, which arrives looking exactly like a call that never happened. */
    private var armedAt = 0L

    private val decoder = ImaAdpcm()
    private val encoder = ImaAdpcm()

    private var wav: WavWriter? = null

    fun register(flutterEngine: FlutterEngine, act: Activity) {
        activity = act
        appContext = act.applicationContext
        // Set here, not in start(): the routing buttons work before a session
        // exists, and on this device a log that does not reach LogBuffer is a
        // log nobody can read.
        HfpRouter.logger = ::log
        repairWifiIfOwed()
        reportUncleanShutdown()
        installCrashHandler()

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listPaired" -> result.success(listPaired())
                    "start" -> {
                        val address = call.argument<String>("address") ?: ""
                        val requested = call.argument<Int>("stage") ?: 1
                        source = call.argument<String>("source") ?: "tone"
                        autoArm = call.argument<Boolean>("autoArm") ?: true
                        // Off the main thread: an RFCOMM connect to a board
                        // that is not there blocks for ~20 s, and on the main
                        // thread it froze the whole app — the launcher, and the
                        // accessibility service that closes the stock
                        // launcher's charging screen (1,231 frames skipped).
                        if (!connecting.compareAndSet(false, true)) {
                            result.success(mapOf("success" to false, "error" to "already connecting"))
                        } else {
                            Thread({
                                val r = try { start(address, requested) } finally { connecting.set(false) }
                                main.post { result.success(r) }
                            }, "call-bridge-connect").start()
                        }
                    }
                    "stop" -> {
                        stop("stopped by user")
                        result.success(true)
                    }
                    "arm" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        result.success(sendArm(on))
                    }
                    "flush" -> {
                        clearPcm()
                        result.success(sendControl(TYPE_FLUSH, ByteArray(0)))
                    }
                    "prepareNetwork" ->
                        prepareNetwork(call.argument<Boolean>("disableWifi") ?: false, result)
                    "sendPcm" -> {
                        val b = call.argument<ByteArray>("pcm")
                        if (b != null) {
                            val pcm = ShortArray(b.size / 2)
                            for (i in pcm.indices) {
                                val lo = b[i * 2].toInt() and 0xFF
                                val hi = b[i * 2 + 1].toInt()
                                pcm[i] = ((hi shl 8) or lo).toShort()
                            }
                            pushPcm(pcm)
                        }
                        result.success(true)
                    }
                    "recordings" -> result.success(listRecordings())
                    "logsDir" -> result.success(logsDir()?.absolutePath)
                    // Block until the last of the agent's voice has actually
                    // left for the board. The stats tick is once a second and
                    // the queue holds ~240 ms, so callers cannot time this from
                    // "queued" — only the thread that owns the queue can.
                    "drain" -> {
                        val capMs = (call.argument<Int>("capMs") ?: 6000).toLong()
                        Thread {
                            val deadline = System.currentTimeMillis() + capMs
                            // Empty ONCE means nothing: the pacing thread feeds
                            // silence continuously, so the queue dips to zero
                            // under ordinary jitter several times a call. Only
                            // a gap wider than a frame period means the talker
                            // has actually stopped producing.
                            var clear = 0
                            while (running.get() && clear < 3 &&
                                System.currentTimeMillis() < deadline) {
                                clear = if (txQueue.isEmpty()) clear + 1 else 0
                                try { Thread.sleep(40) } catch (_: InterruptedException) { break }
                            }
                            val done = clear >= 3
                            main.post { result.success(done) }
                        }.start()
                    }

                    // Test only: die the way the system kills us, so crash
                    // recovery can be exercised. Force-stopping from Android
                    // Settings is impossible during a call — the dialer owns
                    // the screen, the same wall the transfer prompt hit.
                    "killSelf" -> {
                        log("!! killing this process on purpose (recovery test)")
                        main.postDelayed({
                            android.os.Process.killProcess(android.os.Process.myPid())
                        }, 150)
                        result.success(true)
                    }

                    // Undo prepareNetwork's process-wide bind.
                    //
                    // bindProcessToNetwork(cellular) applies to EVERY socket
                    // this process opens, including a server socket. With the
                    // agent on duty from boot, the settings web server came up
                    // bound to cellular and was unreachable from the LAN.
                    "unbindNetwork" -> {
                        try {
                            val cm = appContext?.getSystemService(Context.CONNECTIVITY_SERVICE)
                                as? ConnectivityManager
                            cm?.bindProcessToNetwork(null)
                            log("network: process unbound — back on the default route")
                            result.success(true)
                        } catch (e: Exception) {
                            log("!! unbind failed: ${e.message}")
                            result.success(false)
                        }
                    }

                    "clipsDir" -> result.success(clipsDir()?.absolutePath)
                    // Where call history lives. Same external files dir as the
                    // clips, so it survives an app update and is reachable over
                    // the settings server for inspection.
                    "dataDir" -> result.success(
                        appContext?.getExternalFilesDir(null)?.absolutePath)
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------------- events

    private fun emit(map: Map<String, Any?>) {
        main.post { sink?.success(map) }
    }

    private fun log(msg: String) = emit(mapOf("type" to "log", "msg" to msg))

    /**
     * Heap and system memory, once a second.
     *
     * The process is being killed on long calls and there is no logcat on this
     * device, so the only way to tell a leak from outside pressure is to watch
     * both numbers: our heap climbing means it is us, system free collapsing
     * while our heap is flat means it is not.
     */
    private fun memorySnapshot(): String {
        return try {
            val rt = Runtime.getRuntime()
            val usedMb = (rt.totalMemory() - rt.freeMemory()) / 1048576
            val maxMb = rt.maxMemory() / 1048576
            val am = appContext?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am?.getMemoryInfo(mi)
            val availMb = mi.availMem / 1048576
            "mem ${usedMb}/${maxMb}MB sys ${availMb}MB${if (mi.lowMemory) " LOW" else ""}"
        } catch (e: Exception) {
            "mem ?"
        }
    }

    private fun writeMeanMs(): Long {
        val n = writeCount.getAndSet(0)
        val t = writeNs.getAndSet(0)
        return if (n == 0L) 0 else (t / n) / 1_000_000
    }

    private fun emitStats() {
        val elapsed = if (startedAt == 0L) 0L else System.currentTimeMillis() - startedAt
        emit(
            mapOf(
                "type" to "stats",
                "connected" to running.get(),
                "stage" to stage,
                "armed" to armed,
                "elapsedMs" to elapsed,
                "rxBytes" to rxBytes.get(),
                "txBytes" to txBytes.get(),
                "rxFrames" to rxFrames.get(),
                "txFrames" to txFrames.get(),
                "rxAudio" to rxAudio.get(),
                "resync" to resyncs.get(),
                "dropped" to dropped.get(),
                "starved" to starved.get(),
                "queued" to txQueue.size,
                "callState" to callState,
                "callSetup" to callSetup,
                "callerId" to callerId,
                "wav" to (wav?.path ?: ""),
            )
        )
    }

    // ------------------------------------------------------------ connection

    private fun hasBtPermission(): Boolean {
        if (Build.VERSION.SDK_INT < 31) return true
        val a = activity ?: return false
        return ActivityCompat.checkSelfPermission(
            a, "android.permission.BLUETOOTH_CONNECT"
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestBtPermission() {
        if (Build.VERSION.SDK_INT < 31) return
        val a = activity ?: return
        ActivityCompat.requestPermissions(
            a, arrayOf("android.permission.BLUETOOTH_CONNECT"), 4711
        )
    }

    @Suppress("MissingPermission")
    private fun listPaired(): List<Map<String, String>> {
        if (!hasBtPermission()) {
            requestBtPermission()
            return emptyList()
        }
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()
        return adapter.bondedDevices.map {
            mapOf("name" to (it.name ?: "(unnamed)"), "address" to it.address)
        }.sortedBy { it["name"] }
    }

    @Suppress("MissingPermission")
    private fun start(address: String, requestedStage: Int): Map<String, Any?> {
        if (running.get()) return mapOf("success" to false, "error" to "already running")
        if (!hasBtPermission()) {
            main.post { requestBtPermission() }
            return mapOf("success" to false, "error" to "BLUETOOTH_CONNECT not granted — retry")
        }

        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: return mapOf("success" to false, "error" to "no Bluetooth adapter")
        if (!adapter.isEnabled) {
            return mapOf("success" to false, "error" to "Bluetooth is off")
        }

        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(address)
        } catch (e: Exception) {
            return mapOf("success" to false, "error" to "bad address: ${e.message}")
        }

        stage = requestedStage
        resetCounters()
        HfpRouter.bridgeMac = address

        return try {
            // Discovery running during connect is the classic cause of a slow or
            // failed RFCOMM handshake.
            adapter.cancelDiscovery()

            // SECURE socket. The board registers with ESP_SPP_SEC_AUTHENTICATE;
            // an insecure connect is refused and takes the whole ACL link down
            // with it, killing HFP too (spp-app-integration.md §2).
            val s = device.createRfcommSocketToServiceRecord(SPP_UUID)
            log("connecting to ${device.name ?: address} ($address) — secure RFCOMM")
            s.connect()
            socket = s
            running.set(true)
            startedAt = System.currentTimeMillis()
            appContext?.let { CallBridgeService.start(it) }
            markCallActive(true)
            log(">>> SPP OPEN — stage $stage")
            // The findings doc says API 26, the project notes say Android 12.
            // Which is true decides whether Wi-Fi can be controlled at all.
            log("device: Android SDK ${Build.VERSION.SDK_INT} (${Build.VERSION.RELEASE})")

            if (stage == 7) {
                clearPcm()
                log("stage 7: live agent — caller audio goes up to Gemini,")
                log("its replies come back here. Silence is sent when it is quiet.")
            }

            if (stage == 6) {
                sourcePcm = if (source == "file") loadNewestRecording() else toneP()
                sourcePos = 0
                if (sourcePcm.isEmpty()) {
                    log("!! stage 6: no source audio — falling back to a tone")
                    sourcePcm = toneP()
                }
                log("stage 6: source '$source', ${sourcePcm.size / 16} ms," +
                    " paced off inbound frames")
                log("The caller should hear this, NOT themselves.")
            }

            if (stage == 4) {
                val dir = recordingsDir()
                if (dir == null) {
                    log("!! no external files dir — stage 4 cannot record")
                } else {
                    val f = File(dir, "bridge_${startedAt}.wav")
                    wav = WavWriter(f, 16000)
                    log("stage 4: recording 16 kHz PCM -> ${f.name}")
                }
            }

            if (stage == 1) {
                log("stage 1: holding the socket idle. Not reading, not writing.")
                log("PASS = board logs 'SPP OPEN' and the link survives 2 min.")
            } else {
                startWriter()
                startReader()
            }
            startStats()

            if (stage >= 3) {
                // If Thread.sleep overshoots badly here, no timer-paced design
                // can work on this device and the send path must stay
                // arrival-driven. Measure it rather than assume.
                Thread({
                    var worst = 0L
                    var total = 0L
                    for (i in 0 until 10) {
                        val t0 = System.nanoTime()
                        try { Thread.sleep(60) } catch (_: InterruptedException) {}
                        val dt = (System.nanoTime() - t0) / 1_000_000
                        total += dt
                        if (dt > worst) worst = dt
                    }
                    log("scheduler: sleep(60ms) -> mean ${total / 10} ms, worst $worst ms")
                }, "spp-calib").start()
            }

            if (stage >= 2 && autoArm) {
                // The board boots disarmed and takes no call audio until asked.
                // An unarmed board looks exactly like a broken reader, so arm
                // here and say so loudly (spp-app-integration.md §5.0).
                //
                // autoArm=false is the arm-on-demand experiment: the board stays
                // off the HFP slot until a call arrives, so the wearer's earbud
                // can hold it meanwhile. Ring detection then has to come from
                // PhoneRingChannel, because a board with no SLC sees nothing.
                Thread({
                    try { Thread.sleep(150) } catch (_: InterruptedException) {}
                    sendArm(true)
                }, "spp-arm").start()
            }
            mapOf("success" to true)
        } catch (e: Exception) {
            log("!! connect failed: ${e.message}")
            closeSocket()
            mapOf("success" to false, "error" to (e.message ?: "connect failed"))
        }
    }

    private fun resetCounters() {
        rxBytes.set(0); txBytes.set(0)
        rxFrames.set(0); txFrames.set(0); rxAudio.set(0)
        resyncs.set(0); dropped.set(0)
        seq.set(0)
        callState = 0; callSetup = 0; callerId = ""
        armed = false
        lastAudioAt = 0L
        decoder.reset(); encoder.reset()
        txQueue.clear()
        ctrlQueue.clear()
        wavQueue.clear()
        starved.set(0)
        skipped.set(0)
        pcmTrimmed.set(0)
        priming = true
        trimming = false
        lastSentAt = 0L
        nextSendAt = 0L
        lastRxSeq = -1
    }

    private fun stop(reason: String) {
        if (!running.getAndSet(false)) {
            closeSocket()
            return
        }
        log("<<< closing: $reason")
        // Whether a call is still up decides what releasing the slot means:
        // tidy-up, or a hand-over that has to stay audible.
        HfpRouter.callActive = callState == 1
        // Say the call is over before anything else. stop() used to leave
        // callState at 1, so after an unsolicited close (the board powering off
        // mid-call) the stats tick still read "active" forever — and the call
        // agent's backstop dutifully believed it and reconnected to Gemini on a
        // loop, with no bridge left to carry the audio.
        callState = 0; callSetup = 0; callerId = ""
        main.post {
            sink?.success(mapOf(
                "type" to "callstate", "call" to 0, "setup" to 0,
                "initial" to false,
                // Not "the call ended" — "I can no longer see the call". The
                // socket is going; whether a call is still running on the device
                // is a question only telephony can answer now. Consumers that
                // drop buffered audio still want this; consumers that track
                // call state must NOT read it as idle.
                "closing" to true,
            ))
        }
        markCallActive(false)
        if (armed) appContext?.let { HfpRouter.releaseToUser(it) }
        appContext?.let {
            // A hand-over is not the end of the work: the call is still live on
            // the device, so the process still needs protecting.
            if (HfpRouter.callActive) CallBridgeService.holdForCall(it)
            else CallBridgeService.stop(it)
        }
        releaseNetwork()
        restoreWifi()
        closeSocket()
        wav?.let {
            it.close()
            log("stage 4: wrote ${it.samples} samples -> ${it.path}")
            log("fetch it at http://<device-ip>:8080/api/bridge/recordings")
        }
        wav = null
        readerThread = null
        writerThread = null
        statsThread = null
        armed = false
        emitStats()
    }

    /**
     * Put this process's traffic on cellular for the duration of a call.
     *
     * The agent needs its data connection and the bridge at the same time, and
     * on 2.4 GHz they fight: with the Gemini socket on Wi-Fi the caller hears
     * the agent chopped up, and on LTE the same call is clean. Asking the user
     * to toggle a radio is not an option on a device whose whole premise is
     * acting unattended, so the traffic moves instead of the user.
     *
     * requestNetwork brings cellular up and HOLDS it even though Wi-Fi is the
     * system default; the callback must stay registered for the whole call or
     * the system tears it down again. bindProcessToNetwork does not move
     * already-open sockets, so Gemini must connect AFTER this returns — its
     * resumption handle makes that reconnect free.
     *
     * Fails safe: no SIM, data off, or no answer inside the timeout and we
     * simply carry on as before.
     */
    private fun prepareNetwork(disableWifi: Boolean, result: MethodChannel.Result) {
        val cm = appContext
            ?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null) {
            result.success(mapOf("cellular" to false, "reason" to "no ConnectivityManager"))
            return
        }
        if (netCallback != null) {
            result.success(mapOf("cellular" to true, "reason" to "already bound"))
            return
        }

        val answered = AtomicBoolean(false)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val bound = try {
                    cm.bindProcessToNetwork(network)
                } catch (e: Exception) {
                    log("!! bindProcessToNetwork failed: ${e.message}"); false
                }
                if (bound) log("network: Gemini traffic bound to cellular.")
                if (disableWifi) setWifiOff()
                if (answered.compareAndSet(false, true)) {
                    main.post { result.success(mapOf("cellular" to bound)) }
                }
            }

            override fun onUnavailable() {
                log("!! no cellular network — staying on the default route.")
                log("!! expect chopping if that route is 2.4 GHz Wi-Fi.")
                if (disableWifi) setWifiOff()
                if (answered.compareAndSet(false, true)) {
                    main.post { result.success(mapOf("cellular" to false,
                        "reason" to "cellular unavailable")) }
                }
            }

            override fun onLost(network: Network) {
                // Bound sockets fail hard rather than falling back, by design.
                log("!! cellular lost mid-call — unbinding.")
                try { cm.bindProcessToNetwork(null) } catch (_: Exception) {}
            }
        }

        return try {
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            netCallback = cb
            cm.requestNetwork(req, cb, 5000)
            log("network: asking for cellular (5 s)…")
        } catch (e: Exception) {
            netCallback = null
            log("!! requestNetwork failed: ${e.message}")
            result.success(mapOf("cellular" to false, "reason" to (e.message ?: "failed")))
        }
    }

    private fun releaseNetwork() {
        val cb = netCallback ?: return
        netCallback = null
        try {
            val cm = appContext
                ?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            cm?.bindProcessToNetwork(null)
            cm?.unregisterNetworkCallback(cb)
            log("network: released cellular binding.")
        } catch (e: Exception) {
            log("!! releaseNetwork failed: ${e.message}")
        }
    }

    /**
     * Turn Wi-Fi off for the duration of an agent call.
     *
     * Measured, not assumed: with Wi-Fi associated the caller hears the agent
     * chopped up; with Wi-Fi off and Gemini on LTE the same call is clean. 2.4
     * GHz Wi-Fi and Bluetooth share the band and, on this class of SoC, the
     * antenna — and this link is already carrying a live SCO stream plus 16
     * kB/s of RFCOMM, so it has nothing to give.
     *
     * This is a product rule, not a workaround: the agent needs its data
     * connection and the bridge at the same time, always. Restored on stop.
     */
    private fun setWifiOff() {
        try {
            val wm = appContext
                ?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            wifiWasOn = wm.isWifiEnabled
            if (!wifiWasOn) {
                log("Wi-Fi already off — Gemini will use mobile data.")
                return
            }
            @Suppress("DEPRECATION")
            val ok = wm.setWifiEnabled(false)
            if (ok) {
                // Persisted so a crash mid-call cannot leave the user's Wi-Fi
                // off with nothing left running to turn it back on.
                markWifiOwed(true)
                log("Wi-Fi disabled for this call (restored on stop).")
            } else {
                wifiWasOn = false
                log("!! Could not disable Wi-Fi — Android 10+ blocks this.")
                log("!! Turn it off by hand: on Wi-Fi the caller hears chopping.")
            }
        } catch (e: Exception) {
            log("!! Wi-Fi control failed: ${e.message}")
        }
    }

    private fun restoreWifi() {
        if (!wifiWasOn) return
        wifiWasOn = false
        try {
            val wm = appContext
                ?.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            @Suppress("DEPRECATION")
            wm.setWifiEnabled(true)
            markWifiOwed(false)
            log("Wi-Fi restored.")
        } catch (e: Exception) {
            log("!! Wi-Fi restore failed: ${e.message}")
        }
    }

    /**
     * Records an uncaught JVM exception where the next launch can read it. If
     * the process dies mid-call and this file is EMPTY, nothing threw — which
     * means the system killed us rather than us crashing.
     */
    private fun installCrashHandler() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                appContext?.getSharedPreferences("call_bridge", Context.MODE_PRIVATE)
                    ?.edit()
                    ?.putString("last_crash",
                        "${e.javaClass.simpleName}: ${e.message} on ${t.name}\n" +
                            e.stackTrace.take(8).joinToString("\n") { "  at $it" })
                    ?.commit()
            } catch (_: Throwable) {}
            prev?.uncaughtException(t, e)
        }
    }

    private fun markCallActive(active: Boolean) {
        try {
            appContext?.getSharedPreferences("call_bridge", Context.MODE_PRIVATE)
                ?.edit()?.putBoolean("call_active", active)?.apply()
        } catch (_: Exception) {}
    }

    /**
     * If a previous run set the flag and never cleared it, the process went
     * away mid-call — killed or crashed. There is no ADB on this device, so this
     * is the only way to tell that apart from a clean stop.
     */
    private fun reportUncleanShutdown() {
        try {
            val prefs = appContext
                ?.getSharedPreferences("call_bridge", Context.MODE_PRIVATE) ?: return
            val midCall = prefs.getBoolean("call_active", false)
            val crash = prefs.getString("last_crash", null)
            if (!midCall && crash == null) return
            prefs.edit().putBoolean("call_active", false)
                .remove("last_crash").apply()
            main.post {
                // Reported even when the previous run died OUTSIDE a call. The
                // check used to be gated on call_active, so a process killed
                // after the bridge stopped left no trace at all — which is
                // exactly the case that needed explaining.
                if (midCall) log("!! previous call ended without a clean stop.")
                else log("!! previous run did not exit cleanly.")
                if (crash != null) {
                    log("!! it CRASHED: $crash")
                } else {
                    log("!! nothing threw — the system KILLED the process.")
                }
            }
        } catch (_: Exception) {}
    }

    private fun markWifiOwed(owed: Boolean) {
        try {
            appContext
                ?.getSharedPreferences("call_bridge", Context.MODE_PRIVATE)
                ?.edit()?.putBoolean("wifi_owed", owed)?.apply()
        } catch (_: Exception) {}
    }

    /**
     * Repair a Wi-Fi disable that a crash or kill never undid. Called at
     * registration, before anything else can run.
     */
    private fun repairWifiIfOwed() {
        try {
            val prefs = appContext
                ?.getSharedPreferences("call_bridge", Context.MODE_PRIVATE) ?: return
            if (!prefs.getBoolean("wifi_owed", false)) return
            val wm = appContext
                ?.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            wm?.setWifiEnabled(true)
            prefs.edit().putBoolean("wifi_owed", false).apply()
        } catch (_: Exception) {}
    }

    private fun closeSocket() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
    }

    // ---------------------------------------------------------------- reader

    private fun startReader() {
        val t = Thread({
            val input: InputStream = try {
                socket!!.inputStream
            } catch (e: Exception) {
                log("!! no input stream: ${e.message}"); stop("input stream failed"); return@Thread
            }
            val buf = ByteArray(2048)
            val parser = FrameParser()
            try {
                while (running.get()) {
                    val n = input.read(buf)
                    if (n < 0) { stop("peer closed the stream"); break }
                    if (n == 0) continue
                    rxBytes.addAndGet(n.toLong())
                    // Stage 2 is a byte counter by design — no parsing, so a
                    // framing bug cannot be mistaken for a throughput problem.
                    if (stage >= 3) parser.feed(buf, n)
                }
            } catch (e: Exception) {
                if (running.get()) { log("!! read error: ${e.message}"); stop("read error") }
            }
        }, "spp-reader")
        t.priority = Thread.MAX_PRIORITY
        readerThread = t
        t.start()
    }

    /**
     * RFCOMM is a byte stream: frames arrive split across reads and several to
     * a read. State lives here, across calls, and the magic is validated as it
     * arrives so a desync can never be read as a huge length.
     */
    private class FrameParser {
        private var state = 0 // 0 = want magic0, 1 = want magic1, 2 = header, 3 = payload
        private var scanning = false // inside a run of garbage — count it once
        private val header = ByteArray(HEADER_LEN)
        private var headerFilled = 0
        private var payload = ByteArray(0)
        private var payloadFilled = 0
        private var fType = 0
        private var fRate = 0
        private var fSeq = 0
        private var fLen = 0

        fun feed(data: ByteArray, len: Int) {
            var i = 0
            while (i < len) {
                when (state) {
                    0 -> {
                        if (data[i] == MAGIC0) {
                            header[0] = MAGIC0; headerFilled = 1; state = 1
                        } else if (!scanning) {
                            scanning = true
                            resyncs.incrementAndGet()
                        }
                        i++
                    }
                    1 -> {
                        if (data[i] == MAGIC1) {
                            header[1] = MAGIC1; headerFilled = 2; state = 2
                            scanning = false
                            i++
                        } else {
                            // Not a header after all. Do not consume — this byte
                            // may itself be the start of the real magic.
                            state = 0; headerFilled = 0
                        }
                    }
                    2 -> {
                        val need = HEADER_LEN - headerFilled
                        val take = minOf(need, len - i)
                        System.arraycopy(data, i, header, headerFilled, take)
                        headerFilled += take; i += take
                        if (headerFilled == HEADER_LEN) {
                            fSeq = u16(header, 2)
                            fType = header[4].toInt() and 0xFF
                            fRate = header[5].toInt() and 0xFF
                            fLen = u16(header, 6)
                            if (fLen > MAX_PAYLOAD) {
                                resyncs.incrementAndGet()
                                scanning = true
                                state = 0; headerFilled = 0
                            } else if (fLen == 0) {
                                onFrame(fType, fRate, fSeq, ByteArray(0))
                                state = 0; headerFilled = 0
                            } else {
                                payload = ByteArray(fLen); payloadFilled = 0; state = 3
                            }
                        }
                    }
                    else -> {
                        val need = fLen - payloadFilled
                        val take = minOf(need, len - i)
                        System.arraycopy(data, i, payload, payloadFilled, take)
                        payloadFilled += take; i += take
                        if (payloadFilled == fLen) {
                            onFrame(fType, fRate, fSeq, payload)
                            state = 0; headerFilled = 0
                        }
                    }
                }
            }
        }

        private fun u16(b: ByteArray, off: Int): Int =
            (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
    }

    private fun onFrame(type: Int, rate: Int, fseq: Int, payload: ByteArray) {
        rxFrames.incrementAndGet()
        when (type) {
            TYPE_AUDIO -> onAudioFrame(rate, fseq, payload)
            TYPE_CALL_STATE -> {
                // 2 bytes now: [call, setup]. Tolerate the old 1-byte form.
                val call = if (payload.isNotEmpty()) payload[0].toInt() and 0xFF else 0
                val setup = if (payload.size >= 2) payload[1].toInt() and 0xFF else 0
                // Within a moment of arming, the board is telling us what its
                // indicators already were, not narrating a call. Taking that as
                // a real transition produced a whole outgoing call — dial,
                // alert, answer — inside 4 ms, with no call on the line.
                //
                // Do not adopt the values either. Suppressing only the
                // transition still let callState=1 reach the stats tick, and
                // the Dart side's stats backstop dutifully turned the phantom
                // call back on a few seconds later. The board reports a real
                // transition the moment anything actually changes, so staying
                // at idle until then loses nothing.
                val initial = System.currentTimeMillis() - armedAt < 1500L
                val changed = !initial && (call != callState || setup != callSetup)
                if (!initial) {
                    callState = call; callSetup = setup
                    HfpRouter.callActive = call == 1
                }
                if (initial) {
                    log("board initial state [$call,$setup] — not a call")
                }
                if (changed) {
                    log("CALL-STATE [$call,$setup] — ${describeCall(call, setup)}")
                    if (call == 0 && setup == 0) callerId = ""
                    main.post {
                        sink?.success(mapOf(
                            "type" to "callstate",
                            "call" to call,
                            "setup" to setup,
                            "initial" to false,
                        ))
                    }
                }
                emitStats()
            }
            TYPE_CALLER_ID -> {
                callerId = String(payload, Charsets.UTF_8).trim()
                log("CALLER-ID  $callerId")
                emitStats()
            }
            TYPE_FLUSH -> log("board sent flush")
            TYPE_ARM -> log("board echoed arm (unexpected, board->app)")
            else -> log("unknown frame type $type len ${payload.size}")
        }
    }

    private fun describeCall(call: Int, setup: Int): String = when {
        call == 0 && setup == 1 -> "incoming, ringing"
        call == 0 && setup == 2 -> "outgoing, dialling"
        call == 0 && setup == 3 -> "outgoing, alerting"
        call == 1 -> "answered / active"
        else -> "idle"
    }

    private fun resetAudioSession(why: String) {
        decoder.reset(); encoder.reset()
        txQueue.clear()
        clearPcm()
        priming = true
        trimming = false
        log("audio session reset ($why) — codec state cleared")
    }

    private fun onAudioFrame(rate: Int, fseq: Int, payload: ByteArray) {
        val now = System.currentTimeMillis()

        // Codec state changes ONLY on a real session boundary, never on a
        // timing heuristic.
        //
        // IMA's predictor is a pure integrator with no leak, so resetting ours
        // while the peer's keeps running puts a permanent offset into every
        // sample after it — the caller hears noise for the rest of the call.
        // A gap in arrivals means our transport stalled; it says nothing about
        // whether the board's codec restarted. Its `seq` resetting does.
        val wrapped = lastRxSeq > 65000 && fseq < 500
        if (lastRxSeq >= 0 && fseq < lastRxSeq && !wrapped) {
            resetAudioSession("board seq restarted at $fseq")
        }
        lastRxSeq = fseq

        if (lastAudioAt != 0L && now - lastAudioAt > AUDIO_GAP_RESET_MS) {
            // Informational only — deliberately does not touch the codecs.
            log("${now - lastAudioAt} ms audio gap (codec state kept)")
        }
        lastAudioAt = now
        rxAudio.incrementAndGet()

        when (stage) {
            // Re-frame and send the payload straight back, untouched. Proves
            // framing, split-read handling and the return path at once.
            3 -> enqueue(buildFrame(TYPE_AUDIO, rate, payload))

            // Decode only, to a WAV we can listen to off-device.
            4 -> {
                if (!wavQueue.offer(decoder.decode(payload))) dropped.incrementAndGet()
            }

            // Full codec path in both directions.
            5 -> {
                val pcm = decoder.decode(payload)
                enqueue(buildFrame(TYPE_AUDIO, rate, encoder.encode(pcm)))
            }

            // Play an independent source to the caller.
            //
            // Echo makes the inbound stream both the source and the clock, so a
            // clean echo says nothing about pacing audio that has a cadence of
            // its own. Gemini's does not — it arrives in bursts over a socket.
            // Here the source is stored audio and the clock is still the board's
            // arrivals, which is exactly how the real sender has to work.
            // Live agent. Same clock as stage 6 — the board's arrivals — but
            // the source is Gemini rather than a file, and the caller's audio
            // goes up to Dart to be sent to it.
            7 -> {
                val n = payload.size * 2
                // Skip ahead rather than bank audio the caller will hear late.
                //
                // With hysteresis, because refusing to add only while at the
                // ceiling holds the queue exactly AT the ceiling: the sender is
                // arrival-driven, so one arrival skipped is one frame sent, and
                // the depth never moves. A whole call ran at q 7-8 that way —
                // ~480 ms of standing latency for the price of 8 skipped
                // frames. Trimming to [TX_TRIM_TO] costs a few more frames once
                // and gets the latency back.
                //
                // The skip happens before encode on purpose: ADPCM is a running
                // predictor, so the encoder must never see samples the board's
                // decoder will not. Dropping an already-queued frame instead
                // would desync the two permanently.
                // TX_SKIP_DEPTH - 1, because this check runs before the
                // enqueue and the writer drains one frame between arrivals: at
                // arrival time the depth tops out one below the ceiling, so a
                // test against the ceiling itself never fires. A whole call sat
                // at q 6-7 with skip stuck at 2 for exactly that reason.
                if (txQueue.size >= TX_SKIP_DEPTH - 1) trimming = true
                if (trimming) {
                    if (txQueue.size <= TX_TRIM_TO) {
                        trimming = false
                    } else {
                        skipped.incrementAndGet()
                        takePcm(n)
                        return
                    }
                }
                val caller = decoder.decode(payload)
                val bytes = ByteArray(caller.size * 2)
                var o = 0
                for (v in caller) {
                    bytes[o++] = (v.toInt() and 0xFF).toByte()
                    bytes[o++] = ((v.toInt() shr 8) and 0xFF).toByte()
                }
                main.post { sink?.success(mapOf("type" to "pcm", "pcm" to bytes)) }
                enqueue(buildFrame(TYPE_AUDIO, rate, encoder.encode(takePcm(n))))
            }

            6 -> {
                if (txQueue.size >= TX_SKIP_DEPTH) { skipped.incrementAndGet(); return }
                val n = payload.size * 2          // samples this frame is worth
                val pcm = ShortArray(n)
                for (i in 0 until n) {
                    pcm[i] = sourcePcm[sourcePos]
                    sourcePos = (sourcePos + 1) % sourcePcm.size
                }
                enqueue(buildFrame(TYPE_AUDIO, rate, encoder.encode(pcm)))
            }
        }
    }

    // ---------------------------------------------------------------- writer

    private fun startWriter() {
        val t = Thread({
            val out: OutputStream = try {
                socket!!.outputStream
            } catch (e: Exception) {
                log("!! no output stream: ${e.message}"); return@Thread
            }
            // Deadline-based so sleep overshoot cannot accumulate into drift.
            var next = System.nanoTime()
            while (running.get()) {
                try {
                    // Control frames never wait for the pacing clock.
                    while (true) {
                        val c = ctrlQueue.poll() ?: break
                        writeOne(out, c)
                    }

                    if (stage == 4) {
                        wavQueue.poll(60, TimeUnit.MILLISECONDS)?.let { wav?.write(it) }
                        continue
                    }

                    // Stage 2 never echoes; pacing it would only accumulate a
                    // meaningless starve count.
                    if (stage < 3) {
                        Thread.sleep(60)
                        continue
                    }

                    // Arrival-driven, no timer in the send path.
                    //
                    // Two timer-paced versions both landed at exactly 9 frames/s
                    // against 17 arriving, while the original arrival-driven one
                    // held full rate. That says the sleep itself is the limiter
                    // on this device, so the clock here is the board's frame
                    // arrivals — which is the only clock that cannot drift
                    // against it anyway.
                    if (priming) {
                        // The reserve must fill before the first send, or the
                        // board starts out starved. Only this path sleeps.
                        if (txQueue.size < PRIME_FRAMES) {
                            Thread.sleep(10)
                            continue
                        }
                        priming = false
                        log("pacing primed with ${txQueue.size} frames" +
                            " (${txQueue.size * 60} ms)")
                    }

                    val first = txQueue.poll(200, TimeUnit.MILLISECONDS)
                    if (first == null) {
                        starved.incrementAndGet()
                        continue
                    }

                    // Pace at the rate the board consumes, one deadline per
                    // frame sent, carried rather than re-anchored.
                    //
                    // Two things sank earlier attempts. Measuring the interval
                    // from the END of a write makes the period interval+write
                    // (~107 ms, which is the 9 frames/s both timer versions
                    // produced). And re-anchoring the deadline whenever we are
                    // behind degenerates to the same thing, because a ~47 ms
                    // write leaves every iteration behind its deadline.
                    //
                    // Sending faster than 60 ms/frame is just as wrong: it
                    // drains the reserve above into the board's ring within
                    // seconds, after which there is no jitter buffer anywhere
                    // and every inbound stall reaches the caller.
                    val now = System.nanoTime()
                    if (nextSendAt == 0L || now - nextSendAt > 2 * FRAME_NS) {
                        nextSendAt = now
                    }
                    val wait = nextSendAt - now
                    if (wait > 0) TimeUnit.NANOSECONDS.sleep(wait)

                    // Coalesce into ONE write: the cost is per write, and the
                    // spec requires a frame never be split across writes.
                    val batch = ArrayList<ByteArray>(BATCH_FRAMES)
                    batch.add(first)
                    while (batch.size < BATCH_FRAMES) {
                        batch.add(txQueue.poll() ?: break)
                    }
                    var total = 0
                    for (f in batch) total += f.size
                    val buf = ByteArray(total)
                    var off = 0
                    for (f in batch) {
                        System.arraycopy(f, 0, buf, off, f.size); off += f.size
                    }

                    lastSentAt = System.nanoTime()
                    writeOne(out, buf)
                    txFrames.addAndGet((batch.size - 1).toLong())
                    nextSendAt += batch.size * FRAME_NS
                } catch (e: Exception) {
                    if (running.get()) { log("!! write error: ${e.message}"); stop("write error") }
                    break
                }
            }
        }, "spp-writer")
        writerThread = t
        t.start()
    }

    private fun writeOne(out: OutputStream, bytes: ByteArray) {
        val t0 = System.nanoTime()
        out.write(bytes)
        out.flush()
        val dt = System.nanoTime() - t0
        writeNs.addAndGet(dt)
        writeCount.incrementAndGet()
        while (true) {
            val cur = writeMaxNs.get()
            if (dt <= cur || writeMaxNs.compareAndSet(cur, dt)) break
        }
        txBytes.addAndGet(bytes.size.toLong())
        txFrames.incrementAndGet()
    }

    /** Never blocks the reader: a full queue drops the frame and counts it. */
    private fun enqueue(frame: ByteArray) {
        if (!txQueue.offer(frame)) dropped.incrementAndGet()
    }

    private fun buildFrame(type: Int, rate: Int, payload: ByteArray): ByteArray {
        val out = ByteArray(HEADER_LEN + payload.size)
        val s = seq.getAndIncrement() and 0xFFFF
        out[0] = MAGIC0
        out[1] = MAGIC1
        out[2] = (s and 0xFF).toByte()
        out[3] = ((s shr 8) and 0xFF).toByte()
        out[4] = type.toByte()
        out[5] = rate.toByte()
        out[6] = (payload.size and 0xFF).toByte()
        out[7] = ((payload.size shr 8) and 0xFF).toByte()
        if (payload.isNotEmpty()) {
            System.arraycopy(payload, 0, out, HEADER_LEN, payload.size)
        }
        return out
    }

    private fun sendControl(type: Int, payload: ByteArray): Boolean {
        if (!running.get()) return false
        return ctrlQueue.offer(buildFrame(type, 1, payload))
    }

    private fun sendArm(on: Boolean): Boolean {
        val ok = sendControl(TYPE_ARM, byteArrayOf(if (on) 1 else 0))
        if (ok) {
            armed = on
            if (on) {
                armedAt = System.currentTimeMillis()
                log("ARM(1) sent — the board will now take call audio.")
                log("Check the board log reads ARMED before debugging silence.")
                // This device connects one HFP device at a time, and that device
                // is the one startBluetoothSco() routes to. Arming means the
                // board needs to be it; the earbud gets the slot back on stop.
                appContext?.let { HfpRouter.acquireForBridge(it) }
            } else {
                log("ARM(0) sent — audio handed back to the handset.")
                appContext?.let { HfpRouter.releaseToUser(it) }
            }
            emitStats()
        }
        return ok
    }

    // ----------------------------------------------------------------- stats

    private fun startStats() {
        val t = Thread({
            var lastRx = 0L
            var lastTx = 0L
            while (running.get()) {
                try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
                val rx = rxBytes.get()
                val tx = txBytes.get()
                emitStats()
                if (stage >= 2 && (rx - lastRx > 0 || tx - lastTx > 0)) {
                    log("rate  up ${rx - lastRx} B/s   dn ${tx - lastTx} B/s" +
                        "   q ${txQueue.size}" +
                        "   frames ${rxFrames.get()}/${txFrames.get()}" +
                        "   resync ${resyncs.get()}  drop ${dropped.get()}" +
                        "  starve ${starved.get()}" +
                        "  skip ${skipped.get()}  trim ${pcmTrimmed.get()}" +
                        "  ${memorySnapshot()}" +
                        "  w ${writeMeanMs()}/${writeMaxNs.getAndSet(0) / 1_000_000}ms")
                }
                lastRx = rx
                lastTx = tx
            }
        }, "spp-stats")
        statsThread = t
        t.start()
    }

    // ------------------------------------------------------------ recordings

    private fun recordingsDir(): File? {
        val dir = activity?.getExternalFilesDir(null) ?: return null
        val d = File(dir, "bridge")
        if (!d.exists()) d.mkdirs()
        return d
    }

    private fun pushPcm(pcm: ShortArray) {
        synchronized(outLock) {
            for (v in pcm) {
                val next = (outW + 1) % outPcm.size
                if (next == outR) { outR = (outR + 1) % outPcm.size }
                outPcm[outW] = v
                outW = next
            }
            // Bound latency by discarding the oldest, not the newest.
            var held = (outW - outR + outPcm.size) % outPcm.size
            if (held > OUT_PCM_MAX) {
                outR = (outR + (held - OUT_PCM_MAX)) % outPcm.size
                held = OUT_PCM_MAX
                pcmTrimmed.incrementAndGet()
            }
        }
    }

    private fun takePcm(n: Int): ShortArray {
        val out = ShortArray(n)               // zero-filled = silence
        synchronized(outLock) {
            var i = 0
            while (i < n && outR != outW) {
                out[i++] = outPcm[outR]
                outR = (outR + 1) % outPcm.size
            }
        }
        return out
    }

    private fun clearPcm() {
        synchronized(outLock) { outR = 0; outW = 0 }
    }

    /** 1 kHz at 16 kHz, one second. Chopping in this is audible immediately. */
    private fun toneP(): ShortArray {
        val out = ShortArray(16000)
        for (i in out.indices) {
            out[i] = (Math.sin(2.0 * Math.PI * 1000.0 * i / 16000.0) * 9000).toInt().toShort()
        }
        return out
    }

    /** Newest stage-4 capture, PCM16 mono 16 kHz, header skipped. */
    private fun loadNewestRecording(): ShortArray {
        val d = recordingsDir() ?: return ShortArray(0)
        val f = (d.listFiles() ?: emptyArray())
            .filter { it.isFile && it.name.endsWith(".wav") && it.length() > 44 }
            .maxByOrNull { it.lastModified() } ?: return ShortArray(0)
        return try {
            val bytes = f.readBytes()
            val n = (bytes.size - 44) / 2
            val out = ShortArray(n)
            for (i in 0 until n) {
                val lo = bytes[44 + i * 2].toInt() and 0xFF
                val hi = bytes[44 + i * 2 + 1].toInt()
                out[i] = ((hi shl 8) or lo).toShort()
            }
            log("stage 6: loaded ${f.name} (${n / 16} ms)")
            out
        } catch (e: Exception) {
            log("!! could not read recording: ${e.message}")
            ShortArray(0)
        }
    }

    /** Where Dart persists the log so it survives the process being killed. */
    /** Cached fallback speech, generated once when the network is good. */
    private fun clipsDir(): File? {
        val dir = appContext?.getExternalFilesDir(null) ?: return null
        val d = File(dir, "clips")
        if (!d.exists()) d.mkdirs()
        return d
    }

    private fun logsDir(): File? {
        val dir = appContext?.getExternalFilesDir(null) ?: return null
        val d = File(dir, "logs")
        if (!d.exists()) d.mkdirs()
        return d
    }

    private fun listRecordings(): List<Map<String, Any>> {
        val d = recordingsDir() ?: return emptyList()
        return (d.listFiles() ?: emptyArray()).filter { it.isFile }.map {
            mapOf("name" to it.name, "bytes" to it.length(), "path" to it.absolutePath)
        }
    }

    // --------------------------------------------------------------- helpers

    /**
     * IMA/DVI ADPCM, 4 bits per sample, low nibble first, no block headers.
     * State is continuous for a whole call, so one instance per direction —
     * sharing them makes the predictors drift into noise.
     */
    private class ImaAdpcm {
        private var pred = 0
        private var index = 0

        fun reset() { pred = 0; index = 0 }

        private fun reconstruct(code: Int): Int {
            val step = STEP[index]
            var diffq = step shr 3
            if (code and 4 != 0) diffq += step
            if (code and 2 != 0) diffq += step shr 1
            if (code and 1 != 0) diffq += step shr 2
            pred += if (code and 8 != 0) -diffq else diffq
            if (pred > 32767) pred = 32767
            if (pred < -32768) pred = -32768
            index += INDEX[code]
            if (index < 0) index = 0
            if (index > 88) index = 88
            return pred
        }

        fun decode(input: ByteArray): ShortArray {
            val out = ShortArray(input.size * 2)
            var o = 0
            for (b in input) {
                val v = b.toInt()
                out[o++] = reconstruct(v and 0x0F).toShort()
                out[o++] = reconstruct((v shr 4) and 0x0F).toShort()
            }
            return out
        }

        fun encode(pcm: ShortArray): ByteArray {
            val out = ByteArray(pcm.size / 2)
            var o = 0
            var i = 0
            while (i + 1 < pcm.size) {
                val lo = encodeSample(pcm[i].toInt())
                val hi = encodeSample(pcm[i + 1].toInt())
                out[o++] = ((hi shl 4) or lo).toByte()
                i += 2
            }
            return out
        }

        private fun encodeSample(sample: Int): Int {
            val step = STEP[index]
            var diff = sample - pred
            var code = 0
            if (diff < 0) { code = 8; diff = -diff }
            var tmp = step
            if (diff >= tmp) { code = code or 4; diff -= tmp }
            tmp = tmp shr 1
            if (diff >= tmp) { code = code or 2; diff -= tmp }
            tmp = tmp shr 1
            if (diff >= tmp) code = code or 1
            // Run the decoder's reconstruction so this predictor tracks the
            // far end's exactly.
            reconstruct(code)
            return code
        }

        companion object {
            val INDEX = intArrayOf(-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)
            val STEP = intArrayOf(
                7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
                19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
                50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
                130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
                337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
                876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
                2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
                5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
                15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
            )
        }
    }

    /**
     * Minimal 16-bit mono WAV, valid at every instant.
     *
     * The header is rewritten after each frame rather than only on close: the
     * file is fetched over HTTP while the call is still running, and a header
     * written only at close means anything downloaded before Stop opens as
     * "incorrect filetype".
     */
    private class WavWriter(file: File, private val sampleRate: Int) {
        val path: String = file.absolutePath
        var samples: Long = 0; private set
        private val raf = RandomAccessFile(file, "rw")

        init {
            raf.setLength(0)
            writeHeader()
        }

        fun write(pcm: ShortArray) {
            val b = ByteArray(pcm.size * 2)
            var o = 0
            for (s in pcm) {
                b[o++] = (s.toInt() and 0xFF).toByte()
                b[o++] = ((s.toInt() shr 8) and 0xFF).toByte()
            }
            raf.seek(HEADER + samples * 2L)
            raf.write(b)
            samples += pcm.size
            writeHeader()
        }

        private fun writeHeader() {
            val dataLen = (samples * 2).toInt()
            raf.seek(0)
            raf.write("RIFF".toByteArray())
            raf.write(le32(36 + dataLen))
            raf.write("WAVE".toByteArray())
            raf.write("fmt ".toByteArray())
            raf.write(le32(16))
            raf.write(le16(1))                    // PCM
            raf.write(le16(1))                    // mono
            raf.write(le32(sampleRate))
            raf.write(le32(sampleRate * 2))       // byte rate
            raf.write(le16(2))                    // block align
            raf.write(le16(16))                   // bits
            raf.write("data".toByteArray())
            raf.write(le32(dataLen))
        }

        fun close() {
            try { writeHeader() } catch (_: Exception) {}
            try { raf.close() } catch (_: Exception) {}
        }

        private fun le32(v: Int) = byteArrayOf(
            (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte(), ((v shr 24) and 0xFF).toByte()
        )

        private fun le16(v: Int) = byteArrayOf(
            (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte()
        )

        companion object { private const val HEADER = 44L }
    }
}
