package ai.fox1.channels

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import ai.fox1.services.RingLinkService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import java.util.UUID

/**
 * BLE link to the JY smart ring, on Android's own GATT API.
 *
 * Replaces flutter_blue_plus, whose licence is free only for non-profit use
 * (a company pays from $2,999). The device is Android-only, so a cross-platform
 * plugin bought nothing, and every other hardware link here is already Kotlin
 * behind a channel.
 *
 * This layer only moves bytes. Framing, reassembly and every reply layout stay
 * in `ring_protocol.dart`, where they are unit-tested — nothing here knows what
 * an opcode is.
 *
 * **Android runs one GATT operation at a time**, and enforces it with a private
 * busy flag on the BluetoothGatt that is set when an operation starts and
 * cleared only by that operation's callback. Two consequences shape this file:
 *
 *  - Every read, write and descriptor write goes through [ops]; the next starts
 *    only from the previous one's callback.
 *  - **A callback that never comes wedges the handle for good** — every later
 *    call returns false. The first build hit exactly that: the MTU callback
 *    fired twice, each started a service discovery, the second landed on an
 *    in-flight battery read, the read's callback was lost, and from then on
 *    every write "could not start". So discovery runs once per connection and
 *    setup waits for it to settle, and a timed-out or refused operation now
 *    tears the handle down and reconnects instead of failing forever.
 *
 * Characteristics are matched by UUID fragment — `56FF` service with `33F3`
 * (write) and `33F4` (notify), `180F`/`2A19` battery — as LoraFit does.
 */
@SuppressLint("MissingPermission")
@Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
object RingBleChannel {
    private const val METHOD = "ai.fox1/ring_ble"
    private const val EVENTS = "ai.fox1/ring_ble/events"
    private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private const val OP_TIMEOUT_MS = 5000L

    /** Quiet time once discovery and the MTU exchange are both over. */
    private const val SETTLE_MS = 250L

    /** How long to wait for the ring's own MTU exchange before asking. */
    private const val MTU_WAIT_MS = 1200L
    private const val MAX_RECOVERIES = 2

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private lateinit var appContext: Context

    private var gatt: BluetoothGatt? = null
    private var cmd: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var battery: BluetoothGattCharacteristic? = null
    private var mtu = 23

    /** The device we mean to be connected to; null after the user disconnects. */
    private var targetId: String? = null
    private var recoveries = 0
    private var discovering = false

    /**
     * Discovery succeeded on this handle. It never runs again after that: the
     * ring starts its own MTU exchange at connect, so onMtuChanged fires twice
     * (~0.4 s apart), and the second one re-ran discovery on top of the
     * battery read and lost it — the build before this one only guarded
     * against overlapping with a discovery still in progress.
     */
    private var servicesDone = false

    /** No MTU exchange is in flight; setup's first read may go out. */
    private var mtuSettled = false
    private var mtuRequested = false
    private var setupStarted = false
    private var notifyOk = false

    /**
     * [done] is told whether the operation succeeded — exactly once, whatever
     * happens: completion, refusal, timeout, or the link being torn down.
     */
    private class Op(
        val name: String,
        val waits: Boolean,
        val done: ((Boolean) -> Unit)?,
        val run: () -> Boolean,
    )

    private val ops = ArrayDeque<Op>()
    private var current: Op? = null

    private val opTimeout = Runnable {
        val op = current
        current = null
        op?.done?.invoke(false)
        recover("${op?.name ?: "a GATT operation"} never completed")
    }
    private val setupLater = Runnable { gatt?.let { startSetup(it) } }

    /**
     * The ring negotiates MTU 512 itself right after connecting. Asking again
     * (as the earlier builds did, at connect) put a second exchange on the air
     * just as setup's first read went out, and that read's callback never came
     * — the handle wedged on nearly every connect. So wait for the ring's
     * exchange, and only ask if it has not happened.
     */
    private val mtuCheck = Runnable {
        val g = gatt
        if (g != null && !mtuSettled) {
            mtuRequested = true
            if (g.requestMtu(512)) {
                main.postDelayed(mtuFallback, 2000)
            } else {
                mtuSettled = true
                maybeSetup()
            }
        }
    }
    private val mtuFallback = Runnable {
        if (gatt != null && !mtuSettled) {
            mtuSettled = true
            emit("error", "message" to "MTU request never answered — carrying on at $mtu")
            maybeSetup()
        }
    }

