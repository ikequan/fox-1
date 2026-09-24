package ai.fox1.channels

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object QuickSettingsChannel {
    private const val CHANNEL = "ai.fox1/settings"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isWifiEnabled" -> {
                        val wm = activity.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        result.success(wm.isWifiEnabled)
                    }
                    "setWifiEnabled" -> {
                        // On Android 10+, can't toggle wifi directly — open settings
                        val intent = android.content.Intent(Settings.Panel.ACTION_WIFI)
                        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        activity.startActivity(intent)
                        result.success(true)
                    }
                    "isBluetoothEnabled" -> {
                        val bm = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                        result.success(bm.adapter?.isEnabled == true)
                    }
                    "setBluetoothEnabled" -> {
                        val intent = android.content.Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        activity.startActivity(intent)
                        result.success(true)
                    }
                    "canWriteSettings" -> result.success(Settings.System.canWrite(activity))
                    "openWriteSettings" -> {
                        val intent = android.content.Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                            data = android.net.Uri.parse("package:${activity.packageName}")
                            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        activity.startActivity(intent)
                        result.success(true)
                    }
                    "getBrightness" -> {
                        try {
                            val brightness = Settings.System.getInt(
                                activity.contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS
                            )
                            result.success(brightness / 255.0)
                        } catch (e: Exception) {
                            result.success(0.5)
                        }
                    }
                    "setBrightness" -> {
                        val value = call.argument<Double>("value") ?: 0.5
                        try {
                            if (!Settings.System.canWrite(activity)) {
                                val intent = android.content.Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                                    data = android.net.Uri.parse("package:${activity.packageName}")
                                    addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                activity.startActivity(intent)
                                result.error("PERMISSION_NEEDED", "WRITE_SETTINGS permission required — grant it in the screen that just opened", null)
                                return@setMethodCallHandler
                            }
                            Settings.System.putInt(
                                activity.contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS,
                                (value * 255).toInt()
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BRIGHTNESS_ERROR", e.message, null)
                        }
                    }
                    "getVolume" -> {
                        val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val current = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        result.success(if (max > 0) current.toDouble() / max else 0.5)
                    }
                    "setVolume" -> {
                        val value = call.argument<Double>("value") ?: 0.5
                        val am = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        am.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            (value * max).toInt(),
                            0
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
