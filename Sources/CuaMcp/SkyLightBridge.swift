import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

/// Bridge to SkyLight's private per-pid event-post path, with the
/// `SLSEventAuthenticationMessage` envelope Chromium requires for keyboard.
///
/// Why: public `CGEvent.postToPid` delivers to the target's mach port but
/// skips the `CGSTickleActivityMonitor` → `IOHIDPostEvent` chain that marks
/// events as "live input." Chromium's renderer-IPC boundary filters events
/// missing that trust signal — your click lands in the outer window process
/// and vanishes. `SLEventPostToPid` routes through the activity-monitor
/// tickle so Chromium accepts the event.
///
/// Keyboard on macOS 14+ additionally needs an `SLSEventAuthenticationMessage`
/// envelope attached via `SLEventSetAuthenticationMessage`. Mouse events go
/// through without the envelope (empirically — envelope diverts mouse onto
/// a direct-mach path that bypasses `cgAnnotatedSessionEventTap`, which
/// Chromium's window event handler subscribes to).
///
/// All symbols/classes resolve lazily via `dlopen` + `dlsym` +
/// `NSClassFromString`. Any resolution failure falls through to the public
/// `CGEvent.postToPid` path via `postToPid` returning `false`.
enum SkyLightBridge {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias FactoryMsgSendFn =
        @convention(c) (
            AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32
        ) -> AnyObject?

    private struct Resolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private static let resolved: Resolved? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        func fn<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        guard
            let postToPid = fn("SLEventPostToPid", as: PostToPidFn.self),
            let setAuth = fn("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
            let msgSend = fn("objc_msgSend", as: FactoryMsgSendFn.self),
            let messageClass = NSClassFromString("SLSEventAuthenticationMessage")
        else { return nil }

        return Resolved(
            postToPid: postToPid,
            setAuthMessage: setAuth,
            msgSendFactory: msgSend,
            messageClass: messageClass,
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    private static let setWindowLocationFn: SetWindowLocationFn? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        else {
            return nil
        }
        return unsafeBitCast(p, to: SetWindowLocationFn.self)
    }()

    /// True when the full auth-signed post path resolves.
    static var isAvailable: Bool { resolved != nil }

    /// True when `CGEventSetWindowLocation` resolved.
    static var isWindowLocationAvailable: Bool { setWindowLocationFn != nil }

    /// Post `event` to `pid` via `SLEventPostToPid`.
    ///
    /// `attachAuthMessage=true` (keyboard path) attaches the SLS envelope so
    /// Chromium accepts the event as trusted input. Mouse events should pass
    /// `false` — the envelope forks onto a direct-mach delivery that bypasses
    /// `cgAnnotatedSessionEventTap`.
    ///
    /// Returns `true` when the post was attempted via SkyLight. Returns
    /// `false` when resolution failed — caller should fall back to
    /// `event.postToPid(pid)`.
    @discardableResult
    static func postToPid(_ pid: pid_t, event: CGEvent, attachAuthMessage: Bool = false) -> Bool {
        guard let r = resolved else { return false }
        if attachAuthMessage, let record = extractEventRecord(from: event) {
            if let msg = r.msgSendFactory(
                r.messageClass as AnyObject, r.factorySelector, record, pid, 0)
            {
                r.setAuthMessage(event, msg)
            }
        }
        r.postToPid(pid, event)
        return true
    }

    /// Stamp a window-local point onto `event` via `CGEventSetWindowLocation`.
    /// WindowServer hit-tests directly with this instead of reprojecting from
    /// screen space — more reliable when target is occluded.
    @discardableResult
    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let fn = setWindowLocationFn else { return false }
        fn(event, point)
        return true
    }

