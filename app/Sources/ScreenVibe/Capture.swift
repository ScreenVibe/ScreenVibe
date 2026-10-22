import AppKit
import ScreenCaptureKit

/// A frozen screen: the picture plus what was on it, taken before the overlay appears.
struct Frozen {
    let screen: NSScreen
    let image: CGImage          // full pixels of the screen
    let scale: CGFloat          // pixels per point
    let windows: [WindowInfo]   // front to back, other apps only
    var context = FrontContext()
}

struct WindowInfo {
    let app: String
    let title: String
    let frame: CGRect           // screen points, top-left origin of the main display
}

enum CaptureError: Error { case noDisplay, denied }

enum Capture {
    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func freeze(context: FrontContext) async throws -> Frozen {
        let screen = await MainActor.run { screenUnderMouse() }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.denied
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Frozen(screen: screen, image: image, scale: scale, windows: windowList(), context: context)
    }

    /// Layer-0 windows front to back: another app's (`pid`), or every app's but ScreenVibe's.
    static func windowList(pid: pid_t? = nil) -> [WindowInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? Int32, owner != me, pid == nil || owner == pid,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return WindowInfo(app: w[kCGWindowOwnerName as String] as? String ?? "",
                              title: w[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }
}
