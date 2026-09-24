package ai.fox1.channels

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import ai.fox1.services.HfpRouter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Owner of the communication audio route.
 *
 * The agent talks to the user through a Bluetooth earbud — that is the product,
 * not a preference: the device sits on a wrist, and the interaction is meant to
 * work without lifting it to your mouth. Reaching an earbud mic and speaker
 * means SCO. So the agent needs SCO, and "just use media instead" is not
 * available to us.
 *
 * The problem is that below API 31 `startBluetoothSco()` takes no device
 * argument. With an earbud and the ESP32 bridge both connected as HFP devices,
 * the system chooses, and the bridge frequently wins — the agent's voice goes
 * into a disarmed board and its mic reads silence.
 *
 * Two honest resolutions:
 *
 *  - **API 31+** — `setCommunicationDevice()` names the device. Implemented
 *    below: the media route explicitly skips `bridgeMac`, the bridge route
 *    explicitly selects it.
 *  - **API 30 and below** — no API can express the choice. The only reliable
 *    fix is to make sure the bridge is not a connected HFP device except while
 *    it is carrying a call, which is a board-side change: keep SPP up always,
 *    bring HFP up on demand. Until then this device is a coin flip whenever
 *    both are connected.
 *
 * What is fixed here regardless of version: the route is released. Nothing ever
 * called `stopBluetoothSco()` or restored `mode`, so a wrong choice survived
 * until the process died — which is why disconnecting the earbud did not help.
 */
object AudioChannel {
    private const val CHANNEL = "ai.fox1/audio"
    private const val EVENT_CHANNEL = "ai.fox1/audio_events"

    /** Set while we hold the route, so release is idempotent and honest. */
    private var scoHeld = false

    /** What was last asked for: "media", "bridge" or "idle". */
    @Volatile
    private var currentRoute = "idle"

    /** bridgeMac from the last setRoute, so a re-apply can honour it. */
    @Volatile
    private var currentBridgeMac: String? = null

    @Volatile
    private var lastOnBluetooth = false

    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null

