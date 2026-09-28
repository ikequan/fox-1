package ai.fox1.services

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
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

        /// The window in front, or null — never a crash. Android throws from
        /// inside other apps here: reading the stock launcher while its widget
        /// host was busy raised a NullPointerException from AppWidgetService,
        /// and, uncaught on the main thread, it killed FOX-1 twice in a row
        /// and left the stock launcher on screen.
        private fun AccessibilityService.safeRoot(): AccessibilityNodeInfo? =
            try { rootInActiveWindow } catch (e: Exception) {
                android.util.Log.w("FOX1", "could not read the screen: $e"); null
            }

        /// The raw nested tree. The model no longer gets this (it reads
        /// [getCompactScreen]); kept for the Hub's developer comparison.
        fun getScreenTree(): Map<String, Any?>? {
            val service = instance ?: return null
            val root = service.safeRoot() ?: return null

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

        /**
         * The screen as the model reads it (`get_screen`) — flat lines, ids
         * only on what can be acted on, text merged into the row it belongs
         * to, nothing invisible. About a seventh of the size of the raw tree
         * ([getScreenTree]), and it stays in the conversation, billed again on
         * every later turn.
         *
         *     com.whatsapp/HomeActivity · 320×385
         *     "Chats"
         *     [1] tap "Kofi · Hey, see you at 5 · 10:42"
         *     [2] tap (icon, top-right)
         *     [3] input "Search…" (hint) focused
         *
         * With [keep] the `[n]` nodes become the new [nodeMap] — the ids
         * `tap` and `scroll` take — and the previous ones are retired. Without
         * it nothing is kept, so a background check (waiting for an app or a
         * screen watch) never renumbers the ids the model is holding.
         */
        fun getCompactScreen(keep: Boolean = true): String? {
            val service = instance ?: return null
            val root = service.safeRoot() ?: return null
            if (keep) recycleNodeMap()
            // The display, not the window: a dialog's window is smaller than
            // the screen the model's pixel coordinates refer to.
            val dm = service.resources.displayMetrics
            val screen = Rect(0, 0, dm.widthPixels, dm.heightPixels)
            val pkg = root.packageName?.toString() ?: ""
            val windows = try { service.windows } catch (_: Exception) { emptyList<AccessibilityWindowInfo>() }
            val title = windows.firstOrNull { it.isActive }?.title?.toString() ?: ""
            val above = windowsAbove(windows, screen)
            val appLabel = try {
                service.packageManager.getApplicationLabel(service.packageManager.getApplicationInfo(pkg, 0)).toString()
            } catch (_: Exception) { "" }
            val out = StringBuilder(pkg)
            if (lastActivityPkg == pkg && lastActivity.isNotEmpty()) out.append('/').append(lastActivity)
            // The window title adds something only when it is not just the app's
            // name: a dialog ("Google storage backup"), a conversation ("MTN").
            if (title.isNotEmpty() && title != appLabel) out.append(" · \"").append(clip(title, LABEL_MAX)).append('"')
            // The size, so tap and swipe coordinates (pixels) have something to go on.
            out.append(" · ").append(screen.width()).append('×').append(screen.height())
            out.append('\n')
            val next = AtomicInteger(1)
            // Top first. Each window is read with only what lies above it
            // covering it, and the app last.
            val covering = mutableListOf<Rect>()
            for (w in above) {
                val r = Rect().also { w.getBoundsInScreen(it) }
                if (w.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) {
                    val whole = r.height() * 10 >= screen.height() * 9
                    out.append(if (whole) "(keyboard open, covering the whole screen — press_enter submits, press_back hides it)\n"
                               else "(keyboard open over the bottom of the screen — press_enter submits, press_back hides it)\n")
                } else {
                    val wRoot = w.root
                    if (wRoot != null) {
                        val label = w.title?.toString()?.takeIf { it.isNotBlank() && it != "Pop-Up Window" }
                        out.append("— on top").append(if (label != null) ": \"${clip(label, LABEL_MAX)}\"" else "").append(" —\n")
                        occluders = covering.toList()
                        if (!compactNode(wRoot, screen, next, out, 0, keep)) recycleNode(wRoot)
                        out.append("— under it —\n")
                    }
                }
                covering.add(r)
            }
            occluders = covering.toList()
            if (!compactNode(root, screen, next, out, 0, keep)) recycleNode(root)
            occluders = emptyList()
            windows.forEach { w -> try { @Suppress("DEPRECATION") w.recycle() } catch (_: Exception) {} }
            if (out.length >= COMPACT_MAX_CHARS || next.get() > COMPACT_MAX_IDS) {
                out.append("… more on screen — scroll to see it\n")
            }
            return out.toString().trimEnd()
        }

        /**
         * The windows drawn over the app, top first: its drop-downs, pop-up
         * menus and dialogs (their own windows, never the active one), other
         * apps' overlays, and the keyboard. Unread, a contact picker's
         * filtered list was invisible to the agent, and on a small watch the
         * keyboard covers the whole app while its tree still reads as tappable.
         * Specks (a 1×1 system window) are left out.
         */
        private fun windowsAbove(windows: List<AccessibilityWindowInfo>, screen: Rect): List<AccessibilityWindowInfo> {
            val active = windows.indexOfFirst { it.isActive }
            if (active <= 0) return emptyList()
            val minArea = screen.width() * screen.height() / 20
            return windows.subList(0, active).filter { w ->
                val r = Rect().also { w.getBoundsInScreen(it) }
                r.width() * r.height() >= minArea && when (w.type) {
                    AccessibilityWindowInfo.TYPE_APPLICATION,
                    AccessibilityWindowInfo.TYPE_SYSTEM,
                    AccessibilityWindowInfo.TYPE_INPUT_METHOD -> true
                    else -> false
                }
            }
        }

        /// Rects of the windows above the one being read; a node wholly
        /// inside one of them cannot be seen or touched.
        private var occluders: List<Rect> = emptyList()

        @Volatile private var lastActivity = ""
        @Volatile private var lastActivityPkg = ""
        private val activityClasses = java.util.concurrent.ConcurrentHashMap<String, Boolean>()

        private const val LABEL_MAX = 80
        private const val TEXT_MAX = 300
        // A runaway list (a settings page, a long feed) stops here.
        private const val COMPACT_MAX_CHARS = 8000
        private const val COMPACT_MAX_IDS = 150

        private fun full(out: StringBuilder, next: AtomicInteger) =
            out.length >= COMPACT_MAX_CHARS || next.get() > COMPACT_MAX_IDS

        private fun ownText(n: AccessibilityNodeInfo): String {
            val t = n.text?.toString()?.trim().orEmpty()
            if (t.isNotEmpty()) return t
            val d = n.contentDescription?.toString()?.trim().orEmpty()
            if (d.isNotEmpty()) return d
            return if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim().orEmpty() else ""
        }

        private fun interactive(n: AccessibilityNodeInfo) =
            n.isClickable || n.isLongClickable || n.isEditable || n.isScrollable || n.isCheckable

        /// On screen by position, not by isVisibleToUser: Compose and animated
        /// views report false while plainly showing. Spotify's now-playing
        /// bar and its Pause button were dropped that way, and the helper kept
        /// tapping Play on a podcast that was playing. A view scrolled or
        /// clipped out of sight still goes: its bounds come back empty or off
        /// the screen.
        private fun visible(n: AccessibilityNodeInfo, screen: Rect): Boolean {
            val r = Rect().also { n.getBoundsInScreen(it) }
            return !r.isEmpty && Rect.intersects(r, screen) && occluders.none { it.contains(r) }
        }

        /**
         * The text of a row's non-interactive descendants, for merging into it.
         *
         * The row is visible; its parts need not be. A row peeking in at the
         * bottom edge has its lines below the screen, and they are what tells
         * the model which row it is — a contact picker's last row showed only
         * "Emmanuel", not the number the agent had typed, and it never found
         * the recipient.
         *
         * Text already said by the row (a description that repeats its lines)
         * is not said again.
         */
        private fun mergedText(n: AccessibilityNodeInfo, acc: LinkedHashSet<String>, depth: Int) {
            if (depth > MAX_DEPTH) return
            for (i in 0 until n.childCount) {
                val c = n.getChild(i) ?: continue
                if (!interactive(c)) {
                    val t = ownText(c)
                    if (t.isNotEmpty() && acc.none { it.contains(t) }) acc.add(t)
                    mergedText(c, acc, depth + 1)
                }
                recycleNode(c)
            }
        }

        private fun region(n: AccessibilityNodeInfo, screen: Rect): String {
            val r = Rect().also { n.getBoundsInScreen(it) }
            val v = when { r.centerY() < screen.height() / 3 -> "top"; r.centerY() > screen.height() * 2 / 3 -> "bottom"; else -> "middle" }
            val h = when { r.centerX() < screen.width() / 3 -> "left"; r.centerX() > screen.width() * 2 / 3 -> "right"; else -> "centre" }
            return "$v-$h"
        }

        private fun clip(s: String, max: Int) =
            s.replace('\n', ' ').let { if (it.length > max) it.take(max) + "…" else it }

        /// Writes [n] and what is under it. A `true` return means [n] was stored
        /// in [nodeMap] and the caller must not recycle it.
        private fun compactNode(n: AccessibilityNodeInfo, screen: Rect, next: AtomicInteger, out: StringBuilder, depth: Int, keep: Boolean): Boolean {
            if (depth > MAX_DEPTH || full(out, next)) return false
            if (!visible(n, screen)) return false
            val own = ownText(n)
            var kept = false
            if (interactive(n)) {
                val id = next.getAndIncrement()
                if (keep) { nodeMap[id] = n; kept = true }
                val role = when {
                    n.isEditable -> "input"
                    n.isCheckable -> if (n.isChecked) "check[x]" else "check[ ]"
                    n.isScrollable -> "scroll"
                    else -> "tap"
                }
                val line = StringBuilder("[$id] $role")
                if (n.isEditable) {
                    val value = n.text?.toString()?.trim().orEmpty()
                    val hint = if (Build.VERSION.SDK_INT >= 26) n.hintText?.toString()?.trim().orEmpty() else ""
                    when {
                        value.isNotEmpty() && value != hint -> line.append(" \"").append(clip(value, TEXT_MAX)).append('"')
                        hint.isNotEmpty() -> line.append(" \"").append(clip(hint, LABEL_MAX)).append("\" (hint)")
                        else -> line.append(" (").append(region(n, screen)).append(')')
                    }
                    if (n.isFocused) line.append(" focused")
                } else if (n.isScrollable) {
                    if (own.isNotEmpty()) line.append(" \"").append(clip(own, LABEL_MAX)).append('"')
                    else line.append(" (").append(region(n, screen)).append(')')
                } else {
                    val parts = LinkedHashSet<String>()
                    if (own.isNotEmpty()) parts.add(own)
                    mergedText(n, parts, depth + 1)
                    if (parts.isEmpty()) line.append(" (icon, ").append(region(n, screen)).append(')')
                    // Tap targets are often content — a message bubble, a chat
                    // preview — so they keep TEXT_MAX. Buttons are short anyway.
                    else line.append(" \"").append(clip(parts.joinToString(" · "), TEXT_MAX)).append('"')
                }
                if (n.isSelected) line.append(" sel")
                out.append(line).append('\n')
                if (!n.isScrollable) {
                    // Text is merged above; still walk for tappable elements inside the row.
                    emitInteractiveOnly(n, screen, next, out, depth + 1, keep)
                    return kept
                }
            } else if (own.isNotEmpty()) {
                out.append('"').append(clip(own, TEXT_MAX)).append("\"\n")
            }
            for (i in 0 until n.childCount) {
                val c = n.getChild(i) ?: continue
                if (!compactNode(c, screen, next, out, depth + 1, keep)) recycleNode(c)
            }
            return kept
        }

        private fun emitInteractiveOnly(n: AccessibilityNodeInfo, screen: Rect, next: AtomicInteger, out: StringBuilder, depth: Int, keep: Boolean) {
            if (depth > MAX_DEPTH || full(out, next)) return
            for (i in 0 until n.childCount) {
                val c = n.getChild(i) ?: continue
                var kept = false
                if (visible(c, screen)) {
                    if (interactive(c)) kept = compactNode(c, screen, next, out, depth, keep)
                    else emitInteractiveOnly(c, screen, next, out, depth + 1, keep)
                }
                if (!kept) recycleNode(c)
            }
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
            val root = service.safeRoot() ?: return null
            val sb = StringBuilder()
            sb.append(root.packageName ?: "").append('#')
            appendSignature(root, sb, 0)
            recycleNode(root)
            // And what is drawn over it: closing the keyboard or a drop-down
            // is a change, and was reported as none.
            try {
                val windows = service.windows
                val dm = service.resources.displayMetrics
                for (w in windowsAbove(windows, Rect(0, 0, dm.widthPixels, dm.heightPixels))) {
                    sb.append("|w").append(w.type)
                    w.root?.let { appendSignature(it, sb, 0); recycleNode(it) }
                }
                windows.forEach { w -> try { @Suppress("DEPRECATION") w.recycle() } catch (_: Exception) {} }
            } catch (_: Exception) {}
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

        /// Where a real touch on [nodeId] lands: the centre of the part of it
        /// that is on screen. For apps that ignore the accessibility click.
        fun nodeCenter(nodeId: Int): IntArray? {
            val node = nodeMap[nodeId] ?: return null
            node.refresh()
            val root = instance?.safeRoot() ?: return null
            val screen = Rect().also { root.getBoundsInScreen(it) }
            recycleNode(root)
            val r = Rect().also { node.getBoundsInScreen(it) }
            if (r.isEmpty || !r.intersect(screen)) return null
            return intArrayOf(r.centerX(), r.centerY())
        }

        fun tapByText(text: String): Boolean {
            val service = instance ?: return false
            val root = service.safeRoot() ?: return false
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

        /// Into the input [nodeId] names, else the focused one, else the first.
        fun typeText(text: String, nodeId: Int? = null): Boolean {
            val service = instance ?: return false
            val chosen = nodeId?.let { nodeMap[it] ?: return false }
            if (chosen != null && !chosen.isEditable) return false
            val root = service.safeRoot() ?: return false
            val target = chosen
                ?: findNode(root) { it.isFocused && it.isEditable }
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

        /**
         * The keyboard's Enter, Done, Search, Go or Send key — what submits a
         * search box or confirms a recipient. Setting text through
         * accessibility is not typing, and some fields act only on that key:
         * Messaging's recipient field kept the number as loose text until it.
         * API 30+ has an action for it; before that, the key is found in the
         * keyboard's own window and touched.
         */
        fun pressEnter(callback: (Boolean) -> Unit) {
            val service = instance ?: return callback(false)
            if (Build.VERSION.SDK_INT >= 30) {
                val root = service.safeRoot()
                val input = root?.let { findNode(it) { n -> n.isFocused && n.isEditable } }
                if (input != null && input.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)) {
                    return callback(true)
                }
            }
            val ime = try {
                service.windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            } catch (_: Exception) { null }
            val keys = ime?.root ?: return callback(false)
            val key = ENTER_KEYS.firstNotNullOfOrNull { want ->
                findNode(keys) { n -> ownText(n).equals(want, ignoreCase = true) }
            } ?: return callback(false)
            val r = Rect().also { key.getBoundsInScreen(it) }
            if (r.isEmpty) return callback(false)
            tapAtCoordinates(r.exactCenterX(), r.exactCenterY(), callback)
        }

        /// What keyboards call the key, most specific first; the full-screen
        /// text box's own button says DONE.
        private val ENTER_KEYS = listOf("Send", "Search", "Go", "Done", "Next", "Enter", "Return")

        fun scroll(direction: String, nodeId: Int?, callback: (Boolean) -> Unit) {
            // Try node-based scroll first
            val scrollNode = if (nodeId != null) nodeMap[nodeId] else {
                val root = instance?.safeRoot()
                if (root != null) findNode(root) { it.isScrollable } else null
            }
            if (scrollNode != null && scrollNode.isScrollable) {
                val action = if (direction == "down" || direction == "right")
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                callback(scrollNode.performAction(action))
                return
            }
            // Fallback: a swipe through the middle of the screen.
            val dm = instance?.resources?.displayMetrics
            val cx = (dm?.widthPixels ?: 490) / 2f; val cy = (dm?.heightPixels ?: 580) / 2f
            val d = cy * 0.6f
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
        // A charging screen that opened while FOX-1 was down — during an
        // update, or before the service was back — sent its event to nobody,
        // and stayed up for an hour. Look at what is already there.
        mainHandler.postDelayed({
            try { closeStockLauncherIfInFront() } catch (e: Exception) {
                android.util.Log.w("FOX1", "start check failed: $e")
            }
        }, 1500)
    }

    /// The stock launcher in front while FOX-1 is the home app: go home.
    private fun closeStockLauncherIfInFront() {
        val root = safeRoot()
        val stock = if (root != null) {
            val pkg = root.packageName?.toString()
            recycleNode(root)
            pkg != null && pkg != packageName && isOtherHome(pkg)
        } else {
            // The stock launcher's own screen could not be read (its widget
            // host throws), but its window title is still known: match it
            // against the other home apps' screen names.
            val title = try {
                windows.firstOrNull { it.isActive }?.title?.toString()
            } catch (_: Exception) { null }
            title != null && otherHomeLabels().contains(title)
        }
        if (stock) {
            android.util.Log.i("FOX1", "stock launcher in front at start — going home")
            performGlobalAction(GLOBAL_ACTION_HOME)
        }
    }

    /// Screen and app names of the other home apps, while FOX-1 is the
    /// default one.
    private fun otherHomeLabels(): Set<String> {
        val home = android.content.Intent(android.content.Intent.ACTION_MAIN)
            .addCategory(android.content.Intent.CATEGORY_HOME)
        val pm = packageManager
        if (pm.resolveActivity(home, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                ?.activityInfo?.packageName != packageName) return emptySet()
        return pm.queryIntentActivities(home, 0)
            .filter { it.activityInfo.packageName != packageName }
            .flatMap { listOf(it.loadLabel(pm).toString(), it.activityInfo.applicationInfo.loadLabel(pm).toString()) }
            .toSet()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        AccessibilityKeeper.setWanted(this, false)
        return super.onUnbind(intent)
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Runs on the main thread for every window change on the device: an
        // exception here would take the launcher down.
        try { handleEvent(event) } catch (e: Exception) {
            android.util.Log.w("FOX1", "accessibility event failed: $e")
        }
    }

    private fun handleEvent(event: AccessibilityEvent?) {
        // The activity in front — the compact screen's header. Window-state
        // events also fire for dialogs and menus, so only a class Android
        // knows as an activity counts.
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = event.packageName?.toString() ?: return
        val cls = event.className?.toString() ?: return
        val isActivity = activityClasses.getOrPut("$pkg/$cls") {
            try { packageManager.getActivityInfo(ComponentName(pkg, cls), 0); true } catch (_: Exception) { false }
        }
        if (pkg != packageName && cls.contains("Charg", ignoreCase = true)) {
            android.util.Log.i("FOX1", "window $pkg/$cls · activity=$isActivity")
        }
        if (isActivity) {
            lastActivityPkg = pkg
            lastActivity = cls.substringAfterLast('.')
            if (isStockChargeScreen(pkg, cls)) {
                android.util.Log.i("FOX1", "stock launcher's charge screen $pkg/$cls over FOX-1 — going home")
                performGlobalAction(GLOBAL_ACTION_HOME)
            }
        }
    }

    /**
     * The watch's own launcher stays installed and running as a system app
     * after FOX-1 becomes the home screen, and it opens its charging screen
     * (`com.dw.launcher/.activity.ChargeEffectActivity`) whenever power is
     * connected. Back does not close it; Home does, and comes back to FOX-1.
     * Only while FOX-1 is the default home, and only a charging activity of
     * another home app, so its power-off menu and settings are left alone.
     */
    private fun isStockChargeScreen(pkg: String, cls: String): Boolean {
        if (pkg == packageName || !cls.substringAfterLast('.').contains("Charg", ignoreCase = true)) return false
        return isOtherHome(pkg)
    }

    /// [pkg] is another home app, and FOX-1 is the default one.
    private fun isOtherHome(pkg: String): Boolean {
        val home = android.content.Intent(android.content.Intent.ACTION_MAIN)
            .addCategory(android.content.Intent.CATEGORY_HOME)
        val pm = packageManager
        val default = pm.resolveActivity(home, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo?.packageName
        if (default != packageName) return false
        return pm.queryIntentActivities(home, 0).any { it.activityInfo.packageName == pkg }
    }
    override fun onInterrupt() {}
}
