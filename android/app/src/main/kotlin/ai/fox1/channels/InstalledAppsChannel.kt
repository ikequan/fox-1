package ai.fox1.channels

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.app.SearchManager
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.MediaStore
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import java.util.Locale
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

object InstalledAppsChannel {
    private const val CHANNEL = "ai.fox1/apps"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> Background.run(Background.io, result) {
                        getInstalledApps(activity, call.argument<Boolean>("icons") ?: true, it)
                    }
                    "launchApp" -> launchApp(activity, call, result)
                    "closeApp" -> closeApp(activity, call, result)
                    "closeAllApps" -> closeAllApps(activity, result)
                    "openShortcut" -> openShortcut(activity, call, result)
                    "isMusicActive" -> result.success(
                        (activity.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager).isMusicActive)
                    else -> result.notImplemented()
                }
            }
    }

    /// Icons as PNG, by package and version: each is drawn once, not on
    /// every request.
    private val iconCache = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()

    private fun getInstalledApps(activity: Activity, icons: Boolean, result: MethodChannel.Result) {
        try {
            val pm = activity.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val activities = pm.queryIntentActivities(intent, 0)

            val apps = activities.map { resolveInfo ->
                val appInfo = resolveInfo.activityInfo.applicationInfo
                val name = pm.getApplicationLabel(appInfo).toString()
                val packageName = appInfo.packageName
                val icon = if (!icons) null else {
                    val version = try { pm.getPackageInfo(packageName, 0).lastUpdateTime } catch (_: Exception) { 0L }
                    iconCache.getOrPut("$packageName@$version") {
                        drawableToBytes(pm.getApplicationIcon(appInfo)) ?: ByteArray(0)
                    }.takeIf { it.isNotEmpty() }
                }

                mapOf(
                    "name" to name,
                    "packageName" to packageName,
                    "icon" to icon
                )
            }.filter {
                // Exclude ourselves from the list
                it["packageName"] != activity.packageName
            }.sortedBy {
                (it["name"] as String).lowercase()
            }

            result.success(apps)
        } catch (e: Exception) {
            result.error("GET_APPS_ERROR", e.message, null)
        }
    }

    private fun launchApp(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        if (packageName == null) {
            result.error("INVALID_ARG", "packageName required", null)
            return
        }

        try {
            val intent = activity.packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activity.startActivity(intent)
                result.success(true)
            } else {
                result.error("APP_NOT_FOUND", "Cannot launch $packageName", null)
            }
        } catch (e: Exception) {
            result.error("LAUNCH_ERROR", e.message, null)
        }
    }

    /**
     * The only route an unprivileged app has to closing another app.
     *
     * killBackgroundProcesses() is a no-op against a FOREGROUND app, so we go
     * home first to background the target. FOX-1 is the HOME launcher, so the
     * home intent brings us forward. The kill is posted after a short delay to
     * let that transition land.
     *
     * This is not "force stop": it clears the app's activities and frees its
     * memory, but the system may restart persistent services. Good enough to
     * end a task and reclaim resources, which is what the agent needs.
     */
    private fun closeApp(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val packageName = call.argument<String>("packageName")
        if (packageName.isNullOrEmpty()) {
            result.error("INVALID_ARG", "packageName required", null)
            return
        }
        if (packageName == activity.packageName) {
            result.error("SELF", "Refusing to close FOX-1 itself", null)
            return
        }
        try {
            pauseMedia(activity)
            goHome(activity)
            val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    am.killBackgroundProcesses(packageName)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("CLOSE_ERROR", e.message, null)
                }
            }, 400)
        } catch (e: Exception) {
            result.error("CLOSE_ERROR", e.message, null)
        }
    }

    /**
     * Closes every launchable app except FOX-1. Android does not let a normal
     * app enumerate what is actually running (getRunningAppProcesses returns
     * only our own since API 22), so we sweep the launchable set — killing a
     * package that is not running is harmless.
     */
    private fun closeAllApps(activity: Activity, result: MethodChannel.Result) {
        try {
            pauseMedia(activity)
            goHome(activity)
            val pm = activity.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val packages = pm.queryIntentActivities(intent, 0)
                .map { it.activityInfo.applicationInfo.packageName }
                .distinct()
                .filter { it != activity.packageName }

            val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            // The sweep itself off the main thread: one call per app.
            Handler(Looper.getMainLooper()).postDelayed({
                Background.run(Background.io, result) { r ->
                    var count = 0
                    for (p in packages) {
                        try {
                            am.killBackgroundProcesses(p)
                            count++
                        } catch (_: Exception) {
                        }
                    }
                    r.success(count)
                }
            }, 400)
        } catch (e: Exception) {
            result.error("CLOSE_ALL_ERROR", e.message, null)
        }
    }

    /**
     * Pauses whatever is playing. Closing an app cannot stop its music: a
     * player runs a foreground service, which killBackgroundProcesses leaves
     * alone — "close Spotify" closed it and the podcast played on. The media
     * key reaches the active player without any permission.
     */
    private fun pauseMedia(activity: Activity) {
        try {
            val audio = activity.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            if (!audio.isMusicActive) return
            for (action in listOf(android.view.KeyEvent.ACTION_DOWN, android.view.KeyEvent.ACTION_UP)) {
                audio.dispatchMediaKeyEvent(android.view.KeyEvent(action, android.view.KeyEvent.KEYCODE_MEDIA_PAUSE))
            }
        } catch (_: Exception) {}
    }

    /** FOX-1 is the HOME launcher, so this brings us to the foreground. */
    private fun goHome(activity: Activity) {
        val home = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_HOME)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        activity.startActivity(home)
    }

    private fun drawableToBytes(drawable: Drawable): ByteArray? {
        try {
            // At most 96 px: the list shows them far smaller, and a full-size
            // icon costs its compression on every app.
            val w = drawable.intrinsicWidth.coerceAtLeast(1)
            val h = drawable.intrinsicHeight.coerceAtLeast(1)
            val scale = minOf(1f, 96f / maxOf(w, h))
            val bitmap = when {
                drawable is BitmapDrawable && scale >= 1f -> drawable.bitmap
                else -> {
                    val bmp = Bitmap.createBitmap(
                        (w * scale).toInt().coerceAtLeast(1),
                        (h * scale).toInt().coerceAtLeast(1),
                        Bitmap.Config.ARGB_8888
                    )
                    val canvas = Canvas(bmp)
                    drawable.setBounds(0, 0, canvas.width, canvas.height)
                    drawable.draw(canvas)
                    bmp
                }
            }
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            return stream.toByteArray()
        } catch (e: Exception) {
            return null
        }
    }

    /**
     * An app opened straight at the right place — a search, a song, a route,
     * a chat — in one step, instead of the agent tapping its way there. Each
     * is an intent aimed at one installed app, so it never lands in a
     * browser. Nothing is sent: a WhatsApp message is only typed in.
     */
    private fun openShortcut(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val kind = call.argument<String>("kind") ?: ""
        val pkg = call.argument<String>("package")
        val query = call.argument<String>("query") ?: ""
        val intent = when (kind) {
            // Android's standard "play X" — what the Assistant uses.
            "play" -> Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
                putExtra(SearchManager.QUERY, query)
                putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
            }
            "search" -> when (pkg) {
                "com.spotify.music" -> Intent(Intent.ACTION_VIEW, Uri.parse("spotify:search:" + Uri.encode(query)))
                "com.android.vending" -> Intent(Intent.ACTION_VIEW, Uri.parse("market://search?q=" + Uri.encode(query)))
                "com.google.android.apps.maps" -> Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(query)))
                else -> Intent(Intent.ACTION_SEARCH).putExtra(SearchManager.QUERY, query)
            }
            "navigate" -> Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=" + Uri.encode(query)))
            "whatsapp" -> {
                val number = toInternational(activity, call.argument<String>("number") ?: "")
                    ?: return result.success(mapOf("success" to false, "error" to "Not a phone number WhatsApp can use"))
                val text = call.argument<String>("text") ?: ""
                Intent(Intent.ACTION_VIEW, Uri.parse(
                    "https://api.whatsapp.com/send?phone=$number&text=" + Uri.encode(text)))
            }
            else -> return result.success(mapOf("success" to false, "error" to "Unknown shortcut: $kind"))
        }
        if (pkg != null) intent.setPackage(pkg)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (intent.resolveActivity(activity.packageManager) == null) {
            return result.success(mapOf("success" to false,
                "error" to "${pkg ?: "No app"} does not support $kind — use the screen instead"))
        }
        try {
            activity.startActivity(intent)
            if (kind != "play") return result.success(mapOf("success" to true))
            // An app can accept "play" and do nothing — Spotify on this watch
            // did, and the agent waited on it. Listen for sound instead.
            val audio = activity.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val handler = Handler(Looper.getMainLooper())
            val deadline = System.currentTimeMillis() + 8000
            fun check() {
                when {
                    audio.isMusicActive -> result.success(mapOf("success" to true, "playing" to true))
                    System.currentTimeMillis() > deadline -> result.success(mapOf("success" to true, "playing" to false))
                    else -> handler.postDelayed({ check() }, 500)
                }
            }
            handler.postDelayed({ check() }, 1000)
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Could not open it: ${e.message}"))
        }
    }

    /// "0245753283" → "233245753283", by the SIM's country: WhatsApp's link
    /// needs the country code and no plus.
    private fun toInternational(context: Context, number: String): String? {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val iso = listOf(tm?.simCountryIso, tm?.networkCountryIso, Locale.getDefault().country)
            .firstOrNull { !it.isNullOrBlank() }?.uppercase(Locale.ROOT) ?: return null
        val e164 = if (number.trim().startsWith("+")) number.filter { it == '+' || it.isDigit() }
                   else PhoneNumberUtils.formatNumberToE164(number, iso)
        return e164?.removePrefix("+")?.takeIf { it.length >= 8 }
    }
}
