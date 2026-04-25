import AppKit
import Foundation

/// Menu-bar app for first-run setup + permission status. Runs when the
/// bundle is launched via Finder (Info.plist sets CUA_MCP_UI_MODE=1 then);
/// the same binary runs as an MCP stdio server when spawned by a client.
final class AppUI: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingView: PermissionsView!
    private var refreshTimer: Timer?

    /// Snapshot whoever was frontmost *before* we launched, so we can
    /// restore them during `applicationDidFinishLaunching`. `open` activates
    /// the target app by default — for a background menu-bar tool that's
    /// unwanted. We can't prevent the initial activation, but we can snap
    /// focus back to the user's previous app before our window server
    /// presence is ever visible.
    private static let previousFrontmost: NSRunningApplication? = {
        return NSWorkspace.shared.frontmostApplication
    }()

    /// Holds the delegate alive — `NSApplication.delegate` is a weak
    /// reference, so the local in `run()` would deallocate the instant
    /// the function frame goes out of scope. Without this, the status
    /// item + timer never install because the delegate is gone before
    /// AppKit fires `applicationDidFinishLaunching`.
    private static var keepAlive: AppUI?

    static func run() {
        _ = previousFrontmost  // force eval while launch frontmost is still them
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppUI()
        Self.keepAlive = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write("[appui] didFinishLaunching\n".data(using: .utf8)!)
        // Restore focus to whoever was frontmost before we launched.
        // `open /Applications/CuaMcp.app` forces activation even on
        // `.accessory` apps; we undo it immediately so the user's flow
        // isn't interrupted. Menu-bar icon still appears normally.
        NSApp.hide(nil)
        if let prev = Self.previousFrontmost,
            prev.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        FileHandle.standardError.write(
            "[appui] statusItem isVisible=\(statusItem.isVisible) length=\(statusItem.length)\n"
                .data(using: .utf8)!)
        if let button = statusItem.button {
            // SF Symbol — `cursorarrow.click.2` reads as an agent cursor.
            // Falls back to a glyph string if the symbol isn't available
            // (e.g. very old macOS) so the menubar item is always visible.
            if let img = NSImage(
                systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "cua-mcp")
            {
                button.image = img
            } else {
                button.title = "◉"
            }
            button.toolTip = "mac-cua MCP server"
            button.action = #selector(togglePopover(_:))
            button.target = self
        } else {
            FileHandle.standardError.write(
                "[appui] WARN: statusItem.button is nil\n".data(using: .utf8)!)
        }
        hostingView = PermissionsView(frame: NSRect(x: 0, y: 0, width: 380, height: 380))
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = hostingView
        // Refresh both the menubar badge tint AND the popover view contents
        // every 1.5s. Without the popover refresh, opening the popover before
        // granting permissions left it stuck on the "Grant" prompts even
        // after the user finished the System Settings flow — the row state
        // only updated on next open.
        let badgeTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshBadge()
            self?.hostingView?.refresh()
        }
        RunLoop.main.add(badgeTimer, forMode: .common)
        refreshTimer = badgeTimer
        refreshBadge()

        // Visibility safety net: on machines with crowded menubars the
        // status item gets clipped behind the notch and becomes
        // unreachable. If we have no permissions yet (first launch),
        // show a regular floating window with the same UI so the user
        // can complete setup without hunting for the menubar item.
        // Dismissed once both permissions are granted.
        let axState = Permissions.axState()
        let sr = Permissions.screenRecordingGranted()
        if axState != .granted || !sr {
            showSetupWindow()
        }
    }

    private var setupWindow: NSWindow?

    /// Floating setup window — fallback when the menubar status item is
    /// hidden under the display notch / Bartender / overflow. Shows the
    /// same `PermissionsView` contents. Auto-dismisses 2 s after the user
    /// finishes granting both permissions. Center of main screen, always
    /// on top, no Dock icon (we stay `.accessory`).
    func showSetupWindow() {
        if setupWindow != nil { return }
        let view = PermissionsView(frame: NSRect(x: 0, y: 0, width: 380, height: 380))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "mac-cua setup"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.center()
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = win
        // Refresh THIS window's view tick-by-tick, and dismiss it once
        // both permissions land. Timer is added to `.common` modes so it
        // fires while the window is tracking events (resize, drag) too,
        // not just when the runloop is in default mode.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
            view.refresh()
            let axState = Permissions.axState()
            let sr = Permissions.screenRecordingGranted()
            FileHandle.standardError.write(
                "[appui] setup-window tick: ax=\(axState.rawValue) sr=\(sr)\n"
                    .data(using: .utf8)!)
            if axState == .granted && sr {
                t.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.setupWindow?.close()
                    self?.setupWindow = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        hostingView.refresh()
        // Intentionally do NOT call NSApp.activate(ignoringOtherApps:) —
        // this is a non-activating panel behaviour. The popover is visible
        // and interactive (buttons still click), but the user's previous
        // app remains frontmost. "Everything in the background" ethos.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Menubar icon. Always a cursor SF symbol rendered as a template
    /// image so macOS handles the light/dark menubar theme automatically
    /// — never set `contentTintColor` to a fixed system color, which
    /// breaks template behavior and renders solid red/yellow on top of
    /// the user's menubar (looks broken in dark mode, garish in light).
    ///
    ///   Ready          → `cursorarrow` outline, template tint.
    ///   Needs setup    → `cursorarrow.fill` outline, template tint, with
    ///                    a small `.exclamationmark.circle.fill` SF
    ///                    composited at the bottom-right of the cursor —
    ///                    the badge carries color (yellow / red) at a
    ///                    size where it still reads on the menubar.
    ///
    /// Tooltip text spells out the actionable state.
    private func refreshBadge() {
        let axState = Permissions.axState()
        let sr = Permissions.screenRecordingGranted()
        guard let button = statusItem.button else { return }

        let baseName = (axState == .granted && sr) ? "cursorarrow" : "cursorarrow.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: baseName, accessibilityDescription: "mac-cua")?
            .withSymbolConfiguration(cfg)

        let badgeColor: NSColor?
        let tooltip: String
        switch (axState, sr) {
        case (.granted, true):
            badgeColor = nil
            tooltip = "mac-cua MCP server — ready"
        case (.staleNeedsRestart, _):
            badgeColor = .systemRed
            tooltip = "mac-cua — TCC stale, quit and re-launch this app"
        case (.notGranted, false):
            badgeColor = .systemRed
            tooltip = "mac-cua — needs Accessibility + Screen Recording"
        case (.notGranted, true):
            badgeColor = .systemOrange
            tooltip = "mac-cua — needs Accessibility"
        case (.granted, false):
            badgeColor = .systemOrange
            tooltip = "mac-cua — needs Screen Recording"
        }

        if let badgeColor, let base = base {
            button.image = Self.composeBadged(base: base, badgeColor: badgeColor)
            // Composited image carries its own color — must NOT be
            // template, otherwise macOS strips our tint and re-applies
            // its own.
            button.image?.isTemplate = false
        } else {
            base?.isTemplate = true
            button.image = base
            button.contentTintColor = nil
        }
        button.toolTip = tooltip
    }

    /// Compose a colored exclamation badge at the bottom-right of `base`
    /// for a menubar icon that signals a setup-needed state without
    /// abandoning the cursor identity. Returns a flattened NSImage.
    private static func composeBadged(base: NSImage, badgeColor: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocusFlipped(false)
        defer { img.unlockFocus() }
        // Tint base to label color so it matches menubar text.
        if let tinted = base.tinted(with: NSColor.labelColor) {
            tinted.draw(
                in: NSRect(origin: .zero, size: size), from: .zero,
                operation: .sourceOver, fraction: 1.0)
        }
        // Badge: small filled circle in the bottom-right quadrant.
        let bRect = NSRect(x: size.width - 9, y: 0, width: 9, height: 9)
        badgeColor.setFill()
        NSBezierPath(ovalIn: bRect).fill()
        return img
    }
}

private extension NSImage {
    /// Return a copy of this image with the given color applied as the
    /// fill color for the alpha mask. Used to template-tint an SF symbol
    /// to label color before we composite a colored badge on top of it.
    func tinted(with color: NSColor) -> NSImage? {
        guard let copy = self.copy() as? NSImage else { return nil }
        copy.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}

/// Hand-rolled NSView-based UI — avoids SwiftUI so the app launches
/// instantly on first grant of AX (SwiftUI view init can hang without AX).
final class PermissionsView: NSView {
    private let axRow = PermissionRow(
        title: "Accessibility",
        description: "Read the AX tree of other apps and post synthetic clicks/keystrokes."
    )
    private let srRow = PermissionRow(
        title: "Screen Recording",
        description: "Capture window screenshots as part of get_app_state."
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy MCP config", target: nil, action: nil)
    private let demoButton = NSButton(title: "Cursor demo", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearance()
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Resolve windowBackgroundColor in the current effective appearance and
    /// re-apply to our layer. `cgColor` is a static snapshot — without this
    /// the popover wouldn't track Light↔Dark mode toggles.
    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func setup() {
        let title = NSTextField(labelWithString: "mac-cua MCP server")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 16, y: 346, width: 348, height: 20)
        addSubview(title)

        let subtitle = NSTextField(labelWithString: "Native macOS Computer Use for MCP clients.")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 16, y: 328, width: 348, height: 16)
        addSubview(subtitle)

        axRow.frame = NSRect(x: 16, y: 238, width: 348, height: 78)
        axRow.onGrant = { [weak self] in
            if !Permissions.axTrusted(prompt: true) {
                // prompt:true both prompts and opens System Settings the
                // first time the app asks; subsequent calls are no-ops.
                openSystemSettings(
                    path:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }
            self?.refresh()
        }
        addSubview(axRow)

        srRow.frame = NSRect(x: 16, y: 154, width: 348, height: 78)
        srRow.onGrant = { [weak self] in
            if !Permissions.requestScreenRecording() {
                openSystemSettings(
                    path:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
            }
            self?.refresh()
        }
        addSubview(srRow)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 108, width: 348, height: 38)
        statusLabel.maximumNumberOfLines = 3
        addSubview(statusLabel)

        let configPath = Bundle.main.executablePath ?? "/usr/local/bin/cua-mcp"
        let pathLabel = NSTextField(labelWithString: configPath)
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.frame = NSRect(x: 16, y: 86, width: 348, height: 18)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        addSubview(pathLabel)

        copyButton.frame = NSRect(x: 16, y: 44, width: 160, height: 28)
        copyButton.target = self
        copyButton.action = #selector(copyConfig)
        copyButton.bezelStyle = .rounded
        addSubview(copyButton)

        demoButton.frame = NSRect(x: 184, y: 44, width: 90, height: 28)
        demoButton.target = self
        demoButton.action = #selector(runDemo)
        demoButton.bezelStyle = .rounded
        addSubview(demoButton)

        quitButton.frame = NSRect(x: 282, y: 44, width: 82, height: 28)
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        quitButton.bezelStyle = .rounded
        addSubview(quitButton)

        // Hint line beneath the buttons.
        let hint = NSTextField(
            labelWithString:
                "Cursor demo sweeps the agent cursor across the screen so you can see the motion + click pulse."
        )
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.frame = NSRect(x: 16, y: 4, width: 348, height: 32)
        addSubview(hint)

        refresh()
    }

    @objc private func runDemo() {
        // Sweep the agent cursor through four corners + center so the user
        // can see what the overlay looks like before any tool invocation.
        guard let screen = NSScreen.main?.frame else { return }
        let points: [CGPoint] = [
            CGPoint(x: screen.width * 0.15, y: screen.height * 0.15),
            CGPoint(x: screen.width * 0.85, y: screen.height * 0.15),
            CGPoint(x: screen.width * 0.85, y: screen.height * 0.85),
            CGPoint(x: screen.width * 0.15, y: screen.height * 0.85),
            CGPoint(x: screen.width * 0.50, y: screen.height * 0.50),
        ]
        DispatchQueue.global().async {
            for p in points {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    VirtualCursor.shared.animate(to: p, duration: 0.5) {
                        VirtualCursor.shared.pulse()
                        sem.signal()
                    }
                }
                _ = sem.wait(timeout: .now() + 1.5)
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    func refresh() {
        let axState = Permissions.axState()
        let sr = Permissions.screenRecordingGranted()
        // Stale state still passes the bool check, but the row shows
        // "Granted" so the user can see the system thinks it's on while
        // the status line tells them to restart.
        axRow.setGranted(axState != .notGranted)
        srRow.setGranted(sr)
        switch (axState, sr) {
        case (.granted, true):
            statusLabel.stringValue = "Ready. Point your MCP client at the path below."
        case (.staleNeedsRestart, _):
            statusLabel.stringValue =
                "Accessibility is granted in System Settings but the cache is stale. "
                + "Quit and re-launch this app (or reboot) to refresh — known macOS bug."
        case (.notGranted, false):
            statusLabel.stringValue = "Grant both permissions to enable all tools."
        case (.notGranted, true):
            statusLabel.stringValue =
                "Needs Accessibility — the rest of the tools won't work without it."
        case (.granted, false):
            statusLabel.stringValue =
                "Needs Screen Recording — screenshots will be blank until granted."
        }
    }

    @objc private func copyConfig() {
        let exe = Bundle.main.executablePath ?? "/usr/local/bin/cua-mcp"
        let config = """
            {
              "mcpServers": {
                "mac-cua": {
                  "command": "\(exe)"
                }
              }
            }
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy MCP config"
        }
    }
}

/// One status row — badge + title + description + Grant button.
final class PermissionRow: NSView {
    var onGrant: (() -> Void)?
    private let badge = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Grant", target: nil, action: nil)

    init(title: String, description: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        descLabel.stringValue = description
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        badge.font = NSFont.systemFont(ofSize: 18)
        badge.frame = NSRect(x: 0, y: 50, width: 18, height: 22)
        addSubview(badge)

        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 24, y: 52, width: 220, height: 18)
        addSubview(titleLabel)

        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.maximumNumberOfLines = 3
        descLabel.frame = NSRect(x: 24, y: 8, width: 304, height: 44)
        addSubview(descLabel)

        button.frame = NSRect(x: 250, y: 48, width: 78, height: 24)
        button.target = self
        button.action = #selector(grantTapped)
        button.bezelStyle = .rounded
        button.controlSize = .small
        addSubview(button)
    }

    @objc private func grantTapped() {
        onGrant?()
    }

    func setGranted(_ granted: Bool) {
        let color: NSColor = granted ? .systemGreen : .systemOrange
        badge.attributedStringValue = NSAttributedString(
            string: "●",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 18)]
        )
        button.title = granted ? "Granted" : "Grant"
        button.isEnabled = !granted
    }
}

private func openSystemSettings(path: String) {
    if let url = URL(string: path) {
        NSWorkspace.shared.open(url)
    }
}
