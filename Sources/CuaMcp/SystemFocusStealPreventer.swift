import AppKit
import Foundation

/// Layer 3 of the focus-suppression stack — **reactive** countermeasure for
/// the "target app self-activates in response to a synthetic event" failure
/// mode.
///
/// Mechanism (pure public AppKit — no private SPIs):
///
///   1. Subscribe to `NSWorkspace.didActivateApplicationNotification`.
///   2. When the newly-active app matches the suppressed `targetPid`, call
///      `restoreTo.activate(options: [])` on the main actor **synchronously
///      within the same runloop turn** as the activation notification.
///   3. The zero-delay synchronous demote completes before WindowServer
///      composites the next frame, so the target never visually reaches
///      the front — the user sees no flicker.
///
/// Why this is necessary: even when the tool's post path (SLEventPostToPid +
/// AXESynthesizedIgnoreEventSourceID + yabai FocusWithoutRaise) does
/// everything right, the TARGET app's own response to the event may include
/// an `NSApp.activate(ignoringOtherApps: true)` call — e.g. Chromium's
/// renderer reacting to an activation message, Safari's WebKit process
/// binding focus to a text field. The preventer watches for this and
/// immediately restores the previous frontmost.
///
/// Usage:
/// ```
/// let handle = SystemFocusStealPreventer.shared.beginSuppression(
///     targetPid: pid, restoreTo: NSWorkspace.shared.frontmostApplication!)
/// defer { SystemFocusStealPreventer.shared.endSuppression(handle) }
/// // post events...
/// ```
final class SystemFocusStealPreventer {
    static let shared = SystemFocusStealPreventer()

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var observer: NSObjectProtocol?

    private struct Entry {
        let targetPid: pid_t
        let restoreTo: NSRunningApplication
    }

    struct Handle: Hashable {
        fileprivate let id: UUID
    }

    private init() {}

    /// Begin suppressing focus-steal events for `targetPid`. Any activation
    /// notification that names `targetPid` as the newly-active app
    /// triggers an immediate `restoreTo.activate(options: [])`. Overlapping
    /// calls for different targets are independent — each has its own
    /// `(pid, restoreTo)` entry.
    @discardableResult
    func beginSuppression(targetPid: pid_t, restoreTo: NSRunningApplication) -> Handle {
        let handle = Handle(id: UUID())
        lock.lock()
        entries[handle.id] = Entry(targetPid: targetPid, restoreTo: restoreTo)
        let needsObserver = (observer == nil)
        lock.unlock()

        if needsObserver {
            installObserver()
        }
        return handle
    }

    /// Stop suppressing. Removes the entry for `handle`; tears down the
    /// shared observer when the last entry is removed. Idempotent.
    func endSuppression(_ handle: Handle) {
        lock.lock()
        entries.removeValue(forKey: handle.id)
        let shouldRemoveObserver = entries.isEmpty
        let token = observer
        if shouldRemoveObserver { observer = nil }
        lock.unlock()

        if shouldRemoveObserver, let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func installObserver() {
        // queue: nil delivers the callback synchronously on the posting
        // thread. NSWorkspace posts on main, so our handler runs on main
        // with no extra hop — matters because we want the restore
        // activation as close to the thief's activation moment as
        // possible (same runloop turn, before the next composite).
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleActivation(note)
        }

        lock.lock()
        if observer == nil {
            observer = token
            lock.unlock()
        } else {
            // Raced with another install. Drop the duplicate.
            lock.unlock()
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func handleActivation(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let activatedPid = app.processIdentifier

        lock.lock()
        let restoreTargets = entries.values
            .filter { $0.targetPid == activatedPid }
            .map(\.restoreTo)
        lock.unlock()

        guard let restoreTo = restoreTargets.first else { return }
        // Synchronous demote on the same runloop turn — WindowServer won't
        // composite the next frame until this returns.
        //
        // Use `ignoringOtherApps` so we force `restoreTo` frontmost over
        // the target that just activated. Without this flag the call is
        // advisory — macOS preserves the activation of the app that just
        // fired the notification and `restoreTo` stays behind.
        _ = restoreTo.activate(options: [.activateIgnoringOtherApps])
    }
}