    /**
     * Re-apply the route when the set of audio devices changes.
     *
     * The route used to be chosen once, when the session started, and never
     * revisited. Switch the earbud off mid-conversation and SCO stayed pointed
     * at a device that was no longer there: the agent still heard the device mic
     * and the transcript still appeared, but its voice went nowhere. Turning
     * the earbud back on fixed it, which is exactly the shape of a route that
     * is never recomputed.
     *
     * Only "media" is re-applied. During a bridged call the HfpRouter has
     * deliberately disconnected the earbud, and reacting to that would fight it.
     */
    private val deviceWatcher = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Bluetooth state changes arrive in bursts — profile, ACL and SCO
            // all fire for one earbud going away. Coalesce, then act once.
            pending?.let { main.removeCallbacks(it) }
            val r = Runnable {
                pending = null
                keepCallAudible(context.applicationContext)
                if (currentRoute != "media") return@Runnable
                val was = lastOnBluetooth
                val now = routeMedia(context.applicationContext, currentBridgeMac)
                lastOnBluetooth = now
                if (now != was) {
                    emit(mapOf("type" to "route", "bluetooth" to now,
                        "reason" to (intent.action ?: "device change")))
                }
            }
            pending = r
            main.postDelayed(r, 400)
        }
    }

    /** Also AudioPlayChannel's: each reply's delivery summary rides this stream. */
    fun emit(map: Map<String, Any?>) {
        main.post { sink?.success(map) }
    }

    /**
     * Keep a live carrier call coming out of something the wearer can hear.
     *
     * Runs on every device change, whatever route we think we hold. After the
     * call bridge hands a call to the device there is no session and no route of
     * ours left — but plugging an earbud in and pulling it out again still has
     * to move the audio, and nothing was watching for it. With no headset a
     * call defaults to the earpiece, which on this device is silence.
     *
     * Keyed off AudioManager.mode rather than our own bookkeeping: after the
     * bridge closes we get no more call-state events, so the only trustworthy
     * answer to "is a call still up" is the one telephony maintains itself.
     */
    private fun deviceName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "BT_SCO"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BT_A2DP"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "SPEAKER"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "EARPIECE"
        AudioDeviceInfo.TYPE_TELEPHONY -> "TELEPHONY"
        else -> "t$type"
    }

    private fun keepCallAudible(context: Context) {
        try {
            val am = am(context)
            @Suppress("DEPRECATION")
            if (am.mode != AudioManager.MODE_IN_CALL) {
                HfpRouter.logger("[AUDIO] device change, no call (mode=${am.mode})")
                return
            }
            val headset = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                it.type == AudioDeviceInfo.TYPE_BLE_HEADSET
            }
            val want = !headset
            // Log the real state every time, changed or not. Two cycles of
            // this worked and the third did not, and guessing at why from an
            // outcome alone is what produced the regression — so record what
            // the platform actually holds instead.
            @Suppress("DEPRECATION")
            val spk = am.isSpeakerphoneOn
            @Suppress("DEPRECATION")
            val sco = am.isBluetoothScoOn
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .joinToString(",") { deviceName(it.type) }
            HfpRouter.logger("[AUDIO] in-call state: spk=$spk sco=$sco" +
                " want=${if (want) "speaker" else "headset"} outs=[$outs]")
            if (spk == want) return
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = want
            HfpRouter.logger("[HFP] call audio -> " +
                if (want) "device speaker" else "bluetooth headset")
        } catch (e: Exception) {
            HfpRouter.logger("[HFP] call route failed: ${e.javaClass.simpleName}")
        }
    }

    private fun am(context: Context) =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /**
     * The agent speaks to the user. SCO is explicitly released so the mic comes
     * off the built-in mic rather than whatever HFP device the system fancies,
     * and USAGE_MEDIA playback follows A2DP or the speaker on its own.
     *
     * Returns true if a Bluetooth output is carrying the audio.
     */
    /**
     * The agent speaks to the user — over the earbud when there is one.
     *
     * Needs SCO, because that is the only way to a Bluetooth headset's speaker
     * and mic. On API 31+ we name the device and can guarantee it is not the
     * bridge. Below that we can only ask for "Bluetooth" and hope the system
     * picks the earbud; see the class comment for why that is a board-side fix.
     *
     * Returns true if Bluetooth is carrying the audio.
     */
    private fun routeMedia(context: Context, mac: String?): Boolean {
        val am = am(context)
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        // Fall back to whichever board the bridge is using. Callers rarely have
        // the address to hand, and without it "anything but the bridge" below
        // excludes nothing.
        val bridgeMac = mac ?: HfpRouter.bridgeMac

        if (Build.VERSION.SDK_INT >= 31) {
            val devices = am.availableCommunicationDevices
            // Anything but the bridge. This is the whole point of the newer API.
            val headset = devices.firstOrNull {
                it.address != bridgeMac && (
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
            }
            if (headset != null) {
                am.setCommunicationDevice(headset)
                scoHeld = true
                return true
            }
            devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?.let { am.setCommunicationDevice(it) }
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = true
            return false
        }

        // A2DP alone is not a reason to start SCO — it means media-capable, not
        // headset. Only an actual HFP/LE headset gets the route.
        //
        // And never the bridge. The board IS an HFP headset, so without this it
        // qualifies: the device assistant's voice went to the ESP32 and the
        // wearer heard nothing, right up until the board disconnected and the
        // route fell back to the speaker. The API 31 branch above always had
        // this exclusion; this one did not.
        val headset = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            (it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                it.type == AudioDeviceInfo.TYPE_BLE_HEADSET) &&
                (bridgeMac == null || it.address != bridgeMac)
        }
        if (headset) {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
            @Suppress("DEPRECATION")
            am.startBluetoothSco()
            @Suppress("DEPRECATION")
            am.isBluetoothScoOn = true
            scoHeld = true
            return true
        }

        releaseSco(am)
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = true
        return false
    }

    /** The agent speaks to a caller: SCO to the board, and only the board. */
    private fun routeBridge(context: Context, bridgeMac: String?): Boolean {
        val am = am(context)
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = false

        if (Build.VERSION.SDK_INT >= 31 && bridgeMac != null) {
            val dev = am.availableCommunicationDevices.firstOrNull {
                it.address == bridgeMac
            }
            if (dev != null) {
                am.setCommunicationDevice(dev)
                scoHeld = true
                return true
            }
        }

        @Suppress("DEPRECATION")
        am.startBluetoothSco()
        @Suppress("DEPRECATION")
        am.isBluetoothScoOn = true
        scoHeld = true
        return true
    }

    /** Hand the route back. Safe to call when nothing is held. */
    private fun releaseSco(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= 31) {
            try { am.clearCommunicationDevice() } catch (_: Exception) {}
        }
        try {
            @Suppress("DEPRECATION")
            am.isBluetoothScoOn = false
            @Suppress("DEPRECATION")
            am.stopBluetoothSco()
        } catch (_: Exception) {}
        scoHeld = false
    }

    fun register(flutterEngine: FlutterEngine, context: Context) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }
                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })

        val filter = IntentFilter().apply {
            addAction(BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            @Suppress("DEPRECATION")
            addAction(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        }
        try {
            context.applicationContext.registerReceiver(deviceWatcher, filter)
        } catch (_: Exception) {}

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // route: "media" | "bridge" | "idle"
                    "setRoute" -> {
                        val route = call.argument<String>("route") ?: "media"
                        val mac = call.argument<String>("bridgeMac")
                        currentRoute = route
                        currentBridgeMac = mac
                        val onBt = when (route) {
                            "bridge" -> routeBridge(context, mac)
                            "idle" -> {
                                val am = am(context)
                                releaseSco(am)
                                am.mode = AudioManager.MODE_NORMAL
                                @Suppress("DEPRECATION")
                                am.isSpeakerphoneOn = false
                                false
                            }
                            else -> routeMedia(context, mac)
                        }
                        lastOnBluetooth = onBt
                        result.success(onBt)
                    }

                    /** Legacy name, now just the media route — never starts SCO. */
                    "setSpeakerphoneOn" -> {
                        currentRoute = "media"
                        currentBridgeMac = call.argument<String>("bridgeMac")
                        lastOnBluetooth = routeMedia(context, currentBridgeMac)
                        result.success(lastOnBluetooth)
                    }

                    "releaseRoute" -> {
                        // Not while the board is carrying a call. The device
                        // assistant stands down asynchronously, and its teardown
                        // lands a second or two AFTER arm-on-demand has given the
                        // call to the board — at which point releaseSco() tears
                        // down the SCO link the call is riding on. The device then
                        // falls back to its own microphone and the caller hears
                        // the room instead of the agent.
                        if (HfpRouter.ownsCallAudio) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        currentRoute = "idle"
                        lastOnBluetooth = false
                        val am = am(context)
                        releaseSco(am)
                        am.mode = AudioManager.MODE_NORMAL
                        @Suppress("DEPRECATION")
                        am.isSpeakerphoneOn = false
                        result.success(true)
                    }

                    // Authoritative "is a call up" when the board cannot say.
                    // Once the bridge drops HFP the board receives no CIND
                    // events and reports nothing, so telephony's own mode is
                    // the only source left. 2 = MODE_IN_CALL.
                    "audioMode" -> result.success(am(context).mode)

                    "setCallAudioMode" -> {
                        // Kept for the call screen. "agent" silences local
                        // output (the caller hears Gemini over SPP, so playing
                        // it here too would double it into the room and back
                        // into the mic); "user" puts the call on the speaker.
                        val am = am(context)
                        am.mode = AudioManager.MODE_IN_COMMUNICATION
                        @Suppress("DEPRECATION")
                        am.isSpeakerphoneOn = call.argument<String>("mode") != "agent"
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
