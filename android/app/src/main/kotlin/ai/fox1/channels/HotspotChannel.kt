package ai.fox1.channels

import android.app.Activity
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object HotspotChannel {
    private const val CHANNEL = "ai.fox1/hotspot"
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startHotspot" -> {
                        val wm = activity.applicationContext
                            .getSystemService(Context.WIFI_SERVICE) as WifiManager
                        try {
                            wm.startLocalOnlyHotspot(
                                object : WifiManager.LocalOnlyHotspotCallback() {
                                    override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                                        reservation = res
                                        var ssid = "AndroidAP"
                                        var passphrase = ""
                                        try {
                                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                                val config = res.softApConfiguration
                                                ssid = config.ssid ?: "AndroidAP"
                                                passphrase = config.passphrase ?: ""
                                            } else {
                                                @Suppress("DEPRECATION")
                                                val config = res.wifiConfiguration
                                                ssid = config?.SSID ?: "AndroidAP"
                                                passphrase = config?.preSharedKey ?: ""
                                            }
                                        } catch (e: Exception) {
                                            // Use defaults if config read fails
                                        }
                                        val info = mapOf(
                                            "ssid" to ssid,
                                            "password" to passphrase,
                                            "ip" to "192.168.43.1"
                                        )
                                        Handler(Looper.getMainLooper()).post {
                                            result.success(info)
                                        }
                                    }

                                    override fun onFailed(reason: Int) {
                                        Handler(Looper.getMainLooper()).post {
                                            result.error(
                                                "HOTSPOT_FAILED",
                                                "Failed to start hotspot, reason: $reason",
                                                null
                                            )
                                        }
                                    }

                                    override fun onStopped() {
                                        reservation = null
                                    }
                                },
                                Handler(Looper.getMainLooper())
                            )
                        } catch (e: Exception) {
                            result.error("HOTSPOT_FAILED", e.message, null)
                        }
                    }
                    "stopHotspot" -> {
                        try {
                            reservation?.close()
                            reservation = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("HOTSPOT_STOP_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
