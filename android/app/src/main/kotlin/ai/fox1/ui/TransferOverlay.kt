package ai.fox1.ui

import android.content.Context
import android.graphics.Color
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The hand-over prompt, drawn on top of whatever owns the screen.
 *
 * Two other approaches were tried on this device and both failed for the same
 * underlying reason — during a call the vendor's in-call UI owns the display:
 *
 *  - **A Flutter overlay inside our own MaterialApp.** Correct widget tree,
 *    drawn into a window nobody can see. FOX-1 is not foreground.
 *  - **A full-screen-intent notification.** Only launches an activity when the
 *    screen is off or locked; awake it degrades to a heads-up, and this device's
 *    dialer does not let the shade be pulled down at all.
 *
 * A window from WindowManager is the one thing that genuinely sits above
 * another app. It costs a one-time "draw over other apps" grant, which is the
 * honest price for a prompt that has to interrupt a live call.
 *
 * Deliberately a plain Android view, not Flutter: the engine belongs to an
 * activity that is in the background at this moment, and reaching into it from
 * here would put us back where we started.
 */
object TransferOverlay {

    private var view: View? = null

    fun canShow(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(context)

    /** Send the user to grant it. One tap, once. */
    fun requestPermission(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            context.startActivity(
                android.content.Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    android.net.Uri.parse("package:${context.packageName}")
                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
        }
    }

    fun show(context: Context, who: String, onAction: (String) -> Unit): Boolean {
        if (!canShow(context)) return false
        hide(context)
        return try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val root = build(context, who, onAction)
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                type,
                // Focusable: the buttons have to be tappable. Not
                // NOT_TOUCH_MODAL — taps outside must not reach the dialer's
                // hang-up button by accident.
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                android.graphics.PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.CENTER }
            wm.addView(root, lp)
            view = root
            true
        } catch (e: Exception) {
            false
        }
    }

    fun hide(context: Context) {
        val v = view ?: return
        view = null
        try {
            (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .removeView(v)
        } catch (_: Exception) {
        }
    }

    private fun dp(context: Context, v: Int) =
        (v * context.resources.displayMetrics.density).toInt()

    private fun build(
        context: Context,
        who: String,
        onAction: (String) -> Unit,
    ): View = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setBackgroundColor(Color.parseColor("#F00A0A0F"))
        setPadding(dp(context, 14), dp(context, 10), dp(context, 14), dp(context, 10))

        addView(TextView(context).apply {
            text = "ON THE LINE"
            setTextColor(Color.parseColor("#00E5CC"))
            textSize = 10f
            gravity = Gravity.CENTER
            letterSpacing = 0.18f
        })
        addView(TextView(context).apply {
            text = who
            setTextColor(Color.WHITE)
            textSize = 18f
            maxLines = 2
            gravity = Gravity.CENTER
            setPadding(0, dp(context, 6), 0, dp(context, 14))
        })
        addView(Button(context).apply {
            text = "Take call"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#00C853"))
            setOnClickListener { onAction("take") }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(context, 46))
        })
        addView(Button(context).apply {
            text = "Back to agent"
            setTextColor(Color.parseColor("#B0FFFFFF"))
            setBackgroundColor(Color.parseColor("#2A2A35"))
            setOnClickListener { onAction("back") }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(context, 40)
            ).apply { topMargin = dp(context, 8) }
        })
    }
}
