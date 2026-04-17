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

    static func requestScreenRecording() -> Bool {
        return CGRequestScreenCaptureAccess()
    }

    static func snapshot() -> [String: Any] {
        return [
            "accessibility": axTrusted(prompt: false),
            "screenRecording": screenRecordingGranted(),
        ]
    }
}
