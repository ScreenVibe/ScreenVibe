import AppKit

/// A panel that takes the keyboard without making UandI the active app, so Esc and the tool keys always reach it.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns one markup session: the frozen screen, its canvas and the two palettes.
final class OverlayController {
    let frozen: Frozen
    let window: OverlayWindow
    let canvas: Canvas
    let toolsPalette = Palette(key: "tools")
    let actionsPalette = Palette(key: "actions")
    var onClose: (() -> Void)?
    private var toolsObserver: Any?
    private var sendWindow: SendWindow?

    init(frozen: Frozen) {
        self.frozen = frozen
        window = OverlayWindow(contentRect: frozen.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        canvas = Canvas(frozen: frozen)
        window.contentView = canvas
        canvas.controller = self

        for p in [toolsPalette, actionsPalette] {
            p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.onSettingsChanged = { [weak self] in self?.placePalettes() }
        }
        toolsPalette.makeTiles = { [weak self] large in self?.toolTiles(large: large) ?? [] }
        actionsPalette.makeTiles = { [weak self] large in self?.actionTiles(large: large) ?? [] }
        toolsObserver = NotificationCenter.default.addObserver(forName: ToolStore.didChange, object: nil, queue: .main) {
            [weak self] _ in
            self?.canvas.toolsChanged()
            self?.toolsPalette.rebuild()
        }
    }

    deinit {
        if let toolsObserver { NotificationCenter.default.removeObserver(toolsObserver) }
    }

    func show() {
        window.setFrame(frozen.screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        toolsPalette.rebuild()
        actionsPalette.rebuild()
        placePalettes()
        toolsPalette.orderFront(nil)
        actionsPalette.orderFront(nil)
    }

    func close() {
        sendWindow?.close()
        sendWindow = nil
        toolsPalette.orderOut(nil)
        actionsPalette.orderOut(nil)
        window.orderOut(nil)
        onClose?()
    }

    // MARK: palettes

    func refreshTools() { toolsPalette.rebuild() }

    private func toolTiles(large: Bool) -> [NSView] {
        var tiles: [NSView] = []
        let select = Tile(symbol: "cursorarrow", label: "Select", large: large)
        select.toolTip = "Select (V)"
        select.isOn = canvas.tool == nil
        select.onClick = { [weak self] in self?.canvas.setTool(nil) }
        tiles.append(select)
        for t in ToolStore.shared.tools {
            let tile = Tile(symbol: t.symbol, label: t.name, tint: t.color.blended(withFraction: 0.35, of: .white)!,
                            large: large)
            tile.toolTip = t.shortcut.isEmpty ? t.name : "\(t.name) (\(t.shortcut.uppercased()))"
            tile.isOn = canvas.tool?.id == t.id
            tile.onClick = { [weak self] in self?.canvas.setTool(t) }
            tiles.append(tile)
        }
        let edit = Tile(symbol: "slider.horizontal.3", label: "Edit tools", tint: NSColor.white.withAlphaComponent(0.7),
                        large: large)
        edit.onClick = { ToolEditorWindow.show() }
        tiles.append(edit)
        return tiles
    }

    private func actionTiles(large: Bool) -> [NSView] {
        let discard = Tile(symbol: large ? "" : "xmark", label: "Discard", large: large, wide: true)
        discard.fillColor = NSColor.white.withAlphaComponent(0.14)
        discard.onClick = { [weak self] in self?.close() }
        let copy = Tile(symbol: large ? "" : "doc.on.doc", label: "Copy", large: large, wide: true)
        copy.fillColor = NSColor.white.withAlphaComponent(0.14)
        copy.onClick = { [weak self] in self?.copyMarkup() }
        let send = Tile(symbol: "paperplane.fill", label: "Send", large: large, wide: true)
        send.fillColor = NSColor(hex: "#D6342C")
        send.onClick = { [weak self] in self?.openSend() }
        return [discard, copy, send]
    }

    func placePalettes() {
        let screen = frozen.screen.frame
        let visible = frozen.screen.visibleFrame
        func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: screen.minX + p.x, y: screen.maxY - p.y) }
        let tw = toolsPalette.frame.size, aw = actionsPalette.frame.size

        if let p = toolsPalette.placedTopLeft {
            toolsPalette.moveTopLeft(to: p)
        } else if let crop = canvas.crop {
            var p: CGPoint
            if toolsPalette.vertical {
                p = CGPoint(x: crop.minX - tw.width - 12, y: crop.minY)
                if p.x < 8 { p.x = crop.maxX + 12 }
                if p.x + tw.width > screen.width - 8 { p.x = 8 }
                p.y = min(p.y, screen.height - tw.height - 8)
            } else {
                p = CGPoint(x: crop.minX, y: crop.minY - tw.height - 12)
                if p.y < screen.maxY - visible.maxY + 8 { p.y = crop.maxY + 12 }
                if p.y + tw.height > screen.height - 8 { p.y = screen.maxY - visible.maxY + 8 }
                p.x = min(max(8, p.x), screen.width - tw.width - 8)
            }
            toolsPalette.moveTopLeft(to: toScreen(p))
        } else {
            let p = toolsPalette.vertical
                ? CGPoint(x: 16, y: (screen.height - tw.height) / 2)
                : CGPoint(x: (screen.width - tw.width) / 2, y: screen.maxY - visible.maxY + 12)
            toolsPalette.moveTopLeft(to: toScreen(p))
        }

        if let p = actionsPalette.placedTopLeft {
            actionsPalette.moveTopLeft(to: p)
        } else if let crop = canvas.crop {
            var p = CGPoint(x: crop.maxX - aw.width, y: crop.maxY + 12)
            if p.y + aw.height > screen.height - 8 { p.y = crop.maxY - aw.height - 12 }
            p.x = min(max(8, p.x), screen.width - aw.width - 8)
            actionsPalette.moveTopLeft(to: toScreen(p))
        } else {
            actionsPalette.moveTopLeft(to: toScreen(CGPoint(x: (screen.width - aw.width) / 2, y: screen.height - aw.height - 40)))
        }
    }

