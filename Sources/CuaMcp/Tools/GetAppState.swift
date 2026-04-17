import AppKit
import Foundation

extension Tools {
    static func getAppState(app bundleIdOrName: String) throws -> (app: NSRunningApplication, root: AXNode, text: String) {
        guard Permissions.axTrusted() else {
            throw MCPError(code: -32000, message: "Accessibility permission not granted. Grant it in System Settings → Privacy & Security → Accessibility.")
        }
        let ws = NSWorkspace.shared
        let candidates = ws.runningApplications
        let matched = candidates.first {
            $0.bundleIdentifier == bundleIdOrName || $0.localizedName == bundleIdOrName
        }
        guard let app = matched else {
            throw MCPError(code: -32000, message: "Running application not found: \(bundleIdOrName)")
        }
        let builder = AXTreeBuilder()
        let (runningApp, root) = try builder.build(forPID: app.processIdentifier, app: app)
        let text = AXSerializer.render(root: root, app: runningApp)
        return (runningApp, root, text)
    }
}
