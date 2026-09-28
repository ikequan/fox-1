package ai.fox1

import android.os.Build
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import ai.fox1.channels.AudioChannel
import ai.fox1.channels.HfpProbeChannel
import ai.fox1.channels.PhoneRingChannel
import ai.fox1.channels.RingBleChannel
import ai.fox1.channels.RingInputChannel
import ai.fox1.channels.InstalledAppsChannel
import ai.fox1.channels.NotificationListenerChannel
import ai.fox1.channels.QuickSettingsChannel
import ai.fox1.channels.AlarmChannel
import ai.fox1.channels.AudioPlayChannel
import ai.fox1.channels.CallAudioChannel
import ai.fox1.channels.CallBridgeChannel
import ai.fox1.channels.InCallChannel
import ai.fox1.channels.HotspotChannel
import ai.fox1.channels.PhoneChannel
import ai.fox1.channels.ScreenAutomationChannel
import ai.fox1.channels.SystemActionsChannel

class MainActivity : FlutterActivity() {
    // Every time FOX-1 comes to the front — which, as the home app, is also
    // what happens after a force-stop or an update — put accessibility back if
    // the system dropped it (see AccessibilityKeeper).
    override fun onResume() {
        super.onResume()
        ai.fox1.services.AccessibilityKeeper.restoreIfWanted(this)
        // And stay off the watch's own app killer (see CleanerWhitelist).
        ai.fox1.services.CleanerWhitelist.ensure(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AlarmChannel.register(flutterEngine, this)
        AudioChannel.register(flutterEngine, this)
        AudioPlayChannel.register(flutterEngine)
        CallAudioChannel.register(flutterEngine)
        CallBridgeChannel.register(flutterEngine, this)
        InstalledAppsChannel.register(flutterEngine, this)
        NotificationListenerChannel.register(flutterEngine, this)
        QuickSettingsChannel.register(flutterEngine, this)
        SystemActionsChannel.register(flutterEngine, this)
        HotspotChannel.register(flutterEngine, this)
        HfpProbeChannel.register(flutterEngine, this)
        InCallChannel.register(flutterEngine, this)
        PhoneChannel.register(flutterEngine, this)
        PhoneRingChannel.register(flutterEngine, this)
        RingInputChannel.register(flutterEngine, this)
        RingBleChannel.register(flutterEngine, this)
        ScreenAutomationChannel.register(flutterEngine, this)
    }

    // A copy of every input event goes to the ring test screen, then the
    // system handles it exactly as before. See RingInputChannel.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        RingInputChannel.onKey(event)
        return super.dispatchKeyEvent(event)
    }

    // Touches too: the ring injects its taps and swipes as pointer input.
    // Consumed only for the ring's own device, and only while the ring test
    // screen has asked — the wearer's finger always goes through.
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (RingInputChannel.onTouch(ev)) return true
        return super.dispatchTouchEvent(ev)
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        RingInputChannel.onMotion(ev)
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            enforceImmersive()
        }
    }

    private fun enforceImmersive() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            )
        }
    }
}
