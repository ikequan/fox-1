package ai.fox1.services

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.media.AudioManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Decides which Bluetooth device holds the device's one HFP slot.
 *
 * This device connects exactly one HFP device at a time. Measured, not assumed:
 * with the board and a TECNO earbud both showing "Connected" in settings,
 * BluetoothHeadset.getConnectedDevices() returned only the board, and the
 * earbud's own row read "Connected (no phone)" — A2DP, no headset profile.
 *
 * That single slot is also what steers SCO. startBluetoothSco() takes no device
 * argument on API 27; native btif_hf.cc routes to btif_hf_latest_connected_idx(),
 * the most recently SLC-connected headset. With one slot the two questions
 * collapse into one: whoever holds HFP gets the call audio.
 *
 * So the rule is simply who should be holding it:
 *
 *   idle          the user's earbud   — the agent speaks to the wearer
 *   bridged call  the ESP32 board     — the agent speaks to the caller
 *
 * [acquireForBridge] and [releaseToUser] move the slot between them. Both run on
 * one serial executor so a release can never overtake an acquire, and both are
 * safe to call when there is no earbud, no board, or no Bluetooth at all.
 *
 * The levers are BluetoothHeadset.connect/disconnect. They are @hide, but on
 * API 27 they are gated only by BLUETOOTH_ADMIN — a normal permission — and
 * non-SDK-interface enforcement did not exist until API 28. HfpProbeChannel
 * confirmed on this build that a reflective disconnect really moves the state
 * (2 -> 0), and that SPP survives it untouched.
 *
 * Deliberately absent: setPriority. It would express intent more durably, but a
 * crash mid-call would leave the user's earbud pinned priority-off and silently
 * unable to take calls afterwards. Observation says we do not need it — after a
 * disconnect the board stayed down for 35 s with no auto-reconnect, so the
 * stack is not going to fight these calls.
 */
object HfpRouter {

    private const val SETTLE_MS = 6000L
    private const val POLL_MS = 150L

    private val exec = Executors.newSingleThreadExecutor { r -> Thread(r, "hfp-router") }

    /**
     * Where [HFP] lines go. CallBridgeChannel points this at its own emitter so
     * they reach LogBuffer and http://<device-ip>:8080/logs; until then they fall
     * back to logcat, which on this device means nobody reads them.
     */
    @Volatile
    var logger: (String) -> Unit = { android.util.Log.i("HfpRouter", it) }

    /** Address of the bridge board. Set by CallBridgeChannel when SPP opens. */
    @Volatile
    var bridgeMac: String? = null

    /** Whoever we took the slot from, so [releaseToUser] knows where to give it back. */
    @Volatile
    private var displaced: String? = null

    /**
     * True while a carrier call is up.
     *
     * A release during a live call is a hand-over, not a tidy-up: the call
     * survives the board going away and lands on the device. It has to land
     * somewhere audible, and the default is the earpiece — which on this device
     * means the wearer hears nothing while the caller still hears them.
     */
    @Volatile
    var callActive = false

    /**
     * The board holds the slot and call audio is routed to it.
     *
     * Read by AudioChannel.releaseRoute, which must not tear down SCO while
     * this is true. The device assistant's own teardown lands asynchronously —
     * roughly two seconds after arm-on-demand takes the route — and releaseSco()
     * there killed the very link carrying the call to the board. The caller then
     * heard the device's own microphone: the room, not the agent.
     */
    @Volatile
    var ownsCallAudio = false
        private set

    private var headset: BluetoothHeadset? = null
    private var a2dp: BluetoothA2dp? = null

    // ---------------------------------------------------------------- proxies

    private fun adapter(): BluetoothAdapter? =
        BluetoothAdapter.getDefaultAdapter()?.takeIf { it.isEnabled }

