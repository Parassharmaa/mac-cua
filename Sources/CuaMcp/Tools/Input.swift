import AppKit
import CoreGraphics
import Foundation

extension Tools {
    static func pressKey(_ spec: String, app: String? = nil) throws {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted.")
        }
        if let app { try activate(appIdentifier: app) }
        guard let combo = KeyParser.parse(spec) else {
            throw MCPError(code: -32602, message: "Unrecognized key: \(spec). Use xdotool-style names like Return, Tab, super+c, KP_0.")
        }
        if let unicode = combo.fallbackUnicode {
            typeUnicode(unicode, modifiers: combo.modifiers)
            return
        }
        postKey(virtualKey: combo.virtualKey, flags: combo.modifiers)
    }

    static func typeText(_ text: String, app: String? = nil) throws {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted.")
        }
        if let app { try activate(appIdentifier: app) }
        for scalar in text.unicodeScalars {
            typeUnicode(String(scalar), modifiers: [])
        }
    }

    static func clickAt(x: CGFloat, y: CGFloat, button: String = "left", clickCount: Int = 1, app: String? = nil) throws {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted.")
        }
        if let app { try activate(appIdentifier: app) }
        animateCursorSync(to: CGPoint(x: x, y: y), duration: 0.28)
        let (downType, upType, mouseButton) = mouseEventTypes(button)
        for i in 0..<max(1, clickCount) {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: mouseButton)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: mouseButton)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            up?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    static func clickElement(index: Int) throws {
        guard let element = ElementCache.shared.lookup(index: index) else {
            throw MCPError(code: -32602, message: "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions.")
        }
        let err = AXUIElementPerformAction(element, "AXPress" as CFString)
        if err != .success {
            throw MCPError(code: -32000, message: "AXPress failed on element \(index) (AXError=\(err.rawValue)). This element may not support press — try coordinate click.")
        }
    }

    static func performSecondaryAction(index: Int, action: String) throws {
        guard let element = ElementCache.shared.lookup(index: index) else {
            throw MCPError(code: -32602, message: "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions.")
        }
        let normalized = action.hasPrefix("AX") ? action : "AX\(action)"
        let err = AXUIElementPerformAction(element, normalized as CFString)
        if err != .success {
            throw MCPError(code: -32000, message: "\(action) is not a valid secondary action for element \(index) (AXError=\(err.rawValue))")
        }
    }

    static func setValue(index: Int, value: String) throws {
        guard let element = ElementCache.shared.lookup(index: index) else {
            throw MCPError(code: -32602, message: "The element ID is no longer valid. Re-query the latest state with get_app_state before sending more actions.")
        }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
        guard settable.boolValue else {
            throw MCPError(code: -32000, message: "Cannot set a value for an element that is not settable")
        }
        let err = AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFString)
        if err != .success {
            throw MCPError(code: -32000, message: "Failed to set value (AXError=\(err.rawValue))")
        }
    }

    static func scroll(direction: String, pages: Int, index: Int? = nil) throws {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted.")
        }
        let magnitude = Int32(max(1, pages) * 10)
        let (dx, dy): (Int32, Int32)
        switch direction.lowercased() {
        case "up": (dx, dy) = (0, magnitude)
        case "down": (dx, dy) = (0, -magnitude)
        case "left": (dx, dy) = (magnitude, 0)
        case "right": (dx, dy) = (-magnitude, 0)
        default:
            throw MCPError(code: -32602, message: "Missing scroll direction (up/down/left/right)")
        }
        if let index, let element = ElementCache.shared.lookup(index: index),
           let center = centerOf(element: element) {
            moveMouseSync(to: center)
        }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }

    static func drag(fromX: CGFloat, fromY: CGFloat, toX: CGFloat, toY: CGFloat) throws {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted.")
        }
        animateCursorSync(to: CGPoint(x: fromX, y: fromY), duration: 0.25)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: fromX, y: fromY), mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        let steps = 10
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let x = fromX + (toX - fromX) * t
            let y = fromY + (toY - fromY) * t
            let move = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            move?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: toX, y: toY), mouseButton: .left)
        up?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static func centerOf(element: AXUIElement) -> CGPoint? {
        guard let position = AXTreeBuilder.pointAttribute(element, "AXPosition"),
              let size = AXTreeBuilder.sizeAttribute(element, "AXSize") else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private static func moveMouseSync(to point: CGPoint) {
        animateCursorSync(to: point, duration: 0.2)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
    }

    private static func activate(appIdentifier: String) throws {
        let ws = NSWorkspace.shared
        guard let app = ws.runningApplications.first(where: { $0.bundleIdentifier == appIdentifier || $0.localizedName == appIdentifier }) else {
            throw MCPError(code: -32000, message: "Running application not found: \(appIdentifier)")
        }
        app.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.1)
    }

    private static func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.01)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    private static func typeUnicode(_ str: String, modifiers: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let utf16: [UniChar] = Array(str.utf16)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            down.flags = modifiers
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.008)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            up.flags = modifiers
            utf16.withUnsafeBufferPointer { buf in
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            up.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.012)
    }

    private static func animateCursorSync(to target: CGPoint, duration: TimeInterval) {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            VirtualCursor.shared.animate(to: target, duration: duration) {
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + duration + 0.5)
    }

    private static func mouseEventTypes(_ button: String) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button.lowercased() {
        case "right": return (.rightMouseDown, .rightMouseUp, .right)
        case "middle": return (.otherMouseDown, .otherMouseUp, .center)
        default: return (.leftMouseDown, .leftMouseUp, .left)
        }
    }
}
