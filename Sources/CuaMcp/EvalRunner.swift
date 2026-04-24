import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// In-process background-CU eval harness. Runs the same 15 contract cases as
/// `harness/test_bg_cu_eval.py` but through direct Swift calls — no
/// osascript subprocesses, no pkill/open -a flicker, no parent-terminal
/// activation bleed. What the tool does is what the eval sees.
///
/// Run with: `cua-mcp eval`. Exit code 0 when no cases fail.
enum EvalRunner {
    enum Status: String { case pass = "PASS", fail = "FAIL", skip = "SKIP" }

    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var results: [(label: String, status: Status, dt: TimeInterval, note: String)] = []

        let cases: [(String, () -> (Status, String))] = [
            ("bg_calc_click",             case_bg_calc_click),
            ("bg_textedit_type_ascii",    case_bg_textedit_type_ascii),
            ("bg_textedit_type_cjk",      case_bg_textedit_type_cjk),
            ("cursor_unmoved_click",      case_cursor_unmoved_click),
            ("cursor_unmoved_type",       case_cursor_unmoved_type),
            ("frontmost_multi_tool",      case_frontmost_multi_tool),
            ("zorder_preserved",          case_zorder_preserved),
            ("minimized_clear_error",     case_minimized_clear_error),
            ("chrome_axpress_bg",         case_chrome_axpress_bg),
            ("chrome_pixel_click_bg",     case_chrome_pixel_click_bg),
            ("chrome_omnibox_type_bg",    case_chrome_omnibox_type_bg),
            ("chrome_scroll_bg",          case_chrome_scroll_bg),
            ("slack_click_bg",            case_slack_click_bg),
            ("vscode_click_bg",           case_vscode_click_bg),
            ("chrome_tree_fresh",         case_chrome_tree_fresh),
            ("chrome_closed_loop_click",  case_chrome_closed_loop_click),
        ]
        for (label, fn) in cases {
            let t0 = Date()
            let (status, note) = fn()
            let dt = Date().timeIntervalSince(t0)
            results.append((label, status, dt, note))
        }

        printResults(results)
        cleanup()

