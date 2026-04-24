import AppKit
import Foundation

let args = CommandLine.arguments.dropFirst()

// When launched from Finder, Info.plist's LSEnvironment sets this to 1. An
// MCP client spawn doesn't run through LaunchServices so this is unset —
// we fall through to the stdio server path. --ui forces UI mode from CLI.
let wantsUI =
    ProcessInfo.processInfo.environment["CUA_MCP_UI_MODE"] == "1"
    || args.first == "--ui"

func writeJSON(_ value: Any) {
    let data = try! JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

switch args.first {
case "--version", "-v", "version":
    // Mirror the version we advertise over MCP initialize so clients
    // that introspect both sources see the same number.
    print("cua-mcp 0.1.0")
    exit(0)

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

case "eval":
    // In-process background-CU eval — 15 contract cases. No osascript, no
    // `open -a`, no subprocess focus leakage. Replacement for the legacy
    // Python harness at harness/test_bg_cu_eval.py.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var code: Int32 = 0
    DispatchQueue.global().async {
        code = EvalRunner.run()
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    app.run()
    exit(code)

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

if wantsUI {
    AppUI.run()
    exit(0)
}

// Default: run as MCP stdio server. Log a one-line banner to stderr so
// a client wiring up the server sees `cua-mcp` is alive even before the
// first initialize round-trip. Stderr stays out of the JSON-RPC stream
// on stdout.
FileHandle.standardError.write(
    "cua-mcp 0.1.0 — MCP stdio server ready\n".data(using: .utf8)!)

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
