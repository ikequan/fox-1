package ai.fox1.services

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.atomic.AtomicInteger

class Fox1AccessibilityService : AccessibilityService() {

    companion object {
        var instance: Fox1AccessibilityService? = null
        private var nodeMap = mutableMapOf<Int, AccessibilityNodeInfo>()
        private const val MAX_NODES = 500
        private const val MAX_DEPTH = 15
        private val mainHandler = Handler(Looper.getMainLooper())

        /// True when the user has FOX-1 switched on in Android's accessibility
        /// settings. This is the authoritative check — [instance] only reports
        /// whether the system has bound the service in the *current* process,
        /// which is false for a window after every process start (including boot,
        /// where the launcher activity starts before accessibility services bind).
        fun isEnabledInSettings(context: Context): Boolean {
            val resolver = context.contentResolver
            val globallyOn = try {
                Settings.Secure.getInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0)
            } catch (_: Exception) { 0 }
            if (globallyOn == 0) return false

            val enabled = try {
                Settings.Secure.getString(
                    resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
                )
            } catch (_: Exception) { null } ?: return false

            val expected = ComponentName(context, Fox1AccessibilityService::class.java)
            // Colon-separated, and entries may use either the full or the
            // leading-dot short form; unflattenFromString normalizes both.
            return enabled.split(':').any {
                ComponentName.unflattenFromString(it.trim()) == expected
            }
        }

        /// Whether the system has actually bound the service in this process.
        fun isBound(): Boolean = instance != null

        fun getScreenTree(): Map<String, Any?>? {
            val service = instance ?: return null
            val root = service.rootInActiveWindow ?: return null

            // Read before the node can be recycled below.
            val pkg = root.packageName?.toString() ?: ""

            // Retire the previous generation. nodeMap owns these exclusively —
            // clearing without recycling leaks pooled native node objects, and
            // getScreen runs after every agent action.
            recycleNodeMap()

            val counter = AtomicInteger(0)
            val nodes = mutableListOf<Map<String, Any?>>()
            if (!serializeNode(root, counter, 0, nodes)) recycleNode(root)

            val activity = try {
                val windows = service.windows
                val title = windows.firstOrNull { it.isActive }?.title?.toString() ?: ""
                windows.forEach { window ->
                    try { @Suppress("DEPRECATION") window.recycle() } catch (_: Exception) {}
                }
                title
            } catch (_: Exception) { "" }

            return mapOf(
                "package" to pkg,
                "activity" to activity,
                "node_count" to nodes.size,
                "nodes" to nodes
            )
        }

        @Suppress("DEPRECATION")
        private fun recycleNode(node: AccessibilityNodeInfo) {
            // No-op on API 33+, where node pooling was removed. Still required on
            // the older platforms this app targets.
            try { node.recycle() } catch (_: Exception) {}
        }

        private fun recycleNodeMap() {
            for (node in nodeMap.values) recycleNode(node)
            nodeMap.clear()
        }

        /// Serializes [node] into [out]. The caller transfers ownership: a `true`
        /// return means the node was stored in [nodeMap] and must not be recycled,
        /// `false` means the caller is responsible for recycling it.
        private fun serializeNode(
            node: AccessibilityNodeInfo,
            counter: AtomicInteger,
            depth: Int,
            out: MutableList<Map<String, Any?>>
        ): Boolean {
            if (depth > MAX_DEPTH || counter.get() >= MAX_NODES) return false

            val id = counter.getAndIncrement()

            val bounds = Rect()
            node.getBoundsInScreen(bounds)

            val text = node.text?.toString()
            val desc = node.contentDescription?.toString()
            val cls = node.className?.toString()?.substringAfterLast('.') ?: ""

            // Collect children first
            val children = mutableListOf<Map<String, Any?>>()
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                val kept = counter.get() < MAX_NODES &&
                    serializeNode(child, counter, depth + 1, children)
                if (!kept) recycleNode(child)
            }

            // Skip empty non-interactive containers to keep tree small
            if (text == null && desc == null && !node.isClickable
                && !node.isScrollable && !node.isEditable && children.isEmpty()) {
                return false
            }

            // Only retained nodes enter nodeMap, so every id the model can see in
            // [out] resolves in tapByNodeId, and pruned nodes are freed at once.
            nodeMap[id] = node

            val entry = mutableMapOf<String, Any?>("id" to id, "class" to cls)
            if (text != null) entry["text"] = text
            if (desc != null) entry["description"] = desc
            entry["bounds"] = mapOf(
                "left" to bounds.left, "top" to bounds.top,
                "right" to bounds.right, "bottom" to bounds.bottom
            )
            if (node.isClickable) entry["clickable"] = true
            if (node.isScrollable) entry["scrollable"] = true
            if (node.isEditable) entry["editable"] = true
            if (node.isFocused) entry["focused"] = true
            if (children.isNotEmpty()) entry["children"] = children

