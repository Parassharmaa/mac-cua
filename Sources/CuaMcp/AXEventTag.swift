import Foundation
import CoreGraphics

/// Tag synthesized CGEvents with Apple's `AXESynthesizedIgnoreEventSourceID`
/// so macOS treats them as "ignore" events — same mechanism Sky uses to
/// avoid focus-steal when posting events to a background app.
///
/// Mechanism: `AccessibilitySupport.framework` (a private framework re-exported
/// from the SDK at build time) exposes two int64 constants:
///
///   • `AXESynthesizedEventSourceID`        — marks events as AX-synthesized
///   • `AXESynthesizedIgnoreEventSourceID`  — marks events the window server
///                                             should pass through without
///                                             the usual "treat as user input"
///                                             side effects (like bringing
///                                             the target app to the front)
///
/// When any CGEvent has `kCGEventSourceUserData` set to one of these magic
/// int64 values, macOS recognizes it as synthetic and skips activation.
/// The constants are random-looking on purpose — you can't guess them; they
/// must be read from the private framework.
///
/// We resolve them lazily via `dlopen` + `dlsym` on the symbol's data
/// address (they're exported as data, not functions — the raw bytes at the
/// symbol address ARE the int64 values).
enum AXEventTag {
    static let synthesizedSourceID: Int64 = loadConstant(named: "AXESynthesizedEventSourceID")
    static let ignoreSourceID: Int64 = loadConstant(named: "AXESynthesizedIgnoreEventSourceID")

    /// Apply the ignore-source-id to an event so macOS passes it through
    /// without raising the target app. Call this right before posting
    /// any CGEvent we synthesized.
    static func applyIgnore(_ event: CGEvent?) {
        guard let event else { return }
        guard ignoreSourceID != 0 else { return }
        event.setIntegerValueField(.eventSourceUserData, value: ignoreSourceID)
    }

    private static let handle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/AccessibilitySupport.framework/AccessibilitySupport"
        return dlopen(path, RTLD_LAZY)
    }()

    private static func loadConstant(named name: String) -> Int64 {
        guard let handle else { return 0 }
        guard let sym = dlsym(handle, name) else { return 0 }
        return sym.assumingMemoryBound(to: Int64.self).pointee
    }
}
