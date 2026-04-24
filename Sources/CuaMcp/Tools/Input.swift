import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Tools {
    static func pressKey(_ spec: String, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        AXEnablement.shared.installIfNeeded(for: pid)
        guard let combo = KeyParser.parse(spec) else {
            throw MCPError(
                code: -32602,
                message:
                    "Unrecognized key: \(spec). Use xdotool-style names like Return, Tab, super+c, KP_0."
            )
        }
        let guardRail = BackgroundFocus.activate(pid: pid)
        defer { guardRail.restore() }
        hoverOverFocusedElement(pid: pid)
        pulseCursor()
        if let unicode = combo.fallbackUnicode {
            typeUnicode(unicode, modifiers: combo.modifiers, pid: pid)
        } else {
            postKey(virtualKey: combo.virtualKey, flags: combo.modifiers, pid: pid)
        }
    }

    static func typeText(_ text: String, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        AXEnablement.shared.installIfNeeded(for: pid)
        hoverOverFocusedElement(pid: pid)
        pulseCursor()
        // Arm background-focus suppression for the whole operation.
        // AX writes can cause the target app to self-activate as it
        // processes the change (e.g. TextEdit binds focus to the text
        // area, Chromium notifies its renderer). The preventer catches
        // any such activation and restores the user's frontmost app on
        // the same runloop turn — no visible flicker.
        let guardRail = BackgroundFocus.activate(pid: pid)
        defer { guardRail.restore() }
        if tryAXValueInsert(pid: pid, text: text) { return }
        for scalar in text.unicodeScalars {
            typeUnicode(String(scalar), modifiers: [], pid: pid)
        }
    }

    static func clickAt(
        x: CGFloat, y: CGFloat, button: String = "left", clickCount: Int = 1, app: String? = nil
    ) throws {
        try requireAX()
        let pid = try resolvePid(app)
        AXEnablement.shared.installIfNeeded(for: pid)
        let guardRail = BackgroundFocus.activate(pid: pid)
        defer { guardRail.restore() }
        // x/y are screenshot-pixel coordinates (0,0 = top-left of the
        // focused window's captured PNG). Convert to desktop points using
        // the window's AXPosition + backing scale factor so models can pass
        // coordinates they read off the screenshot directly.
        let point = convertScreenshotPixelToDesktopPoint(x: x, y: y, pid: pid)
        // Phase 2 — primer click for Chromium-family targets. Chromium's
        // user-activation gate blocks things like `window.open`, fullscreen
        // API, and video play/pause unless a recent gesture is trusted. An
        // off-screen primer at `(-1, -1)` ticks the gate forward; the real
        // click that follows a few ms later lands as a trusted continuation.
        // The primer is discarded by the renderer (no window claims that
        // coord) so it has no visible effect.
        if isChromiumFamily(pid: pid) {
            postMouse(
                type: .leftMouseDown, at: CGPoint(x: -1, y: -1),
                button: .left, clickState: 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.008)
            postMouse(
                type: .leftMouseUp, at: CGPoint(x: -1, y: -1),
                button: .left, clickState: 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.015)
        }
        animateCursorSync(to: point, duration: 0.28)
        pulseCursor()
        let (downType, upType, mouseButton) = mouseEventTypes(button)
        for i in 0..<max(1, clickCount) {
            postMouse(type: downType, at: point, button: mouseButton, clickState: i + 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.02)
            postMouse(type: upType, at: point, button: mouseButton, clickState: i + 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    static func clickElement(index: Int) throws {
        let element = try lookupElement(index)
        let targetPid = pidOfElement(element)
        AXEnablement.shared.installIfNeeded(for: targetPid)
        if let center = centerOfElement(element) {
            animateCursorSync(to: center, duration: 0.25)
            pulseCursor()
        }
        // Arm the focus-steal preventer + synthetic AX focus. AXPress
        // dispatched to a backgrounded app sometimes causes the app to
        // self-activate as its target view takes focus; the preventer
        // demotes it back on the same runloop turn. The AX focus
        // suppression writes AXFocused/AXMain on window+element so the
        // target's internal state machine processes the action as
        // focused, without actually raising the window.
        let guardRail = BackgroundFocus.activate(pid: targetPid)
        defer { guardRail.restore() }
        let err = AXFocusSuppression.withSuppression(element: element) {
            AXUIElementPerformAction(element, "AXPress" as CFString)
        }
        guard err == .success else {
            throw MCPError(
                code: -32000,
                message:
                    "AXPress failed on element \(index) (AXError=\(err.rawValue)). This element may not support press — try coordinate click."
            )
        }
    }

    static func performSecondaryAction(index: Int, action: String) throws {
        let element = try lookupElement(index)
        let normalized = action.hasPrefix("AX") ? action : "AX\(action)"
        var supported: CFArray?
        AXUIElementCopyActionNames(element, &supported)
        let names = (supported as? [String]) ?? []
        guard names.contains(normalized) else {
            throw MCPError(
                code: -32000,
                message:
                    "\(action) is not a valid secondary action for element \(index) (available: \(names))"
            )
        }
        let targetPid = pidOfElement(element)
        AXEnablement.shared.installIfNeeded(for: targetPid)
        if let center = centerOfElement(element) {
            animateCursorSync(to: center, duration: 0.25)
            pulseCursor()
        }
        let guardRail = BackgroundFocus.activate(pid: targetPid)
        defer { guardRail.restore() }
        AXFocusSuppression.withSuppression(element: element) {
            _ = AXUIElementPerformAction(element, normalized as CFString)
        }
    }

    static func setValue(index: Int, value: String) throws {
        let element = try lookupElement(index)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
        guard settable.boolValue else {
            throw MCPError(
                code: -32000, message: "Cannot set a value for an element that is not settable")
        }
        let targetPid = pidOfElement(element)
        AXEnablement.shared.installIfNeeded(for: targetPid)
        if let center = centerOfElement(element) {
            animateCursorSync(to: center, duration: 0.25)
            pulseCursor()
        }
        let guardRail = BackgroundFocus.activate(pid: targetPid)
        defer { guardRail.restore() }
        let err = AXFocusSuppression.withSuppression(element: element) {
            AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFString)
        }
        guard err == .success else {
            throw MCPError(code: -32000, message: "Failed to set value (AXError=\(err.rawValue))")
        }
    }

    static func scroll(direction: String, pages: Int, index: Int? = nil, app: String? = nil) throws
    {
        try requireAX()
        let pid = try resolvePid(app)
        AXEnablement.shared.installIfNeeded(for: pid)
        let target = try resolveScrollTarget(index: index, pid: pid)
        let dir = try parseDirection(direction)
        if let element = target.element {
            for (depth, ancestor) in ancestorsInclusive(of: element).enumerated() {
                if performSemanticScroll(on: ancestor, direction: dir, pages: pages) {
                    scrollDebug("semantic hit at ancestor depth \(depth)")
                    return
                }
            }
            scrollDebug("no AX scroll path; falling through to pid-targeted CGEvent")
        }
        // CGEvent scroll fallback — needs background activation for routing.
        let guardRail = BackgroundFocus.activate(pid: pid)
        defer { guardRail.restore() }
        moveMouseSync(to: target.location, pid: pid)
        postPhasedScroll(at: target.location, direction: dir, pages: pages, pid: pid)
    }

    static func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat, app: String? = nil)
        throws
    {
        try requireAX()
        let pid = try resolvePid(app)
        let guardRail = BackgroundFocus.activate(pid: pid)
        defer { guardRail.restore() }
        // Same screenshot-pixel → desktop-point conversion as clickAt.
        let start = convertScreenshotPixelToDesktopPoint(x: fromX, y: fromY, pid: pid)
        let end = convertScreenshotPixelToDesktopPoint(x: toX, y: toY, pid: pid)
        animateCursorSync(to: start, duration: 0.25)
        postMouse(type: .leftMouseDown, at: start, button: .left, clickState: 1, pid: pid)
        Thread.sleep(forTimeInterval: 0.05)
        let steps = 10
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let point = CGPoint(x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
            postMouse(type: .leftMouseDragged, at: point, button: .left, clickState: 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.02)
        }
        postMouse(type: .leftMouseUp, at: end, button: .left, clickState: 1, pid: pid)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private func requireAX() throws {
    guard Permissions.axTrusted() else {
        throw MCPError(code: -32000, message: "Accessibility permission not granted.")
    }
}

private func lookupElement(_ index: Int) throws -> AXUIElement {
    guard let element = ElementCache.shared.lookup(index: index) else {
        throw MCPError(
            code: -32602,
            message:
                "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions."
        )
    }
    return element
}

/// Best-effort pid for an AXUIElement. Returns 0 if we can't resolve — the
/// FocusGuard will still fire but its target-vs-current check is lenient.
private func pidOfElement(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

/// Convert a screenshot-pixel coordinate to a desktop-point coordinate.
///
/// Sky's click/drag tools take coordinates as "pixel coordinates from
/// screenshot" — the (0,0) origin is the top-left of the captured PNG for
/// the focused window, and units are image pixels. `CGEvent` expects global
/// desktop points, so we need to:
///   1. Add the window's desktop origin (AXPosition of the focused window)
///   2. Divide by the screen's backing scale factor (2.0 on Retina)
///
/// If anything goes wrong resolving the window, we fall through to treating
/// the input as already being in desktop points — that's the pre-existing
/// behaviour, so calls that used to work still work.
private func convertScreenshotPixelToDesktopPoint(x: CGFloat, y: CGFloat, pid: pid_t) -> CGPoint {
    let axApp = AXUIElementCreateApplication(pid)
    guard let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow"),
        let origin = AXTreeBuilder.pointAttribute(window, "AXPosition")
    else {
        return CGPoint(x: x, y: y)
    }
    // Scale factor: ask the screen containing the window.
    let scale: CGFloat
    if let screen = NSScreen.screens.first(where: {
        let flipped = flipToCocoa(point: origin)
        return $0.frame.contains(flipped)
    }) {
        scale = screen.backingScaleFactor
    } else {
        scale = NSScreen.main?.backingScaleFactor ?? 2.0
    }
    return CGPoint(x: origin.x + (x / scale), y: origin.y + (y / scale))
}

private func flipToCocoa(point: CGPoint) -> CGPoint {
    guard let mainHeight = NSScreen.screens.first?.frame.height else { return point }
    return CGPoint(x: point.x, y: mainHeight - point.y)
}

private func resolvePid(_ identifier: String?) throws -> pid_t {
    let ws = NSWorkspace.shared
    if let id = identifier {
        guard
            let app = ws.runningApplications.first(where: {
                $0.bundleIdentifier == id || $0.localizedName == id
            })
        else {
            throw MCPError(code: -32000, message: "Running application not found: \(id)")
        }
        return app.processIdentifier
    }
    guard let frontmost = ws.frontmostApplication else {
        throw MCPError(code: -32000, message: "No frontmost application to target.")
    }
    return frontmost.processIdentifier
}

private func tryAXValueInsert(pid: pid_t, text: String) -> Bool {
    let axApp = AXUIElementCreateApplication(pid)
    // 1. Preferred: AXFocusedUIElement — only populated when the target app
    //    has an active text control. When the app is backgrounded this is
    //    often nil, which is why we walk to find a text area below.
    if let focused: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedUIElement"),
        insertText(into: focused, text: text)
    {
        return true
    }
    // 2. Fallback: walk the focused window (or first window) and insert
    //    into the first text-capable leaf we find. This lets type_text work
    //    on apps that aren't active — critical for background CU — without
    //    requiring the caller to first click a text field.
    let searchRoots: [AXUIElement]
    if let focusedWin: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow") {
        searchRoots = [focusedWin]
    } else if let windows: [AXUIElement] = AXTreeBuilder.attribute(axApp, "AXWindows") {
        searchRoots = windows
    } else {
        searchRoots = []
    }
    for root in searchRoots {
        if let text_el = findTextField(in: root), insertText(into: text_el, text: text) {
            return true
        }
    }
    return false
}

/// Try AXSelectedText first (caret-preserving append), fall back to AXValue
/// (full replace, retaining existing content). Returns true on first success.
private func insertText(into element: AXUIElement, text: String) -> Bool {
    var selectedSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, "AXSelectedText" as CFString, &selectedSettable)
    if selectedSettable.boolValue {
        let err = AXUIElementSetAttributeValue(
            element, "AXSelectedText" as CFString, text as CFString)
        if err == .success { return true }
    }
    var valueSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &valueSettable)
    if valueSettable.boolValue {
        let existing: String = AXTreeBuilder.attribute(element, "AXValue") ?? ""
        let err = AXUIElementSetAttributeValue(
            element, "AXValue" as CFString, (existing + text) as CFString)
        if err == .success { return true }
    }
    return false
}

/// BFS for the first AXTextArea / AXTextField in a subtree. Budget-capped to
/// avoid pathological walks.
private func findTextField(in root: AXUIElement) -> AXUIElement? {
    var queue: [AXUIElement] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 250 {
        let cur = queue.removeFirst()
        visited += 1
        if let role: String = AXTreeBuilder.attribute(cur, "AXRole"),
            role == "AXTextArea" || role == "AXTextField"
        {
            return cur
        }
        if let children: [AXUIElement] = AXTreeBuilder.attribute(cur, "AXChildren") {
            queue.append(contentsOf: children)
        }
    }
    return nil
}

/// Classification for the event kind — drives whether `SLSEventAuthenticationMessage`
/// is attached. Keyboard events targeting Chromium on macOS 14+ need the
/// envelope or the renderer trust filter drops them. Mouse events bypass the
/// envelope because it diverts onto a direct-mach path Chromium's window
/// event handler doesn't subscribe to.
private enum SyntheticEventKind { case mouse, keyboard, scroll }

private func postEvent(_ event: CGEvent?, pid: pid_t?, kind: SyntheticEventKind) {
    guard let event else { return }
    // Tag the event with `AXESynthesizedIgnoreEventSourceID` so the window
    // server treats it as a "do not activate" input. Mechanism Sky uses to
    // post clicks/keys to background apps without focus steal.
    AXEventTag.applyIgnore(event)
    if let pid {
        // Route through SkyLight's `SLEventPostToPid` so Chromium's renderer
        // trust filter accepts the event. Attach the
        // `SLSEventAuthenticationMessage` envelope only for keyboard events
        // targeting Chromium-family apps — the envelope diverts AppKit
        // keyboard delivery onto a path native apps don't subscribe to,
        // breaking type_text on TextEdit, Notes, etc.
        let needsAuth = (kind == .keyboard) && isChromiumFamily(pid: pid)
        if SkyLightBridge.postToPid(pid, event: event, attachAuthMessage: needsAuth) {
            return
        }
        // Fallback — SkyLight symbols didn't resolve on this system.
        event.postToPid(pid)
    } else {
        event.post(tap: .cghidEventTap)
    }
}

/// Bundle-id check: Chromium-family (Chrome, Edge, Brave, Arc, Opera, Vivaldi,
/// Slack, VS Code, Discord, Notion — anything Chromium/Electron). Used to
/// gate the keyboard auth-envelope attachment, which Chromium's renderer
/// trust filter requires but native AppKit apps reject.
private func isChromiumFamily(pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid),
        let bid = app.bundleIdentifier
    else { return false }
    let lower = bid.lowercased()
    if lower.hasPrefix("com.google.chrome") { return true }
    if lower.hasPrefix("com.microsoft.edgemac") { return true }
    if lower.hasPrefix("com.brave.browser") { return true }
    if lower.hasPrefix("company.thebrowser.browser") { return true }  // Arc
    if lower.hasPrefix("com.operasoftware") { return true }
    if lower.hasPrefix("com.vivaldi") { return true }
    if lower == "com.tinyspeck.slackmacgap" { return true }
    if lower == "com.microsoft.vscode" { return true }
    if lower.hasPrefix("com.hnc.discord") || lower == "com.discord.discord" { return true }
    if lower == "notion.id" || lower == "com.notion.desktop" { return true }
    return false
}

