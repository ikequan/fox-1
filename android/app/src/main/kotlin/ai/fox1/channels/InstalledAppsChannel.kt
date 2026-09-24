package ai.fox1.channels

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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
                    "getInstalledApps" -> getInstalledApps(activity, result)
                    "launchApp" -> launchApp(activity, call, result)
                    "closeApp" -> closeApp(activity, call, result)
                    "closeAllApps" -> closeAllApps(activity, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun getInstalledApps(activity: Activity, result: MethodChannel.Result) {
        try {
            val pm = activity.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val activities = pm.queryIntentActivities(intent, 0)

            val apps = activities.map { resolveInfo ->
                val appInfo = resolveInfo.activityInfo.applicationInfo
                val name = pm.getApplicationLabel(appInfo).toString()
                val packageName = appInfo.packageName
                val icon = drawableToBytes(pm.getApplicationIcon(appInfo))

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
            goHome(activity)
            val pm = activity.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val packages = pm.queryIntentActivities(intent, 0)
                .map { it.activityInfo.applicationInfo.packageName }
                .distinct()
                .filter { it != activity.packageName }

            val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            Handler(Looper.getMainLooper()).postDelayed({
                var count = 0
                for (p in packages) {
                    try {
                        am.killBackgroundProcesses(p)
                        count++
                    } catch (_: Exception) {
                    }
                }
                result.success(count)
            }, 400)
        } catch (e: Exception) {
            result.error("CLOSE_ALL_ERROR", e.message, null)
        }
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
            val bitmap = when (drawable) {
                is BitmapDrawable -> drawable.bitmap
                else -> {
                    val bmp = Bitmap.createBitmap(
                        drawable.intrinsicWidth.coerceAtLeast(1),
                        drawable.intrinsicHeight.coerceAtLeast(1),
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
}
