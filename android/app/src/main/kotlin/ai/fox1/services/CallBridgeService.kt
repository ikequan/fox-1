package ai.fox1.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/**
 * Keeps the process alive for the duration of a bridged call.
 *
 * Without this the launcher sits in the HOME oom_adj bucket while a call runs —
 * the dialer's InCallUI is the foreground app, not us — and the low-memory
 * killer takes it, which is why long calls died at random. Plain threads do not
 * protect a process; only a foreground service raises its priority.
 *
 * The wake lock is belt and braces: telephony holds its own while a call is up,
 * so the CPU should stay awake anyway, but the bridge outlives individual calls
 * and must not be suspended between them.
 */
class CallBridgeService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private var callWatch: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())

        // A null intent means the system restarted us after killing the
        // process. That is the ONLY prompt reason the app comes back mid-call:
        // FOX-1 is the HOME launcher, but Android only restarts HOME when
        // HOME is needed, and during a call the dialer is foreground. Waiting
        // for that took 99 seconds in testing — long past the point where
        // there was still a caller to rejoin.
        if (intent == null) bringBackForCall()

        if (intent?.getBooleanExtra(EXTRA_HOLD_FOR_CALL, false) == true) {
            holdUntilCallEnds()
        }

        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fox1:call-bridge")
                .apply { setReferenceCounted(false) }
        }
        if (wakeLock?.isHeld != true) wakeLock?.acquire(MAX_CALL_MS)

        // Restart if the system kills us anyway; do not redeliver the intent.
        return START_STICKY
    }

    /**
     * Relaunch the UI, but only if there is a live call to go back to.
     *
     * Starting an activity from a service is unrestricted on API 27. On
     * Android 10+ it is not, but an app holding SYSTEM_ALERT_WINDOW is exempt
     * — and FOX-1 already holds it for the hand-over overlay.
     */
    private fun bringBackForCall() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            if (am.mode != android.media.AudioManager.MODE_IN_CALL) {
                // Nothing to rejoin. Do not drag the launcher in front of
                // whatever the wearer is actually doing.
                return
            }
            val i = packageManager.getLaunchIntentForPackage(packageName) ?: return
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            startActivity(i)
        } catch (e: Exception) {
            android.util.Log.w("CallBridgeService", "relaunch failed: $e")
        }
    }

    /**
     * Stay foreground while a carrier call is still running.
     *
     * The bridge going away does not end the call — it hands it to the device,
     * and the wearer carries on talking. Tearing this service down at that
     * moment dropped the process back into the HOME oom_adj bucket mid-call,
     * with a live telephony session and an audio route it still has to react to
     * when an earbud comes or goes.
     *
     * Polled rather than event-driven on purpose: after the bridge closes there
     * is no call-state channel left to listen to, and AudioManager.mode is the
     * one signal that is authoritative and self-clearing.
     */
    private fun holdUntilCallEnds() {
        callWatch?.let { handler.removeCallbacks(it) }
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val deadline = System.currentTimeMillis() + MAX_HANDOVER_MS
        val r = object : Runnable {
            override fun run() {
                @Suppress("DEPRECATION")
                val inCall = am.mode == AudioManager.MODE_IN_CALL
                if (!inCall || System.currentTimeMillis() > deadline) {
                    callWatch = null
                    stopSelf()
                    return
                }
                handler.postDelayed(this, 3000)
            }
        }
        callWatch = r
        handler.postDelayed(r, 3000)
    }

    override fun onDestroy() {
        callWatch?.let { handler.removeCallbacks(it) }
        callWatch = null
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Call bridge",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Keeps the agent's call audio running"
                        setShowBadge(false)
                    }
                )
            }
        }

        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return b.setContentTitle("Call bridge active")
            .setContentText("Agent call audio in progress")
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "fox1_call_bridge"
        private const val NOTIFICATION_ID = 4711

        private const val EXTRA_HOLD_FOR_CALL = "hold_for_call"

        /** Upper bound on one call; the lock is released on stop regardless. */
        private const val MAX_CALL_MS = 60L * 60L * 1000L

        /** Backstop in case AudioManager.mode never returns to normal. */
        private const val MAX_HANDOVER_MS = 60L * 60L * 1000L

        fun start(context: Context) {
            val i = Intent(context, CallBridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallBridgeService::class.java))
        }

        /**
         * The bridge is done but the call is not. Stay up until it really ends.
         */
        fun holdForCall(context: Context) {
            val i = Intent(context, CallBridgeService::class.java)
                .putExtra(EXTRA_HOLD_FOR_CALL, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }
    }
}
