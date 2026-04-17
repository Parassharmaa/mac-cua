import AppKit
import ApplicationServices
import Foundation

/// CLI debugging subcommands — useful for diagnosing AX issues against a live app.
/// Kept separate from main.swift to avoid cluttering the server entry point.
enum DebugCommands {
    /// `probe-scroll <bundleId>` — dumps the element cache and tries AXScroll on every element that supports it.
    static func probeScroll(target: String) throws {
        let (_, root, _) = try Tools.getAppState(app: target)
        ElementCache.shared.replace(root: root)
        let indices = ElementCache.shared.knownIndices()

        stderr.write("=== element cache ===\n")
        for idx in indices.prefix(30) {
            guard let el = ElementCache.shared.lookup(index: idx) else { continue }
            let role: String = AXTreeBuilder.attribute(el, "AXRole") ?? "?"
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            let actionNames = (actions as? [String]) ?? []
            stderr.write("  [\(idx)] role=\(role) actions=\(actionNames)\n")
        }

        stderr.write("\n=== scroll attempts ===\n")
        for idx in indices {
            guard let el = ElementCache.shared.lookup(index: idx) else { continue }
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            let names = (actions as? [String]) ?? []
            guard names.contains("AXScrollDownByPage") else { continue }
            let before = readVbar(el)
            let down = AXUIElementPerformAction(el, "AXScrollDownByPage" as CFString)
            Thread.sleep(forTimeInterval: 0.1)
            let afterDown = readVbar(el)
            let up = AXUIElementPerformAction(el, "AXScrollUpByPage" as CFString)
            Thread.sleep(forTimeInterval: 0.1)
            let afterUp = readVbar(el)
            stderr.write("  [\(idx)] before=\(before) down=\(down.rawValue)→\(afterDown) up=\(up.rawValue)→\(afterUp)\n")
        }
        stderr.write("\n=== AX trusted? \(Permissions.axTrusted()) ===\n")
    }

    private static func readVbar(_ scrollArea: AXUIElement) -> String {
        var vbar: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollArea, "AXVerticalScrollBar" as CFString, &vbar)
        guard let vbar else { return "(no vbar)" }
        var val: CFTypeRef?
        AXUIElementCopyAttributeValue(vbar as! AXUIElement, "AXValue" as CFString, &val)
        if let v = val as? NSNumber { return v.stringValue }
        return "(no value)"
    }
}

private let stderr = StderrStream()

private final class StderrStream {
    func write(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }
}
