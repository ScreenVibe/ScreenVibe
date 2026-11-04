import AppKit

/// ⌘⌥6: the UI designer. A grid page to draw a new UI on, its title at the top, the tools on the left and the saved
/// UI designs and markups on the right.
final class DesignerWindow: NSWindow, NSTextFieldDelegate {
    private static var shared: DesignerWindow?

    static func show() {
        let w = shared ?? DesignerWindow()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.refreshLists()
    }

    let canvas = DesignCanvas(frame: CGRect(x: 0, y: 0, width: 4000, height: 3000))
    private let scroll = NSScrollView()
    private let titleField = NSTextField()
    private let savedLabel = NSTextField(labelWithString: "")
    private let sizes = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)
    private let palette = DesignPalette()
    private let list = NSStackView()
    private var folder: URL?
    private var saveTimer: Timer?
    private var sendWindow: SendWindow?

    private init() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        super.init(contentRect: screen.insetBy(dx: 30, dy: 20), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "ScreenVibe UI designer"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .aqua)   // a light page, like paper, in dark mode too
        minSize = CGSize(width: 900, height: 560)
        build()
        if let path = UserDefaults.standard.string(forKey: "lastDesign"), let d = DesignStore.load(URL(fileURLWithPath: path)) {
            open(d, folder: URL(fileURLWithPath: path))
        } else {
            open(Design(title: "Untitled design"), folder: nil)
        }
    }

    /// For `--designer-demo`: a sample design (in SCREENVIBE_DESIGN_DIR), pictured with only this window.
    static func demo(dump: String) {
        show()
        guard let w = shared else { return }
        var d = Design(title: "Export dialog for JuicyType")
        func add(_ k: ItemKind, _ r: CGRect, parent: String? = nil, _ f: (inout DesignItem) -> Void = { _ in }) -> String {
            var it = DesignItem.new(k, at: r, size: .m, windowType: .adobe)
            it.parent = parent
            f(&it)
            d.items.append(it)
            return it.id
        }
        let panel = add(.window, CGRect(x: 120, y: 60, width: 280, height: 300)) { $0.windowType = .adobe; $0.title = "JuicyType" }
        _ = add(.popup, CGRect(x: 190, y: 104, width: 150, height: 24), parent: panel) { $0.label = "Flavor"; $0.choices = ["Bubble", "Glossy"] }
        _ = add(.slider, CGRect(x: 190, y: 140, width: 150, height: 24), parent: panel) { $0.label = "Depth" }
        let box = add(.box, CGRect(x: 136, y: 196, width: 248, height: 84), parent: panel) { $0.title = "Effects" }
        _ = add(.checkbox, CGRect(x: 152, y: 212, width: 120, height: 24), parent: box) { $0.title = "Shadow"; $0.on = true }
        _ = add(.checkbox, CGRect(x: 152, y: 244, width: 120, height: 24), parent: box) { $0.title = "Outline" }
        let export = add(.button, CGRect(x: 136, y: 304, width: 90, height: 24), parent: panel) { $0.title = "Export…" }
        let modal = add(.window, CGRect(x: 520, y: 120, width: 340, height: 220)) { $0.windowType = .modal; $0.title = "Export" }
        _ = add(.popup, CGRect(x: 600, y: 164, width: 140, height: 24), parent: modal) { $0.label = "Format"; $0.choices = ["PNG", "PDF"] }
        _ = add(.field, CGRect(x: 600, y: 198, width: 200, height: 24), parent: modal) { $0.label = "Name"; $0.title = "Team logo" }
        _ = add(.radio, CGRect(x: 600, y: 232, width: 160, height: 44), parent: modal) { $0.choices = ["Whole page", "Selection"] }
        _ = add(.button, CGRect(x: 664, y: 300, width: 90, height: 24), parent: modal) { $0.title = "Cancel" }
        _ = add(.button, CGRect(x: 762, y: 300, width: 90, height: 24), parent: modal) { $0.title = "Export" }
        _ = add(.note, CGRect(x: 520, y: 380, width: 200, height: 60)) { $0.title = "Remember the last format." }
        d.links = [DesignLink(from: export, to: modal, text: "opens")]
        let dir = DesignStore.newFolder(for: d.title)
        w.open(d, folder: dir)
        w.saveNow()
        let env = ProcessInfo.processInfo.environment
        if env["SCREENVIBE_DESIGN_TEXT"] != nil, let pic = DesignDrawing.picture(d, folder: dir) {
            print(DesignText.describe(d, picture: URL(fileURLWithPath: "/tmp/design.png"), origin: pic.origin, note: ""))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let c = w.canvas
            if let s = env["SCREENVIBE_DESIGN_DRAG"] {
                // Test only: press at the first point and drag to the second, without letting go.
                let v = s.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
                func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: c.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                if let t = env["SCREENVIBE_DESIGN_TOOL"], let k = ItemKind(rawValue: t) { c.tool = .item(k) }
                if v.count >= 4 {
                    c.mouseDown(with: ev(.leftMouseDown, CGPoint(x: v[0], y: v[1])))
                    c.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: (v[0] + v[2]) / 2, y: (v[1] + v[3]) / 2)))
                    c.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: v[2], y: v[3])))
                    if env["SCREENVIBE_DESIGN_UP"] != nil { c.mouseUp(with: ev(.leftMouseUp, CGPoint(x: v[2], y: v[3]))) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dump))
                }
                if env["SCREENVIBE_DESIGN_UP"] != nil, let s = env["SCREENVIBE_DESIGN_DRAG"], !s.isEmpty {
                    for it in w.canvas.design.items { print(it.kind.rawValue, it.title, it.parent.flatMap { p in w.canvas.design.items.first { $0.id == p }?.title } ?? "-", Int(it.frame.minX), Int(it.frame.minY)) }
                }
                exit(0)
            }
        }
    }

    // MARK: layout

    private func build() {
        let content = NSView()
        contentView = content

        // Top bar: the design's title, whether it is saved, the size for controls, Copy and Send.
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.98, alpha: 1).cgColor
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.delegate = self
        titleField.toolTip = "The design's name. Its folder takes this name."
        savedLabel.font = .systemFont(ofSize: 12)
        savedLabel.textColor = .secondaryLabelColor
        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabelColor
        sizes.target = self
        sizes.action = #selector(sizePicked)
        sizes.selectedSegment = 1
        sizes.toolTip = "The size of the selected controls, and of new ones"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyDesign))
        let send = NSButton(title: "Send…", target: self, action: #selector(sendDesign))
        send.bezelColor = NSColor(hex: "#D63A2F")
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [titleField, savedLabel, spacer, sizeLabel, sizes, copy, send])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        let line = NSBox()
        line.boxType = .separator

        // The page.
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        canvas.needFolder = { [weak self] in self?.ensureFolder() }
        canvas.onChange = { [weak self] in self?.changed() }
        canvas.onToolChange = { [weak self] in self?.palette.refresh() }
        canvas.onSelect = { [weak self] in self?.showSize() }
        palette.canvas = canvas

        // The lists on the right.
        let side = NSScrollView()
        side.hasVerticalScroller = true
        side.drawsBackground = true
        side.backgroundColor = NSColor(white: 0.975, alpha: 1)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        let flip = FlippedStack()
        flip.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        side.documentView = flip
        flip.translatesAutoresizingMaskIntoConstraints = false

        for v in [bar, line, scroll, side, palette] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: side.leadingAnchor),
            side.topAnchor.constraint(equalTo: line.bottomAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            side.widthAnchor.constraint(equalToConstant: 250),
            flip.leadingAnchor.constraint(equalTo: side.contentView.leadingAnchor),
            flip.trailingAnchor.constraint(equalTo: side.contentView.trailingAnchor),
            flip.topAnchor.constraint(equalTo: side.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            list.topAnchor.constraint(equalTo: flip.topAnchor),
            list.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            palette.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 14),
            palette.widthAnchor.constraint(equalToConstant: DesignPalette.width),
            palette.heightAnchor.constraint(equalToConstant: palette.height),
        ])
    }

    override func becomeKey() {
        super.becomeKey()
        refreshLists()
    }

    override func close() {
        saveNow()
        super.close()
    }

    // MARK: open and save

    private func open(_ d: Design, folder: URL?) {
        self.folder = folder
        canvas.load(d, folder: folder)
        titleField.stringValue = d.title
        savedLabel.stringValue = folder == nil ? "" : "Saved"
        if let folder { UserDefaults.standard.set(folder.path, forKey: "lastDesign") }
        else { UserDefaults.standard.removeObject(forKey: "lastDesign") }
        // Start at the top-left of the page, just right of the tools.
        canvas.scroll(CGPoint(x: 0, y: 0))
        refreshLists()
        makeFirstResponder(canvas)
    }

    private func ensureFolder() -> URL? {
        if let folder { return folder }
        let f = DesignStore.newFolder(for: canvas.design.title)
        folder = f
        canvas.folder = f
        UserDefaults.standard.set(f.path, forKey: "lastDesign")
        return f
    }

    private func changed() {
        savedLabel.stringValue = "Saving…"
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        canvas.commitEdit()
        guard folder != nil || !canvas.design.items.isEmpty, let dir = ensureFolder() else { return }
        canvas.design.modified = Date()
        let preview = DesignDrawing.picture(canvas.design, folder: dir, scale: 0.5, grid: true)?.image
        DesignStore.save(canvas.design, to: dir, preview: preview)
        savedLabel.stringValue = "Saved"
        refreshLists()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        canvas.design.title = t.isEmpty ? "Untitled design" : t
        titleField.stringValue = canvas.design.title
        if let f = folder {
            folder = DesignStore.rename(f, to: canvas.design.title)
            canvas.folder = folder
            UserDefaults.standard.set(folder!.path, forKey: "lastDesign")
        }
        saveNow()
        makeFirstResponder(canvas)
    }

    @objc private func sizePicked() {
        canvas.setSize([ControlSize.s, .m, .l][max(0, sizes.selectedSegment)])
    }

    private func showSize() {
        let s = canvas.selectedSize ?? canvas.newSize
        sizes.selectedSegment = [ControlSize.s, .m, .l].firstIndex(of: s) ?? 1
    }

    // MARK: the lists

    func refreshLists() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let head = NSStackView(views: [Self.heading("UI designs"), NSView(), LinkButton(title: "+ New") { [weak self] in
            self?.saveNow()
            self?.open(Design(title: "Untitled design"), folder: nil)
        }])
        head.translatesAutoresizingMaskIntoConstraints = false
        list.addArrangedSubview(head)
        head.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let designs = DesignStore.list()
        if designs.isEmpty && folder == nil { list.addArrangedSubview(Self.hint("Your designs show here once they have something on them.")) }
        for e in designs {
            let r = ListRow(title: e.title, detail: Self.when(e.date), picture: e.preview, current: e.url.standardizedFileURL == folder?.standardizedFileURL)
            r.onClick = { [weak self] in
                guard let self, let d = DesignStore.load(e.url) else { return }
                self.saveNow()
                self.open(d, folder: e.url)
            }
            r.menuItems = [("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }),
                           ("Move to Trash", { [weak self] in self?.trash(e.url) })]
            list.addArrangedSubview(r)
        }
        let mh = Self.heading("Markups (⌘⇧6)")
        list.addArrangedSubview(Self.gap(14))
        list.addArrangedSubview(mh)
        let markups = MarkupFile.list()
        if markups.isEmpty { list.addArrangedSubview(Self.hint("Markups you send or copy show here. Click one to open it again.")) }
        for e in markups.prefix(60) {
            let r = ListRow(title: e.title, detail: Self.when(e.date) + " · " + e.how, picture: e.picture, current: false)
            r.onClick = { (NSApp.delegate as? AppDelegate)?.openSaved(e.url) }
            r.menuItems = [("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }),
                           ("Move to Trash", { [weak self] in
                               try? FileManager.default.trashItem(at: e.url, resultingItemURL: nil)
                               self?.refreshLists() })]
            list.addArrangedSubview(r)
        }
    }

    private func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if url.standardizedFileURL == folder?.standardizedFileURL { open(Design(title: "Untitled design"), folder: nil) }
        refreshLists()
    }

    private static func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    private static func hint(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 12)
        t.textColor = .tertiaryLabelColor
        t.preferredMaxLayoutWidth = 220
        return t
    }

    private static func gap(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "'Today' h:mm a" }
        else if cal.isDateInYesterday(d) { return "Yesterday" }
        else { f.dateFormat = "MMM d" }
        return f.string(from: d)
    }

    // MARK: Copy and Send

    @objc private func copyDesign() {
        saveNow()
        guard let out = makeOutput(note: "") else { return }
        Output.copyToPasteboard(out)
        Toast.show("Copied the design and its words", on: screen ?? NSScreen.main!)
    }

    @objc private func sendDesign() {
        saveNow()
        guard let pic = DesignDrawing.picture(canvas.design, folder: folder) else { return }
        let img = NSImage(cgImage: pic.image, size: CGSize(width: CGFloat(pic.image.width) / 2, height: CGFloat(pic.image.height) / 2))
        let w = SendWindow(marks: [], found: [], spots: [], origin: .zero, picture: { _ in img })
        w.title = "Send the design"
        w.onCancel = { [weak self] in self?.sendWindow?.close(); self?.sendWindow = nil }
        w.onQuit = w.onCancel
        w.onSend = { [weak self] _, _, note, session, _ in
            guard let self, let out = self.makeOutput(note: note) else { return }
            do {
                try Sessions.deliver(out, to: session)
                Sessions.lastId = session.sessionId
                self.sendWindow?.close()
                self.sendWindow = nil
                Toast.show("Sent to \(session.label)", on: self.screen ?? NSScreen.main!)
            } catch {
                let a = NSAlert()
                a.messageText = "The design could not be sent to \(session.label)."
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
        sendWindow = w
        w.present(on: screen ?? NSScreen.main!)
    }

    /// The picture and words a session gets, written where sessions read them.
    private func makeOutput(note: String) -> MarkupOutput? {
        canvas.commitEdit()
        guard let pic = DesignDrawing.picture(canvas.design, folder: folder) else { return nil }
        let dir = Output.root.appendingPathComponent("markups").appendingPathComponent(Output.stamp())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("design.png")
        try? Output.png(pic.image)?.write(to: url)
        let prompt = DesignText.describe(canvas.design, picture: url, origin: pic.origin, note: note)
        try? prompt.write(to: dir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        let img = NSImage(cgImage: pic.image, size: CGSize(width: CGFloat(pic.image.width) / 2, height: CGFloat(pic.image.height) / 2))
        return MarkupOutput(folder: dir, marked: img, prompt: prompt)
    }
}

/// The words a session reads for a design: every window and control, nested as drawn, and the arrows.
enum DesignText {
    static func describe(_ d: Design, picture: URL, origin: CGPoint, note: String) -> String {
        var lines = [
            "ScreenVibe UI design “\(d.title)”: a new UI to build as drawn. Each numbered line is a window or control; indented lines sit inside the one above. Positions are x,y from the top-left of what it sits in (of the picture, for what sits on the page), in points.",
            "Picture (2×): \(picture.path)",
        ]
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { lines.append("Note: \(n)") }
        lines.append("")
        var number: [String: Int] = [:]
        for (i, it) in DesignDrawing.ordered(d.items).enumerated() { number[it.id] = i + 1 }
        func walk(_ parent: String?, depth: Int) {
            for it in DesignDrawing.ordered(d.items) where it.parent == parent {
                let base = d.items.first { $0.id == parent }?.frame.origin ?? origin
                let f = it.frame
                var line = String(repeating: "   ", count: depth) + "\(number[it.id]!). " + name(it)
                line += ", at \(Int((f.minX - base.x).rounded())),\(Int((f.minY - base.y).rounded())), \(Int(f.width.rounded()))×\(Int(f.height.rounded()))"
                if !it.kind.isContainer && it.kind != .note && it.kind != .picture { line += ", size \(it.size.rawValue.uppercased())" }
                lines.append(line + ".")
                walk(it.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        if !d.links.isEmpty {
            lines += ["", "Arrows:"]
            for l in d.links {
                guard let a = d.items.first(where: { $0.id == l.from }), let b = d.items.first(where: { $0.id == l.to }) else { continue }
                var line = "- \(number[a.id]!) \(short(a)) → \(number[b.id]!) \(short(b))"
                if !l.text.isEmpty { line += ": “\(l.text)”" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func q(_ s: String) -> String { "“\(s)”" }

    private static func short(_ it: DesignItem) -> String {
        let words = it.kind == .window ? it.title : it.title.isEmpty ? it.label : it.title
        let kind = it.kind == .window ? it.windowType.title : it.kind.title
        return words.isEmpty ? kind : "\(kind) \(q(words))"
    }

    private static func name(_ it: DesignItem) -> String {
        let choices = it.choices.joined(separator: " / ")
        let label = it.label.isEmpty ? "" : ", label \(q(it.label))"
        switch it.kind {
        case .window: return "\(it.windowType.title) \(q(it.title))"
        case .box: return it.title.isEmpty ? "Box (groups what is in it)" : "Box \(q(it.title)) (groups what is in it)"
        case .button: return "Button \(q(it.title))"
        case .popup: return "Popup\(label), choices \(q(choices))" + (it.choices.first.map { ", shows \(q($0))" } ?? "")
        case .checkbox: return "Checkbox \(q(it.title)), \(it.on ? "checked" : "not checked")"
        case .radio: return "Radio buttons \(q(choices))" + (it.choices.indices.contains(it.pick) ? ", \(q(it.choices[it.pick])) chosen" : "")
        case .field: return "Text field\(label)" + (it.title.isEmpty ? ", empty" : ", showing \(q(it.title))")
        case .slider: return "Slider\(label)"
        case .label: return "Label \(q(it.title))"
        case .tabs: return "Tabs \(q(choices))" + (it.choices.indices.contains(it.pick) ? ", \(q(it.choices[it.pick])) showing" : "")
        case .list: return "List\(label), rows \(q(choices))"
        case .picture: return it.image == nil ? "Picture (an empty spot for one)" : "Picture (see the picture)"
        case .note: return "Note to you, not part of the UI: \(q(it.title))"
        }
    }
}

/// The tools, on the left of the page.
final class DesignPalette: NSView {
    static let width: CGFloat = 62
    weak var canvas: DesignCanvas?
    private var flyout: NSView?
    private let tools: [(DesignTool, String, String)] = [
        (.select, "Select", "cursorarrow"),
        (.item(.window), "Window", "macwindow"),
        (.item(.box), "Box", "square.dashed"),
        (.item(.button), "Button", "capsule"),
        (.item(.popup), "Popup", "chevron.up.chevron.down"),
        (.item(.checkbox), "Checkbox", "checkmark.square"),
        (.item(.radio), "Radio", "smallcircle.filled.circle"),
        (.item(.field), "Field", "character.cursor.ibeam"),
        (.item(.slider), "Slider", "slider.horizontal.3"),
        (.item(.label), "Label", "textformat"),
        (.item(.tabs), "Tabs", "menubar.rectangle"),
        (.item(.list), "List", "list.bullet.rectangle"),
        (.item(.picture), "Picture", "photo"),
        (.arrow, "Arrow", "arrow.turn.down.right"),
        (.item(.note), "Note", "note.text"),
    ]
    private let tile: CGFloat = 42

    var height: CGFloat { CGFloat(tools.count) * tile + 16 }

    override var isFlipped: Bool { true }

    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: "#262629")!.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        for (i, t) in tools.enumerated() {
            let r = CGRect(x: 5, y: 8 + CGFloat(i) * tile, width: bounds.width - 10, height: tile - 2)
            if canvas?.tool == t.0 {
                NSColor(white: 1, alpha: 0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            if let img = NSImage(systemSymbolName: t.2, accessibilityDescription: t.1)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [.white]))) {
                let s = img.size
                img.draw(in: CGRect(x: r.midX - s.width / 2, y: r.minY + 13 - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
            let name = t.0 == .item(.window) ? (canvas?.windowType.title ?? "Window") : t.1
            let w = (name as NSString).size(withAttributes: a).width
            (name as NSString).draw(at: CGPoint(x: r.midX - w / 2, y: r.minY + 24), withAttributes: a)
            if t.0 == .item(.window) {
                let p = NSBezierPath()
                p.move(to: CGPoint(x: r.maxX - 3, y: r.maxY - 9)); p.line(to: CGPoint(x: r.maxX - 3, y: r.maxY - 3)); p.line(to: CGPoint(x: r.maxX - 9, y: r.maxY - 3))
                p.close()
                NSColor(white: 0.75, alpha: 1).setFill()
                p.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - 8) / tile)
        guard tools.indices.contains(i), let canvas else { return }
        closeFlyout()
        canvas.tool = tools[i].0
        if tools[i].0 == .item(.window) { showWindowTypes(at: 8 + CGFloat(i) * tile) }
        window?.makeFirstResponder(canvas)
        needsDisplay = true
    }

    /// The window types, in a row beside the Window tool.
    private func showWindowTypes(at y: CGFloat) {
        guard let host = superview, let canvas else { return }
        let types = WindowType.allCases
        let w: CGFloat = 92, h: CGFloat = 34
        let row = TypeRow(frame: CGRect(x: 0, y: 0, width: CGFloat(types.count) * w + 10, height: h + 10))
        row.types = types
        row.current = canvas.windowType
        row.onPick = { [weak self] t in
            canvas.windowType = t
            canvas.tool = .item(.window)
            self?.closeFlyout()
            self?.needsDisplay = true
        }
        let origin = convert(CGPoint(x: bounds.maxX + 6, y: y + tile + 3), to: host)
        row.frame.origin = CGPoint(x: origin.x, y: host.isFlipped ? origin.y - row.frame.height : origin.y)
        host.addSubview(row)
        flyout = row
    }

    func closeFlyout() {
        flyout?.removeFromSuperview()
        flyout = nil
    }
}

private final class TypeRow: NSView {
    var types: [WindowType] = []
    var current = WindowType.panel
    var onPick: ((WindowType) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: "#262629")!.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let w = (bounds.width - 10) / CGFloat(types.count)
        for (i, t) in types.enumerated() {
            let r = CGRect(x: 5 + CGFloat(i) * w, y: 5, width: w - 2, height: bounds.height - 10)
            if t == current { NSColor(white: 1, alpha: 0.22).setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill() }
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let s = (t.title as NSString).size(withAttributes: a)
            (t.title as NSString).draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: a)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.x - 5) / ((bounds.width - 10) / CGFloat(types.count)))
        if types.indices.contains(i) { onPick?(types[i]) }
    }
}

/// One saved design or markup in the list on the right.
private final class ListRow: NSView {
    var onClick: (() -> Void)?
    var menuItems: [(String, () -> Void)] = []
    private let current: Bool

    init(title: String, detail: String, picture: URL, current: Bool) {
        self.current = current
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let thumb = NSImageView()
        thumb.image = NSImage(contentsOf: picture)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor(hex: "#C9D6E6")!.cgColor
        thumb.layer?.backgroundColor = DesignDrawing.page.cgColor
        let t = NSTextField(wrappingLabelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.maximumNumberOfLines = 2
        t.preferredMaxLayoutWidth = 140
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11.5)
        d.textColor = .secondaryLabelColor
        let words = NSStackView(views: [t, d])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        let row = NSStackView(views: [thumb, words])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 62), thumb.heightAnchor.constraint(equalToConstant: 42),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(equalToConstant: 230),
        ])
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = current ? NSColor(hex: "#DBE8FB")!.cgColor : NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for (title, act) in menuItems { m.addItem(ClosureMenuItem(title: title, handler: act)) }
        return m
    }
}

private final class LinkButton: NSButton {
    private let act: () -> Void
    init(title: String, action: @escaping () -> Void) {
        act = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: DesignDrawing.accent,
                                                                          .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        target = self
        self.action = #selector(go)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func go() { act() }
}

private final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}