    // MARK: actions

    func copyMarkup() {
        guard let out = Output.make(frozen: frozen, crop: canvas.outputArea, marks: canvas.marks) else { return }
        Output.copyToPasteboard(out)
        close()
        Toast.show("Copied the markup and its words", on: frozen.screen)
    }

    /// Shows the Send window over the markup. Return there sends, Esc comes back here.
    func openSend() {
        if let w = sendWindow { w.makeKeyAndOrderFront(nil); return }
        guard let preview = Output.preview(frozen: frozen, crop: canvas.outputArea, marks: canvas.marks) else { return }
        let w = SendWindow(preview: preview, marks: canvas.marks)
        w.onCancel = { [weak self] in self?.closeSendWindow() }
        w.onSend = { [weak self] requests, note, session in self?.send(to: session, requests: requests, note: note) }
        sendWindow = w
        w.present(on: frozen.screen)
    }

    private func closeSendWindow() {
        sendWindow?.close()
        sendWindow = nil
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func send(to s: SessionInfo, requests: [String], note: String) {
        var marks = canvas.marks
        for i in marks.indices where i < requests.count {
            if requests[i] != Output.sentence(for: marks[i]) { marks[i].note = requests[i] }
        }
        guard let out = Output.make(frozen: frozen, crop: canvas.outputArea, marks: marks, note: note,
                                    briefed: Sessions.isBriefed(s)) else { return }
        do {
            try Sessions.deliver(out, to: s)
            Sessions.lastId = s.sessionId
            close()
            Toast.show("Sent to \(s.label)", on: frozen.screen)
        } catch {
            let a = NSAlert()
            a.messageText = "The markup could not be sent to \(s.label)."
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}

/// The frozen screen and everything drawn on it.
final class Canvas: NSView, NSTextFieldDelegate {
    weak var controller: OverlayController?
    let frozen: Frozen
    private let background: NSImage

    private(set) var crop: CGRect?
    private(set) var marks: [Mark] = []
    private(set) var tool: ToolDef?
    private var selected: Int?
    private var pixelSelection: CGRect?
    private var clip: (image: NSImage, source: CGRect)?
    private var undoStack: [(marks: [Mark], crop: CGRect?)] = []

    private enum Drag {
        case none
        case makingCrop(CGPoint)
        case drawing(Mark, CGPoint)
        case moving(Int, CGPoint)
        case resizing(Int, corner: Int)
        case resizingTarget(Int, corner: Int)
        case movingEnd(Int)
        case movingTarget(Int, CGPoint)
        case resizingCrop(handle: Int)
        case marquee(CGPoint)
    }
    private var drag: Drag = .none
    private var aiming: Int?              // a box+arrow mark waiting for the click where it goes
    private var editor: TextPrompt?

    /// What the picture covers: the box, or the whole screen when no box was drawn.
    var outputArea: CGRect { crop ?? bounds }

    init(frozen: Frozen) {
        self.frozen = frozen
        background = NSImage(cgImage: frozen.image, size: frozen.screen.frame.size)
        super.init(frame: CGRect(origin: .zero, size: frozen.screen.frame.size))
        tool = ToolStore.shared.tools.first
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func setTool(_ t: ToolDef?) {
        commitEditor()
        tool = t
        if t != nil { selected = nil }
        controller?.refreshTools()
        needsDisplay = true
    }

    /// For `--demo`: a box and one mark of each kind, so the look can be checked without clicking.
    func loadDemo() {
        let c = CGRect(x: bounds.width * 0.25, y: bounds.height * 0.22, width: bounds.width * 0.5, height: bounds.height * 0.5)
        crop = c
        let tools = ToolStore.shared.tools
        func tool(_ id: String) -> ToolDef? { tools.first { $0.id == id } }
        if let t = tool("remove") { var m = Mark(kind: .tool(t)); m.rect = CGRect(x: c.minX + 30, y: c.minY + 40, width: 260, height: 50); marks.append(m) }
        if let t = tool("wording") { var m = Mark(kind: .tool(t)); m.rect = CGRect(x: c.minX + 30, y: c.minY + 130, width: 140, height: 40); m.text = "Save changes"; marks.append(m) }
        if let t = tool("button") { var m = Mark(kind: .tool(t)); m.rect = CGRect(x: c.minX + 220, y: c.minY + 130, width: 130, height: 44); m.text = ProcessInfo.processInfo.environment["UANDI_DEMO_LABEL"] ?? "Export"; marks.append(m) }
        if let t = tool("move") { var m = Mark(kind: .tool(t)); m.rect = CGRect(x: c.minX + 30, y: c.minY + 230, width: 110, height: 40); m.end = CGPoint(x: c.maxX - 90, y: c.minY + 250); marks.append(m) }
        if let t = tool("note") { var m = Mark(kind: .tool(t)); m.rect = CGRect(x: c.minX + 400, y: c.minY + 40, width: 0, height: 0); m.text = "Too much space up here"; marks.append(m) }
        controller?.placePalettes()
        needsDisplay = true
        let env = ProcessInfo.processInfo.environment
        if env["UANDI_DEMO_TARGET"] != nil, let i = marks.firstIndex(where: { $0.isBoxArrow }) {
            marks[i].targetSize = CGSize(width: marks[i].rect.width * 1.8, height: marks[i].rect.height * 2.2)
            selected = i
            self.tool = nil
        }
        if let words = env["UANDI_DEMO_ASK"] ?? env["UANDI_DEMO_WORDS"], let i = marks.firstIndex(where: { $0.tool?.id == "wording" }) {
            marks[i].text = words
            guard env["UANDI_DEMO_ASK"] != nil else { return }
            openEditor(for: i, isNew: false)
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }

    func toolsChanged() {
        if let t = tool { tool = ToolStore.shared.tools.first { $0.id == t.id } }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        if let c = crop {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: c))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.38).setFill()
            dim.fill()
            let border = NSBezierPath(rect: c.insetBy(dx: -0.75, dy: -0.75))
            border.lineWidth = 1.5
            NSColor.white.setStroke()
            border.stroke()
            if tool == nil { for h in cropHandles(c) { drawHandle(h) } }
        } else {
            NSColor.black.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
        // The open question box shows its mark's words, so the mark's own bubble stays hidden.
        MarkDrawing.drawAll(marks, selected: tool == nil ? selected : nil, hideWordsOf: editor?.index)
        if case .drawing(let m, _) = drag { MarkDrawing.draw(m, number: nil, selected: false) }
        if case .marquee = drag, let r = pixelSelection { drawMarquee(r) }
        else if let r = pixelSelection { drawMarquee(r) }
    }

    private func drawMarquee(_ r: CGRect) {
        let p = NSBezierPath(rect: r)
        p.lineWidth = 1.5
        NSColor.black.setStroke()
        p.stroke()
        p.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        p.stroke()
    }

    private func drawHandle(_ p: CGPoint) {
        let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.darkGray.setStroke()
        NSBezierPath(ovalIn: r).stroke()
    }

    /// Corners first (0-3: tl, tr, bl, br), then edge middles (4-7: top, bottom, left, right).
    private func cropHandles(_ c: CGRect) -> [CGPoint] {
        [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY), CGPoint(x: c.minX, y: c.maxY),
         CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.midX, y: c.minY), CGPoint(x: c.midX, y: c.maxY),
         CGPoint(x: c.minX, y: c.midY), CGPoint(x: c.maxX, y: c.midY)]
    }

    // MARK: mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 8 }

    override func mouseMoved(with event: NSEvent) {
        if let i = aiming {
            marks[i].end = point(event)
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if editor != nil { commitEditor() }
        if let i = aiming {
            marks[i].end = p
            aiming = nil
            needsDisplay = true
            return
        }
        guard let c = crop else {
            drag = .makingCrop(p)
            return
        }
        guard let t = tool else {
            selectDown(at: p, crop: c, clicks: event.clickCount)
            return
        }
        var m = Mark(kind: .tool(t))
        switch t.shape {
        case .box, .oval, .boxArrow: m.rect = CGRect(origin: p, size: .zero)
        case .arrow: m.start = p; m.end = p
        case .pen: m.points = [p]
        case .text:
            m.rect = CGRect(origin: p, size: .zero)
            pushUndo()
            marks.append(m)
            openEditor(for: marks.count - 1, isNew: true)
            needsDisplay = true
            return
        }
        drag = .drawing(m, p)
    }

    private func selectDown(at p: CGPoint, crop c: CGRect, clicks: Int) {
        if let s = selected, s < marks.count {
            let m = marks[s]
            if m.isBoxArrow, let k = m.target.corners.firstIndex(where: { near(p, $0) }) {
                pushUndo()
                marks[s].targetSize = m.target.size
                drag = .resizingTarget(s, corner: k)
                return
            }
            if m.isBoxArrow, near(p, m.end) { pushUndo(); drag = .movingEnd(s); return }
            if let t = m.tool, t.shape == .arrow {
                if near(p, m.end) { pushUndo(); drag = .movingEnd(s); return }
            } else if m.tool?.shape != .pen && m.tool?.shape != .text {
                let a = m.area
                let corners = [CGPoint(x: a.minX, y: a.minY), CGPoint(x: a.maxX, y: a.minY),
                               CGPoint(x: a.minX, y: a.maxY), CGPoint(x: a.maxX, y: a.maxY)]
                if let k = corners.firstIndex(where: { near(p, $0) }) {
                    pushUndo()
                    if m.isBoxArrow { marks[s].targetSize = m.target.size }  // the destination keeps its own size
                    drag = .resizing(s, corner: k)
                    return
                }
            }
        }
        if let k = cropHandles(c).firstIndex(where: { near(p, $0) }) {
            pushUndo()
            drag = .resizingCrop(handle: k)
            return
        }
        if let i = marks.indices.reversed().first(where: { marks[$0].hit(p) }) {
            selected = i
            pixelSelection = nil
            if clicks == 2, marks[i].tool?.ask != nil {
                openEditor(for: i, isNew: false)
            } else if marks[i].isBoxArrow, !marks[i].rect.insetBy(dx: -6, dy: -6).contains(p), marks[i].target.contains(p) {
                pushUndo()
                drag = .movingTarget(i, p)  // dragging the destination moves only the destination
            } else {
                pushUndo()
                drag = .moving(i, p)
            }
            needsDisplay = true
            return
        }
        selected = nil
        pixelSelection = nil
        drag = .marquee(p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .none: return
        case .makingCrop(let s):
            crop = CGRect(p1: s, p2: p)
        case .drawing(var m, let s):
            switch m.tool?.shape {
            case .arrow: m.end = p
            case .pen: m.points.append(p)
            default: m.rect = CGRect(p1: s, p2: p)
            }
            drag = .drawing(m, s)
        case .moving(let i, let last):
            marks[i].offset(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .moving(i, p)
        case .resizing(let i, let corner):
            let a = marks[i].rect
            let fixed = [CGPoint(x: a.maxX, y: a.maxY), CGPoint(x: a.minX, y: a.maxY),
                         CGPoint(x: a.maxX, y: a.minY), CGPoint(x: a.minX, y: a.minY)][corner]
            marks[i].rect = CGRect(p1: fixed, p2: p)
            drag = .resizing(i, corner: marks[i].rect.cornerIndex(of: p))
        case .movingEnd(let i):
            marks[i].end = p
        case .movingTarget(let i, let last):
            marks[i].end = CGPoint(x: marks[i].end.x + p.x - last.x, y: marks[i].end.y + p.y - last.y)
            drag = .movingTarget(i, p)
        case .resizingTarget(let i, let corner):
            let a = marks[i].target
            let fixed = [CGPoint(x: a.maxX, y: a.maxY), CGPoint(x: a.minX, y: a.maxY),
                         CGPoint(x: a.maxX, y: a.minY), CGPoint(x: a.minX, y: a.minY)][corner]
            let r = CGRect(p1: fixed, p2: p)
            marks[i].targetSize = r.size
            marks[i].end = CGPoint(x: r.midX, y: r.midY)
            drag = .resizingTarget(i, corner: r.cornerIndex(of: p))
        case .resizingCrop(let h):
            guard var c = crop else { return }
            var minX = c.minX, maxX = c.maxX, minY = c.minY, maxY = c.maxY
            if [0, 2, 6].contains(h) { minX = p.x }
            if [1, 3, 7].contains(h) { maxX = p.x }
            if [0, 1, 4].contains(h) { minY = p.y }
            if [2, 3, 5].contains(h) { maxY = p.y }
            c = CGRect(p1: CGPoint(x: minX, y: minY), p2: CGPoint(x: maxX, y: maxY))
            crop = c
            controller?.placePalettes()
        case .marquee(let s):
            pixelSelection = CGRect(p1: s, p2: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let current = drag
        drag = .none
        switch current {
        case .makingCrop:
            if let c = crop, c.width < 8 || c.height < 8 { crop = nil }
            controller?.placePalettes()
        case .drawing(let m, _):
            guard let t = m.tool else { break }
            let a = m.area
            if (t.shape == .pen && m.points.count < 2) || (t.shape != .pen && max(a.width, a.height) < 6) { break }
            pushUndo()
            marks.append(m)
            if t.shape == .boxArrow {
                aiming = marks.count - 1
                marks[marks.count - 1].end = point(event)
            } else if t.ask != nil {
                openEditor(for: marks.count - 1, isNew: true)
            }
        case .marquee:
            if let r = pixelSelection, r.width < 4 || r.height < 4 { pixelSelection = nil }
        case .resizingCrop:
            if let c = crop, c.width < 8 || c.height < 8 { undo() }
        default: break
        }
        needsDisplay = true
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 53: // Escape
            if let i = aiming { aiming = nil; marks[i].end = .zero; marks.remove(at: i); needsDisplay = true }
            else if pixelSelection != nil { pixelSelection = nil; needsDisplay = true }
            else if selected != nil { selected = nil; needsDisplay = true }
            else { controller?.close() }
            return
        case 51, 117: // Delete
            if let s = selected { pushUndo(); marks.remove(at: s); selected = nil; needsDisplay = true }
            return
        case 36, 76: // Return
            controller?.openSend()
            return
        default: break
        }
        if cmd {
            switch chars {
            case "z": undo()
            case "c": if pixelSelection != nil { copyPixels() } else { controller?.copyMarkup() }
            case "v": pastePiece()
            case "x": if pixelSelection != nil { copyPixels() }
            default: super.keyDown(with: event)
            }
            return
        }
        if chars == "v" { setTool(nil); return }
        if let t = ToolStore.shared.tools.first(where: { !$0.shortcut.isEmpty && $0.shortcut.lowercased() == chars }) {
            setTool(t)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: copy and paste a part of the frozen screen

    private func copyPixels() {
        guard let r = pixelSelection?.intersection(bounds), !r.isEmpty else { return }
        let s = frozen.scale
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
        guard let cg = frozen.image.cropping(to: px) else { return }
        let img = NSImage(cgImage: cg, size: r.size)
        clip = (img, r)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        flash(r)
    }

    private func pastePiece() {
        var piece = clip
        if piece == nil, let img = NSImage(pasteboard: NSPasteboard.general) {
            let rep = img.representations.first
            let size = rep.map { CGSize(width: CGFloat($0.pixelsWide) / frozen.scale, height: CGFloat($0.pixelsHigh) / frozen.scale) } ?? img.size
            img.size = size
            piece = (img, .null)
        }
        guard let (img, source) = piece else { return }
        let target = crop ?? bounds
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? target.center
        let at = target.contains(mouse) ? mouse : target.center
        var m = Mark(kind: .pasted(img, source: source))
        m.rect = CGRect(x: at.x - img.size.width / 2, y: at.y - img.size.height / 2, width: img.size.width,
                        height: img.size.height)
        pushUndo()
        marks.append(m)
        selected = marks.count - 1
        pixelSelection = nil
        if tool != nil { setTool(nil) }
        needsDisplay = true
    }

    private func flash(_ r: CGRect) {
        pixelSelection = nil
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pixelSelection = r
            self?.needsDisplay = true
        }
    }

    // MARK: undo

    private func pushUndo() {
        undoStack.append((marks, crop))
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        marks = last.marks
        crop = last.crop
        selected = nil
        aiming = nil
        controller?.placePalettes()
        needsDisplay = true
    }

    // MARK: the words a tool asks for

    private func openEditor(for i: Int, isNew: Bool) {
        guard let t = marks[i].tool, let question = t.ask ?? (t.shape == .text ? "What is the note?" : nil) else { return }
        let a = marks[i].area
        let prompt = TextPrompt(question: question, text: marks[i].text, color: t.color)
        var origin = CGPoint(x: a.minX, y: a.maxY + 8)
        if origin.y + prompt.frame.height > bounds.height - 8 { origin.y = max(8, a.minY - prompt.frame.height - 8) }
        origin.x = min(max(8, origin.x), bounds.width - prompt.frame.width - 8)
        prompt.setFrameOrigin(origin)
        prompt.index = i
        prompt.isNew = isNew
        prompt.field.delegate = self
        addSubview(prompt)
        editor = prompt
        needsDisplay = true
        window?.makeFirstResponder(prompt.field)
    }

    private func commitEditor(cancel: Bool = false) {
        guard let e = editor else { return }
        editor = nil
        let text = e.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        e.removeFromSuperview()
        if e.index < marks.count {
            if cancel {
                if e.isNew { marks.remove(at: e.index) }
            } else if text.isEmpty && marks[e.index].tool?.shape == .text {
                marks.remove(at: e.index)
            } else {
                marks[e.index].text = text
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidChange(_ note: Notification) {
        guard let e = editor else { return }
        e.fit()
        if e.frame.maxY > bounds.height - 8 { e.setFrameOrigin(CGPoint(x: e.frame.minX, y: max(8, bounds.height - 8 - e.frame.height))) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitEditor(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { commitEditor(cancel: true); return true }
        return false
    }
}

private extension CGRect {
    /// Which corner of this rect `p` sits on: 0 tl, 1 tr, 2 bl, 3 br.
    func cornerIndex(of p: CGPoint) -> Int {
        (p.x > midX ? 1 : 0) + (p.y > midY ? 2 : 0)
    }
}

/// The small question box that opens right under a mark.
final class TextPrompt: NSView {
    let field = NSTextField()
    var index = 0
    var isNew = true

    init(question: String, text: String, color: NSColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 62))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = color.cgColor
        layer?.borderWidth = 2
        let label = NSTextField(labelWithString: question)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = color
        label.frame = CGRect(x: 10, y: 6, width: 280, height: 16)
        field.stringValue = text
        field.font = .systemFont(ofSize: 14)
        field.frame = CGRect(x: 10, y: 26, width: 280, height: 26)
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        addSubview(label)
        addSubview(field)
        fit()
    }

    /// Grows the box down so every line of the words shows.
    func fit() {
        let text = field.currentEditor()?.string ?? field.stringValue
        let b = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: CGSize(width: field.frame.width - 8, height: 10_000), options: [.usesLineFragmentOrigin],
            attributes: [.font: field.font!])
        let h = max(26, ceil(b.height) + 9)
        guard h != field.frame.height else { return }
        field.frame.size.height = h
        setFrameSize(CGSize(width: frame.width, height: h + 36))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// A short line that confirms what happened, then fades.
enum Toast {
    static func show(_ text: String, on screen: NSScreen) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
        let w = (text as NSString).size(withAttributes: attrs).width + 40
        let frame = CGRect(x: screen.frame.midX - w / 2, y: screen.visibleFrame.maxY - 70, width: w, height: 40)
        let win = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        let fx = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        fx.material = .hudWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: text)
        label.font = attrs[.font] as? NSFont
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 10, width: frame.width, height: 20)
        fx.addSubview(label)
        win.contentView = fx
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; win.animator().alphaValue = 0 }) { win.orderOut(nil) }
        }
    }
}
