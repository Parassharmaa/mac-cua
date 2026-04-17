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
