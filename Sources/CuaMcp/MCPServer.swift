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
                description:
                    "Press a key or key combination on the keyboard (xdotool-style: Return, Tab, super+c, KP_0).",
                schema: [
                    "name": "press_key",
                    "description":
                        "Press a key or key combination (xdotool-style: Return, Tab, super+c, KP_0).",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "key": ["type": "string"],
                            "app": [
                                "type": "string",
                                "description": "Optional: activate this app before pressing.",
                            ],
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
                description:
                    "Type the given text into the currently focused field. Bypasses layout-specific keycodes by sending Unicode.",
                schema: [
                    "name": "type_text",
                    "description": "Type the given text into the currently focused field.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "app": [
                                "type": "string",
                                "description": "Optional: activate this app before typing.",
                            ],
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
                description:
                    "Click an element by index or pixel coordinates from screenshot. Prefer element-targeted interactions over coordinate clicks when an index for the targeted element is available.",
                schema: [
                    "name": "click",
                    "description":
                        "Click an element by index or pixel coordinates from the screenshot. Prefer element_index when available.",
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
                        try Tools.clickAt(
                            x: CGFloat(x), y: CGFloat(y), button: button, clickCount: count,
                            app: args["app"] as? String)
                    } else {
                        throw MCPError(
                            code: -32602,
                            message: "click requires element_index or (x,y). args=\(args)")
                    }
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "perform_secondary_action",
                description:
                    "Perform a named AX action on an element (e.g. Raise, ShowMenu, ShowAlternateUI).",
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
                        let action = args["action"] as? String
                    else {
                        throw MCPError(
                            code: -32602,
                            message: "perform_secondary_action requires element_index and action")
                    }
                    try Tools.performSecondaryAction(index: index, action: action)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "set_value",
                description:
                    "Set an element's value directly (faster and more reliable than type_text for text fields).",
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
                        let value = args["value"] as? String
                    else {
                        throw MCPError(
                            code: -32602, message: "set_value requires element_index and value")
                    }
                    try Tools.setValue(index: index, value: value)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "scroll",
                description:
                    "Scroll in a direction. If element_index is given, scroll while pointing at that element.",
                schema: [
                    "name": "scroll",
                    "description": "Scroll in a direction.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "direction": [
                                "type": "string", "enum": ["up", "down", "left", "right"],
                            ],
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
                    let pages =
                        (args["pages"] as? Int) ?? (args["pages"] as? NSNumber)?.intValue ?? 1
                    let idx =
                        (args["element_index"] as? Int)
                        ?? (args["element_index"] as? NSNumber)?.intValue
                    try Tools.scroll(
                        direction: dir, pages: pages, index: idx, app: args["app"] as? String)
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
                    guard let fx = num("from_x"), let fy = num("from_y"), let tx = num("to_x"),
                        let ty = num("to_y")
                    else {
                        throw MCPError(
                            code: -32602, message: "drag requires from_x, from_y, to_x, to_y")
                    }
                    try Tools.drag(fromX: fx, fromY: fy, toX: tx, toY: ty)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "get_app_state",
                description:
                    "Return the target app's accessibility tree with numbered element indices. Call this first each turn before any other tool. `capture_mode` selects what the response includes: `som` (default) = tree + window screenshot, `ax` = tree only (no Screen Recording dependency), `vision` = screenshot only.",
                schema: [
                    "name": "get_app_state",
                    "description":
                        "Return the target app's accessibility tree with numbered element indices.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": [
                                "type": "string",
                                "description":
                                    "Bundle identifier (preferred) or localized app name.",
                            ],
                            "capture_mode": [
                                "type": "string",
                                "enum": ["som", "ax", "vision"],
                                "description":
                                    "What to return: som=tree+screenshot (default), ax=tree only, vision=screenshot only.",
                            ],
                        ] as [String: Any],
                        "required": ["app"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let app = args["app"] as? String, !app.isEmpty else {
                        throw MCPError(code: -32602, message: "get_app_state requires string 'app'")
                    }
                    let mode = (args["capture_mode"] as? String) ?? "som"
                    guard ["som", "ax", "vision"].contains(mode) else {
                        throw MCPError(
                            code: -32602,
                            message: "capture_mode must be one of: som, ax, vision")
                    }
                    let (runningApp, root, text) = try Tools.getAppState(app: app)
                    ElementCache.shared.replace(root: root)
                    var content: [[String: Any]] = []
                    if mode == "ax" || mode == "som" {
                        content.append(["type": "text", "text": text])
                    }
                    if mode == "vision" || mode == "som" {
                        if let png = Screenshot.captureAppWindowPNG(
                            pid: runningApp.processIdentifier)
                        {
                            content.append(["type": "image", "mimeType": "image/png", "data": png])
                        } else if mode == "vision" {
                            // Vision mode with no screenshot is useless — surface
                            // the failure instead of returning empty content.
                            throw MCPError(
                                code: -32000,
                                message:
                                    "capture_mode=vision requested but Screen Recording permission appears to be missing. Call get_permissions to confirm."
                            )
                        }
                    }
                    return ["content": content]
                }
            ),
            Tool(
                name: "get_clipboard",
                description:
                    "Return the current plain-text contents of the system pasteboard. Useful for agents that coordinate via the clipboard (e.g. Shortcuts, inter-app text transfer).",
                schema: [
                    "name": "get_clipboard",
                    "description": "Return the current plain-text clipboard contents.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:] as [String: Any],
                        "additionalProperties": false,
                    ],
                ],
                handler: { _ in
                    let text = Tools.getClipboard()
                    return ["content": [["type": "text", "text": text]]]
                }
            ),
            Tool(
                name: "set_clipboard",
                description:
                    "Replace the system pasteboard's plain-text contents with the given string. Returns 'ok' on success.",
                schema: [
                    "name": "set_clipboard",
                    "description": "Set the system pasteboard to the given string.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"]
                        ] as [String: Any],
                        "required": ["text"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let text = args["text"] as? String else {
                        throw MCPError(code: -32602, message: "set_clipboard requires 'text'")
                    }
                    let ok = Tools.setClipboard(text)
                    return [
                        "content": [["type": "text", "text": ok ? "ok" : "pasteboard write failed"]]
                    ]
                }
            ),
            Tool(
                name: "wait_for_element",
                description:
                    "Poll the target app's AX tree until an element matches `predicate` (substring-matched case-insensitively against each line of the rendered tree). Returns the element's index on success. Use between a click and the next action to wait for a dialog / new tab / loading state to resolve, instead of sleeping blindly.",
                schema: [
                    "name": "wait_for_element",
                    "description":
                        "Wait for an element matching `predicate` in the target app's AX tree. Returns the element's index on success.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "app": [
                                "type": "string",
                                "description": "Bundle identifier or app name.",
                            ],
                            "predicate": [
                                "type": "string",
                                "description":
                                    "Substring to find in a tree line (case-insensitive). e.g. 'button save' or 'sheet'.",
                            ],
                            "timeout_ms": [
                                "type": "integer",
                                "description": "Max wait before timing out (default 5000).",
                            ],
                        ] as [String: Any],
                        "required": ["app", "predicate"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let app = args["app"] as? String, !app.isEmpty else {
                        throw MCPError(code: -32602, message: "wait_for_element requires 'app'")
                    }
                    guard let predicate = args["predicate"] as? String, !predicate.isEmpty else {
                        throw MCPError(
                            code: -32602, message: "wait_for_element requires 'predicate'")
                    }
                    let timeout =
                        (args["timeout_ms"] as? Int)
                        ?? (args["timeout_ms"] as? NSNumber)?.intValue
                        ?? 5000
                    let idx = try Tools.waitForElement(
                        app: app, matching: predicate, timeoutMs: timeout)
                    return ["content": [["type": "text", "text": "element_index=\(idx)"]]]
                }
            ),
            Tool(
                name: "paste",
                description:
                    "Paste `text` into the currently focused input of the target app. Routes via NSPasteboard + cmd+v — faster than type_text for long or unicode-heavy content and avoids Chromium's per-scalar keyboard trust filter. Prior clipboard contents are restored after the paste.",
                schema: [
                    "name": "paste",
                    "description": "Paste text via NSPasteboard + cmd+v.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "app": [
                                "type": "string",
                                "description": "Optional target app bundle ID or name.",
                            ],
                        ] as [String: Any],
                        "required": ["text"],
                        "additionalProperties": false,
                    ],
                ],
                handler: { args in
                    guard let text = args["text"] as? String else {
                        throw MCPError(code: -32602, message: "paste requires 'text'")
                    }
                    try Tools.paste(text, app: args["app"] as? String)
                    return ["content": [["type": "text", "text": "ok"]]]
                }
            ),
            Tool(
                name: "get_permissions",
                description:
                    "Report which macOS TCC permissions this server currently holds. Lets clients surface actionable setup steps to the user if anything is missing.",
                schema: [
                    "name": "get_permissions",
                    "description":
                        "Report current AX + Screen Recording TCC grant state.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [:] as [String: Any],
                        "additionalProperties": false,
                    ],
                ],
                handler: { _ in
                    let ax = Permissions.axTrusted()
                    let sr = Permissions.screenRecordingGranted()
                    let status: String
                    switch (ax, sr) {
                    case (true, true):
                        status =
                            "All required TCC permissions granted. Server is fully operational."
                    case (true, false):
                        status =
                            "Accessibility granted; Screen Recording NOT granted. Element actions work; get_app_state screenshots will be blank. Grant in System Settings → Privacy & Security → Screen Recording."
                    case (false, true):
                        status =
                            "Screen Recording granted; Accessibility NOT granted. No tools will work. Grant in System Settings → Privacy & Security → Accessibility."
                    case (false, false):
                        status =
                            "Neither Accessibility nor Screen Recording granted. No tools will work. Grant both in System Settings → Privacy & Security."
                    }
                    return ["content": [["type": "text", "text": status]]]
                }
            ),
        ]
    }

    static func lookup(_ name: String) -> Tool? {
        return all.first { $0.name == name }
    }
}

