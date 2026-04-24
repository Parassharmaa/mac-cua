import Foundation
import ApplicationServices
import CoreGraphics

enum Permissions {
    static func axTrusted(prompt: Bool = false) -> Bool {
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
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
