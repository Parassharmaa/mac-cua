import AppKit
import CoreServices
import Foundation

enum Tools {}

private struct AppEntry {
    var name: String
    var bundleId: String
    var running: Bool
    var lastUsed: Date?
    var uses: Int?
}

extension Tools {
    /// Rich text listing matching Sky's format:
    ///   Calculator — com.apple.calculator [running, last-used=2026-04-17, uses=229]
    ///   Reminders — com.apple.reminders [last-used=2026-04-17, uses=8]
    static func listApps() throws -> [[String: Any]] {
        let entries = collectEntries()
        // Sort: running first (by uses desc), then non-running (by uses desc).
        let sorted = entries.sorted { a, b in
            if a.running != b.running { return a.running }
            return (a.uses ?? 0) > (b.uses ?? 0)
        }
        return sorted.map { e in
            var d: [String: Any] = ["name": e.name, "bundleId": e.bundleId, "running": e.running]
            if let lu = e.lastUsed {
                d["lastUsed"] = ISO8601DateFormatter().string(from: lu)
            }
            if let uses = e.uses { d["uses"] = uses }
            return d
        }
    }

    static func renderAppList(_ entries: [[String: Any]]) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let iso = ISO8601DateFormatter()

        return entries.map { e -> String in
            let name = (e["name"] as? String) ?? "?"
            let bid = (e["bundleId"] as? String) ?? "?"
            var flags: [String] = []
            if (e["running"] as? Bool) == true { flags.append("running") }
            if let luStr = e["lastUsed"] as? String, let d = iso.date(from: luStr) {
                flags.append("last-used=\(df.string(from: d))")
            }
            if let uses = e["uses"] as? Int { flags.append("uses=\(uses)") }
            let trailing = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            return "\(name) — \(bid)\(trailing)"
        }.joined(separator: "\n")
    }

    private static func collectEntries() -> [AppEntry] {
        var map: [String: AppEntry] = [:]

        // Running apps (regular activation policy only).
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, let name = app.localizedName else { continue }
            map[bid] = AppEntry(name: name, bundleId: bid, running: true, lastUsed: nil, uses: nil)
        }

        // Also enumerate installed apps from /Applications + /System/Applications + ~/Applications,
        // pulling last-used + uses from Spotlight metadata.
        for dir in [
            "/Applications", "/System/Applications",
            NSString(string: "~/Applications").expandingTildeInPath,
        ] {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for item in contents where item.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(item)
                guard let (bid, name) = bundleInfo(path: path) else { continue }
                let (lastUsed, uses) = spotlightStats(path: path)
                if var existing = map[bid] {
                    existing.lastUsed = lastUsed ?? existing.lastUsed
                    existing.uses = uses ?? existing.uses
                    map[bid] = existing
                } else if lastUsed != nil || uses != nil {
                    map[bid] = AppEntry(
                        name: name, bundleId: bid, running: false, lastUsed: lastUsed, uses: uses)
                }
            }
        }
        return Array(map.values)
    }

    private static func bundleInfo(path: String) -> (String, String)? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
            let bid = bundle.bundleIdentifier
        else { return nil }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (url.deletingPathExtension().lastPathComponent)
        return (bid, name)
    }

    private static func spotlightStats(path: String) -> (Date?, Int?) {
        guard let item = MDItemCreate(nil, path as CFString) else { return (nil, nil) }
        let date = MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date
        let uses = (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue
        return (date, uses)
    }
}