            out.add(entry)
            return true
        }

        /**
         * A cheap hash of what is currently on screen: package plus every text
         * and content-description in the tree.
         *
         * Deliberately does NOT touch nodeMap, so it can be sampled before and
         * after an interaction without invalidating the node ids the agent is
         * holding. Comparing the two tells us whether a tap actually did
         * anything — performAction() returning true only means the action was
         * accepted, not that it had any effect.
         */
        fun getScreenSignature(): String? {
            val service = instance ?: return null
            val root = service.rootInActiveWindow ?: return null
            val sb = StringBuilder()
            sb.append(root.packageName ?: "").append('#')
            appendSignature(root, sb, 0)
            recycleNode(root)
            return sb.toString().hashCode().toString()
        }

        private fun appendSignature(
            node: AccessibilityNodeInfo,
            sb: StringBuilder,
            depth: Int
        ) {
            if (depth > MAX_DEPTH) return
            node.text?.let { sb.append(it).append('|') }
            node.contentDescription?.let { sb.append(it).append('|') }
            if (node.isChecked) sb.append("chk|")
            if (node.isSelected) sb.append("sel|")
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                appendSignature(child, sb, depth + 1)
                recycleNode(child)
            }
        }

        fun tapByNodeId(nodeId: Int): Boolean {
            val node = nodeMap[nodeId] ?: return false
            var target: AccessibilityNodeInfo? = node
            while (target != null && !target.isClickable) {
                target = target.parent
            }
            return target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) ?: false
        }

        fun tapByText(text: String): Boolean {
            val service = instance ?: return false
            val root = service.rootInActiveWindow ?: return false
            val nodes = root.findAccessibilityNodeInfosByText(text)
            if (nodes.isNullOrEmpty()) return false
            var target = nodes[0]
            while (!target.isClickable) {
                val parent = target.parent ?: break
                target = parent
            }
            return target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }

        fun tapAtCoordinates(x: Float, y: Float, callback: (Boolean) -> Unit) {
            val service = instance
            if (service == null) { callback(false); return }
            val path = Path().apply { moveTo(x, y) }
            val stroke = GestureDescription.StrokeDescription(path, 0, 50)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            service.dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(g: GestureDescription) { callback(true) }
                override fun onCancelled(g: GestureDescription) { callback(false) }
            }, mainHandler)
        }

        fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long, callback: (Boolean) -> Unit) {
            val service = instance
            if (service == null) { callback(false); return }
            val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
            val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            service.dispatchGesture(gesture, object : GestureResultCallback() {
                override fun onCompleted(g: GestureDescription) { callback(true) }
                override fun onCancelled(g: GestureDescription) { callback(false) }
            }, mainHandler)
        }

        fun typeText(text: String): Boolean {
            val service = instance ?: return false
            val root = service.rootInActiveWindow ?: return false
            val target = findNode(root) { it.isFocused && it.isEditable }
                ?: findNode(root) { it.isEditable }
                ?: return false
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            return target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        }

        fun pressBack(): Boolean =
            instance?.performGlobalAction(GLOBAL_ACTION_BACK) ?: false

        fun pressHome(): Boolean =
            instance?.performGlobalAction(GLOBAL_ACTION_HOME) ?: false

        fun scroll(direction: String, nodeId: Int?, callback: (Boolean) -> Unit) {
            // Try node-based scroll first
            val scrollNode = if (nodeId != null) nodeMap[nodeId] else {
                val root = instance?.rootInActiveWindow
                if (root != null) findNode(root) { it.isScrollable } else null
            }
            if (scrollNode != null && scrollNode.isScrollable) {
                val action = if (direction == "down" || direction == "right")
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                callback(scrollNode.performAction(action))
                return
            }
            // Fallback: swipe gesture (490x580 screen)
            val cx = 245f; val cy = 290f; val d = 200f
            val (sx, sy, ex, ey) = when (direction) {
                "down" -> listOf(cx, cy + d, cx, cy - d)
                "up" -> listOf(cx, cy - d, cx, cy + d)
                "right" -> listOf(cx + d, cy, cx - d, cy)
                "left" -> listOf(cx - d, cy, cx + d, cy)
                else -> { callback(false); return }
            }
            swipe(sx, sy, ex, ey, 300, callback)
        }

        private fun findNode(
            root: AccessibilityNodeInfo,
            predicate: (AccessibilityNodeInfo) -> Boolean
        ): AccessibilityNodeInfo? {
            if (predicate(root)) return root
            for (i in 0 until root.childCount) {
                val child = root.getChild(i) ?: continue
                val found = findNode(child, predicate)
                if (found != null) return found
            }
            return null
        }
    }

    override fun onCreate() { super.onCreate(); instance = this }
    override fun onDestroy() { super.onDestroy(); instance = null; recycleNodeMap() }

    // Connected: the wearer switched it on. Unbound while FOX-1 is running:
    // they switched it off — a force-stop kills the process without this call.
    // AccessibilityKeeper restores it only while wanted.
    override fun onServiceConnected() {
        super.onServiceConnected()
        AccessibilityKeeper.setWanted(this, true)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        AccessibilityKeeper.setWanted(this, false)
        return super.onUnbind(intent)
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}
}
