package ai.fox1.channels

import android.app.Activity
import android.content.Intent
import android.provider.AlarmClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object AlarmChannel {
    private const val CHANNEL = "ai.fox1/alarm"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAlarm" -> {
                        val hour = call.argument<Int>("hour") ?: run {
                            result.error("INVALID_ARG", "hour is required", null)
                            return@setMethodCallHandler
                        }
                        val minute = call.argument<Int>("minute") ?: run {
                            result.error("INVALID_ARG", "minute is required", null)
                            return@setMethodCallHandler
                        }
                        val message = call.argument<String>("message")

                        try {
                            val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                                putExtra(AlarmClock.EXTRA_HOUR, hour)
                                putExtra(AlarmClock.EXTRA_MINUTES, minute)
                                putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                                if (message != null) {
                                    putExtra(AlarmClock.EXTRA_MESSAGE, message)
                                }
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            activity.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ALARM_ERROR", e.message, null)
                        }
                    }
                    "setTimer" -> {
                        val seconds = call.argument<Int>("seconds") ?: run {
                            result.error("INVALID_ARG", "seconds is required", null)
                            return@setMethodCallHandler
                        }
                        val message = call.argument<String>("message")

                        try {
                            val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
                                putExtra(AlarmClock.EXTRA_LENGTH, seconds)
                                putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                                if (message != null) {
                                    putExtra(AlarmClock.EXTRA_MESSAGE, message)
                                }
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            activity.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TIMER_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
