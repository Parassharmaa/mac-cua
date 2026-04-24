import AppKit
import ApplicationServices
import Foundation

extension Tools {
    /// Poll the target app's AX tree until an element matching `predicate`
    /// appears, or `timeoutMs` elapses. Predicate strings are matched
    /// case-insensitively against each node's rendered "role + title/
    /// description/value" line (same format get_app_state emits).
    ///
    /// Returns the matched element's index on success, or throws with a
    /// "timeout" MCPError on failure. Agents use this between a click
    /// and the next action to wait for a dialog / new tab / loading
    /// state to resolve, instead of a blind `Thread.sleep`.
    ///
    /// Side effect: on success, the element cache is replaced with the
    /// snapshot that produced the match, so the returned index is
    /// immediately usable by `click` / `set_value` / etc.
    static func waitForElement(
        app: String,
        matching predicate: String,
        timeoutMs: Int = 5000
    ) throws -> Int {
        let needle = predicate.lowercased()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        var lastErr: Error?
        while Date() < deadline {
            do {
                let (_, root, text) = try Tools.getAppState(app: app)
                if let idx = findIndex(in: text, matching: needle) {
                    // Replace the element cache so the caller can dispatch
                    // the returned index without a second get_app_state
                    // round-trip.
                    ElementCache.shared.replace(root: root)
                    return idx
                }
            } catch {
                lastErr = error
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        if let lastErr {
            throw MCPError(
                code: -32000,
                message:
                    "wait_for_element timeout after \(timeoutMs)ms — last error: \(lastErr)")
        }
        throw MCPError(
            code: -32000,
            message:
                "wait_for_element timeout after \(timeoutMs)ms — no element matched '\(predicate)'")
    }

    /// Walk the rendered tree text for the first line whose lowercased
    /// tail contains `needle`. Lines look like "   24 button 1, ID: One".
    private static func findIndex(in text: String, matching needle: String) -> Int? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(separator: " ").first,
                let idx = Int(first)
            else { continue }
            let remainder = String(trimmed.dropFirst(first.count)).lowercased()
            if remainder.contains(needle) { return idx }
        }
        return nil
    }
}
