package ai.fox1.channels

import android.content.Context
import android.hardware.input.InputManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The ring's second path: it also enumerates as an Android HID input device
 * (SMART_RING_PROTOCOL.md §7).
 *
 * If its touch gestures arrive as ordinary KeyEvents, "summon the agent from
 * the ring" needs no BLE client at all — MainActivity already receives them.
 * This channel only reports what arrives, so the test screen can answer that
 * question on hardware before anyone builds the harder path.
 *
 * Nothing here consumes an event. MainActivity forwards a copy and then lets
 * the system handle it exactly as before, so a stray volume key still changes
 * the volume.
 *
 * Limit worth knowing: KeyEvents only reach the FOREGROUND activity. As the
 * home launcher that is usually us, but not while another app is open — which
 * is one reason the BLE `button_event` path may still be needed in production.
 */
object RingInputChannel {
    private const val METHOD = "ai.fox1/ring_input"
    private const val EVENTS = "ai.fox1/ring_input/events"

    private var sink: EventChannel.EventSink? = null
    private var inputManager: InputManager? = null
    private val main = Handler(Looper.getMainLooper())

    private val deviceListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(id: Int) = emitDevice("added", id)
        override fun onInputDeviceRemoved(id: Int) = emitDevice("removed", id)
        override fun onInputDeviceChanged(id: Int) = emitDevice("changed", id)
    }

    private fun emitDevice(change: String, id: Int) {
        externalById.remove(id)
        val d = InputDevice.getDevice(id)
        sink?.success(mapOf(
            "type" to "device",
            "change" to change,
            "id" to id,
            "name" to (d?.name ?: "?"),
        ))
    }

    private fun describe(d: InputDevice): Map<String, Any?> = mapOf(
        "id" to d.id,
        "name" to d.name,
        "sources" to sourceNames(d.sources),
        "vendor" to d.vendorId,
        "product" to d.productId,
        "virtual" to d.isVirtual,
        "keyboard" to d.keyboardType,
    )

    private fun sourceNames(s: Int): String {
        val names = mutableListOf<String>()
        if (s and InputDevice.SOURCE_KEYBOARD == InputDevice.SOURCE_KEYBOARD) names += "keyboard"
        if (s and InputDevice.SOURCE_DPAD == InputDevice.SOURCE_DPAD) names += "dpad"
        if (s and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD) names += "gamepad"
        if (s and InputDevice.SOURCE_TOUCHSCREEN == InputDevice.SOURCE_TOUCHSCREEN) names += "touchscreen"
        if (s and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) names += "mouse"
        if (s and InputDevice.SOURCE_TOUCHPAD == InputDevice.SOURCE_TOUCHPAD) names += "touchpad"
        if (s and InputDevice.SOURCE_ROTARY_ENCODER == InputDevice.SOURCE_ROTARY_ENCODER) names += "rotary"
        if (s and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK) names += "joystick"
        return if (names.isEmpty()) "0x${Integer.toHexString(s)}" else names.joinToString("+")
    }

    /** Called by MainActivity for every KeyEvent. Never consumes it. */
    fun onKey(e: KeyEvent) {
        val s = sink ?: return
        // The device's own buttons, and the virtual keyboard that turns its
        // edge-swipe back gesture into KEYCODE_BACK, are not the ring.
        if (!isExternal(e.device)) return
        main.post {
            s.success(mapOf(
                "type" to "key",
                "action" to when (e.action) {
                    KeyEvent.ACTION_DOWN -> "down"
                    KeyEvent.ACTION_UP -> "up"
                    else -> "multiple"
                },
                "code" to e.keyCode,
                "name" to KeyEvent.keyCodeToString(e.keyCode),
                "scan" to e.scanCode,
                "repeat" to e.repeatCount,
                "long" to e.isLongPress,
                "device" to (e.device?.name ?: "?"),
                "source" to sourceNames(e.source),
            ))
        }
    }

    /**
     * Some rings are HID mice or touchpads rather than keyboards — the
     * "scroll TikTok with a ring" kind. Those produce MotionEvents, which a
     * KeyEvent-only probe would never see.
     */
    fun onMotion(e: MotionEvent) {
        val s = sink ?: return
        if (!isExternal(e.device)) return
        main.post {
            s.success(mapOf(
                "type" to "motion",
                "action" to MotionEvent.actionToString(e.actionMasked),
                "x" to e.x,
                "y" to e.y,
                "device" to (e.device?.name ?: "?"),
                "source" to sourceNames(e.source),
            ))
        }
    }

    /**
     * While true, touches from EXTERNAL input devices are consumed instead of
     * reaching the UI. Keyed on external-ness, not the ring's BLE name — the
     * first build matched the name, so it only worked with BLE connected.
     * Cleared whenever the test screen stops listening, so it cannot outlive it.
     */
    @Volatile private var blockExternal = false
    private val externalById = HashMap<Int, Boolean>()
    private var downAt = 0L
    private var downX = 0f
    private var downY = 0f

    /**
     * Not part of the device: the ring, a keyboard, a mouse.
     *
     * On hardware the ring registered as "SR116-0767 · touchscreen, vendor
     * 1452" — 0x05AC, Apple's USB vendor ID, which cheap HID rings borrow —
     * beside the built-in "cst0xx_ts" touchscreen. InputDevice.isExternal is
     * public from API 29; before that it exists but is hidden, so it is reached
     * by reflection, with "has a vendor ID" as the fallback. Cached per device
     * id, because this runs on every touch the wearer makes.
     */
    private fun isExternal(d: InputDevice?): Boolean {
        if (d == null || d.isVirtual) return false
        return externalById.getOrPut(d.id) {
            if (Build.VERSION.SDK_INT >= 29) {
                d.isExternal
            } else {
                try {
                    d.javaClass.getMethod("isExternal").invoke(d) as Boolean
                } catch (_: Exception) {
                    d.vendorId != 0 && !d.name.contains("gpio", ignoreCase = true)
                }
            }
        }
    }

    private fun toolName(t: Int) = when (t) {
        MotionEvent.TOOL_TYPE_FINGER -> "finger"
        MotionEvent.TOOL_TYPE_MOUSE -> "mouse"
        MotionEvent.TOOL_TYPE_STYLUS -> "stylus"
        MotionEvent.TOOL_TYPE_ERASER -> "eraser"
        else -> "unknown"
    }

    /**
     * Touch-type input. On hardware the ring's taps, double-taps and swipes
     * never arrived as keys: it is a Bluetooth touchscreen that injects one of
     * two canned swipes — (160,238)→(160,46) or (160,135)→(160,354) — which
     * reach dispatchTouchEvent and nothing else.
     *
     * The wearer's finger returns at once: not logged, never consumed. The
     * first touch build logged both, and at a glance there was no telling the
     * ring's swipes from the wearer's.
     *
     * Returns true when the event should be CONSUMED.
     */
    fun onTouch(e: MotionEvent): Boolean {
        if (!isExternal(e.device)) return false
        val blocked = blockExternal
        val s = sink
        if (s != null && e.actionMasked != MotionEvent.ACTION_MOVE) {
            if (e.actionMasked == MotionEvent.ACTION_DOWN) {
                downAt = e.eventTime; downX = e.x; downY = e.y
            }
            val m = mutableMapOf<String, Any?>(
                "type" to "touch",
                "action" to MotionEvent.actionToString(e.actionMasked),
                "x" to e.x,
                "y" to e.y,
                "pointers" to e.pointerCount,
                "tool" to toolName(e.getToolType(0)),
                "device" to (e.device?.name ?: "?"),
                "source" to sourceNames(e.source),
                "blocked" to blocked,
            )
            if (e.actionMasked == MotionEvent.ACTION_UP ||
                e.actionMasked == MotionEvent.ACTION_CANCEL) {
                m["dx"] = e.x - downX
                m["dy"] = e.y - downY
                m["ms"] = e.eventTime - downAt
            }
            main.post { s.success(m) }
        }
        return blocked
    }

    fun register(flutterEngine: FlutterEngine, context: Context) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    val im = context.getSystemService(Context.INPUT_SERVICE) as InputManager
                    inputManager = im
                    im.registerInputDeviceListener(deviceListener, main)
                }
                override fun onCancel(arguments: Any?) {
                    sink = null
                    blockExternal = false
                    inputManager?.unregisterInputDeviceListener(deviceListener)
                    inputManager = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Every input device the system knows about. If the ring
                    // is paired and shows up here, the HID path is real.
                    "listInputDevices" -> result.success(
                        // IntArray has no mapNotNull; go through a List.
                        InputDevice.getDeviceIds().toList().mapNotNull { id: Int ->
                            InputDevice.getDevice(id)?.let { describe(it) }
                        })
                    "setBlockExternal" -> {
                        blockExternal = call.argument<Boolean>("on") == true
                        result.success(blockExternal)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
