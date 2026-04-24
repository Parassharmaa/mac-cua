import AppKit
import Foundation

/// Focus-free app interaction — a public-API-first shim that falls back to
/// Apple's private `AccessibilitySupport` framework when the public paths
/// aren't enough.
///
/// Strategy in order of preference:
///   1. `AXUIElementSetAttributeValue(app, kAXEnhancedUserInterface, true)` —
///      public, tells the target to enter AX-optimized mode (keeps tree fresh).
///   2. `SyntheticAppFocusEnforcer` — private class from Apple's own
///      `AccessibilitySupport.framework`. Installs an event tap that tells the
///      target "you are frontmost" without actually changing the OS frontmost
///      app. This is exactly what Codex's Sky plugin does.
///
/// The private path is best-effort: if dlopen or class lookup fails (e.g. OS
/// upgrade renames the class), we quietly fall back to the public shim and
/// input still works — just with a brief focus flicker.
final class SkyFocus {
    static let shared = SkyFocus()
    private init() {}

    private var installed: [pid_t: Any] = [:]
    private var enforcerClass: AnyClass? = {
        _ = dlopen("/System/Library/PrivateFrameworks/AccessibilitySupport.framework/AccessibilitySupport", RTLD_LAZY)
        // Swift-mangled name for `AccessibilitySupport.SyntheticAppFocusEnforcer`.
        return NSClassFromString("_TtC20AccessibilitySupport25SyntheticAppFocusEnforcer")
    }()
    private let queue = DispatchQueue(label: "cua-mcp.skyfocus")

    func installIfNeeded(for pid: pid_t) {
        queue.sync {
            if installed[pid] != nil { return }
            // Public layer: enhanced UI keeps AX tree accurate on a background app.
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            // Chrome/Chromium and Electron apps ship with a minimal AX tree by
            // default for perf. Flipping AXManualAccessibility tells them to
            // build the full tree (with text content, roles, etc.) — without
            // this, web pages show up as bare group elements.
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            // Private layer: SyntheticAppFocusEnforcer would prevent the
            // target app from reactivating itself on receiving events, but
            // it's a pure-Swift class (not NSObject-derived) with no
            // exported init symbol we can `dlsym`. We skip allocation —
            // FocusGuard below gives us a best-effort equivalent.
            installed[pid] = NSNull()
        }
    }
}

/// Snapshot + restore the user's frontmost app around a tool call.
///
/// Sky's `SyntheticAppFocusEnforcer` + `SystemFocusStealPreventer` pair
/// prevents the target app from ever noticing that it isn't frontmost; we
/// can't replicate that via public APIs (see SkyFocus above). The next-best
/// thing is to let the target steal focus briefly, then snap the user's
/// original app back. This produces a ~100ms flicker but leaves the user
/// where they started.
///
/// Usage:
/// ```
/// let guard = FocusGuard.snapshot()
/// // ...post events to target pid...
/// guard.restore()
/// ```
struct FocusGuard {
    let originalPid: pid_t?
    let targetPid: pid_t

    static func snapshot(targetPid: pid_t) -> FocusGuard {
        let orig = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return FocusGuard(originalPid: orig, targetPid: targetPid)
    }

    /// Reclaim focus for the user's original app. Chrome/Electron apps
    /// activate *asynchronously* after receiving events — the activation
    /// often hasn't fired yet when `restore()` is called, so a single
    /// check-then-reactivate races. Instead we poll for up to `window`
    /// seconds and force the original app frontmost any time it isn't.
    func restore(window: TimeInterval = 0.6) {
        guard let originalPid, originalPid != targetPid else { return }
        guard let original = NSRunningApplication(processIdentifier: originalPid) else { return }
        let deadline = Date().addingTimeInterval(window)
        var restored = false
        while Date() < deadline {
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if now != originalPid {
                original.activate(options: [.activateIgnoringOtherApps])
                restored = true
                // Give the activation a beat to take, then check again —
                // Chrome can fire a *second* activation on focus-loss.
                Thread.sleep(forTimeInterval: 0.06)
            } else if restored {
                // We've seen the original frontmost *after* restoring; safe
                // to exit early — if the target tries again, the next tool
                // call's guard will handle it.
                return
            } else {
                // Focus never shifted off the original — nothing to do.
                return
            }
        }
    }
}

private func skyFocusDebug(_ msg: String) {
    if ProcessInfo.processInfo.environment["CUA_FOCUS_DEBUG"] != nil {
        FileHandle.standardError.write("[skyfocus] \(msg)\n".data(using: .utf8)!)
    }
}

/// "Act on background app" setup — three-layer focus suppression:
///
///   Layer 1 — **AX enablement**: `AXManualAccessibility` /
///             `AXEnhancedUserInterface` on the target root element, so
///             Chromium/Electron build a full AX tree and respect AX
///             attribute writes. Cached per-pid via `SkyFocus`.
///
///   Layer 3 — **Reactive** (`SystemFocusStealPreventer`): install an
///             `NSWorkspace.didActivateApplicationNotification` observer
///             that, if the target self-activates in response to our
///             synthetic event, immediately restores the user's previous
///             frontmost app on the same runloop turn. This is the crucial
///             piece that eliminates the visible focus flicker when the
///             target app decides to call `NSApp.activate` internally.
///
///   Layer 3.5 — **Polling fallback** (`FocusGuard`): kept as a safety net
///               for systems where `SystemFocusStealPreventer` misses the
///               activation (e.g., notification coalescing races). Polls
///               for `window` seconds and snaps the user's app back.
///
/// Layer 2 (write AXFocused/AXMain on window+element) is applied by AX
/// action callers, not this helper — see `Tools.withAXFocusSuppressed`.
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
        SkyFocus.shared.installIfNeeded(for: pid)

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
