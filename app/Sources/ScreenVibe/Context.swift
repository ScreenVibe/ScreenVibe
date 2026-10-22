import AppKit
import ApplicationServices

/// What the user was looking at when the screen froze: the front app, its window, its document or web address.
struct FrontContext {
    var app = ""
    var bundleID = ""
    var window = ""
    var document: String?
    var url: String?
    /// A browser ScreenVibe may not ask yet. Asked once the markup closes, so the question is not hidden under it.
    var browserToAsk: String?
}

enum ContextGrab {
    /// Browsers and how their AppleScript names a window's front tab.
    private static let browsers: [String: String] = {
        var b: [String: String] = [:]
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
                   "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"] { b[id] = "active tab" }
        for id in ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] { b[id] = "current tab" }
        return b
    }()

    /// The address in the browser window at `frame`. Matched by position, because two windows can share a title
    /// and the browser's own "front window" is not always the one on top. No match gives no address, never a wrong one.
    private static func script(for bundleID: String, tab: String, frame: CGRect) -> String {
        """
        tell application id "\(bundleID)"
          repeat with w in windows
            set b to bounds of w
            if (item 1 of b) = \(Int(frame.minX)) and (item 2 of b) = \(Int(frame.minY)) then return URL of \(tab) of w
          end repeat
        end tell
        return ""
        """
    }

    /// Must run before ScreenVibe comes to the front, while the user's app is still frontmost.
    static func grab() async -> FrontContext {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return FrontContext() }
        var c = FrontContext()
        c.app = app.localizedName ?? ""
        c.bundleID = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier

        if AXIsProcessTrusted(), ProcessInfo.processInfo.environment["SCREENVIBE_NO_AX"] == nil {
            let ax = AXUIElementCreateApplication(pid)
            if let w = attribute(ax, kAXFocusedWindowAttribute) {
                let win = w as! AXUIElement
                c.window = attribute(win, kAXTitleAttribute) as? String ?? ""
                // Browsers report the page's address here; document apps report the file.
                if let doc = attribute(win, kAXDocumentAttribute) as? String, let u = URL(string: doc) {
                    if u.isFileURL { c.document = u.path } else { c.url = doc }
                }
            }
        }
        let front = Capture.windowList(pid: pid).first
        if c.window.isEmpty { c.window = front?.title ?? "" }

        if c.url == nil, let tab = browsers[c.bundleID], let frame = front?.frame {
            switch permission(for: c.bundleID, ask: false) {
            case noErr: c.url = await run(script(for: c.bundleID, tab: tab, frame: frame))
            case OSStatus(errAEEventWouldRequireUserConsent): c.browserToAsk = c.bundleID
            default: break
            }
        }
        return c
    }

    /// After the markup closes: the questions macOS asks once, so later markups carry more.
    static func askLater(_ c: FrontContext) {
        if let id = c.browserToAsk {
            DispatchQueue.global().async { _ = permission(for: id, ask: true) }
        }
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func permission(for bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return -1 }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    /// Runs the script off the main thread and gives up after a second, so a busy browser never holds up the freeze.
    private static func run(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var done = false
            func finish(_ v: String?) {
                lock.lock(); defer { lock.unlock() }
                if !done { done = true; cont.resume(returning: v) }
            }
            DispatchQueue.global().async {
                var err: NSDictionary?
                let r = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
                finish(r?.isEmpty == false ? r : nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
    }
}
