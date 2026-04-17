import Foundation

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let handler: ([String: Any]) throws -> Any
}

enum ToolRegistry {
    static var all: [Tool] {
        return [
            Tool(
                name: "list_apps",
                description: "List apps on this Mac. Includes running apps.",
                schema: [
                    "name": "list_apps",
                    "description": "List apps on this Mac. Includes running apps.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:] as [String: Any],
                        "additionalProperties": false,
                    ],
                ],
                handler: { _ in
                    let apps = try Tools.listApps()
                    return ["content": [["type": "text", "text": formatAppList(apps)]]]
                }
            ),
            Tool(
                name: "press_key",
                description: "Press a key or key combination on the keyboard (xdotool-style: Return, Tab, super+c, KP_0).",
                schema: [
                    "name": "press_key",
                    "description": "Press a key or key combination (xdotool-style: Return, Tab, super+c, KP_0).",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "key": ["type": "string"],
                            "app": ["type": "string", "description": "Optional: activate this app before pressing."],
                        ] as [String: Any],
                        "required": ["key"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let key = args["key"] as? String, !key.isEmpty else {
                        throw MCPError(code: -32602, message: "press_key requires 'key'")
                    }
                    try Tools.pressKey(key, app: args["app"] as? String)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "type_text",
                description: "Type the given text into the currently focused field. Bypasses layout-specific keycodes by sending Unicode.",
                schema: [
                    "name": "type_text",
                    "description": "Type the given text into the currently focused field.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "app": ["type": "string", "description": "Optional: activate this app before typing."],
                        ] as [String: Any],
                        "required": ["text"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let text = args["text"] as? String else {
                        throw MCPError(code: -32602, message: "type_text requires 'text'")
                    }
                    try Tools.typeText(text, app: args["app"] as? String)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "click",
                description: "Click on an element (by element_index from the latest get_app_state) or at screen coordinates.",
                schema: [
                    "name": "click",
                    "description": "Click an element by index, or at x/y screen coordinates.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "element_index": ["type": "integer"],
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "button": ["type": "string", "enum": ["left", "right", "middle"]],
                            "click_count": ["type": "integer"],
                            "app": ["type": "string"],
                        ] as [String: Any],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    func intOf(_ k: String) -> Int? {
                        if let v = args[k] as? Int { return v }
                        if let v = args[k] as? NSNumber { return v.intValue }
                        if let v = args[k] as? Double { return Int(v) }
                        if let v = args[k] as? String, let i = Int(v) { return i }
                        return nil
                    }
                    func doubleOf(_ k: String) -> Double? {
                        if let v = args[k] as? Double { return v }
                        if let v = args[k] as? NSNumber { return v.doubleValue }
                        if let v = args[k] as? Int { return Double(v) }
                        if let v = args[k] as? String, let d = Double(v) { return d }
                        return nil
                    }
                    if let index = intOf("element_index") {
                        try Tools.clickElement(index: index)
                    } else if let x = doubleOf("x"), let y = doubleOf("y") {
                        let button = args["button"] as? String ?? "left"
                        let count = intOf("click_count") ?? 1
                        try Tools.clickAt(x: CGFloat(x), y: CGFloat(y), button: button, clickCount: count, app: args["app"] as? String)
                    } else {
                        throw MCPError(code: -32602, message: "click requires element_index or (x,y). args=\(args)")
                    }
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "perform_secondary_action",
                description: "Perform a named AX action on an element (e.g. Raise, ShowMenu, ShowAlternateUI).",
                schema: [
                    "name": "perform_secondary_action",
                    "description": "Perform a named AX action on an element.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "element_index": ["type": "integer"],
                            "action": ["type": "string"],
                        ] as [String: Any],
                        "required": ["element_index", "action"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let index = args["element_index"] as? Int,
                          let action = args["action"] as? String else {
                        throw MCPError(code: -32602, message: "perform_secondary_action requires element_index and action")
                    }
                    try Tools.performSecondaryAction(index: index, action: action)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "set_value",
                description: "Set an element's value directly (faster and more reliable than type_text for text fields).",
                schema: [
                    "name": "set_value",
                    "description": "Set an element's value directly.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "element_index": ["type": "integer"],
                            "value": ["type": "string"],
                        ] as [String: Any],
                        "required": ["element_index", "value"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let index = args["element_index"] as? Int,
                          let value = args["value"] as? String else {
                        throw MCPError(code: -32602, message: "set_value requires element_index and value")
                    }
                    try Tools.setValue(index: index, value: value)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "scroll",
                description: "Scroll in a direction. If element_index is given, scroll while pointing at that element.",
                schema: [
                    "name": "scroll",
                    "description": "Scroll in a direction.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                            "pages": ["type": "integer"],
                            "element_index": ["type": "integer"],
                            "app": ["type": "string"],
                        ] as [String: Any],
                        "required": ["direction"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let dir = args["direction"] as? String else {
                        throw MCPError(code: -32602, message: "Missing scroll direction")
                    }
                    let pages = (args["pages"] as? Int) ?? (args["pages"] as? NSNumber)?.intValue ?? 1
                    let idx = (args["element_index"] as? Int) ?? (args["element_index"] as? NSNumber)?.intValue
                    try Tools.scroll(direction: dir, pages: pages, index: idx, app: args["app"] as? String)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "drag",
                description: "Drag from one screen point to another.",
                schema: [
                    "name": "drag",
                    "description": "Drag from one screen point to another.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "from_x": ["type": "number"],
                            "from_y": ["type": "number"],
                            "to_x": ["type": "number"],
                            "to_y": ["type": "number"],
                        ] as [String: Any],
                        "required": ["from_x", "from_y", "to_x", "to_y"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    func num(_ k: String) -> CGFloat? {
                        if let d = args[k] as? Double { return CGFloat(d) }
                        if let i = args[k] as? Int { return CGFloat(i) }
                        return nil
                    }
                    guard let fx = num("from_x"), let fy = num("from_y"), let tx = num("to_x"), let ty = num("to_y") else {
                        throw MCPError(code: -32602, message: "drag requires from_x, from_y, to_x, to_y")
                    }
                    try Tools.drag(fromX: fx, fromY: fy, toX: tx, toY: ty)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "get_app_state",
                description: "Activate the target app and return its accessibility tree with numbered element indices. Call this first each turn before any other tool.",
                schema: [
                    "name": "get_app_state",
                    "description": "Activate the target app and return its accessibility tree with numbered element indices.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": ["type": "string", "description": "Bundle identifier (preferred) or localized app name."]
                        ] as [String: Any],
                        "required": ["app"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let app = args["app"] as? String, !app.isEmpty else {
                        throw MCPError(code: -32602, message: "get_app_state requires string 'app'")
                    }
                    let (runningApp, root, text) = try Tools.getAppState(app: app)
                    ElementCache.shared.replace(root: root)
                    var content: [[String: Any]] = [["type": "text", "text": text]]
                    if let png = Screenshot.captureAppWindowPNG(pid: runningApp.processIdentifier) {
                        content.append(["type": "image", "mimeType": "image/png", "data": png])
                    }
                    return ["content": content]
                }
            ),
        ]
    }

    static func lookup(_ name: String) -> Tool? {
        return all.first { $0.name == name }
    }
}

private func formatAppList(_ apps: [[String: Any]]) -> String {
    apps.map { app in
        let name = app["name"] as? String ?? "(unknown)"
        let bundle = app["bundleId"] as? String ?? ""
        let active = (app["active"] as? Bool) == true ? " [active]" : ""
        let hidden = (app["hidden"] as? Bool) == true ? " [hidden]" : ""
        return "\(name) — \(bundle)\(active)\(hidden)"
    }.joined(separator: "\n")
}

final class MCPServer {
    private let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private let serverInfo: [String: Any] = ["name": "mac-cua-mcp", "version": "0.1.0"]

    func run() {
        let stdout = FileHandle.standardOutput
        while let raw = readLine(strippingNewline: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handle(message: msg, stdout: stdout)
        }
    }

    private func handle(message: [String: Any], stdout: FileHandle) {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            if let id = id { writeError(to: stdout, id: id, code: -32600, message: "Missing method") }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]

        if id == nil {
            return
        }

        do {
            let result = try dispatch(method: method, params: params)
            writeResponse(to: stdout, id: id!, result: result)
        } catch let err as MCPError {
            if method == "tools/call" {
                writeResponse(to: stdout, id: id!, result: [
                    "content": [["type": "text", "text": err.message]],
                    "isError": true,
                ])
            } else {
                writeError(to: stdout, id: id!, code: err.code, message: err.message)
            }
        } catch {
            if method == "tools/call" {
                writeResponse(to: stdout, id: id!, result: [
                    "content": [["type": "text", "text": "Internal error: \(error)"]],
                    "isError": true,
                ])
            } else {
                writeError(to: stdout, id: id!, code: -32603, message: "Internal error: \(error)")
            }
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            return initialize(params: params)
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return ["tools": ToolRegistry.all.map { $0.schema }]
        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                throw MCPError(code: -32602, message: "tools/call requires a string 'name'")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = ToolRegistry.lookup(name) else {
                throw MCPError(code: -32602, message: "Unknown tool '\(name)'")
            }
            return try tool.handler(args)
        case "resources/list":
            return ["resources": [] as [Any]]
        case "resources/templates/list":
            return ["resourceTemplates": [] as [Any]]
        case "prompts/list":
            return ["prompts": [] as [Any]]
        default:
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initialize(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = (requested != nil && supportedProtocols.contains(requested!)) ? requested! : supportedProtocols[0]
        return [
            "protocolVersion": version,
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false, "subscribe": false],
                "prompts": ["listChanged": false],
            ],
            "serverInfo": serverInfo,
            "instructions": "Native macOS Computer Use MCP server. Call get_app_state first each turn, then act on returned element indices.",
        ]
    }

    private func writeResponse(to stdout: FileHandle, id: Any, result: Any) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        write(payload: payload, to: stdout)
    }

    private func writeError(to stdout: FileHandle, id: Any, code: Int, message: String) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
        write(payload: payload, to: stdout)
    }

    private func write(payload: [String: Any], to stdout: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        stdout.write(data)
        stdout.write(Data([0x0A]))
    }
}

struct MCPError: Error {
    let code: Int
    let message: String
}

