import AppKit
import Foundation

extension Tools {
    /// Return the current NSPasteboard string contents, or empty string if
    /// the pasteboard holds no plain-text payload. Non-destructive — does
    /// not modify the pasteboard.
    static func getClipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    /// Write `text` as the pasteboard's plain-text contents, replacing any
    /// previous payload. Returns `true` when the write landed — the
    /// pasteboard reports a changeCount bump after a successful
    /// `setString`. Running in an `.accessory` NSApplication context does
    /// not block pasteboard writes; no TCC prompt is needed.
    @discardableResult
    static func setClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    /// Paste `text` into the currently focused input of `app` (or the
    /// frontmost app if `app` is nil). Implementation: write `text` to the
    /// pasteboard, fire `cmd+v`, then restore the prior clipboard after a
    /// short delay. Faster than `type_text` for long or unicode-heavy
    /// content — avoids per-scalar CGEvent dispatch and sidesteps
    /// Chromium's keyboard trust filter entirely (cmd+v is a single
    /// short keystroke sequence).
    static func paste(_ text: String, app: String? = nil) throws {
        let prior = getClipboard()
        _ = setClipboard(text)
        // Brief settle so the pasteboard's changeCount propagates before
        // we fire the shortcut.
        Thread.sleep(forTimeInterval: 0.05)
        try pressKey("cmd+v", app: app)
        // Restore the user's original clipboard shortly after so the
        // paste contents don't linger in their buffer. 300ms gives the
        // target enough time to consume the paste.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = setClipboard(prior)
        }
    }
}