    private var scanner: BluetoothLeScanner? = null
    private val stopScanLater = Runnable { stopScan() }

    // ------------------------------------------------------------ plumbing

    private fun emit(type: String, vararg kv: Pair<String, Any?>) {
        val m = HashMap<String, Any?>()
        m["type"] = type
        for ((k, v) in kv) m[k] = v
        if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(m)
        else main.post { sink?.success(m) }
    }

    private fun manager() =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager

    private fun enqueue(
        name: String,
        waits: Boolean = true,
        done: ((Boolean) -> Unit)? = null,
        run: () -> Boolean,
    ) {
        ops.addLast(Op(name, waits, done, run))
        drive()
    }

    /** Main thread only. Starts queued operations until one is in flight. */
    private fun drive() {
        while (current == null) {
            val op = ops.pollFirst() ?: return
            val started = try {
                op.run()
            } catch (e: Exception) {
                emit("error", "message" to "${op.name}: $e")
                false
            }
            if (!op.waits) {
                op.done?.invoke(started)
                continue
            }
            if (!started) {
                // With the queue in charge, a refusal means Android's busy flag
                // is stuck — nothing after this would start either.
                op.done?.invoke(false)
                recover("Android refused ${op.name}")
                return
            }
            current = op
            main.postDelayed(opTimeout, OP_TIMEOUT_MS)
        }
    }

    private fun opDone(ok: Boolean) {
        main.removeCallbacks(opTimeout)
        val op = current
        current = null
        op?.done?.invoke(ok)
        drive()
    }

    private fun frag(u: UUID) = u.toString().substring(4, 8)

    private fun props(p: Int) = listOfNotNull(
        if (p and BluetoothGattCharacteristic.PROPERTY_READ != 0) "read" else null,
        if (p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) "write" else null,
        if (p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) "writeNoResp" else null,
        if (p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) "notify" else null,
        if (p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) "indicate" else null,
    ).joinToString(",")

    private fun describe(d: BluetoothDevice, origin: String): Map<String, Any?> = mapOf(
        "id" to d.address,
        "name" to (d.name ?: ""),
        "origin" to origin,
        "kind" to when (d.type) {
            BluetoothDevice.DEVICE_TYPE_LE -> "le"
            BluetoothDevice.DEVICE_TYPE_CLASSIC -> "classic"
            BluetoothDevice.DEVICE_TYPE_DUAL -> "dual"
            else -> "?"
        },
    )

    // ---------------------------------------------------------- discovery

    /**
     * Devices the system already knows. A ring paired in Android settings is
     * connected as an HID device and may not advertise at all, so a scan would
     * never find it; GATT still opens on the same link.
     */
    private fun known(): List<Map<String, Any?>> {
        val mgr = manager() ?: return emptyList()
        val out = LinkedHashMap<String, Map<String, Any?>>()
        try {
            for (d in mgr.getConnectedDevices(BluetoothProfile.GATT)) {
                out[d.address] = describe(d, "connected")
            }
        } catch (e: Exception) {
            emit("error", "message" to "connected list: $e")
        }
        try {
            for (d in mgr.adapter?.bondedDevices ?: emptySet()) {
                if (!out.containsKey(d.address)) out[d.address] = describe(d, "paired")
            }
        } catch (e: Exception) {
            emit("error", "message" to "paired list: $e")
        }
        return out.values.toList()
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, r: ScanResult) {
            val has56ff = r.scanRecord?.serviceUuids
                ?.any { it.uuid.toString().contains("56ff", ignoreCase = true) } == true
            emit(
                "scan",
                "id" to r.device.address,
                "name" to (r.scanRecord?.deviceName ?: r.device.name ?: ""),
                "rssi" to r.rssi,
                "has56ff" to has56ff,
            )
        }

