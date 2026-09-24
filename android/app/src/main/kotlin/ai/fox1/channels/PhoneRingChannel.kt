package ai.fox1.channels

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Ring detection from the device's own telephony, independent of the board.
 *
 * The board sees calls only while it holds an HFP SLC: `spp_send_call_state()`
 * in the firmware is called from `ESP_HF_CLIENT_CIND_CALL_EVT` and
 * `..._CALL_SETUP_EVT` and nowhere else, so a board that is not connected
 * reports nothing at all. That is what blocks arming the board per call rather
 * than holding the HFP slot all day — with the slot free, nothing would tell us
 * the phone was ringing.
 *
 * This is the replacement signal. `ACTION_PHONE_STATE_CHANGED` gives RINGING /
 * OFFHOOK / IDLE plus the incoming number, and needs only `READ_PHONE_STATE`
 * (plus `READ_CALL_LOG` for the number on API 29+) — both already held. No
 * default-dialer decision required.
 *
 * Registered at RUNTIME, deliberately. Android 8's implicit-broadcast ban
 * applies to manifest-declared receivers; a runtime one still receives
 * PHONE_STATE. The cost is that it only runs while the process does — which is
 * fine here, because the process that would arm the board is the same one.
 */
object PhoneRingChannel {
    private const val METHOD = "ai.fox1/phone_ring"
    private const val EVENTS = "ai.fox1/phone_ring/events"

    private var receiver: BroadcastReceiver? = null
    private var sink: EventChannel.EventSink? = null

    /** Last number seen while ringing. IDLE and OFFHOOK carry no number. */
    private var lastNumber: String = ""

    private fun emit(state: String, number: String) {
        sink?.success(mapOf("state" to state, "number" to number))
    }

    private fun start(context: Context) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
                val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
                // Only RINGING carries a number. Hold it so the OFFHOOK that
                // follows an answered call is still attributable to a caller —
                // everything downstream is filed under the number.
                val n = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                if (!n.isNullOrBlank()) lastNumber = n
                when (state) {
                    TelephonyManager.EXTRA_STATE_RINGING ->
                        emit("ringing", lastNumber)
                    TelephonyManager.EXTRA_STATE_OFFHOOK ->
                        emit("offhook", lastNumber)
                    TelephonyManager.EXTRA_STATE_IDLE -> {
                        emit("idle", lastNumber)
                        lastNumber = ""
                    }
                }
            }
        }
        context.applicationContext.registerReceiver(
            r, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED))
        receiver = r
    }

    private fun stop(context: Context) {
        receiver?.let {
            try { context.applicationContext.unregisterReceiver(it) } catch (_: Exception) {}
        }
        receiver = null
        lastNumber = ""
    }

    fun register(flutterEngine: FlutterEngine, context: Context) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    start(context)
                }
                override fun onCancel(arguments: Any?) {
                    sink = null
                    stop(context)
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Whether the number will actually arrive. Without this the
                    // ring is still seen, but anonymously — and a call with no
                    // number cannot be matched to history or auto-answer rules.
                    "hasPermission" -> result.success(
                        context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                            == PackageManager.PERMISSION_GRANTED)
                    else -> result.notImplemented()
                }
            }
    }
}