    /// Extract embedded `SLSEventRecord *` from a `CGEvent`. Layout per
    /// SkyLight ObjC type encodings: `{CFRuntimeBase, uint32_t, SLSEventRecord *}`
    /// which on 64-bit puts the record pointer at offset 24. Probe adjacent
    /// offsets for resilience across OS revisions.
    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(
                to: UnsafeMutableRawPointer?.self)
            if let p = slot.pointee { return p }
        }
        return nil
    }

    // MARK: - Focus-without-raise SPIs (yabai recipe)
    //
    // Activates a target app for AppKit event routing without asking
    // WindowServer to raise its window or trigger Space follow. Recipe:
    //
    //   1. `_SLPSGetFrontProcess(&prev)` — capture current frontmost PSN.
    //   2. `GetProcessForPID(target, &tgt)` — resolve target PSN.
    //   3. `SLPSPostEventRecordTo(prev, buf[0x8A]=0x02)` — defocus prev.
    //   4. `SLPSPostEventRecordTo(tgt, buf[0x8A]=0x01, wid@0x3C..3F)` — focus.
    //
    // Deliberately skips `SLPSSetFrontProcessWithOptions` — that's the step
    // that would raise the window / follow Space. After the recipe, target
    // `isActive=true`, accepts synthetic events as trusted input, but the
    // window stays wherever it was in the z-stack.

    private typealias PostEventRecordToFn =
        @convention(c) (
            UnsafeRawPointer, UnsafePointer<UInt8>
        ) -> Int32
    private typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let postEventRecordToFn: PostEventRecordToFn? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLPSPostEventRecordTo") else {
            return nil
        }
        return unsafeBitCast(p, to: PostEventRecordToFn.self)
    }()

    private static let getFrontProcessFn: GetFrontProcessFn? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_SLPSGetFrontProcess") else {
            return nil
        }
        return unsafeBitCast(p, to: GetFrontProcessFn.self)
    }()

    private static let getProcessForPIDFn: GetProcessForPIDFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else {
            return nil
        }
        return unsafeBitCast(p, to: GetProcessForPIDFn.self)
    }()

    static var isFocusWithoutRaiseAvailable: Bool {
        getFrontProcessFn != nil && getProcessForPIDFn != nil && postEventRecordToFn != nil
    }

    /// Put `targetPid` into AppKit-active state pointing at its window
    /// `targetWid` without raising the window or triggering Space follow.
    /// Returns `false` when SPIs unavailable or event posts failed.
    @discardableResult
    static func activateWithoutRaise(targetPid: pid_t, targetWid: CGWindowID) -> Bool {
        guard let getFront = getFrontProcessFn,
            let getPSN = getProcessForPIDFn,
            let post = postEventRecordToFn
        else { return false }

        // PSN buffers: 8 bytes each (high UInt32 + low UInt32).
        var prevPSN = [UInt32](repeating: 0, count: 2)
        var targetPSN = [UInt32](repeating: 0, count: 2)

        let prevOk = prevPSN.withUnsafeMutableBytes { raw in
            getFront(raw.baseAddress!) == 0
        }
        guard prevOk else { return false }

        let targetOk = targetPSN.withUnsafeMutableBytes { raw in
            getPSN(targetPid, raw.baseAddress!) == 0
        }
        guard targetOk else { return false }

        // 248-byte event record layout (from yabai source, verified on macOS 15):
        //   bytes[0x04] = 0xF8        — opcode high
        //   bytes[0x08] = 0x0D        — opcode low
        //   bytes[0x3C..0x3F]         — little-endian CGWindowID (target only)
        //   bytes[0x8A]               — 0x01 focus / 0x02 defocus
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8
        buf[0x08] = 0x0D
        let wid = UInt32(targetWid)
        buf[0x3C] = UInt8(wid & 0xFF)
        buf[0x3D] = UInt8((wid >> 8) & 0xFF)
        buf[0x3E] = UInt8((wid >> 16) & 0xFF)
        buf[0x3F] = UInt8((wid >> 24) & 0xFF)

        // Defocus previous front.
        buf[0x8A] = 0x02
        let defocusOk = prevPSN.withUnsafeBytes { psnRaw in
            buf.withUnsafeBufferPointer { bp in
                post(psnRaw.baseAddress!, bp.baseAddress!) == 0
            }
        }

        // Focus target.
        buf[0x8A] = 0x01
        let focusOk = targetPSN.withUnsafeBytes { psnRaw in
            buf.withUnsafeBufferPointer { bp in
                post(psnRaw.baseAddress!, bp.baseAddress!) == 0
            }
        }

        return defocusOk && focusOk
    }

    /// Resolve a target pid to its primary on-screen `CGWindowID` for use
    /// with `activateWithoutRaise`. Prefers the first on-screen window owned
    /// by `pid`, matching CGWindowList's front-to-back order so we pick the
    /// topmost visible window for that process.
    ///
    /// Fallback: the private `_AXUIElementGetWindow` SPI converts an
    /// AXUIElement (focused window) directly to its CGWindowID. Used when
    /// the CGWindowList walk finds nothing (rare — process exists but has
    /// no on-screen windows).
    static func primaryWindowID(forPid pid: pid_t) -> CGWindowID? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32,
                ownerPid == pid,
                let num = info[kCGWindowNumber as String] as? Int
            else { continue }
            // Skip layer > 0 windows (menubar, dock, floating utility) — the
            // primary window is layer 0.
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            return CGWindowID(num)
        }
        // No on-screen layer-0 window. Try any on-screen window for this pid.
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32,
                ownerPid == pid,
                let num = info[kCGWindowNumber as String] as? Int
            else { continue }
            return CGWindowID(num)
        }
        return nil
    }
}
