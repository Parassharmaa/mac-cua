import AppKit
import ApplicationServices
import Foundation

struct AXNode {
    let index: Int
    let element: AXUIElement
    let role: String?
    let roleDescription: String?
    let title: String?
    let description: String?
    let value: String?
    let help: String?
    let identifier: String?
    let enabled: Bool?
    let selected: Bool?
    let focused: Bool?
    let settable: Bool
    let valueType: String?
    let position: CGPoint?
    let size: CGSize?
    let actions: [String]
    let children: [AXNode]
}

enum AXError2: Error {
    case appNotFound(String)
    case unexpected(String)
}

final class AXTreeBuilder {
    private var nextIndex = 0

    func build(forAppWithBundleID bundleID: String) throws -> (app: NSRunningApplication, root: AXNode) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else {
            throw AXError2.appNotFound(bundleID)
        }
        return try build(forPID: app.processIdentifier, app: app)
    }

    func build(forPID pid: pid_t, app: NSRunningApplication) throws -> (app: NSRunningApplication, root: AXNode) {
        let axApp = AXUIElementCreateApplication(pid)
        var root: AXUIElement = axApp
        if let focusedWindow: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow") {
            root = focusedWindow
        } else if let windows: [AXUIElement] = AXTreeBuilder.attribute(axApp, "AXWindows"), let first = windows.first {
            root = first
        }
        let node = walk(root, depth: 0, maxDepth: 25)
        return (app, node)
    }

    private func walk(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        let idx = nextIndex
        nextIndex += 1

        let role: String? = AXTreeBuilder.attribute(element, "AXRole")
        let roleDescription: String? = AXTreeBuilder.attribute(element, "AXRoleDescription")
        let title: String? = AXTreeBuilder.attribute(element, "AXTitle")
        let description: String? = AXTreeBuilder.attribute(element, "AXDescription")
        let help: String? = AXTreeBuilder.attribute(element, "AXHelp")
        let identifier: String? = AXTreeBuilder.attribute(element, "AXIdentifier")
        let enabled: Bool? = AXTreeBuilder.attribute(element, "AXEnabled")
        let selected: Bool? = AXTreeBuilder.attribute(element, "AXSelected")
        let focused: Bool? = AXTreeBuilder.attribute(element, "AXFocused")

        var valueString: String? = nil
        var valueType: String? = nil
        if let rawValue: CFTypeRef = AXTreeBuilder.rawAttribute(element, "AXValue") {
            valueString = describeValue(rawValue)
            valueType = cfTypeLabel(rawValue)
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)

        let position: CGPoint? = AXTreeBuilder.pointAttribute(element, "AXPosition")
        let size: CGSize? = AXTreeBuilder.sizeAttribute(element, "AXSize")

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        var actions: [String] = []
        if let arr = actionNames as? [String] {
            actions = arr.filter { $0 != "AXPress" && $0 != "AXCancel" && $0 != "AXConfirm" && $0 != "AXShowMenu" }
                .map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
        }

        var children: [AXNode] = []
        if depth < maxDepth {
            if let rawChildren: [AXUIElement] = AXTreeBuilder.attribute(element, "AXChildren") {
                children = rawChildren.map { walk($0, depth: depth + 1, maxDepth: maxDepth) }
            }
        }

        return AXNode(
            index: idx, element: element,
            role: role, roleDescription: roleDescription,
            title: title, description: description,
            value: valueString, help: help, identifier: identifier,
            enabled: enabled, selected: selected, focused: focused,
            settable: settable.boolValue,
            valueType: valueType,
            position: position, size: size,
            actions: actions, children: children
        )
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard err == .success, let raw else { return nil }
        return raw as? T
    }

    static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard err == .success, let raw else { return nil }
        return raw
    }

    static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let raw = rawAttribute(element, name) else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(raw as! AXValue, .cgPoint, &point) { return point }
        return nil
    }

    static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let raw = rawAttribute(element, name) else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(raw as! AXValue, .cgSize, &size) { return size }
        return nil
    }
}

