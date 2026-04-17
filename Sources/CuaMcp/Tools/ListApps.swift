import AppKit
import Foundation

enum Tools {}

extension Tools {
    static func listApps() throws -> [[String: Any]] {
        let ws = NSWorkspace.shared
        return ws.runningApplications.compactMap { app -> [String: Any]? in
            guard app.activationPolicy == .regular else { return nil }
            var entry: [String: Any] = [
                "pid": Int(app.processIdentifier),
                "running": true,
            ]
            if let name = app.localizedName { entry["name"] = name }
            if let bundleId = app.bundleIdentifier { entry["bundleId"] = bundleId }
            if let launchDate = app.launchDate {
                entry["launchDate"] = ISO8601DateFormatter().string(from: launchDate)
            }
            entry["active"] = app.isActive
            entry["hidden"] = app.isHidden
            return entry
        }
    }
}
