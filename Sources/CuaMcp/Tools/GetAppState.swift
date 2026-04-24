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
        // Flip AXEnhancedUserInterface + AXManualAccessibility on the target
        // pid so Chrome/Electron expose their full AX tree. This also
        // primes the state for subsequent input tools.
        AXEnablement.shared.installIfNeeded(for: app.processIdentifier)
        // Chrome builds the tree lazily — give it a tick after flipping the
        // switch so web content has a chance to populate.
        Thread.sleep(forTimeInterval: 0.08)
        let builder = AXTreeBuilder()
        let (runningApp, root) = try builder.build(forPID: app.processIdentifier, app: app)
        let text = AXSerializer.render(root: root, app: runningApp)
        return (runningApp, root, text)
    }
}
