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

    static func run() {
        _ = previousFrontmost  // force eval while launch frontmost is still them
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppUI()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore focus to whoever was frontmost before we launched.
        // `open /Applications/CuaMcp.app` forces activation even on
        // `.accessory` apps; we undo it immediately so the user's flow
        // isn't interrupted. Menu-bar icon still appears normally.
        NSApp.hide(nil)
        if let prev = Self.previousFrontmost,
           prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate(options: [.activateIgnoringOtherApps])
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "●"
            button.toolTip = "mac-cua MCP server"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        hostingView = PermissionsView(frame: NSRect(x: 0, y: 0, width: 360, height: 320))
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = hostingView
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshBadge()
        }
        refreshBadge()
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

    /// Tint the menu-bar dot based on whether we have the permissions we
    /// need: green when both AX and Screen Recording are granted, yellow
    /// when one is missing, red when both are missing.
    private func refreshBadge() {
        let ax = Permissions.axTrusted()
        let sr = Permissions.screenRecordingGranted()
        guard let button = statusItem.button else { return }
        let color: NSColor
        switch (ax, sr) {
        case (true, true): color = .systemGreen
        case (false, false): color = .systemRed
        default: color = .systemYellow
        }
        let attr = NSAttributedString(
            string: "●",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 14)]
        )
        button.attributedTitle = attr
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
        title.frame = NSRect(x: 16, y: 288, width: 328, height: 20)
        addSubview(title)

        let subtitle = NSTextField(labelWithString: "Native macOS Computer Use for MCP clients.")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 16, y: 270, width: 328, height: 16)
        addSubview(subtitle)

        axRow.frame = NSRect(x: 16, y: 180, width: 328, height: 78)
        axRow.onGrant = { [weak self] in
            if !Permissions.axTrusted(prompt: true) {
                // prompt:true both prompts and opens System Settings the
                // first time the app asks; subsequent calls are no-ops.
                openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
            self?.refresh()
        }
        addSubview(axRow)

        srRow.frame = NSRect(x: 16, y: 96, width: 328, height: 78)
        srRow.onGrant = { [weak self] in
            if !Permissions.requestScreenRecording() {
                openSystemSettings(path: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            self?.refresh()
        }
        addSubview(srRow)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 16, y: 60, width: 328, height: 28)
        statusLabel.maximumNumberOfLines = 2
        addSubview(statusLabel)

        copyButton.frame = NSRect(x: 16, y: 12, width: 180, height: 28)
        copyButton.target = self
        copyButton.action = #selector(copyConfig)
        copyButton.bezelStyle = .rounded
        addSubview(copyButton)

        quitButton.frame = NSRect(x: 252, y: 12, width: 92, height: 28)
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        quitButton.bezelStyle = .rounded
        addSubview(quitButton)

        refresh()
    }

    func refresh() {
        let ax = Permissions.axTrusted()
        let sr = Permissions.screenRecordingGranted()
        axRow.setGranted(ax)
        srRow.setGranted(sr)
        if ax && sr {
            statusLabel.stringValue = "Ready. Point your MCP client at the path below."
        } else if !ax && !sr {
            statusLabel.stringValue = "Grant both permissions to enable all tools."
        } else if !ax {
            statusLabel.stringValue = "Needs Accessibility — the rest of the tools won't work without it."
        } else {
            statusLabel.stringValue = "Needs Screen Recording — screenshots will be blank until granted."
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
