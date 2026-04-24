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
case "--help", "-h", "help":
    let usage = """
        cua-mcp — native macOS Computer Use MCP server.

        Usage:
          cua-mcp                 Run as MCP stdio server (default)
          cua-mcp --ui            Launch the menu-bar UI
          cua-mcp --version       Print version
          cua-mcp eval            Run 20-case in-process eval, human table
          cua-mcp eval-json       Same eval, line-delimited JSON output
          cua-mcp cursor-demo     Sweep the agent cursor across the screen
          cua-mcp tools           Print the JSON schema for all MCP tools
          cua-mcp permissions     Print AX + Screen Recording grant state
          cua-mcp probe-state <bundle-id>  Dump the AX tree for an app
          cua-mcp --help          This message

        Env vars:
          CUA_HIDE_CURSOR=1       Disable the overlay cursor (default on)
          CUA_CURSOR_DEBUG=1      Log cursor events to stderr
          CUA_FOCUS_DEBUG=1       Log focus-suppression activity
          CUA_SCROLL_DEBUG=1      Log scroll dispatch path

        MCP client registration (Claude Code):
          claude mcp add --scope user mac-cua -- /abs/path/to/cua-mcp

        First-run: grant Accessibility + Screen Recording in
        System Settings → Privacy & Security.
        """
    print(usage)
    exit(0)

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

case "eval", "eval-json":
    // In-process background-CU eval. No osascript, no `open -a`, no
    // subprocess focus leakage. `eval` prints a human-readable table;
    // `eval-json` emits one JSON object per case on stdout for CI /
    // scripting consumption.
    //
    // `--fast` skips the 100× perf stress case (~1s) for inner-loop
    // iteration. The perf case is the only one that takes meaningfully
    // longer than a single AX interaction.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let json = (args.first == "eval-json")
    let fast = args.contains("--fast")
    var code: Int32 = 0
    DispatchQueue.global().async {
        code = EvalRunner.run(jsonOutput: json, skipPerf: fast)
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    app.run()
    exit(code)

case "cursor-demo":
    // Exercises the full cursor feature surface so users can verify the
    // overlay works before wiring it into an agent: a long sweep to each
    // corner (shows heading rotation), short hops (different motion
    // profile), double-click (back-to-back pulse + ring), a pause that
    // lets the 2s idle fade trigger, then a final center click.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.2)
        let screen = NSScreen.screens.first!.frame
        func sweep(_ p: CGPoint, dur: TimeInterval, clickCount: Int = 1) {
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                VirtualCursor.shared.animate(to: p, duration: dur) { sem.signal() }
            }
            _ = sem.wait(timeout: .now() + dur + 2)
            for _ in 0..<clickCount {
                DispatchQueue.main.async { VirtualCursor.shared.pulse() }
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // Long diagonal sweeps — showcases heading rotation along arc.
        sweep(CGPoint(x: screen.width * 0.1, y: screen.height * 0.15), dur: 0.6)
        sweep(CGPoint(x: screen.width * 0.9, y: screen.height * 0.15), dur: 0.7)
        sweep(CGPoint(x: screen.width * 0.9, y: screen.height * 0.85), dur: 0.7)
        sweep(CGPoint(x: screen.width * 0.1, y: screen.height * 0.85), dur: 0.7)
        // Short hops — no arc, linear with overshoot.
        sweep(CGPoint(x: screen.width * 0.2, y: screen.height * 0.85), dur: 0.3)
        sweep(CGPoint(x: screen.width * 0.3, y: screen.height * 0.85), dur: 0.3)
        // Double click — two rings at same spot.
        sweep(CGPoint(x: screen.width * 0.5, y: screen.height * 0.5), dur: 0.5, clickCount: 2)
        // Let the 2s idle fade trigger, then revive.
        Thread.sleep(forTimeInterval: 2.5)
        sweep(CGPoint(x: screen.width * 0.5, y: screen.height * 0.4), dur: 0.4)
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
