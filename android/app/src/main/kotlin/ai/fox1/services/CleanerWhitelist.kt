package ai.fox1.services

import android.content.Context
import android.os.Environment
import android.util.Log
import java.io.File

/**
 * Keeps FOX-1 on the watch maker's kill whitelist.
 *
 * The DW watches' SystemUI (`AlarmKillAppsReceiver`) force-stops every app
 * five minutes after the screen goes off, sparing only the packages listed,
 * comma-separated, in `/sdcard/whileList.txt` (their spelling). A force-stop
 * on Android 8 also drops FOX-1's accessibility service, and with FOX-1 dead
 * the stock launcher's charging screen stays in front until the cable comes
 * out. The file listed ClawPin's old package names, so the move to `ai.fox1`
 * lost the protection.
 *
 * Only on those watches: the file already exists, or the DW launcher is
 * installed. Needs WRITE_EXTERNAL_STORAGE; without it this does nothing.
 */
object CleanerWhitelist {
    private const val TAG = "FOX1_CLEAN"

    fun ensure(context: Context) {
        try {
            @Suppress("DEPRECATION")
            val file = File(Environment.getExternalStorageDirectory(), "whileList.txt")
            if (!file.exists() && !dwWatch(context)) return
            val current = if (file.exists()) file.readText() else ""
            val listed = current.split(',').map { it.trim() }
            if (context.packageName in listed) return
            val sep = if (current.isEmpty() || current.trimEnd().endsWith(',')) "" else ","
            file.writeText(current.trimEnd() + sep + context.packageName + ",")
            Log.i(TAG, "added ${context.packageName} to ${file.path}")
        } catch (e: Exception) {
            Log.w(TAG, "could not update the kill whitelist: $e")
        }
    }

    private fun dwWatch(context: Context) = try {
        context.packageManager.getPackageInfo("com.dw.launcher", 0); true
    } catch (_: Exception) { false }
}
