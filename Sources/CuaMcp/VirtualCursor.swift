import AppKit
import Foundation

final class VirtualCursor {
    static let shared = VirtualCursor()
    private init() {}

    private var panel: NSPanel?
    private var contentView: NSView?
    private let cursorSize = NSSize(width: 40, height: 40)

    private func log(_ s: String) {
        if ProcessInfo.processInfo.environment["CUA_CURSOR_DEBUG"] != nil {
            FileHandle.standardError.write("[cursor] \(s)\n".data(using: .utf8)!)
        }
    }

    func ensureInstalled() {
        if panel != nil { return }
        let contentRect = NSRect(origin: .zero, size: cursorSize)
        let p = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let container = CursorContentView(frame: contentRect)
        container.wantsLayer = true
        p.contentView = container
        panel = p
        contentView = container
        log("installed panel at level \(p.level.rawValue), size \(cursorSize)")
    }

    func animate(to target: CGPoint, duration: TimeInterval = 0.3, completion: (() -> Void)? = nil) {
        ensureInstalled()
        guard let panel else { completion?(); return }
        let screenPoint = flipToScreen(target)
        let destOrigin = NSPoint(x: screenPoint.x - cursorSize.width / 2,
                                 y: screenPoint.y - cursorSize.height / 2)
        log("animate -> screen=(\(screenPoint.x),\(screenPoint.y)) panel-origin=(\(destOrigin.x),\(destOrigin.y))")
        if !panel.isVisible {
            let currentMouse = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: currentMouse.x - cursorSize.width / 2,
                                         y: currentMouse.y - cursorSize.height / 2))
            panel.orderFrontRegardless()
            log("panel made visible at mouse=(\(currentMouse.x),\(currentMouse.y))")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(destOrigin)
        }, completionHandler: {
            self.log("animate complete")
            completion?()
        })
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func flipToScreen(_ point: CGPoint) -> CGPoint {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return point }
        return CGPoint(x: point.x, y: mainHeight - point.y)
    }
}

final class CursorContentView: NSView {
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        guard let ctx else { return }

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 6, y: bounds.height - 4))
        arrow.line(to: NSPoint(x: 6, y: 6))
        arrow.line(to: NSPoint(x: bounds.width * 0.35, y: bounds.height * 0.35))
        arrow.line(to: NSPoint(x: bounds.width * 0.55, y: bounds.height * 0.35))
        arrow.line(to: NSPoint(x: 6, y: bounds.height - 4))
        arrow.close()

        NSColor(calibratedRed: 1, green: 0.25, blue: 0.35, alpha: 0.92).setFill()
        arrow.fill()

        NSColor.white.setStroke()
        arrow.lineWidth = 2.0
        arrow.stroke()

        let ring = NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.05,
                                               y: bounds.height * 0.05,
                                               width: bounds.width * 0.9,
                                               height: bounds.height * 0.9))
        NSColor.white.withAlphaComponent(0.35).setStroke()
        ring.lineWidth = 1.0
        ring.stroke()
        _ = ctx
    }
}
