import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Tools {
    static func pressKey(_ spec: String, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        guard let combo = KeyParser.parse(spec) else {
            throw MCPError(code: -32602, message: "Unrecognized key: \(spec). Use xdotool-style names like Return, Tab, super+c, KP_0.")
        }
        if let unicode = combo.fallbackUnicode {
            typeUnicode(unicode, modifiers: combo.modifiers, pid: pid)
        } else {
            postKey(virtualKey: combo.virtualKey, flags: combo.modifiers, pid: pid)
        }
    }

    static func typeText(_ text: String, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        if tryAXValueInsert(pid: pid, text: text) { return }
        for scalar in text.unicodeScalars {
            typeUnicode(String(scalar), modifiers: [], pid: pid)
        }
    }

    static func clickAt(x: CGFloat, y: CGFloat, button: String = "left", clickCount: Int = 1, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        animateCursorSync(to: CGPoint(x: x, y: y), duration: 0.28)
        let (downType, upType, mouseButton) = mouseEventTypes(button)
        for i in 0..<max(1, clickCount) {
            postMouse(type: downType, at: CGPoint(x: x, y: y), button: mouseButton, clickState: i + 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.02)
            postMouse(type: upType, at: CGPoint(x: x, y: y), button: mouseButton, clickState: i + 1, pid: pid)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    static func clickElement(index: Int) throws {
        let element = try lookupElement(index)
        let err = AXUIElementPerformAction(element, "AXPress" as CFString)
        guard err == .success else {
            throw MCPError(code: -32000, message: "AXPress failed on element \(index) (AXError=\(err.rawValue)). This element may not support press — try coordinate click.")
        }
    }

    static func performSecondaryAction(index: Int, action: String) throws {
        let element = try lookupElement(index)
        let normalized = action.hasPrefix("AX") ? action : "AX\(action)"
        var supported: CFArray?
        AXUIElementCopyActionNames(element, &supported)
        let names = (supported as? [String]) ?? []
        guard names.contains(normalized) else {
            throw MCPError(code: -32000, message: "\(action) is not a valid secondary action for element \(index) (available: \(names))")
        }
        _ = AXUIElementPerformAction(element, normalized as CFString)
    }

    static func setValue(index: Int, value: String) throws {
        let element = try lookupElement(index)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
        guard settable.boolValue else {
            throw MCPError(code: -32000, message: "Cannot set a value for an element that is not settable")
        }
        let err = AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFString)
        guard err == .success else {
            throw MCPError(code: -32000, message: "Failed to set value (AXError=\(err.rawValue))")
        }
    }

    static func scroll(direction: String, pages: Int, index: Int? = nil, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        let target = try resolveScrollTarget(index: index, pid: pid)
        let dir = try parseDirection(direction)
        if let element = target.element {
            for (depth, ancestor) in ancestorsInclusive(of: element).enumerated() {
                if performSemanticScroll(on: ancestor, direction: dir, pages: pages) {
                    scrollDebug("semantic hit at ancestor depth \(depth)")
                    return
                }
            }
            scrollDebug("no AX scroll path; falling through to brief-focus CGEvent")
        }
        withBriefFocus(pid: pid) {
            moveMouseSync(to: target.location, pid: nil)
            postPhasedScroll(at: target.location, direction: dir, pages: pages, pid: nil)
        }
    }

    static func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat, app: String? = nil) throws {
        try requireAX()
        let pid = try resolvePid(app)
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
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
        throw MCPError(code: -32602, message: "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions.")
    }
    return element
}

private func resolvePid(_ identifier: String?) throws -> pid_t {
    let ws = NSWorkspace.shared
    if let id = identifier {
        guard let app = ws.runningApplications.first(where: { $0.bundleIdentifier == id || $0.localizedName == id }) else {
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
    guard let focused: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedUIElement") else {
        return false
    }
    // Prefer inserting via AXSelectedText (appends at caret; keeps existing content)
    var selectedSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(focused, "AXSelectedText" as CFString, &selectedSettable)
    if selectedSettable.boolValue {
        let err = AXUIElementSetAttributeValue(focused, "AXSelectedText" as CFString, text as CFString)
        if err == .success { return true }
    }
    // Fallback: replace the whole value (appending existing + text to preserve content)
    var valueSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(focused, "AXValue" as CFString, &valueSettable)
    if valueSettable.boolValue {
        let existing: String = AXTreeBuilder.attribute(focused, "AXValue") ?? ""
        let err = AXUIElementSetAttributeValue(focused, "AXValue" as CFString, (existing + text) as CFString)
        if err == .success { return true }
    }
    return false
}

private func postEvent(_ event: CGEvent?, pid: pid_t?) {
    guard let event else { return }
    if let pid {
        event.postToPid(pid)
    } else {
        event.post(tap: .cghidEventTap)
    }
}

private func withBriefFocus(pid: pid_t, _ body: () -> Void) {
    let ws = NSWorkspace.shared
    let previous = ws.frontmostApplication
    if let target = NSRunningApplication(processIdentifier: pid) {
        target.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.04)
    }
    body()
    Thread.sleep(forTimeInterval: 0.02)
    if let previous, previous.processIdentifier != pid {
        previous.activate(options: [.activateIgnoringOtherApps])
    }
}

