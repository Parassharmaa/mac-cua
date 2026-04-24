import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum Screenshot {
    /// Capture the main window of a running app as PNG, base64-encoded.
    /// Uses ScreenCaptureKit (macOS 12.3+) which works correctly on Sequoia.
    /// Falls back to `CGWindowListCreateImage` on older systems.
    static func captureAppWindowPNG(pid: pid_t) -> String? {
        if #available(macOS 14.0, *) {
            return captureViaSCK(pid: pid)
        }
        return captureViaCGWindowList(pid: pid)
    }

    // MARK: - ScreenCaptureKit path (macOS 14+)
    //
    // Sequoia's window server no longer serves `CGWindowListCreateImage` for
    // other processes — it returns a blank image. SCK's
    // `SCScreenshotManager.captureImage(contentFilter:configuration:)` is the
    // supported replacement (requires macOS 14 Sonoma or newer).

    @available(macOS 14.0, *)
    private static func captureViaSCK(pid: pid_t) -> String? {
        let sem = DispatchSemaphore(value: 0)
        var image: CGImage?
        var reason: String?
        Task.detached {
            do {
                // Ask for ALL windows (incl. offscreen). SCK's onScreenWindowsOnly
                // filter drops windows the window server considers hidden — on
                // repeated get_app_state calls, Chrome's window can flicker
                // in/out of that set during layout. Filter ourselves instead.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let candidates = content.windows
                    .filter { window -> Bool in
                        guard window.owningApplication?.processID == pid else { return false }
                        guard window.windowLayer == 0 else { return false }
                        return window.frame.width >= 32 && window.frame.height >= 32
                    }
                    .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }
                guard let window = candidates.first else {
                    reason = "no matching layer-0 window for pid=\(pid); total=\(content.windows.count)"
                    sem.signal(); return
                }
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width)
                config.height = Int(window.frame.height)
                config.capturesAudio = false
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if image == nil { reason = "captureImage returned nil" }
            } catch {
                reason = "SCK threw: \(error)"
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3.0)
        if image == nil, let reason {
            screenshotDebug(reason)
        }
        guard let image else { return nil }
        return pngBase64(from: image)
    }

    // MARK: - Legacy CGWindowList path

    private static func captureViaCGWindowList(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let match = windowInfo.first { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { return false }
            return true
        }
        guard let match,
              let windowID = match[kCGWindowNumber as String] as? CGWindowID,
              let cgImage = CGWindowListCreateImage(
                  .null,
                  .optionIncludingWindow,
                  windowID,
                  [.boundsIgnoreFraming, .bestResolution]
              )
        else { return nil }
        return pngBase64(from: cgImage)
    }

    private static func pngBase64(from cgImage: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }
}

private func screenshotDebug(_ msg: String) {
    if ProcessInfo.processInfo.environment["CUA_SCREENSHOT_DEBUG"] != nil {
        FileHandle.standardError.write("[screenshot] \(msg)\n".data(using: .utf8)!)
    }
}
