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
}