    /** Blocking proxy fetch. Only ever called on [exec], never on the main thread. */
    private fun proxy(context: Context, profile: Int): BluetoothProfile? {
        (if (profile == BluetoothProfile.HEADSET) headset else a2dp)?.let { return it }
        val ad = adapter() ?: return null
        val latch = CountDownLatch(1)
        var got: BluetoothProfile? = null
        val ok = ad.getProfileProxy(context.applicationContext, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(p: Int, px: BluetoothProfile) {
                if (p != profile) return
                got = px
                if (p == BluetoothProfile.HEADSET) headset = px as BluetoothHeadset
                else if (p == BluetoothProfile.A2DP) a2dp = px as BluetoothA2dp
                latch.countDown()
            }
            override fun onServiceDisconnected(p: Int) {
                if (p == BluetoothProfile.HEADSET) headset = null
                if (p == BluetoothProfile.A2DP) a2dp = null
            }
        }, profile)
        if (!ok) return null
        latch.await(3, TimeUnit.SECONDS)
        return got
    }

    /**
     * Point a live call at the device's speaker, or take it off again.
     *
     * Deliberately does not touch `mode`: during a carrier call that belongs to
     * telephony, and overriding it breaks the routing we are trying to fix.
     */
    private fun speakerphone(context: Context, on: Boolean) {
        try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = on
        } catch (e: Exception) {
            logger("[HFP] speakerphone($on) failed: ${e.javaClass.simpleName}")
        }
    }

    private fun device(mac: String?): BluetoothDevice? = try {
        mac?.let { adapter()?.getRemoteDevice(it) }
    } catch (e: Exception) { null }

    private fun name(d: BluetoothDevice): String = d.name ?: d.address

    /**
     * Is this device actually here — powered on, with a live ACL link?
     *
     * Bonded is not present. The router once picked a paired earbud that was
     * switched off and sat in STATE_CONNECTING for the full timeout, blocking
     * the hand-back for six seconds and leaving a pending attempt that could
     * have completed later and taken the slot unasked.
     *
     * `isConnected` is @hide but, like the rest of what this file uses, is
     * reachable on API 27. If it is not, saying "not present" is the safe
     * answer: the caller falls back to the device speaker, which always works.
     */
    private fun isPresent(d: BluetoothDevice): Boolean = try {
        BluetoothDevice::class.java.getMethod("isConnected").invoke(d) as? Boolean ?: false
    } catch (e: Exception) {
        false
    }

    // --------------------------------------------------------------- the lever

    private fun invoke(method: String, hs: BluetoothHeadset, d: BluetoothDevice): Boolean = try {
        val m = BluetoothHeadset::class.java.getMethod(method, BluetoothDevice::class.java)
        m.isAccessible = true
        m.invoke(hs, d) as? Boolean ?: false
    } catch (e: Exception) {
        false
    }

    /**
     * Ask for a state change and wait for it to actually land.
     *
     * The reflective call returns true meaning "request accepted", not "done" —
     * the SLC takes a second or two either way. Returning early would let the
     * caller arm the board before it can hear anything, so we poll.
     */
    private fun await(
        hs: BluetoothHeadset,
        d: BluetoothDevice,
        want: Int,
    ): Boolean {
        if (hs.getConnectionState(d) == want) return true
        val method = if (want == BluetoothProfile.STATE_CONNECTED) "connect" else "disconnect"
        if (!invoke(method, hs, d)) {
            // A disconnect on a device that has already gone (board powered
            // off, out of range) fails here and is not a problem.
            logger("[HFP] $method(${name(d)}) refused" +
                if (isPresent(d)) " by the stack" else " — device is not present")
            return false
        }
        val deadline = System.currentTimeMillis() + SETTLE_MS
        while (System.currentTimeMillis() < deadline) {
            if (hs.getConnectionState(d) == want) {
                logger("[HFP] ${name(d)} -> ${if (want == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected"}")
                return true
            }
            try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) { return false }
        }
        logger("[HFP] ${name(d)} did not reach $method within ${SETTLE_MS}ms " +
            "(state ${hs.getConnectionState(d)})")
        // Leave nothing pending. A connect still in STATE_CONNECTING can land
        // minutes later and take the slot from whoever holds it by then.
        if (want == BluetoothProfile.STATE_CONNECTED) invoke("disconnect", hs, d)
        return false
    }

    // ------------------------------------------------------------ user headset

    /**
     * The earbud to hand the slot back to.
     *
     * Preference order: whoever we displaced, then whatever is playing media
     * right now (A2DP-connected is the strongest signal that it is on the user's
     * ear), then any bonded audio device that is not the board. Never the board.
     */
    private fun userHeadset(context: Context): BluetoothDevice? {
        val bridge = bridgeMac
        displaced?.let { mac ->
            if (!mac.equals(bridge, ignoreCase = true)) {
                device(mac)?.let { if (isPresent(it)) return it }
            }
        }
        // A2DP-connected is the strongest evidence an earbud is on someone's
        // ear. There is deliberately no "any bonded audio device" fallback
        // below this: that was a guess, and it cost six seconds and picked the
        // wrong earbud. No candidate means the device speaker, immediately.
        return (proxy(context, BluetoothProfile.A2DP) as? BluetoothA2dp)
            ?.connectedDevices
            ?.firstOrNull { !it.address.equals(bridge, ignoreCase = true) }
    }

    // ------------------------------------------------------------------- API

    /**
     * Give the HFP slot to the board, so bridged call audio goes over its SCO.
     *
     * Anything else holding the slot is disconnected first, which also removes
     * the earbud's ability to interfere: with no SLC it never receives RING and
     * cannot send ATA to steal the audio mid-call.
     */
    fun acquireForBridge(context: Context) = exec.execute {
        try {
            val board = device(bridgeMac) ?: run {
                logger("[HFP] no bridge address known — leaving routing alone"); return@execute
            }
            val hs = proxy(context, BluetoothProfile.HEADSET) as? BluetoothHeadset ?: run {
                logger("[HFP] headset proxy unavailable — leaving routing alone"); return@execute
            }

            val others = hs.connectedDevices.filter { !it.address.equals(bridgeMac, ignoreCase = true) }
            if (others.isEmpty() && hs.getConnectionState(board) == BluetoothProfile.STATE_CONNECTED) {
                logger("[HFP] board already holds the slot")
                ownsCallAudio = true
                return@execute
            }
            for (d in others) {
                displaced = d.address
                logger("[HFP] freeing the slot from ${name(d)}")
                await(hs, d, BluetoothProfile.STATE_DISCONNECTED)
            }
            // Connecting last is what makes the board latest_connected_idx, which
            // is what startBluetoothSco() will pick.
            await(hs, board, BluetoothProfile.STATE_CONNECTED)
            ownsCallAudio = true
            logger("[HFP] call audio routed to the bridge")
        } catch (e: Exception) {
            logger("[HFP] acquire failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Hand the slot back to the user's earbud (or to nobody, which leaves the
     * device's own speaker and mic — still a working route).
     *
     * Called when a bridged call ends, so the agent can talk to the wearer again.
     */
    fun releaseToUser(context: Context) = exec.execute {
        ownsCallAudio = false
        try {
            val hs = proxy(context, BluetoothProfile.HEADSET) as? BluetoothHeadset ?: run {
                logger("[HFP] headset proxy unavailable — cannot hand the slot back"); return@execute
            }
            device(bridgeMac)?.let { board ->
                if (hs.getConnectionState(board) != BluetoothProfile.STATE_DISCONNECTED) {
                    logger("[HFP] releasing the slot from the bridge")
                    await(hs, board, BluetoothProfile.STATE_DISCONNECTED)
                }
            }
            val ear = userHeadset(context)
            val landed = ear != null && await(hs, ear, BluetoothProfile.STATE_CONNECTED)
            if (landed) {
                logger("[HFP] call audio routed to ${name(ear!!)}")
                if (callActive) speakerphone(context, false)
            } else {
                if (ear == null) {
                    logger("[HFP] no user headset — audio falls back to the device")
                } else {
                    logger("[HFP] ${name(ear)} would not take the slot" +
                        " — audio falls back to the device")
                }
                // "Falls back to the device" was only ever true for the mic. The
                // caller could hear the wearer and the wearer heard nothing,
                // because with no headset a call defaults to the earpiece.
                if (callActive) {
                    speakerphone(context, true)
                    logger("[HFP] call handed to the device speaker")
                }
            }
            displaced = null
        } catch (e: Exception) {
            logger("[HFP] release failed: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /** One line for the logs: who holds the slot, and is SCO up on it. */
    fun describe(context: Context) = exec.execute {
        val hs = proxy(context, BluetoothProfile.HEADSET) as? BluetoothHeadset
        if (hs == null) { logger("[HFP] proxy unavailable"); return@execute }
        val devs = hs.connectedDevices
        if (devs.isEmpty()) logger("[HFP] slot: empty (device speaker/mic)")
        else devs.forEach {
            logger("[HFP] slot: ${name(it)} audio=${if (hs.isAudioConnected(it)) "ON" else "off"}" +
                if (it.address.equals(bridgeMac, ignoreCase = true)) " (bridge)" else "")
        }
    }
}
