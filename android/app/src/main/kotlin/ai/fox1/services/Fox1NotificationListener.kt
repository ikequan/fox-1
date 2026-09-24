package ai.fox1.services

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

class Fox1NotificationListener : NotificationListenerService() {

    companion object {
        var instance: Fox1NotificationListener? = null
        var eventSink: EventChannel.EventSink? = null
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        sendUpdate()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        sendUpdate()
    }

    private fun sendUpdate() {
        val sink = eventSink ?: return
        try {
            val notifications = activeNotifications.map { sbn ->
                val extras = sbn.notification.extras
                mapOf(
                    "key" to sbn.key,
                    "packageName" to sbn.packageName,
                    "title" to (extras.getString("android.title") ?: ""),
                    "text" to (extras.getCharSequence("android.text")?.toString() ?: ""),
                    "timestamp" to sbn.postTime
                )
            }
            // Must post to main thread for Flutter event channel
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                sink.success(notifications)
            }
        } catch (_: Exception) {
            // Ignore errors during notification updates
        }
    }
}
