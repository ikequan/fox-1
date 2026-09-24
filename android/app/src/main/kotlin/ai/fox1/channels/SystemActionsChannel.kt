package ai.fox1.channels

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import ai.fox1.ui.TransferOverlay
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

object SystemActionsChannel {
    private const val CHANNEL = "ai.fox1/system"

    /// Safety net: even a leaked lock expires rather than draining the battery.
    private const val MAX_HOLD_MS = 5 * 60 * 1000L

    private var screenLock: PowerManager.WakeLock? = null

    /// AccessibilityService gestures only land on an interactive display, so UI
    /// automation needs the screen genuinely awake — and it must survive
    /// FOX-1 being backgrounded when the agent opens another app, which a
    /// window FLAG_KEEP_SCREEN_ON would not.
    @Suppress("DEPRECATION")
    private fun acquire(activity: Activity): Boolean {
        return try {
            val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (screenLock == null) {
                screenLock = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "fox1:agent-automation"
                ).apply { setReferenceCounted(false) }
            }
            // Re-acquiring refreshes the timeout, so repeated tool calls extend
            // the hold instead of stacking locks.
            screenLock?.acquire(MAX_HOLD_MS)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun release(): Boolean {
        return try {
            screenLock?.let { if (it.isHeld) it.release() }
            true
        } catch (e: Exception) {
            false
        }
    }

    /// A pattern the wearer will notice on a wrist, repeated until cancelled.
    ///
    /// A live caller is waiting on the other end of this, so it has to be
    /// insistent rather than polite — and it has to stop the moment the prompt
    /// is answered, which is why it repeats rather than fires once.
    private var vibrator: Vibrator? = null

    @Suppress("DEPRECATION")
    private fun alert(activity: Activity, repeat: Boolean): Boolean = try {
        val v = vibrator ?: (activity.getSystemService(Context.VIBRATOR_SERVICE)
            as Vibrator).also { vibrator = it }
        // wait, buzz, wait, buzz — long enough to feel through a sleeve.
        val pattern = longArrayOf(0, 400, 200, 400, 900)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createWaveform(pattern, if (repeat) 0 else -1))
        } else {
            v.vibrate(pattern, if (repeat) 0 else -1)
        }
        true
    } catch (e: Exception) {
        false
    }

    @Suppress("DEPRECATION")
    private fun stopAlert(): Boolean = try {
        vibrator?.cancel()
        true
    } catch (e: Exception) {
        false
    }

    /**
     * Put FOX-1 in front of whatever owns the screen.
     *
     * During a call that is the system dialer's in-call UI, not us — so a
     * Flutter overlay inside our own MaterialApp is invisible no matter how
     * correct it is. A full-screen-intent notification is the mechanism Android
     * gives for exactly this: "a live person needs an answer now".
     *
     * Belt and braces on purpose. On API 27 a direct startActivity still works
     * (background-start restrictions arrived in 29) and is instant; the
     * notification is the path that survives on newer Android, which is the
     * product target. Whichever lands first wins and the other is harmless.
     */
    private fun bringToFront(activity: Activity, who: String): Boolean = try {
        val nm = activity
            .getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    PROMPT_CHANNEL, "Call hand-over",
                    NotificationManager.IMPORTANCE_HIGH,
                )
            )
        }
        val intent = Intent(activity, activity.javaClass).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        val pi = PendingIntent.getActivity(
            activity, 0, intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(activity, PROMPT_CHANNEL)
        else
            @Suppress("DEPRECATION") Notification.Builder(activity)
        val n = builder
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("$who is on the line")
            .setContentText("Take the call, or send it back to the agent")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setFullScreenIntent(pi, true)
            .addAction(
                android.R.drawable.ic_menu_call, "Take call",
                actionIntent(activity, ACTION_TAKE, 1))
            .addAction(
                android.R.drawable.ic_menu_revert, "Back to agent",
                actionIntent(activity, ACTION_BACK, 2))
            .build()
        nm.notify(PROMPT_NOTIFICATION_ID, n)

        // Show over the lock screen and light the display, both API 27.
        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    activity.setShowWhenLocked(true)
                    activity.setTurnScreenOn(true)
                }
                activity.startActivity(intent)
            } catch (_: Exception) {
            }
        }
        true
    } catch (e: Exception) {
        false
    }

    private fun clearFront(activity: Activity): Boolean = try {
        (activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(PROMPT_NOTIFICATION_ID)
        activity.runOnUiThread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    activity.setShowWhenLocked(false)
                    activity.setTurnScreenOn(false)
                }
            } catch (_: Exception) {
            }
        }
        true
    } catch (e: Exception) {
        false
    }

    private const val PROMPT_CHANNEL = "fox1_call_handover"
    private const val PROMPT_NOTIFICATION_ID = 4712
    private const val EVENT_CHANNEL = "ai.fox1/system/events"

    const val ACTION_TAKE = "ai.fox1.TRANSFER_TAKE"
    const val ACTION_BACK = "ai.fox1.TRANSFER_BACK"

    private var sink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    /**
     * Notification actions rather than an activity.
     *
     * A full-screen intent only launches an activity when the screen is off or
     * locked; awake and unlocked — which is the normal case here, the dialer is
     * showing — Android downgrades it to a heads-up notification. And the HOME
     * activity does not reliably outrank a foreground in-call screen anyway.
     *
     * So stop fighting for the foreground. The notification already reaches the
     * wearer; give it the two buttons and it *is* the prompt.
     */
    private val actionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = when (intent.action) {
                ACTION_TAKE -> "take"
                ACTION_BACK -> "back"
                else -> return
            }
            main.post { sink?.success(mapOf("type" to "transfer", "action" to action)) }
        }
    }

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    private fun actionIntent(activity: Activity, action: String, code: Int) =
        PendingIntent.getBroadcast(
            activity, code, Intent(action).setPackage(activity.packageName),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

    /// Keeps the CPU running for a moment after a ring press or a dropped
    /// socket. With the screen off the device sleeps between Bluetooth events,
    /// and a wake from the ring stalled half-built until the next one arrived.
    /// Reference-counted with timeouts: overlapping callers each get their full
    /// window, and nothing has to remember to release it.
    private var cpuLock: PowerManager.WakeLock? = null

    private fun keepCpuAwake(context: Context, ms: Long) {
        val lock = cpuLock ?: (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fox1:agent-wake")
            .apply { setReferenceCounted(true) }
            .also { cpuLock = it }
        lock.acquire(ms.coerceIn(1_000L, 60_000L))
    }

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }
                override fun onCancel(arguments: Any?) { sink = null }
            })

        if (!receiverRegistered) {
            try {
                activity.applicationContext.registerReceiver(
                    actionReceiver,
                    IntentFilter().apply {
                        addAction(ACTION_TAKE)
                        addAction(ACTION_BACK)
                    })
                receiverRegistered = true
            } catch (_: Exception) {
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireScreenLock" -> result.success(acquire(activity))

                    // Wake the screen AND buzz. Both, together: a prompt the
                    // wearer cannot see is no better than one they cannot feel.
                    "alertWearer" -> {
                        val who = call.argument<String>("who") ?: "Someone"
                        acquire(activity)
                        // The window is the prompt that actually works here.
                        // The notification stays as the fallback for when the
                        // overlay grant is missing.
                        val shown = TransferOverlay.show(activity.applicationContext, who) { a ->
                            main.post {
                                sink?.success(mapOf("type" to "transfer", "action" to a))
                            }
                        }
                        if (!shown) bringToFront(activity, who)
                        alert(activity, call.argument<Boolean>("repeat") ?: true)
                        result.success(shown)
                    }
                    // Deliberately not alertWearer: that shows the hand-over
                    // overlay, which is a decision the wearer has to make right
                    // now. This is only "look at your wrist".
                    "nudgeWearer" -> {
                        acquire(activity)
                        try {
                            val v = vibrator ?: (activity.getSystemService(Context.VIBRATOR_SERVICE)
                                as Vibrator).also { vibrator = it }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                v.vibrate(VibrationEffect.createOneShot(350, 180))
                            } else {
                                @Suppress("DEPRECATION")
                                v.vibrate(350)
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("SystemActions", "nudge failed: $e")
                        }
                        result.success(true)
                    }
                    // A short buzz and nothing else — hold-to-talk feedback for
                    // a ring worn with the wrist down. nudgeWearer also turns
                    // the screen on, which nobody holding a ring is looking at.
                    "vibrate" -> {
                        val ms = (call.argument<Int>("ms") ?: 40).toLong()
                        val amp = (call.argument<Int>("amplitude") ?: 200).coerceIn(1, 255)
                        try {
                            val v = vibrator ?: (activity.getSystemService(Context.VIBRATOR_SERVICE)
                                as Vibrator).also { vibrator = it }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                v.vibrate(VibrationEffect.createOneShot(ms, amp))
                            } else {
                                @Suppress("DEPRECATION")
                                v.vibrate(ms)
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("SystemActions", "vibrate failed: $e")
                        }
                        result.success(true)
                    }
                    "keepCpuAwake" -> {
                        val ms = (call.argument<Int>("ms") ?: 15_000).toLong()
                        try {
                            keepCpuAwake(activity.applicationContext, ms)
                        } catch (e: Exception) {
                            android.util.Log.w("SystemActions", "wake lock failed: $e")
                        }
                        result.success(true)
                    }
                    // Battery-optimisation exemption. Without it Android cuts
                    // the network (and ignores wake locks) while the device
                    // idles, and a hold on the ring timed out before the socket
                    // to Gemini had even opened.
                    // Which renderer the engine actually started with, for the
                    // fox's performance test. The engine names it in its own
                    // log at start-up, and an app may read its own log lines.
                    // Off the main thread: logcat can take a moment.
                    "rendererInfo" -> {
                        Thread {
                            val lines = try {
                                val p = Runtime.getRuntime().exec(arrayOf("logcat", "-d", "-v", "brief"))
                                p.inputStream.bufferedReader().readLines()
                                    .filter {
                                        it.contains("impeller", true) ||
                                            it.contains("skia", true) ||
                                            it.contains("rendering backend", true)
                                    }
                                    .takeLast(4)
                            } catch (e: Exception) {
                                listOf("could not read the log: ${e.message}")
                            }
                            val requested = try {
                                activity.packageManager
                                    .getApplicationInfo(activity.packageName, PackageManager.GET_META_DATA)
                                    .metaData?.get("io.flutter.embedding.android.EnableImpeller")
                            } catch (_: Exception) {
                                null
                            }
                            activity.runOnUiThread {
                                result.success(mapOf(
                                    "manifest" to (requested?.toString() ?: "not set (default)"),
                                    "log" to (if (lines.isEmpty()) "no renderer line found" else lines.joinToString(" | ")),
                                ))
                            }
                        }.start()
                    }
                    "backgroundAllowed" -> {
                        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(activity.packageName))
                    }
                    "allowBackground" -> {
                        val shown = try {
                            activity.startActivity(Intent(
                                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                android.net.Uri.parse("package:${activity.packageName}")))
                            true
                        } catch (_: Exception) {
                            // Some builds hide the direct prompt; the list still works.
                            try {
                                activity.startActivity(Intent(
                                    android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                                true
                            } catch (_: Exception) {
                                false
                            }
                        }
                        result.success(shown)
                    }
                    // After a restore: every store holds what it loaded at
                    // start, so the app starts again. Android usually brings
                    // a killed on-screen app back by itself; the alarm is for
                    // when it does not. SINGLE_TOP, not CLEAR_TASK: when
                    // Android got there first, a CLEAR_TASK launch started a
                    // second copy, whose Hub found the port still taken.
                    "restartApp" -> {
                        val launch = activity.packageManager
                            .getLaunchIntentForPackage(activity.packageName)
                            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        if (launch != null) {
                            val pi = PendingIntent.getActivity(activity, 7301, launch,
                                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                            (activity.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager)
                                .set(android.app.AlarmManager.RTC, System.currentTimeMillis() + 800, pi)
                        }
                        result.success(launch != null)
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            android.os.Process.killProcess(android.os.Process.myPid())
                        }, 300)
                    }
                    "stopAlert" -> {
                        TransferOverlay.hide(activity.applicationContext)
                        clearFront(activity)
                        result.success(stopAlert())
                    }

                    "canOverlay" ->
                        result.success(TransferOverlay.canShow(activity))
                    "requestOverlay" -> {
                        TransferOverlay.requestPermission(activity)
                        result.success(true)
                    }

                    "releaseScreenLock" -> result.success(release())
                    "isScreenLockHeld" -> result.success(screenLock?.isHeld == true)
                    "expandStatusBar" -> {
                        try {
                            val service = activity.getSystemService("statusbar")
                            val clazz = Class.forName("android.app.StatusBarManager")
                            val method = clazz.getMethod("expandNotificationsPanel")
                            method.invoke(service)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("STATUS_BAR_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