private func postMouse(
    type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, pid: pid_t?
) {
    let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    // Stamp a window-local point via `CGEventSetWindowLocation` so
    // WindowServer's hit-test uses the window-local point directly instead
    // of reprojecting from screen space. Matters when the target window
    // is occluded or on a different Space — the global-to-local transform
    // WindowServer would otherwise do can land the click on the wrong view.
    if let event, let pid, SkyLightBridge.isWindowLocationAvailable {
        if let localPoint = windowLocalPoint(for: point, pid: pid) {
            SkyLightBridge.setWindowLocation(event, localPoint)
        }
    }
    postEvent(event, pid: pid, kind: .mouse)
}

/// Convert a screen-space desktop point to window-local coordinates for
/// the target's primary on-screen window. Returns nil when the window
/// frame can't be resolved.
private func windowLocalPoint(for screenPoint: CGPoint, pid: pid_t) -> CGPoint? {
    let axApp = AXUIElementCreateApplication(pid)
    guard let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow"),
        let origin = AXTreeBuilder.pointAttribute(window, "AXPosition")
    else { return nil }
    return CGPoint(x: screenPoint.x - origin.x, y: screenPoint.y - origin.y)
}

private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
    let src = CGEventSource(stateID: .combinedSessionState)
    postKeyEvent(source: src, virtualKey: virtualKey, keyDown: true, flags: flags, pid: pid)
    Thread.sleep(forTimeInterval: 0.01)
    postKeyEvent(source: src, virtualKey: virtualKey, keyDown: false, flags: flags, pid: pid)
    Thread.sleep(forTimeInterval: 0.02)
}

