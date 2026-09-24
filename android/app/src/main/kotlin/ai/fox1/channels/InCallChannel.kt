package ai.fox1.channels

import android.app.Activity
import android.content.Intent
import android.telecom.TelecomManager
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import ai.fox1.services.Fox1InCallService

object InCallChannel {
    private const val METHOD = "ai.fox1/in_call"
    private const val EVENTS = "ai.fox1/in_call/events"

    /**
     * Pick the phone up. Returns "dialer"/"telecom", or "!<reason>" on failure.
     *
     * The reason is returned rather than logged because this device has no ADB:
     * an android.util.Log line here is a line nobody can read, which is how the
     * first attempt failed silently with "no mechanism available" and no clue
     * as to why.
     */
    private fun answerRingingCall(activity: Activity): String {
        // Best path, when FOX-1 is the dialer.
        if (Fox1InCallService.answerRinging()) return "dialer"

        // The supported path for everyone else. The plan recorded
        // acceptRingingCall() as system-only; that has not been true since
        // API 26, when ANSWER_PHONE_CALLS became a normal runtime permission.
        // No default dialer, no reflection, and it keeps working on the newer
        // Android the product targets.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return "!needs Android 8 or newer"
        }
        if (activity.checkSelfPermission(Manifest.permission.ANSWER_PHONE_CALLS)
            != PackageManager.PERMISSION_GRANTED) {
            return "!ANSWER_PHONE_CALLS not granted — tap Grant answer permission"
        }
        return try {
            val tm = activity.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            tm.acceptRingingCall()
            "telecom"
        } catch (e: SecurityException) {
            "!refused: ${e.message}"
        } catch (e: Exception) {
            "!${e.javaClass.simpleName}: ${e.message}"
        }
    }

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Fox1InCallService.eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    Fox1InCallService.eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCallState" -> {
                        result.success(Fox1InCallService.getCallInfo())
                    }
                    "endCall" -> {
                        val ended = Fox1InCallService.endActiveCall()
                        result.success(mapOf<String, Any>(
                            "success" to ended,
                            "result" to if (ended) "Call ended" else "No active call"
                        ))
                    }
                    // Two ways to pick up. InCallService.answer() when we are
                    // the dialer; TelecomManager.acceptRingingCall() otherwise,
                    // which needs only the ANSWER_PHONE_CALLS runtime permission
                    // and is supported rather than reflected.
                    "answerCall" -> {
                        val via = answerRingingCall(activity)
                        val ok = !via.startsWith("!")
                        result.success(mapOf<String, Any?>(
                            "success" to ok,
                            "via" to if (ok) via else null,
                            "reason" to if (ok) null else via.substring(1),
                        ))
                    }
                    "hasAnswerPermission" -> {
                        result.success(
                            activity.checkSelfPermission(
                                Manifest.permission.ANSWER_PHONE_CALLS
                            ) == PackageManager.PERMISSION_GRANTED)
                    }
                    "requestAnswerPermission" -> {
                        activity.requestPermissions(
                            arrayOf(Manifest.permission.ANSWER_PHONE_CALLS), 4417)
                        result.success(true)
                    }
                    "isDefaultDialer" -> {
                        val tm = activity.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                        result.success(tm.defaultDialerPackage == activity.packageName)
                    }
                    "requestDefaultDialer" -> {
                        try {
                            val intent = Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).apply {
                                putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, activity.packageName)
                            }
                            activity.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
