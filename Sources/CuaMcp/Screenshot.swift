import AppKit
import CoreGraphics
import Foundation

enum Screenshot {
    /// Capture the main window of a running app as PNG, base64-encoded.
    /// Returns nil if the app has no visible windows or capture fails.
    static func captureAppWindowPNG(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let match = windowInfo.first { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0  // regular app windows; skip status bar, menu bar, etc.
            else { return false }
            if let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, !isOnscreen {
                return false
            }
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