private func formatAppList(_ apps: [[String: Any]]) -> String {
    Tools.renderAppList(apps)
}

final class MCPServer {
    private let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private let serverInfo: [String: Any] = ["name": "mac-cua-mcp", "version": "0.1.1"]

    func run() {
        let stdout = FileHandle.standardOutput
        while let raw = readLine(strippingNewline: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            handle(message: msg, stdout: stdout)
        }
    }

    private func handle(message: [String: Any], stdout: FileHandle) {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            if let id = id {
                writeError(to: stdout, id: id, code: -32600, message: "Missing method")
            }
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
                writeResponse(
                    to: stdout, id: id!,
                    result: [
                        "content": [["type": "text", "text": err.message]],
                        "isError": true,
                    ])
            } else {
                writeError(to: stdout, id: id!, code: err.code, message: err.message)
            }
        } catch {
            if method == "tools/call" {
                writeResponse(
                    to: stdout, id: id!,
                    result: [
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
        let version =
            (requested != nil && supportedProtocols.contains(requested!))
            ? requested! : supportedProtocols[0]
        return [
            "protocolVersion": version,
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false, "subscribe": false],
                "prompts": ["listChanged": false],
            ],
            "serverInfo": serverInfo,
            "instructions": """
            Native macOS Computer Use MCP server.

            Usage:
              1. Call get_app_state on a target app each turn before
                 issuing any action. The returned tree assigns element
                 indices used by click / set_value / scroll /
                 perform_secondary_action.
              2. Tool actions run in the background: the target app
                 does not come to the foreground, the user's cursor
                 does not move, and their frontmost app is preserved.
              3. Prefer element_index over pixel coordinates for AX-
                 addressable targets — faster, more reliable, and not
                 subject to window-layout drift.
              4. Pixel clicks into Chromium/Electron web content work
                 via a trusted per-pid SkyLight path; a one-time primer
                 click satisfies the renderer's user-activation gate.
            """,
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
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        stdout.write(data)
        stdout.write(Data([0x0A]))
    }
}

struct MCPError: Error {
    let code: Int
    let message: String
}
