import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController?
    private var starting = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Self.menubarImage()
            b.toolTip = "ScreenVibe: mark up the screen (⌘⇧6)"
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        Self.moveFromUandI()
        Self.deleteOldMarkups()
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
        if ProcessInfo.processInfo.environment["SCREENVIBE_DEMO_SPACE"] != nil {
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
        if ProcessInfo.processInfo.environment["SCREENVIBE_DEMO_SEND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                o.openSend()
                if let path = ProcessInfo.processInfo.environment["SCREENVIBE_DUMP_SEND"], let v = NSApp.keyWindow?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["SCREENVIBE_DUMP_PALETTE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let v = o.toolsPalette.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        if let dump = ProcessInfo.processInfo.environment["SCREENVIBE_DUMP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let v = o.canvas
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dump))
                }
                if ProcessInfo.processInfo.environment["SCREENVIBE_DEMO_COPY"] != nil { o.copyMarkup() }
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
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_6), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: OSType(0x53564942), id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        // Another app holds ⌘⇧6: say so in the icon's tooltip, since the menu still works.
        if status != noErr { statusItem.button?.toolTip = "ScreenVibe: mark up the screen. ⌘⇧6 is taken by another app." }
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
            let login = ClosureMenuItem(title: "Start at login") {
                let s = SMAppService.mainApp
                do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
                catch { NSAlert(error: error).runModal() }
            }
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            m.addItem(login)
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "About ScreenVibe") {
                let credit = NSAttributedString(string: "Created by Hanaan",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credit])
            })
            m.addItem(ClosureMenuItem(title: "Quit ScreenVibe") { NSApp.terminate(nil) })
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
        a.messageText = "ScreenVibe needs permission to see the screen."
        a.informativeText = "Turn on ScreenVibe in System Settings, under Privacy & Security, Screen & System Audio Recording. Then quit ScreenVibe from its menu bar icon and open it again: macOS applies the permission only after a restart."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Markups and inbox folders older than 30 days go, so full-size pictures don't pile up. Checked at launch and daily.
    static func deleteOldMarkups() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var folders: [URL] = []
        for top in ["markups", "inbox"] {
            let dir = Output.root.appendingPathComponent(top)
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            // markups/<time>, inbox/<session>/<time>
            folders += top == "markups" ? items : items.flatMap {
                (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
        }
        for f in folders {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: f)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 24 * 3600) { deleteOldMarkups() }
    }

    /// ScreenVibe was called UandI. Carries over its folder (tools, markups) and its settings, once.
    static func moveFromUandI() {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let old = home.appendingPathComponent(".uandi"), new = home.appendingPathComponent(".screenvibe")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        let d = UserDefaults.standard
        guard !d.bool(forKey: "movedFromUandI"), let was = UserDefaults(suiteName: "com.slsuite.uandi") else { return }
        for (k, v) in was.dictionaryRepresentation() where d.object(forKey: k) == nil
            && ["tools.", "actions.", "lastSession", "askedAccessibility"].contains(where: { k.hasPrefix($0) }) {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "movedFromUandI")
    }

    /// The app icon from icon.svg (a dashed screen area with a pointer), cut to its art and drawn as a template image
    /// so it follows the menu bar's light and dark look.
    static func menubarImage() -> NSImage {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="253.3 216.2 46 46"><path d="M292.6,261.8h-5.9v-2h5.8v2ZM280.9,261.8h-5.8v-2h5.8v2ZM269.3,261.8h-5.8v-2h5.8v2ZM257.3,261.1c-2.1-1.1-3.5-3.2-3.5-5.6h2c0,1.6.9,3.1,2.4,3.8l-.9,1.8ZM298.2,258.2l-1.8-.9c.3-.6.4-1.2.4-1.8v-3.5h2v3.5c0,.9-.2,1.8-.6,2.7ZM255.8,249.7h-2v-5.8h2v5.8ZM298.8,246.2h-2v-5.8h2v5.8ZM255.8,238.1h-2v-5.8h2v5.8ZM298.8,234.6h-2v-5.8h2v5.8ZM255.8,226.4h-2v-3.5c0-1,.2-1.9.6-2.7l1.8.9c-.3.6-.4,1.2-.4,1.8v3.5ZM296.8,222.9c0-1.6-.9-3.1-2.4-3.8l.9-1.8c2.2,1,3.5,3.2,3.5,5.6h-2ZM289.1,218.7h-5.8v-2h5.8v2ZM277.4,218.7h-5.8v-2h5.8v2ZM265.8,218.7h-5.8v-1.8s0-.2,0-.2h5.8s0,2,0,2Z"/><path d="M261.3,225.1l20,20c0,0,.1.2.1.3,0,.2-.2.4-.4.4h-11.1l-7.9,7.9c0,0-.2.1-.3.1h0c-.2,0-.4-.2-.4-.4v-28.4M261.3,222.9c-.3,0-.6,0-.9.2-.8.3-1.4,1.2-1.4,2.1v28.4c0,1.5,1.2,2.7,2.7,2.7s1.4-.3,1.9-.8l7.3-7.3h10.1c1.5,0,2.7-1.2,2.7-2.7s-.3-1.4-.8-1.9l-20-20c-.4-.4-1-.7-1.6-.7h0Z"/></svg>"#
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.size = CGSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
