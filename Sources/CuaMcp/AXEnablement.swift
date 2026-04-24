import AppKit
import Foundation

/// AX enablement shim. Writes the two boolean attributes that tell a
/// target application "an AX client is actually here, please build your
/// full accessibility tree":
///
///   - `AXEnhancedUserInterface` — the legacy AppleScript-era hint.
///     Native AppKit apps accept it; most Cocoa apps respond by keeping
///     their AX tree fresh while backgrounded.
///   - `AXManualAccessibility` — the modern Chromium/Electron hint.
///     Chrome, Slack, VS Code, Discord, and other Blink shells ship
///     with their web accessibility pipeline off by default and flip it
///     on only when either attribute is set. Without this, webpages
///     render as bare group elements in the AX tree.
///
/// Chromium-family apps reset `AXEnhancedUserInterface` on some state
/// transitions (occlusion, Space switch, tab switch), so we re-assert
/// every snapshot for them. Native AppKit apps take the assertion
/// permanently — we cache that to avoid redundant writes.
final class AXEnablement {
    static let shared = AXEnablement()
    private init() {}

    /// pids that have already accepted the attribute write. Native AppKit
    /// apps land here permanently.
    private var stableInstalled: Set<pid_t> = []
    private let queue = DispatchQueue(label: "cua-mcp.skyfocus")

    func installIfNeeded(for pid: pid_t) {
        queue.sync {
            let axApp = AXUIElementCreateApplication(pid)
            // Chromium-family: always re-write. They reset the attribute
            // on backgrounding/tab switches, so caching "installed" is
            // incorrect — the flag may be off again by the time we re-read
            // the tree.
            let isChromium = isChromiumPid(pid)
            if stableInstalled.contains(pid) && !isChromium { return }
            AXUIElementSetAttributeValue(
                axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if !isChromium { stableInstalled.insert(pid) }
        }
    }

    private func isChromiumPid(_ pid: pid_t) -> Bool {
        guard let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        let lower = bid.lowercased()
        return lower.hasPrefix("com.google.chrome")
            || lower.hasPrefix("com.microsoft.edgemac")
            || lower.hasPrefix("com.brave.browser")
            || lower.hasPrefix("company.thebrowser.browser")
            || lower == "com.tinyspeck.slackmacgap"
            || lower == "com.microsoft.vscode"
            || lower.hasPrefix("com.hnc.discord")
            || lower.hasPrefix("notion")
    }
}

/// "Act on background app" setup — layered focus suppression:
///
///   Layer 1 — **AX enablement**: `AXManualAccessibility` /
///             `AXEnhancedUserInterface` on the target root element, so
///             Chromium/Electron build a full AX tree and respect AX
///             attribute writes. Re-asserted every snapshot for
///             Chromium (they reset the flag on backgrounding), cached
///             for native AppKit apps. Handled via `AXEnablement`.
///
///   Layer 2 — **Synthetic AX focus** (`AXFocusSuppression`): writes
///             `AXFocused`/`AXMain` on the target's window and element
///             just before an AX action fires, restores the prior
///             values after. Tells the target's internal state machine
///             "these components have focus" so it processes the
///             action as if the user had focused them first.
///
///   Layer 3 — **Reactive preventer** (`SystemFocusStealPreventer`):
///             installs an `NSWorkspace.didActivateApplicationNotification`
///             observer. If the target self-activates in response to
///             our event, synchronously restores the user's previous
///             frontmost on the same runloop turn. The observer stays
///             armed for 3s past tool return so late self-activations
///             (document-open animations, renderer round-trips) also
///             land inside the suppression window.
///
/// Layer 2 is applied by AX action callers (`clickElement`,
/// `performSecondaryAction`, `setValue`) around the AX dispatch; layers
/// 1 and 3 are handled by `BackgroundFocus.activate`.
///
/// Usage:
/// ```
/// let token = BackgroundFocus.activate(pid: pid)
/// defer { token.restore() }
/// // post events...
/// ```
struct BackgroundFocus {
    private let preventerHandle: SystemFocusStealPreventer.Handle?

