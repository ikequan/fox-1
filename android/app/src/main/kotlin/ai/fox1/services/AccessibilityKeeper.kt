package ai.fox1.services

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log

/**
 * Keeps FOX-1's accessibility service on.
 *
 * Android 8 drops an app from the enabled accessibility services whenever the
 * app is force-stopped or updated — a battery saver's "close all apps", an
 * install — and the wearer finds on-screen tasks silently off ("I enabled it
 * but it went back"). An app cannot switch it back on by itself, unless it
 * holds WRITE_SECURE_SETTINGS, which only ADB can grant, once:
 *
 *     adb shell pm grant ai.fox1 android.permission.WRITE_SECURE_SETTINGS
 *
 * With it, FOX-1 restores the service on every start — but only while the
 * wearer wants it: switched on (the service connected) and not since switched
 * off in Android's settings (the service unbound while FOX-1 was running). A
 * force-stop kills the process without an unbind, so it does not count as the
 * wearer turning it off.
 */
object AccessibilityKeeper {
    private const val TAG = "FOX1_A11Y"

    // Flutter's shared_preferences file and key prefix, so Dart reads the same
    // value as `accessibility_wanted`.
    private const val PREFS = "FlutterSharedPreferences"
    private const val WANTED = "flutter.accessibility_wanted"

    fun canKeep(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    fun wanted(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(WANTED, false)

    fun setWanted(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(WANTED, on).apply()
    }

    /** Switches the service back on if the wearer wants it and FOX-1 may. */
    fun restoreIfWanted(context: Context): Boolean {
        if (!wanted(context) || !canKeep(context)) return false
        if (Fox1AccessibilityService.isEnabledInSettings(context)) return false
        return try {
            val resolver = context.contentResolver
            val me = ComponentName(context, Fox1AccessibilityService::class.java).flattenToString()
            val current = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
                ?.split(':')?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList()
            // Keep every other app's service exactly as it was.
            val next = (current.filter { ComponentName.unflattenFromString(it)?.packageName != context.packageName } + me)
                .joinToString(":")
            Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, next)
            Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            Log.i(TAG, "accessibility was switched off by the system — switched back on")
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not restore accessibility: $e")
            false
        }
    }
}
