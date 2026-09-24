package ai.fox1.channels

import ai.fox1.services.HfpRouter
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Probe for the API 27 SCO-routing workaround.
 *
 * On Android 8.1 the HFP device that receives SCO is not chosen by
 * `startBluetoothSco()` — that call carries no device. The choice is made in
 * native `btif_hf.cc`, which picks `btif_hf_latest_connected_idx()`: the most
 * recently SLC-connected headset wins. So the way to steer SCO is to control
 * which device connected last.
 *
 * `BluetoothHeadset.connect(device)` / `disconnect(device)` can do that. They
 * are @hide, but on API 27 they are gated only by BLUETOOTH_ADMIN — a normal
 * permission — and non-SDK-interface enforcement did not exist until API 28.
 * So reflection should reach them on a stock build.
 *
 * "Should". A manufacturer-patched Bluetooth APK would break it, and this device
 * is not stock in other respects. This probe answers that question before any
 * state machine is written on top of the assumption. It reports; [disconnect]
 * and [connect] are the only calls that change anything, and only when asked.
 *
 * Nothing here depends on the earbud — the rule lives in the device's own stack
 * and treats every HFP device alike.
 */
object HfpProbeChannel {
    private const val CHANNEL = "ai.fox1/hfp_probe"

    private var headset: BluetoothHeadset? = null

    private fun proxy(context: Context, then: (BluetoothHeadset?) -> Unit) {
        headset?.let { then(it); return }
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) { then(null); return }
        adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(p: Int, px: BluetoothProfile) {
                if (p == BluetoothProfile.HEADSET) {
                    headset = px as BluetoothHeadset
                    then(headset)
                }
            }
            override fun onServiceDisconnected(p: Int) {
                if (p == BluetoothProfile.HEADSET) headset = null
            }
        }, BluetoothProfile.HEADSET)
    }

    private fun sysProp(key: String): String = try {
        Class.forName("android.os.SystemProperties")
            .getMethod("get", String::class.java)
            .invoke(null, key) as? String ?: ""
    } catch (e: Exception) { "<unreadable: ${e.javaClass.simpleName}>" }

    /** Is the hidden method present on this build's BluetoothHeadset? */
    private fun hasMethod(name: String): String = try {
        BluetoothHeadset::class.java
            .getMethod(name, BluetoothDevice::class.java)
        "present"
    } catch (e: NoSuchMethodException) {
        "MISSING — build is patched or differs from AOSP"
    } catch (e: Exception) {
        "error: ${e.javaClass.simpleName}"
    }

    private fun report(context: Context, hs: BluetoothHeadset?): String {
        val sb = StringBuilder()
        sb.appendLine("── HFP probe ──")
        sb.appendLine("android SDK: ${android.os.Build.VERSION.SDK_INT}")

        val admin = context.checkSelfPermission(android.Manifest.permission.BLUETOOTH_ADMIN)
        sb.appendLine("BLUETOOTH_ADMIN: " +
            if (admin == PackageManager.PERMISSION_GRANTED) "granted" else "DENIED")

        // bt.max.hf.connections is the AG-side knob and the one that governs
        // here — the device is the audio gateway, the board and earbud are the
        // headsets. (bt.max.hfpclient.connections is the HF role, i.e. a device
        // acting AS a headset, and does not apply.) Neither is authoritative on
        // a patched build; the connected-devices list below is.
        for (k in listOf("bt.max.hf.connections", "bt.max.hfpclient.connections")) {
            val v = sysProp(k)
            sb.appendLine("$k: " + if (v.isBlank()) "<unset — stock default is 1>" else v)
        }

        sb.appendLine("connect(BluetoothDevice): ${hasMethod("connect")}")
        sb.appendLine("disconnect(BluetoothDevice): ${hasMethod("disconnect")}")
        sb.appendLine("setPriority(BluetoothDevice,int): " + try {
            BluetoothHeadset::class.java
                .getMethod("setPriority", BluetoothDevice::class.java, Int::class.javaPrimitiveType)
            "present"
        } catch (e: Exception) { "MISSING" })

        if (hs == null) {
            sb.appendLine("headset proxy: UNAVAILABLE")
            return sb.toString()
        }
        sb.appendLine("headset proxy: ok")
        val devices = hs.connectedDevices
        sb.appendLine("connected HFP devices: ${devices.size}")
        for (d in devices) {
            sb.appendLine("  ${d.address}  ${d.name}" +
                "  audio=${if (hs.isAudioConnected(d)) "ON" else "off"}")
        }
        sb.appendLine("bridge address: ${HfpRouter.bridgeMac ?: "<not set — start the bridge first>"}")
        return sb.toString()
    }

    /** The one call that proves it: does a reflective disconnect actually work? */
    private fun invoke(name: String, hs: BluetoothHeadset, dev: BluetoothDevice): String = try {
        val m = BluetoothHeadset::class.java.getMethod(name, BluetoothDevice::class.java)
        m.isAccessible = true
        val r = m.invoke(hs, dev)
        "$name(${dev.address}) returned $r"
    } catch (e: Exception) {
        "$name(${dev.address}) FAILED: ${e.javaClass.simpleName}: ${e.message}"
    }

    private fun device(mac: String): BluetoothDevice? = try {
        BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(mac)
    } catch (e: Exception) { null }

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> proxy(context) { hs -> result.success(report(context, hs)) }

                    // Move the slot by hand, to test the state machine without a
                    // call. The bridge normally sets bridgeMac when SPP opens;
                    // accept it here so the buttons work before that.
                    "acquire" -> {
                        call.argument<String>("mac")?.let { HfpRouter.bridgeMac = it }
                        HfpRouter.acquireForBridge(context)
                        result.success("acquire requested — see the [HFP] lines")
                    }
                    "release" -> {
                        HfpRouter.releaseToUser(context)
                        result.success("release requested — see the [HFP] lines")
                    }

                    "disconnect", "connect" -> {
                        val mac = call.argument<String>("mac")
                        val dev = mac?.let { device(it) }
                        if (dev == null) { result.success("no such device: $mac"); return@setMethodCallHandler }
                        proxy(context) { hs ->
                            if (hs == null) result.success("headset proxy unavailable")
                            else {
                                val before = hs.getConnectionState(dev)
                                val r = invoke(call.method, hs, dev)
                                result.success("$r\n  state before: $before" +
                                    " (watch the list on the next probe for the real answer)")
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