    static func activate(pid: pid_t) -> BackgroundFocus {
        AXEnablement.shared.installIfNeeded(for: pid)

        let ws = NSWorkspace.shared
        guard let frontmost = ws.frontmostApplication else {
            return BackgroundFocus(preventerHandle: nil)
        }
        if frontmost.processIdentifier == pid {
            return BackgroundFocus(preventerHandle: nil)
        }
        let handle = SystemFocusStealPreventer.shared.beginSuppression(
            targetPid: pid, restoreTo: frontmost
        )
        return BackgroundFocus(preventerHandle: handle)
    }

    func restore() {
        guard let handle = preventerHandle else { return }
        // Target apps sometimes self-activate seconds after our action —
        // TextEdit finishing a document-open animation, Chrome completing
        // a renderer round-trip. Keep the preventer armed for 3s past the
        // tool return to catch those late activations.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            SystemFocusStealPreventer.shared.endSuppression(handle)
        }
    }
}

/// Layer 2 — synthetic AX focus. Writes `AXFocused=true` on the enclosing
/// window and element, and `AXMain=true` on the window, just before an AX
/// action fires. Restores the prior values on exit. This tells the target
/// app's AppKit state machine "these components have focus" so it processes
/// the AX action as if the user had focused them first, without calling
/// `NSApp.activate` or raising the window.
///
/// Best-effort: if an attribute isn't settable on a given element (common —
/// labels, static text, AX roots), the write is a no-op and the primary
/// action still dispatches. Skipped entirely when the enclosing window is
/// minimized — writing AXFocused/AXMain on a minimized Chrome window will
/// deminiaturize it.
enum AXFocusSuppression {
    /// Run `body` with synthetic AX focus applied to `element` and its
    /// enclosing window. Restores prior focus state on both success and
    /// throw.
    static func withSuppression<T>(element: AXUIElement, body: () throws -> T) rethrows -> T {
        let window = enclosingWindow(of: element)
        let minimized = window.flatMap { readBool($0, "AXMinimized") } ?? false
        if minimized {
            // Don't inflate AX focus on minimized windows — Chrome and others
            // deminiaturize on AXFocused write. Just run the body.
            return try body()
        }
        let prior = capture(window: window, element: element)
        apply(window: window, element: element)
        defer { restore(state: prior) }
        return try body()
    }

    // MARK: — state capture / restore

    private struct State {
        let window: AXUIElement?
        let element: AXUIElement
        let priorWindowFocused: Bool?
        let priorWindowMain: Bool?
        let priorElementFocused: Bool?
    }

    private static func capture(window: AXUIElement?, element: AXUIElement) -> State {
        State(
            window: window,
            element: element,
            priorWindowFocused: window.flatMap { readBool($0, "AXFocused") },
            priorWindowMain: window.flatMap { readBool($0, "AXMain") },
            priorElementFocused: readBool(element, "AXFocused")
        )
    }

    private static func apply(window: AXUIElement?, element: AXUIElement) {
        if let window {
            writeBool(window, "AXFocused", true)
            writeBool(window, "AXMain", true)
        }
        writeBool(element, "AXFocused", true)
    }

    private static func restore(state: State) {
        if let window = state.window {
            if let prior = state.priorWindowFocused {
                writeBool(window, "AXFocused", prior)
            }
            if let prior = state.priorWindowMain {
                writeBool(window, "AXMain", prior)
            }
        }
        if let prior = state.priorElementFocused {
            writeBool(state.element, "AXFocused", prior)
        }
    }

    // MARK: — AX helpers

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXWindow" as CFString, &value)
        guard err == .success, let raw = value else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func readBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let v = value else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((v as! CFBoolean))
        }
        return nil
    }

    private static func writeBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        _ = AXUIElementSetAttributeValue(
            element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
