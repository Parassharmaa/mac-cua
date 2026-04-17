import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()

func writeJSON(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

switch args.first {
case "tools":
    writeJSON(["tools": ToolRegistry.all.map { $0.schema }])
    exit(0)

case "probe-list-apps":
    writeJSON(try! Tools.listApps())
    exit(0)

case "probe-state" where args.count >= 2:
    do {
        let (_, _, text) = try Tools.getAppState(app: Array(args)[1])
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "probe-scroll" where args.count >= 2:
    do {
        try DebugCommands.probeScroll(target: Array(args)[1])
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }

case "permissions":
    writeJSON(Permissions.snapshot())
    exit(0)

case "cursor-demo":
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

default:
    break
}

// Default: run as MCP stdio server.
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
