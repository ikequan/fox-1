package ai.fox1.services

import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.InCallService
import io.flutter.plugin.common.EventChannel

class Fox1InCallService : InCallService() {

    companion object {
        var instance: Fox1InCallService? = null
        var eventSink: EventChannel.EventSink? = null
        var activeCall: Call? = null

        fun endActiveCall(): Boolean {
            val call = activeCall ?: return false
            call.disconnect()
            return true
        }

        /** The preferred way to pick up: only works when we are the dialer. */
        fun answerRinging(): Boolean {
            val call = activeCall ?: return false
            if (call.state != Call.STATE_RINGING) return false
            // Video state 0 = audio only. There is no audio-only overload.
            call.answer(0)
            return true
        }

        fun isRinging(): Boolean = activeCall?.state == Call.STATE_RINGING

        fun getCallInfo(): Map<String, Any?>? {
            val call = activeCall ?: return null
            val number = call.details?.handle?.schemeSpecificPart ?: ""
            val state = mapCallState(call.state)
            return mapOf(
                "state" to state,
                "phoneNumber" to number,
            )
        }

        private fun mapCallState(state: Int): String = when (state) {
            Call.STATE_DIALING -> "dialing"
            Call.STATE_RINGING -> "ringing"
            Call.STATE_ACTIVE -> "active"
            Call.STATE_HOLDING -> "holding"
            Call.STATE_DISCONNECTED -> "disconnected"
            Call.STATE_CONNECTING -> "connecting"
            else -> "unknown"
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            postCallState(call, state)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        activeCall = call
        call.registerCallback(callCallback)
        postCallState(call, call.state)
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        call.unregisterCallback(callCallback)
        if (activeCall == call) {
            activeCall = null
        }
        postEvent(mapOf(
            "state" to "disconnected",
            "phoneNumber" to (call.details?.handle?.schemeSpecificPart ?: ""),
        ))
    }

    private fun postCallState(call: Call, state: Int) {
        val number = call.details?.handle?.schemeSpecificPart ?: ""
        postEvent(mapOf(
            "state" to mapCallState(state),
            "phoneNumber" to number,
        ))
    }

    private fun postEvent(data: Map<String, Any?>) {
        val sink = eventSink ?: return
        mainHandler.post {
            try {
                sink.success(data)
            } catch (_: Exception) {}
        }
    }
}