        override fun onScanFailed(errorCode: Int) {
            emit("error", "message" to "scan failed (code $errorCode)")
            scanner = null
            emit("scanState", "scanning" to false)
        }
    }

    private fun startScan(seconds: Int): Boolean {
        val s = manager()?.adapter?.bluetoothLeScanner ?: return false
        stopScan()
        scanner = s
        s.startScan(
            null,
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
            scanCallback,
        )
        emit("scanState", "scanning" to true)
        main.postDelayed(stopScanLater, seconds * 1000L)
        return true
    }

    private fun stopScan() {
        main.removeCallbacks(stopScanLater)
        val s = scanner ?: return
        scanner = null
        try {
            s.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        emit("scanState", "scanning" to false)
    }

    // --------------------------------------------------------- connection

    /** The user's connect: a fresh start, with a fresh recovery budget. */
    private fun connect(id: String): Boolean {
        if (manager()?.adapter == null) return false
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return false
        stopScan()
        closeGatt()
        targetId = id
        recoveries = 0
        return open(id)
    }

    private fun open(id: String): Boolean {
        val adapter = manager()?.adapter ?: return false
        discovering = false
        servicesDone = false
        mtuSettled = false
        mtuRequested = false
        setupStarted = false
        notifyOk = false
        gatt = adapter.getRemoteDevice(id)
            .connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
        return gatt != null
    }

    /**
     * Drops the handle. Every queued and in-flight operation is answered
     * `false` so nothing on the Dart side waits forever.
     */
    private fun closeGatt() {
        main.removeCallbacks(opTimeout)
        main.removeCallbacks(mtuCheck)
        main.removeCallbacks(mtuFallback)
        main.removeCallbacks(setupLater)
        val pending = listOfNotNull(current) + ops.toList()
        current = null
        ops.clear()
        for (op in pending) op.done?.invoke(false)
        cmd = null
        notifyChar = null
        battery = null
        mtu = 23
        discovering = false
        servicesDone = false
        mtuSettled = false
        mtuRequested = false
        setupStarted = false
        notifyOk = false
        val g = gatt ?: return
        gatt = null
        try {
            g.disconnect()
            g.close()
        } catch (_: Exception) {
        }
    }

    /**
     * A wedged handle cannot be un-wedged from outside, so start over on a new
     * one. Bounded: a ring that keeps wedging is reported, not looped on.
     */
    private fun recover(reason: String) {
        val id = targetId ?: return
        if (gatt == null) return
        if (recoveries >= MAX_RECOVERIES) {
            emit("error", "message" to "$reason — gave up after $MAX_RECOVERIES reconnects; tap Connect again")
            targetId = null
            closeGatt()
            emit("state", "state" to "disconnected", "status" to -2)
            return
        }
        recoveries++
        emit("state", "state" to "reconnecting", "reason" to reason, "attempt" to recoveries)
        closeGatt()
        main.postDelayed({ if (gatt == null && targetId == id) open(id) }, 800)
    }

    private fun disconnect() {
        targetId = null
        val g = gatt ?: return
        g.disconnect()
        // A disconnect that never calls back would leave the handle open and the
        // next connect refused; close it ourselves if the stack stays quiet.
        main.postDelayed({
            if (gatt === g) {
                closeGatt()
                emit("state", "state" to "disconnected", "status" to -1)
            }
        }, 1500)
    }

    private fun startDiscovery(g: BluetoothGatt) {
        if (discovering || servicesDone || g !== gatt) return
        discovering = true
        if (!g.discoverServices()) emit("error", "message" to "service discovery refused")
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (g !== gatt) {
                    // A late callback from a handle we already let go of.
                    try { g.close() } catch (_: Exception) {}
                    return@post
                }
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        emit("state", "state" to "connected", "status" to status)
                        // Discover now; the MTU is the ring's to set first
                        // (see mtuCheck). Setup waits for both.
                        startDiscovery(g)
                        main.postDelayed(mtuCheck, MTU_WAIT_MS)
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        emit("state", "state" to "disconnected", "status" to status)
                        targetId = null
                        closeGatt()
                    }
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) {
            main.post {
                if (g !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) mtu = value
                emit("mtu", "mtu" to mtu, "status" to status, "ours" to mtuRequested)
                // The ring's own exchange at a small MTU still leaves ours to do.
                if (!mtuRequested && mtu < 100) return@post
                mtuSettled = true
                main.removeCallbacks(mtuCheck)
                main.removeCallbacks(mtuFallback)
                maybeSetup()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post { if (g === gatt) onServices(g, status) }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int,
        ) {
            if (Build.VERSION.SDK_INT >= 33) return
            val v = c.value?.copyOf() ?: ByteArray(0)
            main.post { if (g === gatt) onRead(c, v, status) }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int,
        ) {
            val v = value.copyOf()
            main.post { if (g === gatt) onRead(c, v, status) }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int,
        ) {
            main.post {
                if (g !== gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    emit("error", "message" to "write ${frag(c.uuid)} failed, status $status")
                }
                opDone(status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int,
        ) {
            main.post {
                if (g !== gatt) return@post
                val ok = status == BluetoothGatt.GATT_SUCCESS
                if (!ok) {
                    emit("error", "message" to
                        "enable notify on ${frag(d.characteristic.uuid)} failed, status $status")
                } else if (d.characteristic.uuid == notifyChar?.uuid) {
                    notifyOk = true
                }
                opDone(ok)
            }
        }

        // The value is copied on the binder thread: before API 33 the stack
        // reuses the characteristic's buffer for the next notification.
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return
            val v = c.value?.copyOf() ?: return
            main.post { emit("notify", "char" to frag(c.uuid), "value" to v) }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray,
        ) {
            val v = value.copyOf()
            main.post { emit("notify", "char" to frag(c.uuid), "value" to v) }
        }
    }

    private fun onRead(c: BluetoothGattCharacteristic, v: ByteArray, status: Int) {
        val ok = status == BluetoothGatt.GATT_SUCCESS
        if (ok) {
            emit("read", "char" to frag(c.uuid), "value" to v)
        } else {
            emit("error", "message" to "read ${frag(c.uuid)} failed, status $status")
        }
        opDone(ok)
    }

    /**
     * May run more than once per connection — a second discovery, or the stack
     * re-discovering after the ring's Service Changed indication. References are
     * refreshed every time; setup is queued once, after discovery goes quiet.
     */
    private fun onServices(g: BluetoothGatt, status: Int) {
        discovering = false
        if (status != BluetoothGatt.GATT_SUCCESS) {
            emit("error", "message" to "service discovery failed, status $status")
            return
        }
        servicesDone = true
        val list = ArrayList<Map<String, Any?>>()
        cmd = null
        notifyChar = null
        battery = null
        for (s in g.services) {
            val su = s.uuid.toString().lowercase()
            list += mapOf(
                "uuid" to s.uuid.toString(),
                "chars" to s.characteristics.map { c ->
                    mapOf("uuid" to c.uuid.toString(), "props" to props(c.properties))
                },
            )
            for (c in s.characteristics) {
                val cu = c.uuid.toString().lowercase()
                if (su.contains("56ff") && cu.contains("33f3")) cmd = c
                if (su.contains("56ff") && cu.contains("33f4")) notifyChar = c
                if (su.contains("180f") && cu.contains("2a19")) battery = c
            }
        }
        emit(
            "services",
            "services" to list,
            "repeat" to setupStarted,
            "cmd" to (cmd != null),
            "notify" to (notifyChar != null),
            "battery" to (battery != null),
        )
        maybeSetup()
    }

    /** Setup waits until discovery and the MTU exchange are both over. */
    private fun maybeSetup() {
        if (!servicesDone || !mtuSettled || setupStarted) return
        main.removeCallbacks(setupLater)
        main.postDelayed(setupLater, SETTLE_MS)
    }

    private fun startSetup(g: BluetoothGatt) {
        if (setupStarted || g !== gatt) return
        setupStarted = true
        // LoraFit's order: battery first, then the command channel's notify.
        battery?.let { b ->
            if (b.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
                enqueue("read battery") { g.readCharacteristic(b) }
            }
            if (b.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                enableNotify(g, b)
            }
        }
        notifyChar?.let { enableNotify(g, it) }
        enqueue("ready", waits = false) {
            emit("ready", "mtu" to mtu, "cmd" to (cmd != null), "notify" to notifyOk)
            true
        }
    }

    private fun enableNotify(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
        val d = c.getDescriptor(CCCD)
        if (d == null) {
            // No CCCD to write: register locally and hope the ring pushes.
            g.setCharacteristicNotification(c, true)
            if (c.uuid == notifyChar?.uuid) notifyOk = true
            emit("error", "message" to "${frag(c.uuid)} has no CCCD — notifications registered locally only")
            return
        }
        enqueue("enable notify ${frag(c.uuid)}") {
            if (!g.setCharacteristicNotification(c, true)) return@enqueue false
            val indicateOnly =
                c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 &&
                    c.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0
            val v = if (indicateOnly) BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            else BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeDescriptor(d, v) == BluetoothStatusCodes.SUCCESS
            } else {
                d.value = v
                g.writeDescriptor(d)
            }
        }
    }

    /** [done] says whether the ring's stack accepted the write. */
    private fun write(data: ByteArray, done: (Boolean) -> Unit) {
        val g = gatt
        val c = cmd
        if (g == null || c == null) {
            done(false)
            return
        }
        val type = if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val op = if (data.size >= 4)
            "write 0x%02X".format((data[2].toInt() and 0xff) or ((data[3].toInt() and 0xff) shl 8))
        else "write"
        enqueue(op, done = done) {
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeCharacteristic(c, data, type) == BluetoothStatusCodes.SUCCESS
            } else {
                c.writeType = type
                c.value = data
                g.writeCharacteristic(c)
            }
        }
    }

    // ---------------------------------------------------------- recordings

    /**
     * Decodes the ring's offline recordings: bare 40-byte Opus packets, 20 ms
     * each, 16 kHz mono (as LoraFit decodes them — 640 bytes of PCM each).
     *
     * Uses the platform's own Opus decoder through MediaCodec, so there is no
     * native library to ship. Android's software Opus decoder always outputs
     * 48 kHz, so the result is brought back to 16 kHz by averaging each group
     * of three samples — crude, but the source is band-limited to 8 kHz by the
     * encoder, so there is little above the new Nyquist to fold back.
     *
     * Returns PCM16 little-endian mono and its rate.
     */
    private fun decodeOpus(frames: ByteArray, frameBytes: Int): Map<String, Any?> {
        val n = frames.size / frameBytes
        val head = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("OpusHead".toByteArray(Charsets.US_ASCII))
            put(1.toByte()) // version
            put(1.toByte()) // channels
            putShort(0) // pre-skip — LoraFit decodes raw packets and drops nothing
            putInt(16000) // original input rate (informational)
            putShort(0) // output gain
            put(0.toByte()) // channel mapping family
        }.array()
        fun nanos(v: Long): ByteBuffer =
            ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(v).also { it.rewind() }

        val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48000, 1)
        fmt.setByteBuffer("csd-0", ByteBuffer.wrap(head))
        fmt.setByteBuffer("csd-1", nanos(0))
        fmt.setByteBuffer("csd-2", nanos(80_000_000L))

        val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
        val decoderName = codec.name
        val out = ByteArrayOutputStream()
        var rate = 48000
        var channels = 1
        try {
            codec.configure(fmt, null, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            var fed = 0
            var eosSent = false
            var done = false
            val deadline = System.currentTimeMillis() + 120_000
            while (!done) {
                if (System.currentTimeMillis() > deadline) error("decoder stalled after $fed/$n frames")
                if (!eosSent) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        buf.clear()
                        if (fed < n) {
                            buf.put(frames, fed * frameBytes, frameBytes)
                            codec.queueInputBuffer(i, 0, frameBytes, fed * 20_000L, 0)
                            fed++
                        } else {
                            codec.queueInputBuffer(
                                i, 0, 0, fed * 20_000L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eosSent = true
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    o >= 0 -> {
                        if (info.size > 0) {
                            val b = codec.getOutputBuffer(o)!!
                            b.position(info.offset)
                            b.limit(info.offset + info.size)
                            val arr = ByteArray(info.size)
                            b.get(arr)
                            out.write(arr)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                    }
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                }
            }
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
        }

        // To mono shorts, then down to 16 kHz when the rate divides evenly.
        val raw = ByteBuffer.wrap(out.toByteArray()).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val mono = ShortArray(raw.remaining() / channels)
        for (i in mono.indices) {
            var sum = 0
            for (ch in 0 until channels) sum += raw.get(i * channels + ch)
            mono[i] = (sum / channels).toShort()
        }
        val factor = if (rate > 16000 && rate % 16000 == 0) rate / 16000 else 1
        val outRate = rate / factor
        val pcm = ByteBuffer.allocate(mono.size / factor * 2).order(ByteOrder.LITTLE_ENDIAN)
        var i = 0
        while (i + factor <= mono.size) {
            var sum = 0
            for (k in 0 until factor) sum += mono[i + k]
            pcm.putShort((sum / factor).toShort())
            i += factor
        }
        return mapOf(
            "pcm" to pcm.array(),
            "rate" to outRate,
            "decodedRate" to rate,
            "channels" to channels,
            "frames" to n,
            "decoder" to decoderName,
        )
    }

    private fun recordingsDir(): String? {
        val base = appContext.getExternalFilesDir(null) ?: return null
        return File(base, "ring_recordings").apply { mkdirs() }.absolutePath
    }

    // ------------------------------------------------------------ channels

    fun register(flutterEngine: FlutterEngine, context: Context) {
        appContext = context.applicationContext

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                    stopScan()
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "known" -> result.success(known())
                        "startScan" -> result.success(
                            startScan(call.argument<Int>("seconds") ?: 10))
                        "stopScan" -> {
                            stopScan()
                            result.success(null)
                        }
                        "connect" -> result.success(connect(call.argument<String>("id") ?: ""))
                        // Answers when the write completes (or fails), not when
                        // it is queued — the first build said "sent" for writes
                        // Android had refused.
                        "write" -> write(call.argument<ByteArray>("data") ?: ByteArray(0)) { ok ->
                            result.success(ok)
                        }
                        "disconnect" -> {
                            disconnect()
                            result.success(null)
                        }
                        "isConnected" -> result.success(gatt != null && cmd != null)
                        "recordingsDir" -> result.success(recordingsDir())
                        // Internal storage: health data is not for other apps,
                        // and on API 27 the external files dir is readable by
                        // any app holding the storage permission.
                        "healthDir" -> result.success(
                            File(appContext.filesDir, "health").apply { mkdirs() }.absolutePath)
                        "keepAlive" -> {
                            if (call.argument<Boolean>("on") == true) {
                                RingLinkService.start(appContext,
                                    call.argument<String>("text") ?: "Smart ring")
                            } else {
                                RingLinkService.stop(appContext)
                            }
                            result.success(null)
                        }
                        "decodeOpus" -> {
                            val frames = call.argument<ByteArray>("frames") ?: ByteArray(0)
                            val size = call.argument<Int>("frameBytes") ?: 40
                            // A minute of audio is 3,000 packets; keep it off
                            // the main thread.
                            Thread {
                                try {
                                    val r = decodeOpus(frames, size)
                                    main.post { result.success(r) }
                                } catch (e: Exception) {
                                    main.post { result.error("decode", e.toString(), null) }
                                }
                            }.start()
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ring_ble", e.toString(), null)
                }
            }
    }
}
