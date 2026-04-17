import AppKit
import Foundation

final class VirtualCursor {
    static let shared = VirtualCursor()
    private init() {}

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private let cursorSize = NSSize(width: 24, height: 24)

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
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let iv = NSImageView(frame: contentRect)
        iv.image = NSCursor.arrow.image
        iv.imageScaling = .scaleProportionallyUpOrDown
        p.contentView = iv
        panel = p
        imageView = iv
    }

    func animate(to target: CGPoint, duration: TimeInterval = 0.3, completion: (() -> Void)? = nil) {
        ensureInstalled()
        guard let panel else { completion?(); return }
        let screenPoint = flipToScreen(target)
        let originY = screenPoint.y - cursorSize.height / 2
        let originX = screenPoint.x - cursorSize.width / 2
        let destOrigin = NSPoint(x: originX, y: originY)
        if !panel.isVisible {
            let currentMouse = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: currentMouse.x - cursorSize.width / 2, y: currentMouse.y - cursorSize.height / 2))
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(destOrigin)
        }, completionHandler: {
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
