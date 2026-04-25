import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum Permissions {
    /// Three-state grant report:
    ///   - `granted`        : TCC says granted AND a real AX read succeeded.
    ///   - `notGranted`     : TCC says not granted.
    ///   - `staleNeedsRestart`: TCC says granted but a real AX call returns
    ///                          empty/nil. Known macOS bug — usually
    ///                          requires re-launching this app or rebooting
    ///                          to clear the bogus cache. Surface this
    ///                          state to the user with a "Restart" affordance.
    enum State: String {
        case granted, notGranted, staleNeedsRestart
    }

    static func axTrusted(prompt: Bool = false) -> Bool {
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Functional probe — `AXIsProcessTrusted` returning true is necessary
    /// but not sufficient. macOS occasionally caches a stale "granted" state
    /// where the underlying AX SPI still rejects calls. Verify by reading
    /// an attribute we know exists on a system process (Finder), under a
    /// short timeout. Returns the granular `State`.
    static func axState() -> State {
        if !axTrusted(prompt: false) { return .notGranted }
        // Functional probe: read Finder's frontmost-window title via AX.
        // Safe because Finder always runs and always exposes its tree.
        // If AX is truly granted, this succeeds in <50ms.
        guard
            let finder = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder"
            ).first
        else { return .granted }  // no Finder to probe; trust the bool
        let axApp = AXUIElementCreateApplication(finder.processIdentifier)
        var role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, "AXRole" as CFString, &role)
        if err == .success, role != nil { return .granted }
        return .staleNeedsRestart
    }

    static func screenRecordingGranted() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Registers this bundle with TCC for Screen Recording and asks for
    /// permission. The TCC subsystem only adds an app to the Privacy &
    /// Security > Screen Recording list once it has *attempted* a capture —
    /// `CGRequestScreenCaptureAccess()` by itself sometimes doesn't
    /// register. Priming with a real capture call guarantees the entry
    /// appears in System Settings.
    static func requestScreenRecording() -> Bool {
        // Step 1: attempt a tiny real capture so TCC records the request and
        // lists the app in Settings.
        _ = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        )
        // Step 2: fire the actual permission prompt (no-op if already shown).
        return CGRequestScreenCaptureAccess()
    }

    static func snapshot() -> [String: Any] {
        return [
            "accessibility": axTrusted(prompt: false),
            "screenRecording": screenRecordingGranted(),
        ]
    }
}
