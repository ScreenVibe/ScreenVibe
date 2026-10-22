import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController?
    private var starting = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menubarImage()
            b.toolTip = "UandI: mark up the screen (⌘⇧6)"
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        registerHotKey()
        Guide.write()
        let args = CommandLine.arguments
        if args.contains("--print-context") {
            // Check what a markup would say about the front app, after a pause to switch apps.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let c = await ContextGrab.grab()
                print("app=\(c.app) id=\(c.bundleID) window=\(c.window) url=\(c.url ?? "-") doc=\(c.document ?? "-") ask=\(c.browserToAsk ?? "-") ax=\(AXIsProcessTrusted())")
                exit(0)
            }
            return
        }
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
        if ProcessInfo.processInfo.environment["UANDI_DEMO_SPACE"] != nil {
            // Test only: Space down, drag the box 100 points right, Space up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let w = o.window, v = o.canvas
                func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                func key(_ t: NSEvent.EventType) -> NSEvent {
                    NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                     context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                }
                let before = v.crop!
                let c = CGPoint(x: before.midX, y: before.midY)
                w.sendEvent(key(.keyDown))
                w.sendEvent(ev(.leftMouseDown, c))
                w.sendEvent(ev(.leftMouseDragged, CGPoint(x: c.x + 100, y: c.y)))
                w.sendEvent(ev(.leftMouseUp, CGPoint(x: c.x + 100, y: c.y)))
                w.sendEvent(key(.keyUp))
                print("key=\(w.isKeyWindow) responder=\(w.firstResponder === v) before=\(before.origin) after=\(v.crop!.origin)")
                let n = v.marks.count
                v.setTool(ToolStore.shared.tools.first { $0.id == "remove" })
                w.sendEvent(ev(.leftMouseDown, CGPoint(x: c.x, y: c.y)))
                w.sendEvent(ev(.leftMouseDragged, CGPoint(x: c.x + 80, y: c.y + 40)))
                w.sendEvent(ev(.leftMouseUp, CGPoint(x: c.x + 80, y: c.y + 40)))
                print("marks \(n)->\(v.marks.count) tool=\(v.tool?.name ?? "Select") cropping=\(v.cropping)")
                exit(0)
            }
        }
        if ProcessInfo.processInfo.environment["UANDI_DEMO_SEND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                o.openSend()
                if let path = ProcessInfo.processInfo.environment["UANDI_DUMP_SEND"], let v = NSApp.keyWindow?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["UANDI_DUMP_PALETTE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let v = o.toolsPalette.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
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

    /// ⌘⇧6 starts a markup from anywhere.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.start() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_6), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: OSType(0x55414E44), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            let m = NSMenu()
            m.addItem(ClosureMenuItem(title: "Mark up the screen  ⌘⇧6") { [weak self] in self?.start() })
            m.addItem(ClosureMenuItem(title: "Edit tools…") { ToolEditorWindow.show() })
            m.addItem(ClosureMenuItem(title: "Open the markups folder") {
                let dir = Output.root.appendingPathComponent("markups")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "About UandI") {
                let credit = NSAttributedString(string: "Created by Vibe Coding prodigy Hanaan",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credit])
            })
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
                let context = await ContextGrab.grab()
                let frozen = try await Capture.freeze(context: context)
                let o = OverlayController(frozen: frozen)
                o.onClose = { [weak self] in
                    self?.overlay = nil
                    ContextGrab.askLater(context)
                }
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
