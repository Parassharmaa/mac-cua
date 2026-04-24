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
    private var nodeBudget = 1500
    private var budgetExceeded = false

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

    private static let batchAttrs: [CFString] = [
        "AXRole" as CFString, "AXRoleDescription" as CFString,
        "AXTitle" as CFString, "AXDescription" as CFString,
        "AXHelp" as CFString, "AXIdentifier" as CFString,
        "AXEnabled" as CFString, "AXSelected" as CFString, "AXFocused" as CFString,
        "AXValue" as CFString,
    ]

    private func walk(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        let idx = nextIndex
        nextIndex += 1

        var batched: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, AXTreeBuilder.batchAttrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &batched)
        let arr = (batched as? [Any]) ?? []
        func strAt(_ i: Int) -> String? {
            guard i < arr.count else { return nil }
            return arr[i] as? String
        }
        func boolAt(_ i: Int) -> Bool? {
            guard i < arr.count else { return nil }
            return arr[i] as? Bool
        }
        let role = strAt(0)
        let roleDescription = strAt(1)
        let title = strAt(2)
        let description = strAt(3)
        let help = strAt(4)
        let identifier = strAt(5)
        let enabled = boolAt(6)
        let selected = boolAt(7)
        let focused = boolAt(8)

        var valueString: String? = nil
        var valueType: String? = nil
        if arr.count > 9 {
            let rawValue = arr[9] as CFTypeRef
            if CFGetTypeID(rawValue) != CFNullGetTypeID() {
                valueString = describeValue(rawValue)
                valueType = cfTypeLabel(rawValue)
            }
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)

        let position: CGPoint? = AXTreeBuilder.pointAttribute(element, "AXPosition")
        let size: CGSize? = AXTreeBuilder.sizeAttribute(element, "AXSize")

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        var actions: [String] = []
        if let arr = actionNames as? [String] {
            let isScrollArea = role == "AXScrollArea"
            actions = arr
                .filter { name in
                    if ["AXPress", "AXCancel", "AXConfirm", "AXShowMenu"].contains(name) { return false }
                    // ScrollByPage actions are redundant with the role itself.
                    if isScrollArea && name.hasPrefix("AXScroll") && name.hasSuffix("ByPage") { return false }
                    return true
                }
                .map { cleanActionName($0) }
        }

        var children: [AXNode] = []
        if depth < maxDepth && !budgetExceeded {
            if let rawChildren: [AXUIElement] = AXTreeBuilder.attribute(element, "AXChildren") {
                let limited = collapseRepeated(rawChildren, keep: 40)
                for child in limited {
                    if nextIndex >= nodeBudget {
                        budgetExceeded = true
                        break
                    }
                    children.append(walk(child, depth: depth + 1, maxDepth: maxDepth))
                }
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

    /// Strip "AX" prefix + pick the short action name out of selector-dump junk like
    /// "Name:Copy\nTarget:0x0\nSelector:(null)".
    private func cleanActionName(_ raw: String) -> String {
        var s = raw
        if let firstLine = s.split(separator: "\n").first {
            s = String(firstLine)
        }
        if let colon = s.range(of: "Name:") {
            s = String(s[colon.upperBound...])
        }
        if s.hasPrefix("AX") { s = String(s.dropFirst(2)) }
        return s
    }

    /// Cap number of children walked per node — mirrors how Sky elides long lists.
    private func collapseRepeated(_ children: [AXUIElement], keep: Int) -> [AXUIElement] {
        if children.count <= keep + 5 { return children }
        return Array(children.prefix(keep))
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
        if let instructions = appSpecificInstructions(bundleId: bundleId) {
            out += "<app_specific_instructions>\n\(instructions)\n</app_specific_instructions>\n"
        }
        out += "<app_state>\n"
        out += "App=\(bundleId) (pid \(pid))\n"
        if let title = AXTreeBuilder.attribute(root.element, "AXTitle") as String?,
           let name = app.localizedName {
            out += "Window: \"\(title)\", App: \(name).\n"
        } else if let name = app.localizedName {
            out += "App: \(name).\n"
        }
        renderNode(root, indent: 0, into: &out)

        // Sky emits a "The focused UI element is N …" trailer at the end of
        // its AX tree. This is the biggest practical signal for models
        // deciding whether to type_text immediately vs first clicking a
        // text field. Locate the focused node in our walked subtree and
        // emit it with the same shape.
        if let focused = firstFocusedLeaf(root) {
            out += "\nThe focused UI element is \(focused.index) \(roleLabel(focused))"
            let inline = inlineDescriptors(focused)
            if !inline.isEmpty { out += " \(inline)" }
            out += "\n"
        }
        out += "</app_state>"
        return out
    }

    /// Per-bundle contextual hints Sky embeds at the top of get_app_state.
    /// These are compact operating guidelines that steer the model without
    /// lengthening the tree body.
    private static func appSpecificInstructions(bundleId: String) -> String? {
        switch bundleId {
        case "com.google.Chrome", "com.google.Chrome.canary",
             "com.apple.Safari", "com.microsoft.edgemac",
             "com.brave.Browser", "org.mozilla.firefox":
            return """
            When navigating to a new website or starting a separate web task, prefer opening a new tab instead of reusing the current tab. Use press_key cmd+t to open a new tab, then type the URL and press Return.
            """
        default:
            return nil
        }
    }

    private static func firstFocusedLeaf(_ node: AXNode) -> AXNode? {
        // Prefer the deepest focused descendant — top-level windows often
        // report focused=true too, but we want the most specific target.
        var result: AXNode?
        func walk(_ n: AXNode) {
            if n.focused == true { result = n }
            for c in n.children { walk(c) }
        }
        walk(node)
        return result
    }

    private static func renderNode(_ node: AXNode, indent: Int, into out: inout String) {
        // Collapse pass-through wrapper groups — SwiftUI apps like Finder,
        // TextEdit, Chrome wrap content in several naked AXGroup layers.
        // Skip rendering this line but still walk children (so the indices
        // remain stable and clickable by element_index).
        if isPassThroughGroup(node) {
            for child in node.children {
                renderNode(child, indent: indent, into: &out)
            }
            return
        }
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

    /// A pass-through node carries no identifying info and exists only to
    /// group children in AX — safe to elide from the rendered tree. Skipping
    /// these doesn't break element_index because every node still gets an
    /// index during the walk.
    private static func isPassThroughGroup(_ node: AXNode) -> Bool {
        guard node.role == "AXGroup" else { return false }
        if nonEmpty(node.title) != nil { return false }
        if nonEmpty(node.description) != nil { return false }
        if nonEmpty(node.identifier) != nil { return false }
        if nonEmpty(node.value) != nil { return false }
        if !node.actions.isEmpty { return false }
        if node.selected == true || node.focused == true { return false }
        return true
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

    /// Match Sky's inline label packing:
    ///   • collapse exact duplicates across title/description/identifier
    ///     (e.g. `button Description: Percent, ID: Percent` → `button Percent`)
    ///   • drop the `Help:` prefix when help duplicates description
    ///   • drop the `Value:` prefix for text-like roles where the value IS
    ///     the element's content (AXStaticText, AXText).
    private static func inlineDescriptors(_ node: AXNode) -> String {
        var parts: [String] = []
        let title = nonEmpty(node.title)
        let desc = nonEmpty(node.description)
        let id = nonEmpty(node.identifier)

        // Bare label (no prefix) — pick the "best" single name: title wins,
        // else description, else identifier.
        let bareLabel: String?
        if let title { bareLabel = title }
        else if let desc { bareLabel = desc }
        else if let id { bareLabel = id }
        else { bareLabel = nil }
        if let bareLabel { parts.append(bareLabel) }

        // Add Description only if different from the bare label already emitted.
        if let desc, desc != bareLabel {
            parts.append("Description: \(desc)")
        }

        // Value: drop prefix for plain text roles; also skip if value equals
        // anything we've already rendered.
        if let v = nonEmpty(node.value), v != bareLabel, v != desc {
            if node.role == "AXStaticText" || node.role == "AXText" {
                parts.append("Value: \(v)")
            } else {
                parts.append("Value: \(v)")
            }
        }

        // Help only if it adds info beyond description.
        if let h = nonEmpty(node.help), h != desc, h != bareLabel {
            parts.append("Help: \(h)")
        }

        // Identifier only if distinct from everything we've shown.
        if let id, id != bareLabel, id != desc {
            parts.append("ID: \(id)")
        }
        return parts.joined(separator: ", ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
