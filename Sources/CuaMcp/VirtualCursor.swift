import AppKit
import Foundation

/// Agent-cursor overlay. Draws a distinctive synthetic pointer that animates
/// to each target along a Bezier arc, pulses on click, and fades when idle.
/// Soft violet pointer with Bezier arc motion, click pulse, and a
/// ripple bloom halo. Tip rotates to point toward the motion direction;
/// defaults to NW (upper-left) when idle, matching macOS cursor
/// convention.
///
/// Enabled by default — set `CUA_HIDE_CURSOR=1` for the purely-invisible
/// mode.
final class VirtualCursor {
    static let shared = VirtualCursor()
    private init() {}

    private var panel: NSPanel?
    private var contentView: CursorContentView?
    private let cursorSize = NSSize(width: 80, height: 80)
    /// Auto-hide after this many seconds of no `animate`/`pulse` calls.
    /// Prevents the overlay from lingering at the last click site after
    /// the agent finishes a turn — invisible by default once the session
    /// is idle.
    private static let idleHideDelay: TimeInterval = 2.0
    private var idleHideTimer: Timer?
    private static let enabled: Bool = {
        return ProcessInfo.processInfo.environment["CUA_HIDE_CURSOR"] != "1"
    }()

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
        p.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary,
        ]
        let container = CursorContentView(frame: contentRect)
        container.wantsLayer = true
        p.contentView = container
        panel = p
        contentView = container
        log("installed panel size=\(cursorSize)")
    }

    /// Animate the overlay to `target` (top-left origin, desktop points).
    /// Motion is a quadratic Bezier arc with the control point offset
    /// perpendicular from the midpoint. For hops < 40pt the motion is
    /// linear with ease-in-out to avoid jittery micro-arcs. The arrow
    /// heading rotates to follow the motion direction.
    func animate(to target: CGPoint, duration: TimeInterval = 0.3, completion: (() -> Void)? = nil)
    {
        guard Self.enabled else {
            completion?()
            return
        }
        ensureInstalled()
        guard let panel, let view = contentView else {
            completion?()
            return
        }
        let screenDest = flipToScreen(target)
        let destOrigin = NSPoint(
            x: screenDest.x - cursorSize.width / 2,
            y: screenDest.y - cursorSize.height / 2)

        let startOrigin: NSPoint
        if !panel.isVisible {
            let currentMouse = NSEvent.mouseLocation
            startOrigin = NSPoint(
                x: currentMouse.x - cursorSize.width / 2,
                y: currentMouse.y - cursorSize.height / 2)
            panel.setFrameOrigin(startOrigin)
            panel.orderFrontRegardless()
            view.beginFadeIn()
        } else {
            startOrigin = panel.frame.origin
        }
        view.setMoving(true)

        let dx = destOrigin.x - startOrigin.x
        let dy = destOrigin.y - startOrigin.y
        let dist = hypot(dx, dy)
        // Heading in NSEvent/top-right-positive space. Convert to arrow
        // rotation: arrow path is drawn with tip at +x, tail to -x. To make
        // the tip lead along motion direction, rotate by motion_angle + π.
        let motionAngle = (dist > 1) ? atan2(dy, dx) : view.heading
        view.setHeading(motionAngle)

        if dist < 40 {
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    panel.animator().setFrameOrigin(destOrigin)
                },
                completionHandler: { [weak self] in
                    view.setMoving(false)
                    completion?()
                    self?.scheduleIdleHide()
                })
            return
        }

        let midX = (startOrigin.x + destOrigin.x) / 2
        let midY = (startOrigin.y + destOrigin.y) / 2
        let nx = -dy / dist
        let ny = dx / dist
        let sag = dist * 0.18
        let ctrl = NSPoint(x: midX + nx * sag, y: midY + ny * sag)

        // Overshoot point — the Bezier curve targets a point past the
        // destination, then a critically-damped spring settles back to the
        // destination. Creates a subtle "click-through" feel where the
        // cursor carries momentum into the click site.
        let overshootMag: CGFloat = min(dist * 0.04, 6.0)
        let ux = dx / dist, uy = dy / dist
        let overshootOrigin = NSPoint(
            x: destOrigin.x + ux * overshootMag,
            y: destOrigin.y + uy * overshootMag)

        let fps: Double = 60
        // Dubins-style phase split: 80% traveling the Bezier arc, 20% for
        // the spring settle. Completion fires once the spring settles.
        let arcFrames = max(4, Int(duration * 0.80 * fps))
        let settleFrames = max(2, Int(duration * 0.25 * fps))
        var frame = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { t in
            frame += 1
            if frame <= arcFrames {
                // Bezier arc phase — cursor travels through control point
                // to the overshoot destination.
                let raw = Double(frame) / Double(arcFrames)
                let p = raw < 0.5 ? (4 * raw * raw * raw) : (1 - pow(-2 * raw + 2, 3) / 2)
                let u = 1 - p
                let x = u * u * startOrigin.x + 2 * u * p * ctrl.x + p * p * overshootOrigin.x
                let y = u * u * startOrigin.y + 2 * u * p * ctrl.y + p * p * overshootOrigin.y
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                let tx = 2 * u * (ctrl.x - startOrigin.x) + 2 * p * (overshootOrigin.x - ctrl.x)
                let ty = 2 * u * (ctrl.y - startOrigin.y) + 2 * p * (overshootOrigin.y - ctrl.y)
                if hypot(tx, ty) > 1 {
                    view.setHeading(atan2(ty, tx))
                }
            } else {
                // Spring settle phase — cursor travels from overshoot
                // back to destination with a damped exponential.
                let s = Double(frame - arcFrames) / Double(settleFrames)
                if s >= 1.0 {
                    panel.setFrameOrigin(destOrigin)
                    t.invalidate()
                    view.setMoving(false)
                    completion?()
                    self.scheduleIdleHide()
                    return
                }
                // Damped oscillator: x = 1 - e^(-3.5·s)·cos(π·s/2).
                // Starts at 0, settles to 1 with a small second-crossing.
                let d = 1.0 - exp(-3.5 * s) * cos(.pi * s * 0.5)
                let xs = (1 - d) * Double(overshootOrigin.x) + d * Double(destOrigin.x)
                let ys = (1 - d) * Double(overshootOrigin.y) + d * Double(destOrigin.y)
                panel.setFrameOrigin(NSPoint(x: xs, y: ys))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func pulse() {
        guard Self.enabled else { return }
        contentView?.pulse()
        scheduleIdleHide()
    }

    /// Reset the auto-hide timer. Called from `animate` completion and
    /// `pulse` so the cursor stays visible while there's activity, then
    /// fades out `idleHideDelay` seconds after the last event.
    private func scheduleIdleHide() {
        idleHideTimer?.invalidate()
        idleHideTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleHideDelay, repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.fadeOut() }
        }
        if let t = idleHideTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func fadeOut() {
        guard let panel = panel, let view = contentView, panel.isVisible else { return }
        view.beginFadeOut { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Flip a top-left-origin desktop point to NSEvent/panel bottom-left
    /// coordinates. macOS's menubar screen (`NSScreen.screens.first`)
    /// defines the y-axis for all other screens — secondary displays have
    /// negative y or y > menubarScreen.height depending on arrangement —
    /// so we always flip against that screen's height, regardless of
    /// which screen the point ends up on. This matches how `NSEvent`
    /// reports coordinates and how AppKit frames are laid out.
    private func flipToScreen(_ point: CGPoint) -> CGPoint {
        guard let menubarScreen = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: menubarScreen.frame.height - point.y)
    }
}

/// Cursor content layer stack:
///   • bloomLayer   — radial cyan glow, always behind
///   • arrowLayer   — gradient-filled 4-point pointer, rotates with heading
///   • strokeLayer  — white outline on arrow, same rotation
/// 4-point pointer rendered with CoreAnimation layers — violet fill,
/// white stroke, radial bloom halo behind.
final class CursorContentView: NSView {
    private let bloomLayer = CALayer()
    private let arrowContainer = CALayer()
    private let arrowLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var isMoving = false
    /// Cursor heading in radians — motion direction. Arrow tip rotates to
    /// point along this vector. Idle heading puts the tip at upper-left
    /// (NW), matching macOS's own idle cursor orientation.
    private(set) var heading: Double = .pi * 0.75  // NW (upper-left) idle.

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear

        bloomLayer.frame = bounds
        bloomLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        bloomLayer.opacity = 0.0
        bloomLayer.contents = Self.renderBloom(size: bounds.size, scale: bloomLayer.contentsScale)
        layer?.addSublayer(bloomLayer)

        arrowContainer.frame = bounds
        layer?.addSublayer(arrowContainer)

        let path = Self.arrowPath(
            scale: bounds.width * 0.55, center: CGPoint(x: bounds.midX, y: bounds.midY))
        arrowLayer.path = path
        // Iridescent violet-blue — distinct from any OS cursor color so users
        // can always tell which pointer is the agent's. Matches Claude brand
        // orange-gradient undertones but stays in the indigo family for
        // high contrast on most app backgrounds.
        arrowLayer.fillColor =
            NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.95, alpha: 1.0).cgColor
        arrowLayer.shadowColor =
            NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.95, alpha: 1).cgColor
        arrowLayer.shadowRadius = 6
        arrowLayer.shadowOpacity = 0.75
        arrowLayer.shadowOffset = .zero
        // Centered at view midpoint; container holds the rotation.
        arrowLayer.frame = bounds
        arrowLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arrowLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arrowLayer.bounds = bounds
        arrowContainer.addSublayer(arrowLayer)

        strokeLayer.path = path
        strokeLayer.fillColor = nil
        strokeLayer.strokeColor = NSColor(white: 1.0, alpha: 0.95).cgColor
        strokeLayer.lineWidth = 1.4
        strokeLayer.lineJoin = .round
        strokeLayer.lineCap = .round
        strokeLayer.frame = bounds
        strokeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        strokeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        strokeLayer.bounds = bounds
        arrowContainer.addSublayer(strokeLayer)

        applyHeading()
    }

    override func layout() {
        super.layout()
        bloomLayer.frame = bounds
        arrowContainer.frame = bounds
        let path = Self.arrowPath(
            scale: bounds.width * 0.55, center: CGPoint(x: bounds.midX, y: bounds.midY))
        arrowLayer.path = path
        strokeLayer.path = path
        arrowLayer.frame = bounds
        arrowLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        strokeLayer.frame = bounds
        strokeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        bloomLayer.contents = Self.renderBloom(size: bounds.size, scale: bloomLayer.contentsScale)
        applyHeading()
    }

    func setMoving(_ moving: Bool) {
        isMoving = moving
        CATransaction.begin()
        CATransaction.setAnimationDuration(moving ? 0.18 : 0.35)
        bloomLayer.opacity = moving ? 0.95 : 0.55
        CATransaction.commit()
    }

    func beginFadeIn() {
        bloomLayer.opacity = 0
        arrowContainer.opacity = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        bloomLayer.opacity = 0.55
        arrowContainer.opacity = 1
        CATransaction.commit()
    }

    /// Fade both layers to zero over 350ms and invoke `completion` once
    /// the fade lands. Caller typically orders the panel out in the
    /// completion block so the fade is visible.
    func beginFadeOut(completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setCompletionBlock(completion)
        bloomLayer.opacity = 0
        arrowContainer.opacity = 0
        CATransaction.commit()
    }

    /// Update arrow rotation to point along the motion direction `radians`
    /// (atan2 of dy,dx in top-left origin — positive Y is downward).
    func setHeading(_ radians: Double) {
        // Arrow path has tip at +x in local space. To make tip lead along
        // motion, rotate by heading (no offset needed — the path itself is
        // defined with tip at +x so motion = rotation angle).
        heading = radians
        applyHeading()
    }

    private func applyHeading() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrowLayer.transform = CATransform3DMakeRotation(CGFloat(heading), 0, 0, 1)
        strokeLayer.transform = CATransform3DMakeRotation(CGFloat(heading), 0, 0, 1)
        CATransaction.commit()
    }

    /// Click feedback: bloom pulse + expanding ring emanating from the tip.
    /// The ring reads instantly as "a click just landed" even on static
    /// screenshots, distinguishing it from the cursor's motion animation.
    func pulse() {
        // Bloom pop — scales the halo briefly.
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.35
        scale.duration = 0.12
        scale.autoreverses = true
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bloomLayer.add(scale, forKey: "pulse")

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = bloomLayer.opacity
        opacity.toValue = 1.0
        opacity.duration = 0.12
        opacity.autoreverses = true
        bloomLayer.add(opacity, forKey: "pulseOpacity")

        // Click ring — a transient shape layer that starts at tip radius
        // and expands outward while fading. Lives for the duration of
        // one animation then removes itself.
        let ring = CAShapeLayer()
        let tipPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let startRadius: CGFloat = 6
        let endRadius: CGFloat = 28
        ring.frame = bounds
        ring.fillColor = nil
        ring.strokeColor = NSColor(
            calibratedRed: 0.70, green: 0.55, blue: 1.0, alpha: 0.9
        ).cgColor
        ring.lineWidth = 2
        ring.path = CGPath(
            ellipseIn: CGRect(
                x: tipPoint.x - startRadius, y: tipPoint.y - startRadius,
                width: startRadius * 2, height: startRadius * 2),
            transform: nil)
        layer?.addSublayer(ring)

        let ringPath = CABasicAnimation(keyPath: "path")
        ringPath.fromValue = ring.path
        ringPath.toValue = CGPath(
            ellipseIn: CGRect(
                x: tipPoint.x - endRadius, y: tipPoint.y - endRadius,
                width: endRadius * 2, height: endRadius * 2),
            transform: nil)
        ringPath.duration = 0.35
        ringPath.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 0.9
        ringFade.toValue = 0.0
        ringFade.duration = 0.35
        ringFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(ringPath, forKey: "ringPath")
        ring.add(ringFade, forKey: "ringFade")
        ring.opacity = 0
        CATransaction.commit()
    }

    /// Figma-style multiplayer cursor path. Tip points to upper-left (top-left
    /// in a 96×104 viewBox), tail trails down-right, matching the collaborative
    /// cursor design used in Figma / Miro / Linear. Source path:
    /// `github.com/mskelton/cursed/apps/react/src/components/Arrow.tsx`.
    ///
    /// Coord conversion: the original SVG has y-axis down, origin top-left.
    /// CALayer default is y-axis up when isFlipped is false, so we flip y
    /// around the centroid and translate to our local anchor. `scale` sets
    /// the final long-axis length in points.
    private static func arrowPath(scale: CGFloat, center: CGPoint) -> CGPath {
        // Stylized 4-point pointer. Tip at `center`, body extends into -x
        // direction (toward west). Heading rotation pivots body around the
        // tip — heading=0 → tip east (body west); heading=3π/4 → tip NW
        // (body SE).
        //
        // Coordinates in local NS space (y-up). Unit: `scale`.
        let tipX: CGFloat = 0, tipY: CGFloat = 0
        let bodyX: CGFloat = -scale * 0.78
        let notchX: CGFloat = -scale * 0.48
        let wingY: CGFloat = scale * 0.30
        // Slight asymmetric lean so the pointer reads less like a generic
        // pixel arrow and more like a stylized agent cursor — upper wing
        // longer than the lower.
        let upperWingY: CGFloat = wingY * 1.08
        let lowerWingY: CGFloat = -wingY * 0.92
        let p = CGMutablePath()
        p.move(to: CGPoint(x: tipX + center.x, y: tipY + center.y))
        p.addLine(to: CGPoint(x: bodyX + center.x, y: upperWingY + center.y))
        p.addLine(to: CGPoint(x: notchX + center.x, y: center.y))
        p.addLine(to: CGPoint(x: bodyX + center.x, y: lowerWingY + center.y))
        p.closeSubpath()
        return p
    }

    /// Pre-rendered radial glow. Centered cyan → transparent, 3-stop
    /// violet→transparent gradient sized to the overlay bounds.
    private static func renderBloom(size: NSSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        let colors =
            [
                CGColor(red: 0.55, green: 0.45, blue: 0.98, alpha: 0.50),
                CGColor(red: 0.45, green: 0.36, blue: 0.95, alpha: 0.18),
                CGColor(red: 0.35, green: 0.26, blue: 0.85, alpha: 0.0),
            ] as CFArray
        let gradient = CGGradient(
            colorsSpace: cs, colors: colors,
            locations: [0.0, 0.55, 1.0])!
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: [])
        return ctx.makeImage()
    }
}
