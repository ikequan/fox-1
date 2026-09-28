package ai.fox1.channels

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Work that must not run on the main thread.
 *
 * The main thread also delivers the display's frame timing to Flutter and
 * runs the accessibility service. Anything slow there freezes the launcher:
 * rendering every app icon stalled the swipe to the app list, and a Bluetooth
 * connect to an absent board froze the app for 20 s — long enough for the
 * stock launcher's charging screen to stay up.
 */
object Background {
    private val main = Handler(Looper.getMainLooper())

    /// Reading and acting on other apps' screens. One thread, so reads and
    /// taps keep their order and the node ids stay consistent.
    val screen: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "fox1-screen") }

    /// Package, icon and contact queries.
    val io: ExecutorService = Executors.newSingleThreadExecutor { Thread(it, "fox1-io") }

    fun onMain(block: () -> Unit) { main.post(block) }

    /// Runs [work] on [on]; its [MethodChannel.Result] answers on the main
    /// thread, as Flutter requires, and an exception becomes an error reply.
    fun run(on: ExecutorService, result: MethodChannel.Result, work: (MethodChannel.Result) -> Unit) {
        val r = MainThreadResult(result)
        on.execute {
            try { work(r) } catch (e: Exception) { r.error("ERROR", e.message, null) }
        }
    }
}

/// A [MethodChannel.Result] that may be answered from any thread.
class MainThreadResult(private val r: MethodChannel.Result) : MethodChannel.Result {
    private val main = Handler(Looper.getMainLooper())
    override fun success(result: Any?) { main.post { r.success(result) } }
    override fun error(code: String, message: String?, details: Any?) { main.post { r.error(code, message, details) } }
    override fun notImplemented() { main.post { r.notImplemented() } }
}