private func postKeyEvent(
    source: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags, pid: pid_t
) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown)
    else { return }
    event.flags = flags
    postEvent(event, pid: pid, kind: .keyboard)
}

private func typeUnicode(_ str: String, modifiers: CGEventFlags, pid: pid_t) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let utf16: [UniChar] = Array(str.utf16)
    postUnicodeEvent(source: src, utf16: utf16, keyDown: true, modifiers: modifiers, pid: pid)
    Thread.sleep(forTimeInterval: 0.008)
    postUnicodeEvent(source: src, utf16: utf16, keyDown: false, modifiers: modifiers, pid: pid)
    Thread.sleep(forTimeInterval: 0.012)
}

private func postUnicodeEvent(
    source: CGEventSource?, utf16: [UniChar], keyDown: Bool, modifiers: CGEventFlags, pid: pid_t
) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
        return
    }
    event.flags = modifiers
    utf16.withUnsafeBufferPointer { buf in
        event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
    }
    postEvent(event, pid: pid, kind: .keyboard)
}

/// Move just the virtual cursor overlay — no synthetic .mouseMoved CGEvent
/// is posted. A real mouseMoved event can cause macOS to animate to the
/// target window's Space (Mission Control slide) if the target is in a
/// different Space, because the window server needs to route the move to
/// a visible window. Scroll-at-location still works because scroll wheel
/// events are routed by location alone and don't trigger Space switching.
private func moveMouseSync(to point: CGPoint, pid: pid_t?) {
    animateCursorSync(to: point, duration: 0.2)
}