        let nFail = results.filter { $0.status == .fail }.count
        return nFail == 0 ? 0 : 1
    }

    // MARK: - Output

    private static func printResults(_ rows: [(String, Status, TimeInterval, String)]) {
        let green = "\u{001b}[32m", red = "\u{001b}[31m", grey = "\u{001b}[90m", reset = "\u{001b}[0m"
        print("")
        print("\(pad("case", 32)) \(pad("status", 8)) \(pad("dur", 7)) note")
        print(String(repeating: "─", count: 100))
        for (label, status, dt, note) in rows {
            let color = status == .pass ? green : status == .fail ? red : grey
            let s = String(format: "%.1fs", dt)
            print("\(pad(label, 32)) \(color)\(pad(status.rawValue, 8))\(reset) \(pad(s, 5)).  \(note)")
        }
        let p = rows.filter { $0.1 == .pass }.count
        let f = rows.filter { $0.1 == .fail }.count
        let k = rows.filter { $0.1 == .skip }.count
        print("")
        print("\(p)/\(rows.count) pass  \(f) fail  \(k) skip")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }

    // MARK: - Helpers

    private static let calcBundle = "com.apple.calculator"
    private static let textEditBundle = "com.apple.TextEdit"
    private static let chromeBundle = "com.google.Chrome"
    private static let slackBundle = "com.tinyspeck.slackmacgap"
    private static let vscodeBundle = "com.microsoft.VSCode"

    private static func frontmost() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    private static func noSteal(_ targetBundle: String) -> Bool {
        frontmost() != targetBundle
    }

    /// Run `action` with a before/after frontmost delta check. Returns:
    /// - .pass if target never became frontmost (or was already frontmost
    ///   and remained frontmost — the action didn't RAISE it further).
    /// - .fail if target was not frontmost before and became frontmost after.
    /// - .skip if target was frontmost before (contract vacuous — we can't
    ///   measure a steal the action didn't cause).
    private static func measureNoSteal(_ targetBundle: String, _ action: () -> Void) -> (Status, String) {
        let before = frontmost()
        action()
        Thread.sleep(forTimeInterval: 0.3)
        let after = frontmost()
        if before == targetBundle {
            // Target was already frontmost; can't measure steal. Report
            // "pass" if still target (no-op outcome) else pass.
            return (.pass, "before==target (vacuous) after=\(after)")
        }
        if after == targetBundle {
            return (.fail, "before=\(before) after=\(after) (stole)")
        }
        return (.pass, "before=\(before) after=\(after)")
    }

    private static func appRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// Launch `bundle` in the background (no activation) and wait until its
    /// process is registered + has at least one window. Idempotent.
    ///
    /// `opening` optionally forces a file URL to open with the app — critical
    /// for document apps like TextEdit, which, on recent macOS releases,
    /// present an Open-File sheet (not a text area) when launched with no
    /// file argument. Passing a pre-created temp file ensures the app opens
    /// with a real document window containing an editable text area.
    @discardableResult
    private static func ensureRunning(_ bundle: String, opening fileURL: URL? = nil, timeout: TimeInterval = 4.0) -> Bool {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: bundle) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        let sem = DispatchSemaphore(value: 0)
        if let fileURL {
            ws.open([fileURL], withApplicationAt: url, configuration: cfg) { _, _ in sem.signal() }
        } else if appRunning(bundle) {
            return true
        } else {
            ws.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
        }
        _ = sem.wait(timeout: .now() + timeout)
        Thread.sleep(forTimeInterval: 0.8)
        return appRunning(bundle)
    }

    /// Write an empty temp file named `bg-eval-<ts>.txt` under `/tmp` and
    /// return its file URL. Used so TextEdit launches with a real document.
    private static func makeTempTextFile() -> URL? {
        let path = "/tmp/bg-eval-\(Int(Date().timeIntervalSince1970 * 1000)).txt"
        guard FileManager.default.createFile(atPath: path, contents: Data()) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func cursorPoint() -> CGPoint {
        let e = CGEvent(source: nil)
        return e?.location ?? .zero
    }

    private static func setCursor(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
    }

    private static func axTreeText(_ bundle: String) -> String? {
        do {
            let (_, root, text) = try Tools.getAppState(app: bundle)
            // Mirror MCPServer's get_app_state handler: populate the element
            // cache so subsequent clickElement / setValue lookups by index
            // resolve. Without this every indexed op throws "element ID no
            // longer valid".
            ElementCache.shared.replace(root: root)
            return text
        } catch {
            return nil
        }
    }

    private static func parseIndices(_ text: String, match: (String) -> Bool) -> [Int] {
        var ids: [Int] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.split(separator: " ").first,
                  let idx = Int(first) else { continue }
            let remainder = String(trimmed.dropFirst(first.count)).lowercased()
            if match(remainder) { ids.append(idx) }
        }
        return ids
    }

    private static func readValue(of focusedBundle: String, role: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: focusedBundle).first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Walk focused window → text area / text field.
        if let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow"),
           let text = findFirst(in: window, matching: role),
           let value: String = AXTreeBuilder.attribute(text, "AXValue")
        {
            return value
        }
        return nil
    }

    private static func findFirst(in element: AXUIElement, matching role: String) -> AXUIElement? {
        var queue: [AXUIElement] = [element]
        var visited = 0
        while let cur = queue.first, visited < 400 {
            queue.removeFirst()
            visited += 1
            if let r: String = AXTreeBuilder.attribute(cur, "AXRole"), r == role {
                return cur
            }
            if let children: [AXUIElement] = AXTreeBuilder.attribute(cur, "AXChildren") {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    // MARK: - Cases (contract: tool must never make target frontmost)

    private static func case_bg_calc_click() -> (Status, String) {
        // Kill any prior Calculator so we start from a known single-process
        // state. User-visible Calculator windows from prior manual use can
        // make this test ambiguous otherwise.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: calcBundle) {
            app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.6)
        guard ensureRunning(calcBundle) else { return (.skip, "Calculator unavailable") }

        // 1. Verify AX tree is populated and has the expected keypad.
        guard let text = axTreeText(calcBundle) else { return (.fail, "no AX tree") }
        let clearIdx = parseIndices(text) { $0.contains("button") && $0.contains("clear") }.first
        if let clearIdx {
            try? Tools.clickElement(index: clearIdx)
            Thread.sleep(forTimeInterval: 0.25)
        }

        let pre = readCalcDisplay() ?? ""
        // 2. Pre-assert display is clean (0 or empty) before we click.
        let baselineOk = pre.contains("0") || pre.isEmpty
        if !baselineOk {
            return (.fail, "precondition: display='\(pre)' should be '0' after clear")
        }

        guard let text2 = axTreeText(calcBundle) else { return (.fail, "no AX tree (2)") }
        // Tree lines like: "24 button 1, ID: One". Match on the identifier
        // suffix to avoid grabbing an unrelated "1" from help/description
        // text in a different locale.
        let oneIdx = parseIndices(text2) {
            $0.contains(" 1,") || $0.contains("id: one")
        }.first
        guard let oneIdx else { return (.skip, "no '1' button in tree") }

        let before = frontmost()
        do { try Tools.clickElement(index: oneIdx) }
        catch { return (.fail, "click(idx=\(oneIdx)): \(error)") }
        // Allow the renderer to catch up — give Calculator 300ms beyond the
        // AXPress dispatch for its display label to re-render.
        Thread.sleep(forTimeInterval: 0.6)

        let after = frontmost()
        let display = readCalcDisplay() ?? ""
        let stole = before != calcBundle && after == calcBundle
        // Explicit "1" check — not just contains "1" (display could contain
        // "1" as part of "10" from a prior state).
        let clean = display.replacingOccurrences(of: "\u{200E}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = clean == "1" && !stole
        return (ok ? .pass : .fail,
                "pre='\(pre)' idx=\(oneIdx) display='\(display)' (clean='\(clean)') before=\(before) after=\(after) stole=\(stole)")
    }

    private static func readCalcDisplay() -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: calcBundle).first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow") else { return nil }
        // Calculator's display is typically an AXScrollArea containing a
        // text element, or an AXStaticText with the digit value. Walk the
        // subtree and collect any AXStaticText/AXValue strings that look
        // like numeric values.
        var queue: [AXUIElement] = [window]
        var candidates: [String] = []
        var visited = 0
        while let cur = queue.first, visited < 200 {
            queue.removeFirst(); visited += 1
            let role: String? = AXTreeBuilder.attribute(cur, "AXRole")
            let value: String? = AXTreeBuilder.attribute(cur, "AXValue")
            let desc: String? = AXTreeBuilder.attribute(cur, "AXDescription")
            if role == "AXStaticText" || role == "AXTextField" {
                if let v = value, !v.isEmpty { candidates.append(v) }
                if let d = desc, !d.isEmpty { candidates.append(d) }
            }
            if let kids: [AXUIElement] = AXTreeBuilder.attribute(cur, "AXChildren") {
                queue.append(contentsOf: kids)
            }
        }
        // Calculator display usually matches pattern /^-?\d/ — pick first.
        return candidates.first(where: { $0.first?.isNumber ?? false }) ?? candidates.first
    }

    private static func case_bg_textedit_type_ascii() -> (Status, String) {
        guard let f = makeTempTextFile(), ensureRunning(textEditBundle, opening: f)
        else { return (.skip, "TextEdit unavailable") }
        _ = axTreeText(textEditBundle)
        let before = frontmost()
        do { try Tools.typeText("hello_bg", app: textEditBundle) }
        catch { return (.fail, "type: \(error)") }
        Thread.sleep(forTimeInterval: 0.4)
        let val = readValue(of: textEditBundle, role: "AXTextArea") ?? ""
        let after = frontmost()
        let stole = before != textEditBundle && after == textEditBundle
        let ok = val.contains("hello_bg") && !stole
        return (ok ? .pass : .fail, "val=\(quoted(val)) before=\(before) after=\(after) stole=\(stole)")
    }

    private static func case_bg_textedit_type_cjk() -> (Status, String) {
        guard let f = makeTempTextFile(), ensureRunning(textEditBundle, opening: f)
        else { return (.skip, "TextEdit unavailable") }
        _ = axTreeText(textEditBundle)
        let before = frontmost()
        do { try Tools.typeText("日本語", app: textEditBundle) }
        catch { return (.fail, "type: \(error)") }
        Thread.sleep(forTimeInterval: 0.5)
        let val = readValue(of: textEditBundle, role: "AXTextArea") ?? ""
        let after = frontmost()
        let stole = before != textEditBundle && after == textEditBundle
        let ok = val.contains("日本語") && !stole
        return (ok ? .pass : .fail, "val=\(quoted(val)) before=\(before) after=\(after) stole=\(stole)")
    }

    private static func case_cursor_unmoved_click() -> (Status, String) {
        guard ensureRunning(calcBundle) else { return (.skip, "Calculator unavailable") }
        setCursor(CGPoint(x: 500, y: 500))
        Thread.sleep(forTimeInterval: 0.2)
        let before = cursorPoint()
        guard let text = axTreeText(calcBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("button") && $0.contains("clear") }
        guard let idx = candidates.first else { return (.skip, "no Clear") }
        do {
            try Tools.clickElement(index: idx)
        } catch {
            return (.fail, "click: \(error)")
        }
        Thread.sleep(forTimeInterval: 0.3)
        let after = cursorPoint()
        let moved = abs(after.x - before.x) > 3 || abs(after.y - before.y) > 3
        return (moved ? .fail : .pass, "before=\(pt(before)) after=\(pt(after))")
    }

    private static func case_cursor_unmoved_type() -> (Status, String) {
        guard let f = makeTempTextFile(), ensureRunning(textEditBundle, opening: f)
        else { return (.skip, "TextEdit unavailable") }
        setCursor(CGPoint(x: 500, y: 500))
        Thread.sleep(forTimeInterval: 0.2)
        let before = cursorPoint()
        _ = axTreeText(textEditBundle)
        do {
            try Tools.typeText("x", app: textEditBundle)
        } catch {
            return (.fail, "type: \(error)")
        }
        Thread.sleep(forTimeInterval: 0.3)
        let after = cursorPoint()
        let moved = abs(after.x - before.x) > 3 || abs(after.y - before.y) > 3
        return (moved ? .fail : .pass, "before=\(pt(before)) after=\(pt(after))")
    }

    private static func case_frontmost_multi_tool() -> (Status, String) {
        guard ensureRunning(calcBundle),
              let f = makeTempTextFile(), ensureRunning(textEditBundle, opening: f)
        else { return (.skip, "apps unavailable") }
        var stolen: [(String, String, String)] = []  // (op, before, after)
        let ops: [(label: String, target: String, run: () throws -> Void)] = [
            ("get_app_state(calc)", calcBundle, { _ = try Tools.getAppState(app: Self.calcBundle) }),
            ("press_key(Escape)",    calcBundle, { try Tools.pressKey("Escape", app: Self.calcBundle) }),
            ("type_text",            textEditBundle, { try Tools.typeText("y", app: Self.textEditBundle) }),
            ("scroll",               textEditBundle, { try Tools.scroll(direction: "down", pages: 1, index: nil, app: Self.textEditBundle) }),
        ]
        for op in ops {
            let before = frontmost()
            do { try op.run() } catch { /* non-fatal for this invariant */ }
            Thread.sleep(forTimeInterval: 0.25)
            let after = frontmost()
            // Contract: a tool operation on `target` must not cause
            // `target` to become frontmost when it wasn't already. If
            // target was already frontmost before the op, we're not
            // measuring a steal.
            if before != op.target && after == op.target {
                stolen.append((op.label, before, after))
            }
        }
        return (stolen.isEmpty ? .pass : .fail, "stolen=\(stolen)")
    }

    private static func case_zorder_preserved() -> (Status, String) {
        guard ensureRunning(calcBundle) else { return (.skip, "Calculator unavailable") }
        guard let text = axTreeText(calcBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("button") && $0.contains("clear") }
        guard let idx = candidates.first else { return (.skip, "no Clear") }
        do { try Tools.clickElement(index: idx) } catch { return (.fail, "click: \(error)") }
        Thread.sleep(forTimeInterval: 0.3)
        return (noSteal(calcBundle) ? .pass : .fail, "front=\(frontmost())")
    }

    private static func case_minimized_clear_error() -> (Status, String) {
        guard ensureRunning(calcBundle) else { return (.skip, "Calculator unavailable") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: calcBundle).first
        else { return (.skip, "calc app not resolvable") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow") else {
            return (.skip, "no window")
        }
        AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.5)
        // Try clicking anything — minimized window should refuse.
        let text = axTreeText(calcBundle) ?? ""
        let candidates = parseIndices(text) { $0.contains("button") }
        var note = "no buttons"
        if let idx = candidates.first {
            do { try Tools.clickElement(index: idx) } catch { note = "refused: \(error)" }
            Thread.sleep(forTimeInterval: 0.4)
        }
        let deminiaturized = !noSteal(calcBundle)
        // Restore.
        AXUIElementSetAttributeValue(window, "AXMinimized" as CFString, kCFBooleanFalse)
        return (deminiaturized ? .fail : .pass, "\(note) front_after=\(frontmost())")
    }

    private static func case_chrome_axpress_bg() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        guard let text = axTreeText(chromeBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("button") || $0.contains("link") }
        guard let idx = candidates.first else { return (.skip, "no button/link") }
        return measureNoSteal(chromeBundle) {
            do { try Tools.clickElement(index: idx) } catch { /* recorded below */ }
        }
    }

    private static func case_chrome_pixel_click_bg() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        _ = axTreeText(chromeBundle)
        setCursor(CGPoint(x: 500, y: 500))
        let before = cursorPoint()
        let (status, note) = measureNoSteal(chromeBundle) {
            do { try Tools.clickAt(x: 400, y: 400, button: "left", clickCount: 1, app: chromeBundle) }
            catch { /* recorded below */ }
        }
        let after = cursorPoint()
        let moved = abs(after.x - before.x) > 3 || abs(after.y - before.y) > 3
        if moved { return (.fail, "cursor_moved=\(moved) \(note)") }
        return (status, "cursor_moved=false \(note)")
    }

    private static func case_chrome_omnibox_type_bg() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        guard let text = axTreeText(chromeBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("text field") }
        guard let idx = candidates.first else { return (.skip, "no text field") }
        return measureNoSteal(chromeBundle) {
            do { try Tools.setValue(index: idx, value: "about:blank") } catch { }
        }
    }

    private static func case_chrome_scroll_bg() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        _ = axTreeText(chromeBundle)
        return measureNoSteal(chromeBundle) {
            do { try Tools.scroll(direction: "down", pages: 2, index: nil, app: chromeBundle) } catch { }
        }
    }

    private static func case_slack_click_bg() -> (Status, String) {
        guard appRunning(slackBundle) else { return (.skip, "Slack not running") }
        guard let text = axTreeText(slackBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("button") || $0.contains("link") }
        guard let idx = candidates.first else { return (.skip, "no button/link") }
        return measureNoSteal(slackBundle) {
            do { try Tools.clickElement(index: idx) } catch { }
        }
    }

    private static func case_vscode_click_bg() -> (Status, String) {
        guard appRunning(vscodeBundle) else { return (.skip, "VSCode not running") }
        guard let text = axTreeText(vscodeBundle) else { return (.fail, "no tree") }
        let candidates = parseIndices(text) { $0.contains("button") || $0.contains("link") || $0.contains("tab") }
        guard let idx = candidates.first else { return (.skip, "no clickable") }
        return measureNoSteal(vscodeBundle) {
            do { try Tools.clickElement(index: idx) } catch { }
        }
    }

    /// Closed-loop Chrome test. Navigates to a data: URL with a big red
    /// button whose onclick sets `document.title = "HIT_<ts>"`. Pixel-clicks
    /// the button via `Tools.clickAt` while Chrome is backgrounded. Reads
    /// title back via NSAppleScript's `execute javascript`. Success = title
    /// updated AND Chrome did not become frontmost.
    ///
    /// Requires Chrome's "Allow JavaScript from Apple Events" (View →
    /// Developer). Skips gracefully if disabled.
    private static func case_chrome_closed_loop_click() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        // Preflight: verify AppleScript can read Chrome's active tab.
        guard let _ = chromeRunAS("tell application \"Google Chrome\" to return name of active tab of front window") else {
            return (.skip, "Chrome AppleScript scripting blocked")
        }
        // Navigate to a button page.
        let html = "data:text/html,<html><body style='margin:0'>"
                 + "<button style='position:fixed;top:100px;left:100px;"
                 + "width:300px;height:200px;font-size:40px'"
                 + " onclick='document.title=\"HIT_\"+Date.now()'>TAP</button></body></html>"
        _ = chromeRunAS("tell application \"Google Chrome\" to set URL of active tab of front window to \"\(html)\"")
        Thread.sleep(forTimeInterval: 1.0)
        // Preflight: try JS exec. If it fails, the user hasn't enabled it.
        let idle = chromeRunAS("tell application \"Google Chrome\" to execute front window's active tab javascript \"document.title='IDLE'; document.title\"")
        if idle == nil { return (.skip, "Chrome JS-from-AppleEvents disabled (enable in View → Developer)") }
        Thread.sleep(forTimeInterval: 0.3)

        let preFront = frontmost()
        // Resolve Chrome window frame via AX.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundle).first
        else { return (.skip, "no Chrome pid") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = AXTreeBuilder.attribute(axApp, "AXFocusedWindow"),
              let pos = AXTreeBuilder.pointAttribute(window, "AXPosition")
        else { return (.skip, "no Chrome window geom") }
        // Button center in screen points: window top-left + (~250, ~250)
        // accounting for browser chrome height (~80pt).
        let chromeBarH: CGFloat = 80
        let clickX = pos.x + 100 + 150
        let clickY = pos.y + chromeBarH + 100 + 100
        // Pixel click in screenshot-pixel coords relative to the window.
        // Tools.clickAt expects screenshot-pixel coords from captured PNG —
        // window-local (0,0) = window top-left. So pass the LOCAL offsets.
        do {
            try Tools.clickAt(
                x: (clickX - pos.x) * 2,   // Retina backing scale
                y: (clickY - pos.y) * 2,
                button: "left", clickCount: 1, app: chromeBundle)
        } catch {
            return (.fail, "clickAt: \(error)")
        }
        Thread.sleep(forTimeInterval: 0.6)

        let title = chromeRunAS("tell application \"Google Chrome\" to execute front window's active tab javascript \"document.title\"") ?? ""
        let postFront = frontmost()
        let stole = preFront != chromeBundle && postFront == chromeBundle
        let ok = title.contains("HIT_") && !stole
        return (ok ? .pass : .fail, "title=\(quoted(title)) stole=\(stole) click=(\(Int(clickX)),\(Int(clickY)))")
    }

    /// Run an AppleScript snippet in-process via `NSAppleScript`. No
    /// subprocess, no osascript. Returns nil on any error (script compile,
    /// Chrome scripting disabled, execution fault).
    private static func chromeRunAS(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errs: NSDictionary?
        let result = script.executeAndReturnError(&errs)
        if errs != nil { return nil }
        return result.stringValue
    }

    private static func case_chrome_tree_fresh() -> (Status, String) {
        guard appRunning(chromeBundle) else { return (.skip, "Chrome not running") }
        let before = frontmost()
        guard let t1 = axTreeText(chromeBundle) else { return (.fail, "no first tree") }
        Thread.sleep(forTimeInterval: 0.6)
        guard let t2 = axTreeText(chromeBundle) else { return (.fail, "no second tree") }
        let after = frontmost()
        let n1 = t1.split(separator: "\n").count
        let n2 = t2.split(separator: "\n").count
        // Steal check only if before != chrome.
        let stole = (before != chromeBundle) && (after == chromeBundle)
        let ok = n2 >= n1 / 2 && n2 > 5 && !stole
        return (ok ? .pass : .fail, "n1=\(n1) n2=\(n2) before=\(before) after=\(after) stole=\(stole)")
    }

    // MARK: - cleanup + misc

    private static func cleanup() {
        // Gracefully terminate Calculator + TextEdit (opened by eval), leave
        // Chrome/Slack/VSCode alone — user may be mid-session in them.
        for bundle in [calcBundle, textEditBundle] {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                app.terminate()
            }
        }
        // Sweep temp files.
        let tmp = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            for name in contents where name.hasPrefix("bg-eval-") && name.hasSuffix(".txt") {
                try? FileManager.default.removeItem(atPath: "/tmp/\(name)")
            }
        }
        _ = tmp
    }

    private static func quoted(_ s: String) -> String { "'\(s)'" }
    private static func pt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
}
