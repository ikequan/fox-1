package ai.fox1.channels

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import ai.fox1.services.Fox1NotificationListener

object NotificationListenerChannel {
    private const val METHOD_CHANNEL = "ai.fox1/notifications"
    private const val EVENT_CHANNEL = "ai.fox1/notifications/events"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getActiveNotifications" -> getActiveNotifications(result)
                    "dismissNotification" -> {
                        val key = call.argument<String>("key") ?: ""
                        dismissNotification(key, result)
                    }
                    "isListenerEnabled" -> isListenerEnabled(activity, result)
                    "requestListenerPermission" -> requestListenerPermission(activity, result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Fox1NotificationListener.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    Fox1NotificationListener.eventSink = null
                }
            })
    }

    private fun getActiveNotifications(result: MethodChannel.Result) {
        val instance = Fox1NotificationListener.instance
        if (instance == null) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        try {
            val notifications = instance.activeNotifications.map { sbn ->
                val extras = sbn.notification.extras
                mapOf(
                    "key" to sbn.key,
                    "packageName" to sbn.packageName,
                    "title" to (extras.getString("android.title") ?: ""),
                    "text" to (extras.getCharSequence("android.text")?.toString() ?: ""),
                    "timestamp" to sbn.postTime
                )
            }
            result.success(notifications)
        } catch (e: Exception) {
            result.error("NOTIF_ERROR", e.message, null)
        }
    }

    private fun dismissNotification(key: String, result: MethodChannel.Result) {
        val instance = Fox1NotificationListener.instance
        if (instance != null) {
            try {
                instance.cancelNotification(key)
                result.success(true)
            } catch (e: Exception) {
                result.error("DISMISS_ERROR", e.message, null)
            }
        } else {
            result.success(false)
        }
    }

    private fun isListenerEnabled(activity: Activity, result: MethodChannel.Result) {
        val cn = ComponentName(activity, Fox1NotificationListener::class.java)
        val flat = Settings.Secure.getString(
            activity.contentResolver,
            "enabled_notification_listeners"
        )
        result.success(flat?.contains(cn.flattenToString()) == true)
    }

    private fun requestListenerPermission(activity: Activity, result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("PERMISSION_ERROR", e.message, null)
        }
    }
}
