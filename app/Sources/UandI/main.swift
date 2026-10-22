import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController?
    private var starting = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menubarImage()
            b.toolTip = "UandI: mark up the screen"
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count { demo(path: args[i + 1]) }
    }

    /// Opens the overlay on a saved picture instead of the live screen, with sample marks.
    private func demo(path: String) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil), let screen = NSScreen.main else { return }
        let frozen = Frozen(screen: screen, image: image, scale: CGFloat(image.width) / screen.frame.width, windows: [])
        let o = OverlayController(frozen: frozen)
        o.onClose = { [weak self] in self?.overlay = nil }
        overlay = o
        o.show()
        o.canvas.loadDemo()
        if let dump = ProcessInfo.processInfo.environment["UANDI_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let v = o.canvas
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dump))
                }
                if ProcessInfo.processInfo.environment["UANDI_DEMO_COPY"] != nil { o.copyMarkup() }
            }
        }
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let m = NSMenu()
            m.addItem(ClosureMenuItem(title: "Mark up the screen") { [weak self] in self?.start() })
            m.addItem(ClosureMenuItem(title: "Edit tools…") { ToolEditorWindow.show() })
            m.addItem(ClosureMenuItem(title: "Open the markups folder") {
                let dir = Output.root.appendingPathComponent("markups")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "Quit UandI") { NSApp.terminate(nil) })
            statusItem.menu = m
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            start()
        }
    }

    func start() {
        guard overlay == nil, !starting else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let frozen = try await Capture.freeze()
                let o = OverlayController(frozen: frozen)
                o.onClose = { [weak self] in self?.overlay = nil }
                overlay = o
                o.show()
            } catch {
                askForPermission()
            }
        }
    }

    private func askForPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "UandI needs permission to see the screen."
        a.informativeText = "Turn on UandI in System Settings, under Privacy & Security, Screen & System Audio Recording. Then click the UandI icon in the menu bar again."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "U&I" drawn as a template image so it follows the menu bar's light and dark look.
    static func menubarImage() -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                                                    .foregroundColor: NSColor.black]
        let s = "U&I" as NSString
        let ts = s.size(withAttributes: attrs)
        let size = CGSize(width: ceil(ts.width) + 8, height: 16)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.black.setStroke()
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            box.lineWidth = 1.5
            box.stroke()
            s.draw(at: CGPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.5), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