private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, pid: pid_t?) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
    event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    postEvent(event, pid: pid)
}

private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
    let src = CGEventSource(stateID: .combinedSessionState)
    postKeyEvent(source: src, virtualKey: virtualKey, keyDown: true, flags: flags, pid: pid)
    Thread.sleep(forTimeInterval: 0.01)
    postKeyEvent(source: src, virtualKey: virtualKey, keyDown: false, flags: flags, pid: pid)
    Thread.sleep(forTimeInterval: 0.02)
}

private func postKeyEvent(source: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags, pid: pid_t) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else { return }
    event.flags = flags
    postEvent(event, pid: pid)
}

private func typeUnicode(_ str: String, modifiers: CGEventFlags, pid: pid_t) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let utf16: [UniChar] = Array(str.utf16)
    postUnicodeEvent(source: src, utf16: utf16, keyDown: true, modifiers: modifiers, pid: pid)
    Thread.sleep(forTimeInterval: 0.008)
    postUnicodeEvent(source: src, utf16: utf16, keyDown: false, modifiers: modifiers, pid: pid)
    Thread.sleep(forTimeInterval: 0.012)
}

private func postUnicodeEvent(source: CGEventSource?, utf16: [UniChar], keyDown: Bool, modifiers: CGEventFlags, pid: pid_t) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return }
    event.flags = modifiers
    utf16.withUnsafeBufferPointer { buf in
        event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
    }
    postEvent(event, pid: pid)
}

private func centerOf(index: Int) -> CGPoint? {
    guard let element = ElementCache.shared.lookup(index: index),
          let position = AXTreeBuilder.pointAttribute(element, "AXPosition"),
          let size = AXTreeBuilder.sizeAttribute(element, "AXSize") else { return nil }
    return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
}

private func moveMouseSync(to point: CGPoint, pid: pid_t?) {
    animateCursorSync(to: point, duration: 0.2)
    postMouse(type: .mouseMoved, at: point, button: .left, clickState: 0, pid: pid)
}

private func animateCursorSync(to target: CGPoint, duration: TimeInterval) {
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        VirtualCursor.shared.animate(to: target, duration: duration) { sem.signal() }
    }
    _ = sem.wait(timeout: .now() + duration + 0.5)
}

private struct ScrollTarget {
    let location: CGPoint
    let element: AXUIElement?
}

private func resolveScrollTarget(index: Int?, pid: pid_t) throws -> ScrollTarget {
    let fallback = windowCenter(forPid: pid)
    if let index {
        guard let element = ElementCache.shared.lookup(index: index) else {
            throw MCPError(code: -32602, message: "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions.")
        }
        if let position = AXTreeBuilder.pointAttribute(element, "AXPosition"),
           let size = AXTreeBuilder.sizeAttribute(element, "AXSize") {
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
       let size = AXTreeBuilder.sizeAttribute(window, "AXSize") {
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

private func performSemanticScroll(on element: AXUIElement, direction: ScrollDirection, pages: Int) -> Bool {
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

private func postPhasedScroll(at location: CGPoint, direction: ScrollDirection, pages: Int, pid: pid_t?) {
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
        if s == 0 { phase = .began }
        else if s == steps - 1 { phase = .ended }
        else { phase = .changed }
        postScrollEvent(location: location, dx: stepDx, dy: stepDy, phase: phase, pid: pid)
        Thread.sleep(forTimeInterval: 0.012)
    }
}

private func postScrollEvent(location: CGPoint, dx: CGFloat, dy: CGFloat, phase: CGScrollPhase, pid: pid_t?) {
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 2,
        wheel1: Int32(dy),
        wheel2: Int32(dx),
        wheel3: 0
    ) else { return }
    event.location = location
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    postEvent(event, pid: pid)
}

private func mouseEventTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
    switch button.lowercased() {
    case "right": return (.rightMouseDown, .rightMouseUp, .right)
    case "middle": return (.otherMouseDown, .otherMouseUp, .center)
    default: return (.leftMouseDown, .leftMouseUp, .left)
    }
}