private func describeValue(_ cfValue: CFTypeRef) -> String? {
    let type = CFGetTypeID(cfValue)
    if type == CFStringGetTypeID() {
        return cfValue as? String
    }
    if type == CFBooleanGetTypeID() {
        return (cfValue as? Bool) == true ? "true" : "false"
    }
    if type == CFNumberGetTypeID() {
        if let n = cfValue as? NSNumber { return n.stringValue }
    }
    return nil
}

private func cfTypeLabel(_ cfValue: CFTypeRef) -> String {
    let type = CFGetTypeID(cfValue)
    if type == CFStringGetTypeID() { return "string" }
    if type == CFBooleanGetTypeID() { return "bool" }
    if type == CFNumberGetTypeID() { return "number" }
    if type == AXValueGetTypeID() { return "ax_value" }
    if type == CFArrayGetTypeID() { return "array" }
    return "unknown"
}

enum AXSerializer {
    static func render(root: AXNode, app: NSRunningApplication) -> String {
        var out = ""
        let bundleId = app.bundleIdentifier ?? "unknown"
        let pid = app.processIdentifier
        out += "App=\(bundleId) (pid \(pid))\n"
        if let title = AXTreeBuilder.attribute(root.element, "AXTitle") as String?,
           let name = app.localizedName {
            out += "Window: \"\(title)\", App: \(name).\n"
        } else if let name = app.localizedName {
            out += "App: \(name).\n"
        }
        renderNode(root, indent: 0, into: &out)
        return out
    }

    private static func renderNode(_ node: AXNode, indent: Int, into out: inout String) {
        let tabs = String(repeating: "\t", count: indent)
        var line = "\(tabs)\(node.index) "
        line += roleLabel(node)
        let modifiers = attributeModifiers(node)
        if !modifiers.isEmpty { line += " (\(modifiers.joined(separator: ", ")))" }
        let inline = inlineDescriptors(node)
        if !inline.isEmpty { line += " " + inline }
        if !node.actions.isEmpty {
            line += ", Secondary Actions: " + node.actions.joined(separator: ", ")
        }
        out += line + "\n"
        for child in node.children {
            renderNode(child, indent: indent + 1, into: &out)
        }
    }

    private static func roleLabel(_ node: AXNode) -> String {
        let label = node.roleDescription ?? stripRolePrefix(node.role) ?? "element"
        let disabled = (node.enabled == false) ? " (disabled)" : ""
        return label + disabled
    }

    private static func stripRolePrefix(_ role: String?) -> String? {
        guard let role, role.hasPrefix("AX") else { return role }
        var s = String(role.dropFirst(2))
        s = s.replacingOccurrences(of: "UIElement", with: "")
        return s.isEmpty ? nil : s.lowercased()
    }

    private static func attributeModifiers(_ node: AXNode) -> [String] {
        var mods: [String] = []
        if node.settable, let t = node.valueType { mods.append("settable, \(t)") }
        else if node.settable { mods.append("settable") }
        if node.selected == true { mods.append("selected") }
        else if node.selected == false { mods.append("selectable") }
        if node.focused == true { mods.append("focused") }
        return mods
    }

    private static func inlineDescriptors(_ node: AXNode) -> String {
        var parts: [String] = []
        if let t = node.title, !t.isEmpty { parts.append(t) }
        if let d = node.description, !d.isEmpty, d != node.title { parts.append("Description: \(d)") }
        if let v = node.value, !v.isEmpty, v != node.title, v != node.description { parts.append("Value: \(v)") }
        if let h = node.help, !h.isEmpty { parts.append("Help: \(h)") }
        if let id = node.identifier, !id.isEmpty { parts.append("ID: \(id)") }
        return parts.joined(separator: ", ")
    }
}
