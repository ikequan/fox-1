package ai.fox1.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while a smart ring is paired, so its BLE link, the
 * hold-to-talk button and the 30-minute health sync survive the screen going
 * off and another app coming to the front.
 *
 * Same reason as [CallBridgeService]: as HOME the launcher sits in a bucket the
 * low-memory killer reaches, and only a foreground service lifts it. It holds
 * no wake lock — the Bluetooth stack wakes the CPU for every notification, and
 * a day-long lock would cost more battery than the ring itself.
 *
 * The link lives in RingBleChannel / RingService, not here; this only raises
 * the process's priority and says so in the shade.
 */
class RingLinkService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra(EXTRA_TEXT)?.let { lastText = it }
        startForeground(NOTIFICATION_ID, buildNotification(lastText))
        // Not sticky: restarted without the Flutter engine there is no link to
        // keep, only a notification claiming one. HOME relaunches the UI, and
        // the UI restarts this.
        return START_NOT_STICKY
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Smart ring", NotificationManager.IMPORTANCE_LOW)
                        .apply {
                            description = "Keeps the smart ring connected"
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
        return b.setContentTitle("Smart ring")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "fox1_ring"
        private const val NOTIFICATION_ID = 4712
        private const val EXTRA_TEXT = "text"

        @Volatile private var lastText = "Connecting…"

        /** Starts the service, or updates its text if it is already up. */
        fun start(context: Context, text: String) {
            val i = Intent(context, RingLinkService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RingLinkService::class.java))
        }
    }
}
