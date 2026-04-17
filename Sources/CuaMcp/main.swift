import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()

func writeJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

if args.first == "tools" {
    writeJSON(["tools": ToolRegistry.all.map { $0.schema }])
    exit(0)
}

if args.first == "probe-list-apps" {
    writeJSON(try! Tools.listApps())
    exit(0)
}

if args.first == "probe-state", args.count >= 2 {
    let target = Array(args)[1]
    do {
        let (_, _, text) = try Tools.getAppState(app: target)
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

if args.first == "permissions" {
    writeJSON(Permissions.snapshot())
    exit(0)
}

if args.first == "probe-scroll", args.count >= 2 {
    let target = Array(args)[1]
    do {
        let (_, root, _) = try Tools.getAppState(app: target)
        ElementCache.shared.replace(root: root)
        let indices = ElementCache.shared.knownIndices()
        FileHandle.standardError.write("=== element cache ===\n".data(using: .utf8)!)
        for idx in indices.prefix(30) {
            guard let el = ElementCache.shared.lookup(index: idx) else { continue }
            let role: String = AXTreeBuilder.attribute(el, "AXRole") ?? "?"
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            let actionNames = (actions as? [String]) ?? []
            FileHandle.standardError.write("  [\(idx)] role=\(role) actions=\(actionNames)\n".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\n=== scroll attempts ===\n".data(using: .utf8)!)
        func readVbar(_ scrollArea: AXUIElement) -> String {
            var vbar: CFTypeRef?
            AXUIElementCopyAttributeValue(scrollArea, "AXVerticalScrollBar" as CFString, &vbar)
            guard let vbar else { return "(no vbar)" }
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(vbar as! AXUIElement, "AXValue" as CFString, &val)
            if let v = val as? NSNumber { return v.stringValue }
            return "(no value)"
        }
        for idx in indices {
            guard let el = ElementCache.shared.lookup(index: idx) else { continue }
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            let names = (actions as? [String]) ?? []
            if names.contains("AXScrollDownByPage") {
                let before = readVbar(el)
                let down = AXUIElementPerformAction(el, "AXScrollDownByPage" as CFString)
                Thread.sleep(forTimeInterval: 0.1)
                let afterDown = readVbar(el)
                let up = AXUIElementPerformAction(el, "AXScrollUpByPage" as CFString)
                Thread.sleep(forTimeInterval: 0.1)
                let afterUp = readVbar(el)
                FileHandle.standardError.write("  [\(idx)] before=\(before) down=\(down.rawValue)→\(afterDown) up=\(up.rawValue)→\(afterUp)\n".data(using: .utf8)!)
            }
        }
        FileHandle.standardError.write("\n=== AX trusted? \(Permissions.axTrusted()) ===\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

if args.first == "cursor-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.2)
        let screen = NSScreen.screens.first!.frame
        let points: [CGPoint] = [
            CGPoint(x: screen.width * 0.1, y: screen.height * 0.1),
            CGPoint(x: screen.width * 0.9, y: screen.height * 0.1),
            CGPoint(x: screen.width * 0.9, y: screen.height * 0.9),
            CGPoint(x: screen.width * 0.1, y: screen.height * 0.9),
            CGPoint(x: screen.width * 0.5, y: screen.height * 0.5),
        ]
        for p in points {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                VirtualCursor.shared.animate(to: p, duration: 0.6) { sem.signal() }
            }
            _ = sem.wait(timeout: .now() + 2)
            Thread.sleep(forTimeInterval: 0.3)
        }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    app.run()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let serverThread = Thread {
    MCPServer().run()
    DispatchQueue.main.async {
        NSApplication.shared.terminate(nil)
    }
}
serverThread.name = "MCPServerLoop"
serverThread.start()

app.run()