/// Animate the virtual cursor to `target`. Duration scales with distance so
/// short hops feel snappy while long hops across the screen still read as
/// intentional motion. Caller blocks until animation completes (or 0.5s past).
private func animateCursorSync(to target: CGPoint, duration baseDuration: TimeInterval) {
    let current = NSEvent.mouseLocation
    // Flip back from NSEvent (bottom-left) to CGPoint (top-left) space.
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    let fromTopLeft = CGPoint(x: current.x, y: screenHeight - current.y)
    let distance = hypot(target.x - fromTopLeft.x, target.y - fromTopLeft.y)
    // 120px/s minimum up to 1000px/s max — short snap ≈0.15s, long sweep ≈0.55s.
    let scaled = min(0.55, max(0.15, baseDuration * Double(distance / 180.0)))
    let duration = distance < 2 ? 0.05 : scaled
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        VirtualCursor.shared.animate(to: target, duration: duration) { sem.signal() }
    }
    _ = sem.wait(timeout: .now() + duration + 0.5)
}

private func pulseCursor() {
    DispatchQueue.main.async {
        VirtualCursor.shared.pulse()
    }
}

private func centerOfElement(_ element: AXUIElement) -> CGPoint? {
    guard let position = AXTreeBuilder.pointAttribute(element, "AXPosition"),
        let size = AXTreeBuilder.sizeAttribute(element, "AXSize")
    else { return nil }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

/// Move the virtual cursor to the currently-focused UI element inside `pid`.
/// Used for keyboard actions so the overlay at least lands somewhere meaningful.
private func hoverOverFocusedElement(pid: pid_t) {
    let axApp = AXUIElementCreateApplication(pid)
    if let focused: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedUIElement"),
        let center = centerOfElement(focused)
    {
        animateCursorSync(to: center, duration: 0.22)
        return
    }
    // Fall back to the focused-window center.
    animateCursorSync(to: windowCenter(forPid: pid), duration: 0.22)
}

private struct ScrollTarget {
    let location: CGPoint
    let element: AXUIElement?
}

private func resolveScrollTarget(index: Int?, pid: pid_t) throws -> ScrollTarget {
    let fallback = windowCenter(forPid: pid)
    if let index {
        guard let element = ElementCache.shared.lookup(index: index) else {
            throw MCPError(
                code: -32602,
                message:
                    "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions."
            )
        }
        if let position = AXTreeBuilder.pointAttribute(element, "AXPosition"),
            let size = AXTreeBuilder.sizeAttribute(element, "AXSize")
        {
            let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
            if isOnScreen(center) {
                return ScrollTarget(location: center, element: element)
            }
        }
        return ScrollTarget(location: fallback, element: element)
    }
    return ScrollTarget(location: fallback, element: nil)
}

private func isOnScreen(_ point: CGPoint) -> Bool {
    for screen in NSScreen.screens {
        if screen.frame.contains(point) { return true }
    }
    return false
}

private func windowCenter(forPid pid: pid_t) -> CGPoint {
    let axApp = AXUIElementCreateApplication(pid)
    if let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow"),
        let pos = AXTreeBuilder.pointAttribute(window, "AXPosition"),
        let size = AXTreeBuilder.sizeAttribute(window, "AXSize")
    {
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }
    let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    return CGPoint(x: screen.midX, y: screen.midY)
}

private enum ScrollDirection { case up, down, left, right }

private func parseDirection(_ s: String) throws -> ScrollDirection {
    switch s.lowercased() {
    case "up": return .up
    case "down": return .down
    case "left": return .left
    case "right": return .right
    default: throw MCPError(code: -32602, message: "Invalid scroll direction: \(s)")
    }
}

private func semanticAction(_ d: ScrollDirection) -> String {
    // Axis flip: user "down" means "show more content below" = move content upward.
    switch d {
    case .up: return "AXScrollDownByPage"
    case .down: return "AXScrollUpByPage"
    case .left: return "AXScrollRightByPage"
    case .right: return "AXScrollLeftByPage"
    }
}

private func ancestorsInclusive(of element: AXUIElement) -> [AXUIElement] {
    var chain: [AXUIElement] = [element]
    var current = element
    while chain.count < 12, let parent: AXUIElement = AXTreeBuilder.attribute(current, "AXParent") {
        chain.append(parent)
        current = parent
    }
    return chain
}

private func scrollDebug(_ msg: String) {
    if ProcessInfo.processInfo.environment["CUA_SCROLL_DEBUG"] != nil {
        FileHandle.standardError.write("[scroll] \(msg)\n".data(using: .utf8)!)
    }
}

private func performSemanticScroll(on element: AXUIElement, direction: ScrollDirection, pages: Int)
    -> Bool
{
    let action = semanticAction(direction)
    var supported: CFArray?
    AXUIElementCopyActionNames(element, &supported)
    guard let names = supported as? [String], names.contains(action) else { return false }
    for _ in 0..<max(1, pages) {
        _ = AXUIElementPerformAction(element, action as CFString)
        Thread.sleep(forTimeInterval: 0.03)
    }
    return true
}

private func postPhasedScroll(
    at location: CGPoint, direction: ScrollDirection, pages: Int, pid: pid_t?
) {
    let total = CGFloat(max(1, pages)) * 400.0
    let (dx, dy): (CGFloat, CGFloat)
    switch direction {
    case .up: (dx, dy) = (0, total)
    case .down: (dx, dy) = (0, -total)
    case .left: (dx, dy) = (total, 0)
    case .right: (dx, dy) = (-total, 0)
    }
    let steps = 10
    let stepDx = dx / CGFloat(steps)
    let stepDy = dy / CGFloat(steps)
    for s in 0..<steps {
        let phase: CGScrollPhase
        if s == 0 {
            phase = .began
        } else if s == steps - 1 {
            phase = .ended
        } else {
            phase = .changed
        }
        postScrollEvent(location: location, dx: stepDx, dy: stepDy, phase: phase, pid: pid)
        Thread.sleep(forTimeInterval: 0.012)
    }
}

private func postScrollEvent(
    location: CGPoint, dx: CGFloat, dy: CGFloat, phase: CGScrollPhase, pid: pid_t?
) {
    guard
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        )
    else { return }
    event.location = location
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    postEvent(event, pid: pid, kind: .scroll)
}

private func mouseEventTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
    switch button.lowercased() {
    case "right": return (.rightMouseDown, .rightMouseUp, .right)
    case "middle": return (.otherMouseDown, .otherMouseUp, .center)
    default: return (.leftMouseDown, .leftMouseUp, .left)
    }
}
