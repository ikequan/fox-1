package ai.fox1.channels

import android.app.Activity
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import ai.fox1.services.Fox1AccessibilityService

object ScreenAutomationChannel {
    private const val CHANNEL = "ai.fox1/screen_automation"

    /**
     * Why a gesture or read failed, in words the model can act on.
     *
     * Only getScreen used to say this; every other tool returned a bare
     * success=false with no error key, which reached the agent as "FAILED:
     * null". The commonest cause by far is the accessibility service being
     * switched off, and that is exactly the thing a user can fix if told.
     */
    private fun whyFailed(activity: Activity, otherwise: String): String = when {
        !Fox1AccessibilityService.isEnabledInSettings(activity) ->
            "Accessibility service is disabled — enable FOX-1 under Android accessibility settings"
        // Enabled but not yet bound in this process: transient, worth retrying.
        !Fox1AccessibilityService.isBound() ->
            "Accessibility service is enabled but not bound yet — retry in a moment"
        else -> otherwise
    }

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isServiceEnabled" -> {
                        result.success(Fox1AccessibilityService.isEnabledInSettings(activity))
                    }
                    "getServiceStatus" -> {
                        result.success(mapOf<String, Any>(
                            "enabled" to Fox1AccessibilityService.isEnabledInSettings(activity),
                            "bound" to Fox1AccessibilityService.isBound()
                        ))
                    }
                    "keepStatus" -> result.success(mapOf(
                        "granted" to ai.fox1.services.AccessibilityKeeper.canKeep(activity),
                        "wanted" to ai.fox1.services.AccessibilityKeeper.wanted(activity),
                        "restored" to ai.fox1.services.AccessibilityKeeper.restoreIfWanted(activity),
                    ))
                    "openAccessibilitySettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            activity.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "getScreenSignature" -> {
                        result.success(Fox1AccessibilityService.getScreenSignature())
                    }
                    "getScreen" -> {
                        val tree = Fox1AccessibilityService.getScreenTree()
                        if (tree != null) {
                            result.success(mapOf<String, Any>("success" to true, "screen" to tree))
                        } else {
                            result.success(mapOf<String, Any>(
                                "success" to false,
                                "error" to whyFailed(activity, "No active window to read")))
                        }
                    }
                    "tap" -> {
                        val nodeId = call.argument<Int>("node_id")
                        val text = call.argument<String>("text")
                        val x = call.argument<Double>("x")
                        val y = call.argument<Double>("y")

                        when {
                            nodeId != null -> {
                                val ok = Fox1AccessibilityService.tapByNodeId(nodeId)
                                result.success(mapOf<String, Any>("success" to ok,
                                    "result" to if (ok) "Tapped node $nodeId" else "Node $nodeId not found or not clickable"))
                            }
                            text != null -> {
                                val ok = Fox1AccessibilityService.tapByText(text)
                                result.success(mapOf<String, Any>("success" to ok,
                                    "result" to if (ok) "Tapped '$text'" else "Text '$text' not found"))
                            }
                            x != null && y != null -> {
                                Fox1AccessibilityService.tapAtCoordinates(x.toFloat(), y.toFloat()) { ok ->
                                    result.success(mapOf<String, Any>("success" to ok,
                                        "result" to if (ok) "Tapped at ($x, $y)" else "Tap gesture failed"))
                                }
                            }
                            else -> {
                                result.success(mapOf<String, Any>("success" to false, "error" to "Provide node_id, text, or x/y coordinates"))
                            }
                        }
                    }
                    "swipe" -> {
                        val x1 = call.argument<Double>("x1")?.toFloat() ?: 0f
                        val y1 = call.argument<Double>("y1")?.toFloat() ?: 0f
                        val x2 = call.argument<Double>("x2")?.toFloat() ?: 0f
                        val y2 = call.argument<Double>("y2")?.toFloat() ?: 0f
                        val duration = call.argument<Int>("duration_ms")?.toLong() ?: 300L

                        Fox1AccessibilityService.swipe(x1, y1, x2, y2, duration) { ok ->
                            result.success(mapOf<String, Any>("success" to ok,
                                "result" to if (ok) "Swiped" else "Swipe gesture failed"))
                        }
                    }
                    "typeText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val ok = Fox1AccessibilityService.typeText(text)
                        result.success(if (ok)
                            mapOf<String, Any>("success" to true, "result" to "Typed text")
                        else
                            mapOf<String, Any>("success" to false,
                                "error" to whyFailed(activity, "No editable field found")))
                    }
                    "pressBack" -> {
                        val ok = Fox1AccessibilityService.pressBack()
                        result.success(if (ok)
                            mapOf<String, Any>("success" to true, "result" to "Back pressed")
                        else
                            mapOf<String, Any>("success" to false,
                                "error" to whyFailed(activity, "Back press had no effect")))
                    }
                    "pressHome" -> {
                        val ok = Fox1AccessibilityService.pressHome()
                        result.success(if (ok)
                            mapOf<String, Any>("success" to true, "result" to "Home pressed")
                        else
                            mapOf<String, Any>("success" to false,
                                "error" to whyFailed(activity, "Home press had no effect")))
                    }
                    "scroll" -> {
                        val direction = call.argument<String>("direction") ?: "down"
                        val nodeId = call.argument<Int>("node_id")
                        Fox1AccessibilityService.scroll(direction, nodeId) { ok ->
                            result.success(if (ok)
                                mapOf<String, Any>("success" to true,
                                    "result" to "Scrolled $direction")
                            else
                                mapOf<String, Any>("success" to false,
                                    "error" to whyFailed(activity, "Scroll failed")))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
