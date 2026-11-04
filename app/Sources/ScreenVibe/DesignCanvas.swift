import AppKit

enum DesignTool: Equatable {
    case select, item(ItemKind), arrow, freeform
}

/// The grid page: windows and controls placed, moved, sized, grouped and joined with arrows.
final class DesignCanvas: NSView, NSTextFieldDelegate {
    var design = Design(title: "Untitled design")
    var folder: URL?
    /// Called after every change, to save.
    var onChange: (() -> Void)?
    var onToolChange: (() -> Void)?
    var onSelect: (() -> Void)?
    /// Makes the design's folder if it has none yet (for pasted pictures).
    var needFolder: (() -> URL?)?
    var tool: DesignTool = .select { didSet { window?.invalidateCursorRects(for: self); onToolChange?() } }
    /// The size and window type new items get.
    var newSize = ControlSize.m
    var windowType = WindowType.panel

    private(set) var selection = Set<String>() { didSet { onSelect?() } }
    private var selectedLink: String?
    private var undoStack: [(items: [DesignItem], links: [DesignLink])] = []
    private var drag = Drag.none
    private var guides: [(CGPoint, CGPoint)] = []
    private var editor: (field: NSTextField, id: String, part: String)?
    private var hover: String?
    /// Freeform text being typed: where it was clicked, and the window it goes in (none: a new window there).
    private var freeform: (field: NSTextField, at: CGPoint, window: String?)?
    private var pendingPick: (id: String, row: Int, at: CGPoint)?
    private static let pasteType = NSPasteboard.PasteboardType("com.screenvibe.design-items")

    private enum Drag {
        case none
        case creating(ItemKind, CGPoint, CGPoint)
        case moving(start: CGPoint, frames: [String: CGRect], undone: Bool)
        case resizing(id: String, corner: Int, start: CGRect)
        case marquee(CGPoint, CGPoint)
        case linking(from: String, to: CGPoint)
        case slider(String)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : .crosshair)
    }

    func load(_ d: Design, folder: URL?) {
        commitEdit()
        design = d
        self.folder = folder
        selection = []
        selectedLink = nil
        undoStack = []
        DesignDrawing.lastWay = [:]
        needsDisplay = true
    }

    // MARK: finding things

    private func item(_ id: String?) -> DesignItem? { design.items.first { $0.id == id } }
    private func index(_ id: String) -> Int? { design.items.firstIndex { $0.id == id } }

    /// The topmost item under the point: a control before the box or window it sits in.
    private func item(at p: CGPoint) -> DesignItem? {
        DesignDrawing.ordered(design.items).reversed().first { DesignDrawing.bounds($0).insetBy(dx: -2, dy: -2).contains(p) }
    }

    private func descendants(of ids: Set<String>) -> Set<String> {
        var out = ids
        var grew = true
        while grew {
            grew = false
            for it in design.items where !out.contains(it.id) {
                if let p = it.parent, out.contains(p) { out.insert(it.id); grew = true }
            }
        }
        return out
    }

    private func link(at p: CGPoint) -> DesignLink? {
        design.links.last { l in
            guard let a = item(l.from), let b = item(l.to) else { return false }
            let pts = DesignDrawing.route(from: a.frame, to: b.frame)
            return zip(pts, pts.dropFirst()).contains { s, e in
                CGRect(p1: s, p2: e).insetBy(dx: -5, dy: -5).contains(p)
            }
        }
    }

    /// The window or box an item at `r` belongs in: the smallest one around its middle, not itself or inside it.
    private func container(for r: CGRect, excluding ex: Set<String>, kind: ItemKind) -> String? {
        guard kind != .window else { return nil }   // windows sit on the page
        let c = CGPoint(x: r.midX, y: r.midY)
        return design.items
            .filter { $0.kind.isContainer && !ex.contains($0.id) && $0.frame.contains(c) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    /// After a window or box is drawn or sized: what now sits in it belongs to it, what left it does not.
    private func regroup(_ id: String) {
        guard let c = item(id) else { return }
        for i in design.items.indices {
            let it = design.items[i]
            guard it.id != id, it.kind != .window, !descendants(of: [it.id]).contains(id) else { continue }
            let center = CGPoint(x: it.frame.midX, y: it.frame.midY)
            if it.parent == c.parent, c.frame.contains(center) {
                design.items[i].parent = id
            } else if it.parent == id, !c.frame.contains(center) {
                design.items[i].parent = c.parent
            }
        }
    }

    // MARK: undo

    private func pushUndo() {
        undoStack.append((design.items, design.links))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    func undo() {
        commitEdit()
        guard let last = undoStack.popLast() else { return }
        design.items = last.items
        design.links = last.links
        selection = selection.filter { id in design.items.contains { $0.id == id } }
        changed()
    }

    private func changed() {
        needsDisplay = true
        onChange?()
    }

    // MARK: S/M/L

    /// Sets the size of the selected controls, and of the next ones.
    func setSize(_ s: ControlSize) {
        newSize = s
        let ids = selection.filter { item($0)?.kind.isContainer == false }
        guard !ids.isEmpty else { return }
        pushUndo()
        for i in design.items.indices where ids.contains(design.items[i].id) {
            design.items[i].size = s
            let k = design.items[i].kind
            if k.isOneLine {
                let f = design.items[i].frame
                design.items[i].frame = CGRect(x: f.minX, y: f.midY - s.height / 2, width: f.width, height: s.height)
            } else if k == .radio {
                DesignDrawing.fitRadio(&design.items[i])
            }
        }
        changed()
    }

    var selectedSize: ControlSize? {
        let sizes = Set(selection.compactMap { item($0) }.filter { !$0.kind.isContainer }.map(\.size))
        return sizes.count == 1 ? sizes.first : nil
    }

    // MARK: mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private func handles(_ r: CGRect) -> [CGPoint] { r.corners }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .arrow else { if hover != nil { hover = nil; needsDisplay = true }; return }
        let h = item(at: point(event))?.id
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        commitEdit()
        window?.makeFirstResponder(self)
        switch tool {
        case .arrow:
            if let it = item(at: p) { drag = .linking(from: it.id, to: p) }
            return
        case .item(let k):
            drag = .creating(k, p, p)
            return
        case .freeform:
            startFreeform(at: p)
            return
        case .select: break
        }
        if selection.count == 1, let id = selection.first, let it = item(id),
           let k = handles(it.frame).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 7 }) {
            drag = .resizing(id: id, corner: k, start: it.frame)
            pushUndo()
            return
        }
        if let it = item(at: p) {
            selectedLink = nil
            if event.clickCount == 2 { edit(it, at: p); return }
            if it.kind == .checkbox, DesignDrawing.checkSquare(it).insetBy(dx: -3, dy: -3).contains(p), let i = index(it.id) {
                pushUndo()
                design.items[i].on.toggle()
                selection = [it.id]
                changed()
                return
            }
            if selection.contains(it.id), it.kind == .slider, it.frame.contains(p) {
                pushUndo()
                drag = .slider(it.id)
                mouseDragged(with: event)
                return
            }
            if selection.contains(it.id), let row = DesignDrawing.rows(it).firstIndex(where: { $0.contains(p) }) {
                pendingPick = (it.id, row, p)
            }
            if event.modifierFlags.contains(.shift) {
                if selection.contains(it.id) { selection.remove(it.id) } else { selection.insert(it.id) }
            } else if !selection.contains(it.id) {
                selection = [it.id]
            }
            let moving = descendants(of: selection)
            var frames: [String: CGRect] = [:]
            for id in moving { if let f = item(id)?.frame { frames[id] = f } }
            drag = .moving(start: p, frames: frames, undone: false)
            needsDisplay = true
            return
        }
        if let l = link(at: p) {
            selection = []
            selectedLink = l.id
            if event.clickCount == 2 { editLink(l.id) }
            needsDisplay = true
            return
        }
        selectedLink = nil
        if !event.modifierFlags.contains(.shift) { selection = [] }
        drag = .marquee(p, p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .none: return
        case .creating(let k, let s, _):
            drag = .creating(k, s, p)
        case .moving(let start, let frames, let undone):
            if !undone { pushUndo(); drag = .moving(start: start, frames: frames, undone: true) }
            var dx = p.x - start.x, dy = p.y - start.y
            if !event.modifierFlags.contains(.command) {
                let roots = selection.compactMap { frames[$0] }
                if let r = roots.reduce(nil as CGRect?, { acc, r in acc.map { $0.union(r) } ?? r }) {
                    let parent = selection.count == 1 ? item(selection.first)?.parent : nil
                    let s = snap(r.offsetBy(dx: dx, dy: dy), excluding: Set(frames.keys), parent: parent)
                    dx += s.dx; dy += s.dy
                    guides = s.lines
                }
            } else {
                guides = []
            }
            for (id, f) in frames { if let i = index(id) { design.items[i].frame = f.offsetBy(dx: dx, dy: dy) } }
        case .resizing(let id, let corner, let start):
            guard let i = index(id) else { return }
            let fixed = [CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX, y: start.maxY),
                         CGPoint(x: start.maxX, y: start.minY), CGPoint(x: start.minX, y: start.minY)][corner]
            var q = p
            let s = snapPoint(q, excluding: descendants(of: [id]), parent: design.items[i].parent)
            q.x += s.dx; q.y += s.dy
            guides = s.lines
            var r = CGRect(p1: fixed, p2: q)
            let it = design.items[i]
            if it.kind.isOneLine { r = CGRect(x: r.minX, y: start.minY, width: r.width, height: start.height) }
            r.size.width = max(r.width, it.kind.isOneLine ? 24 : 40)
            r.size.height = max(r.height, it.kind.isOneLine ? r.height : 30)
            design.items[i].frame = r
        case .marquee(let s, _):
            drag = .marquee(s, p)
            let r = CGRect(p1: s, p2: p)
            let hits = Set(design.items.filter { r.intersects(DesignDrawing.bounds($0)) }.map(\.id))
            // A window or box caught whole brings what is in it; its contents are not picked one by one.
            selection = hits.filter { id in !(item(id)?.parent.map { hits.contains($0) } ?? false) }
        case .linking(let from, _):
            drag = .linking(from: from, to: p)
            let h = item(at: p)?.id
            hover = h == from ? nil : h
        case .slider(let id):
            guard let i = index(id) else { return }
            let f = design.items[i].frame
            design.items[i].value = Double(min(1, max(0, (p.x - f.minX - 7) / max(1, f.width - 14))))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        let current = drag
        drag = .none
        guides = []
        defer { pendingPick = nil; needsDisplay = true }
        switch current {
        case .none: break
        case .creating(let k, let s, let e):
            var r = CGRect(p1: s, p2: e)
            let def = DesignItem.defaultSize(k, size: newSize, windowType: windowType)
            if max(r.width, r.height) < 6 { r = CGRect(origin: s, size: def) }
            if k.isOneLine { r = CGRect(x: r.minX, y: r.midY - newSize.height / 2, width: max(r.width, 40), height: newSize.height) }
            if k == .radio { r.size.height = newSize.rowGap * 2 }
            var it = DesignItem.new(k, at: r, size: newSize, windowType: windowType)
            if k == .note { it.size = .m }
            let snapped = snap(r, excluding: [], parent: nil)
            it.frame = r.offsetBy(dx: snapped.dx, dy: snapped.dy)
            pushUndo()
            it.parent = container(for: it.frame, excluding: [it.id], kind: k)
            design.items.append(it)
            if k.isContainer { regroup(it.id) }
            selection = [it.id]
            tool = .select
            changed()
            startEditing(new: it)
        case .moving(_, let frames, let undone):
            if !undone {
                if let pp = pendingPick, hypot(p.x - pp.at.x, p.y - pp.at.y) < 3, let i = index(pp.id) {
                    pushUndo()
                    design.items[i].pick = pp.row
                    changed()
                }
                return
            }
            // What was moved joins the window or box it was dropped in.
            let moved = Set(frames.keys)
            for id in selection {
                guard let i = index(id), let it = item(id) else { continue }
                if let par = it.parent, moved.contains(par) { continue }
                design.items[i].parent = container(for: it.frame, excluding: descendants(of: [id]), kind: it.kind)
            }
            changed()
        case .resizing(let id, _, _):
            if item(id)?.kind.isContainer == true { regroup(id) }
            changed()
        case .marquee:
            break
        case .linking(let from, _):
            hover = nil
            guard let to = item(at: p)?.id, to != from else { return }
            pushUndo()
            let l = DesignLink(from: from, to: to)
            design.links.append(l)
            selection = []
            selectedLink = l.id
            changed()
            editLink(l.id)
        case .slider:
            changed()
        }
    }

    // MARK: guides

    private struct Snap { var dx: CGFloat = 0, dy: CGFloat = 0; var lines: [(CGPoint, CGPoint)] = [] }

    private func others(excluding ex: Set<String>) -> [DesignItem] { design.items.filter { !ex.contains($0.id) } }

    /// Moves `r` a little so its edges or middle line up with other items, or keep the spacing other items keep.
    private func snap(_ r: CGRect, excluding ex: Set<String>, parent: String?) -> Snap {
        let near: CGFloat = 5
        let os = others(excluding: ex)
        var bestX: CGFloat?, bestY: CGFloat?
        func tryX(_ d: CGFloat) { if abs(d) < near, abs(d) < abs(bestX ?? .infinity) { bestX = d } }
        func tryY(_ d: CGFloat) { if abs(d) < near, abs(d) < abs(bestY ?? .infinity) { bestY = d } }
        for o in os.map(\.frame) {
            for c in [r.minX, r.midX, r.maxX] { for v in [o.minX, o.midX, o.maxX] { tryX(v - c) } }
            for c in [r.minY, r.midY, r.maxY] { for v in [o.minY, o.midY, o.maxY] { tryY(v - c) } }
        }
        // The usual margin inside a window or box.
        if let par = item(parent ?? container(for: r, excluding: ex, kind: .button)) {
            let f = par.frame, top = f.minY + DesignDrawing.titleBarHeight(par)
            tryX(f.minX + 16 - r.minX); tryX(f.maxX - 16 - r.maxX); tryY(top + 16 - r.minY); tryY(f.maxY - 16 - r.maxY)
        }
        // Spacing: the gaps neighbors already keep, or 8.
        let siblings = os.filter { $0.parent == parent && !$0.kind.isContainer || $0.parent == parent && $0.kind == .box }.map(\.frame)
        var vGaps: Set<CGFloat> = [8], hGaps: Set<CGFloat> = [8]
        for a in siblings { for b in siblings where a != b {
            if a.maxX > b.minX && b.maxX > a.minX, b.minY >= a.maxY, b.minY - a.maxY <= 60 { vGaps.insert((b.minY - a.maxY).rounded()) }
            if a.maxY > b.minY && b.maxY > a.minY, b.minX >= a.maxX, b.minX - a.maxX <= 60 { hGaps.insert((b.minX - a.maxX).rounded()) }
        } }
        var spacing: [(CGPoint, CGPoint)] = []
        if let above = siblings.filter({ $0.maxX > r.minX && r.maxX > $0.minX && $0.maxY <= r.minY + near }).max(by: { $0.maxY < $1.maxY }) {
            for g in vGaps { let d = above.maxY + g - r.minY; if abs(d) < near, abs(d) <= abs(bestY ?? .infinity) { bestY = d
                let x = max(above.minX, r.minX) + 6; spacing = [(CGPoint(x: x, y: above.maxY), CGPoint(x: x, y: above.maxY + g))] } }
        }
        if let left = siblings.filter({ $0.maxY > r.minY && r.maxY > $0.minY && $0.maxX <= r.minX + near }).max(by: { $0.maxX < $1.maxX }) {
            for g in hGaps { let d = left.maxX + g - r.minX; if abs(d) < near, abs(d) <= abs(bestX ?? .infinity) { bestX = d
                let y = max(left.minY, r.minY) + 6; spacing.append((CGPoint(x: left.maxX, y: y), CGPoint(x: left.maxX + g, y: y))) } }
        }
        var s = Snap(dx: bestX ?? 0, dy: bestY ?? 0)
        s.lines = lines(for: r.offsetBy(dx: s.dx, dy: s.dy), others: os.map(\.frame)) + spacing
        return s
    }

    private func snapPoint(_ p: CGPoint, excluding ex: Set<String>, parent: String?) -> Snap {
        let s = snap(CGRect(origin: p, size: .zero), excluding: ex, parent: parent)
        return s
    }

    /// Guide lines for every edge or middle of `r` that lines up with another item.
    private func lines(for r: CGRect, others: [CGRect]) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        for o in others {
            for c in [r.minX, r.midX, r.maxX] where [o.minX, o.midX, o.maxX].contains(where: { abs($0 - c) < 0.5 }) {
                out.append((CGPoint(x: c, y: min(r.minY, o.minY) - 6), CGPoint(x: c, y: max(r.maxY, o.maxY) + 6)))
            }
            for c in [r.minY, r.midY, r.maxY] where [o.minY, o.midY, o.maxY].contains(where: { abs($0 - c) < 0.5 }) {
                out.append((CGPoint(x: min(r.minX, o.minX) - 6, y: c), CGPoint(x: max(r.maxX, o.maxX) + 6, y: c)))
            }
        }
        return out
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        DesignDrawing.drawGrid(dirtyRect)
        DesignDrawing.drawAll(design, folder: folder, hiddenText: editor.map { ($0.id, $0.part) })
        let accent = DesignDrawing.accent
        for id in selection {
            guard let it = item(id) else { continue }
            let p = NSBezierPath(rect: DesignDrawing.bounds(it).insetBy(dx: -3, dy: -3))
            p.lineWidth = 1.5
            accent.setStroke()
            p.stroke()
            if selection.count == 1 {
                for h in handles(it.frame) {
                    let b = NSBezierPath(rect: CGRect(x: h.x - 3.5, y: h.y - 3.5, width: 7, height: 7))
                    NSColor.white.setFill(); b.fill()
                    accent.setStroke(); b.lineWidth = 1.2; b.stroke()
                }
            }
        }
        if let id = selectedLink, let l = design.links.first(where: { $0.id == id }), let a = item(l.from), let b = item(l.to) {
            let pts = DesignDrawing.route(from: a.frame, to: b.frame)
            let p = NSBezierPath()
            p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }
            p.lineWidth = 7
            accent.withAlphaComponent(0.25).setStroke()
            p.stroke()
        }
        if let h = item(hover) {
            let p = NSBezierPath(rect: h.frame.insetBy(dx: -3, dy: -3))
            p.lineWidth = 2
            DesignDrawing.arrowColor.setStroke()
            p.stroke()
        }
        switch drag {
        case .creating(_, let s, let e):
            let p = NSBezierPath(rect: CGRect(p1: s, p2: e))
            p.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            p.stroke()
        case .marquee(let s, let e):
            let r = CGRect(p1: s, p2: e)
            accent.withAlphaComponent(0.1).setFill(); r.fill()
            accent.setStroke(); NSBezierPath(rect: r).stroke()
        case .linking(let from, let to):
            if let a = item(from) {
                let target = item(hover)?.frame ?? CGRect(x: to.x, y: to.y, width: 0, height: 0)
                DesignDrawing.drawLink(DesignDrawing.route(from: a.frame, to: target), text: "", dashed: item(hover) == nil)
            }
        default: break
        }
        for (a, b) in guides {
            let p = NSBezierPath()
            p.move(to: a); p.line(to: b)
            p.lineWidth = 1
            DesignDrawing.guideColor.setStroke()
            p.stroke()
        }
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 51, 117: deleteSelection(); return
        case 53:
            if tool != .select { tool = .select } else { selection = []; selectedLink = nil; needsDisplay = true }
            return
        case 123, 124, 125, 126:
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let d = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0), 125: CGVector(dx: 0, dy: step),
                     126: CGVector(dx: 0, dy: -step)][event.keyCode]!
            let ids = descendants(of: selection)
            guard !ids.isEmpty else { return }
            pushUndo()
            for i in design.items.indices where ids.contains(design.items[i].id) { design.items[i].frame = design.items[i].frame.offsetBy(dx: d.dx, dy: d.dy) }
            changed()
            return
        case 36, 76:
            if selection.count == 1, let it = item(selection.first) { edit(it, at: nil) }
            return
        default: break
        }
        if cmd {
            switch chars {
            case "z": undo()
            case "c": copySelection()
            case "x": copySelection(); deleteSelection()
            case "v": paste()
            case "d": copySelection(); paste()
            case "a": selection = Set(design.items.map(\.id)); needsDisplay = true
            default: super.keyDown(with: event)
            }
            return
        }
        if chars == "v" { tool = .select; return }
        if chars == "a" { tool = .arrow; return }
        if chars == "f" { tool = .freeform; return }
        super.keyDown(with: event)
    }

    private func deleteSelection() {
        if let id = selectedLink {
            pushUndo()
            design.links.removeAll { $0.id == id }
            selectedLink = nil
            changed()
            return
        }
        let gone = descendants(of: selection)
        guard !gone.isEmpty else { return }
        pushUndo()
        design.items.removeAll { gone.contains($0.id) }
        design.links.removeAll { gone.contains($0.from) || gone.contains($0.to) }
        selection = []
        changed()
    }

    private struct Clip: Codable { var items: [DesignItem]; var links: [DesignLink] }

    private func copySelection() {
        let ids = descendants(of: selection)
        guard !ids.isEmpty else { return }
        let clip = Clip(items: design.items.filter { ids.contains($0.id) },
                        links: design.links.filter { ids.contains($0.from) && ids.contains($0.to) })
        guard let data = try? JSONEncoder().encode(clip) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteType)
    }

    /// Pastes copied items beside where they were, or a picture from the clipboard.
    func paste() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.pasteType), let clip = try? JSONDecoder().decode(Clip.self, from: data) {
            var map: [String: String] = [:]
            for it in clip.items { map[it.id] = UUID().uuidString }
            let items = clip.items.map { it -> DesignItem in
                var n = it
                n.id = map[it.id]!
                n.parent = it.parent.flatMap { map[$0] } ?? it.parent
                n.frame = it.frame.offsetBy(dx: 20, dy: 20)
                return n
            }
            pushUndo()
            design.items += items
            design.links += clip.links.map { DesignLink(from: map[$0.from]!, to: map[$0.to]!, text: $0.text) }
            selection = Set(items.filter { $0.parent == nil || map.values.contains($0.parent!) == false }.map(\.id))
            changed()
            // The copy stays on the clipboard, so a second paste lands 20 points further.
            let next = Clip(items: items, links: [])
            if let d = try? JSONEncoder().encode(next) { pb.clearContents(); pb.setData(d, forType: Self.pasteType) }
            return
        }
        guard let img = NSImage(pasteboard: pb), let dir = folder ?? needFolder?(),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let name = "picture-\(UUID().uuidString.prefix(8)).png"
        try? Output.png(cg)?.write(to: dir.appendingPathComponent(name))
        folder = dir
        let px = img.representations.first.map { CGSize(width: CGFloat($0.pixelsWide) / 2, height: CGFloat($0.pixelsHigh) / 2) } ?? img.size
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? CGPoint(x: 200, y: 200)
        let at = visibleRect.contains(mouse) ? mouse : CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        var it = DesignItem(kind: .picture, frame: CGRect(x: at.x - px.width / 2, y: at.y - px.height / 2, width: px.width, height: px.height))
        it.image = name
        pushUndo()
        it.parent = container(for: it.frame, excluding: [it.id], kind: .picture)
        design.items.append(it)
        selection = [it.id]
        changed()
    }

    // MARK: words, edited where they are drawn

    /// A new item starts with its words selected, ready to type over.
    private func startEditing(new it: DesignItem) {
        switch it.kind {
        case .popup, .field, .slider, .list: begin(it.id, "label")
        case .radio, .tabs: begin(it.id, "choices")
        case .picture: break
        default: begin(it.id, "title")
        }
    }

    private func edit(_ it: DesignItem, at p: CGPoint?) {
        if let p, let lr = DesignDrawing.labelRect(it), lr.insetBy(dx: -3, dy: -3).contains(p) { begin(it.id, "label"); return }
        if let p, let tr = DesignDrawing.titleRect(it), tr.contains(p) { begin(it.id, "title"); return }
        switch it.kind {
        case .popup, .radio, .tabs, .list: begin(it.id, "choices")
        case .slider: begin(it.id, "label")
        case .picture: choosePicture(it.id)
        default: begin(it.id, "title")
        }
    }

    private func editLink(_ id: String) { begin(id, "link") }

    private func begin(_ id: String, _ part: String) {
        commitEdit()
        let f = NSTextField()
        var r: CGRect
        var multi = false
        if part == "link" {
            guard let l = design.links.first(where: { $0.id == id }), let a = item(l.from), let b = item(l.to) else { return }
            let m = DesignDrawing.middle(DesignDrawing.route(from: a.frame, to: b.frame))
            r = CGRect(x: m.x - 70, y: m.y - 11, width: 140, height: 22)
            f.stringValue = l.text
            f.font = .systemFont(ofSize: 12, weight: .semibold)
            f.alignment = .center
        } else {
            guard let it = item(id) else { return }
            f.font = it.size.font
            switch part {
            case "label":
                var probe = it
                if probe.label.isEmpty { probe.label = "Label:" }
                r = DesignDrawing.labelRect(probe) ?? it.frame
                r = CGRect(x: r.maxX - max(r.width, 90), y: r.minY - 2, width: max(r.width, 90), height: r.height + 4)
                f.alignment = it.kind == .list ? .left : .right
                f.stringValue = it.label
            case "choices":
                multi = true
                f.stringValue = it.choices.joined(separator: "\n")
                let n = CGFloat(max(2, it.choices.count + 1))
                r = CGRect(x: it.frame.minX, y: it.frame.minY, width: max(it.frame.width, 160), height: n * 18 + 8)
            default:
                if let tr = DesignDrawing.titleRect(it) {
                    r = tr
                    f.alignment = it.kind == .window && it.windowType != .adobe ? .center : .left
                    f.font = it.kind == .box ? DesignDrawing.boxFont : .systemFont(ofSize: 12, weight: .semibold)
                } else if it.kind == .note {
                    r = it.frame.insetBy(dx: 4, dy: 4)
                    multi = true
                    f.font = .systemFont(ofSize: 13)
                } else if it.kind == .checkbox {
                    let sq = DesignDrawing.checkSquare(it)
                    r = CGRect(x: sq.maxX + 5, y: it.frame.minY, width: max(80, it.frame.maxX - sq.maxX - 5), height: it.frame.height)
                } else {
                    r = it.frame.insetBy(dx: it.kind == .button ? 4 : 2, dy: 0)
                    f.alignment = it.kind == .button ? .center : .left
                }
                f.stringValue = it.title
            }
        }
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = .white
        f.textColor = .black
        f.focusRingType = .exterior
        if multi {
            f.usesSingleLineMode = false
            f.cell?.wraps = true
            f.cell?.isScrollable = false
        } else {
            f.cell?.isScrollable = true
            f.cell?.usesSingleLineMode = true
            let h = ceil(f.font!.boundingRectForFont.height) + 2
            r = CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
        }
        f.frame = r
        f.delegate = self
        pushUndo()
        addSubview(f)
        editor = (f, id, part)
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    func commitEdit() {
        finishFreeform()
        guard let e = editor else { return }
        editor = nil
        let raw = e.field.currentEditor()?.string ?? e.field.stringValue
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        e.field.removeFromSuperview()
        if window?.firstResponder == nil || window?.firstResponder is NSTextView { window?.makeFirstResponder(self) }
        if e.part == "link" {
            if let i = design.links.firstIndex(where: { $0.id == e.id }) { design.links[i].text = text }
        } else if let i = index(e.id) {
            switch e.part {
            case "label": design.items[i].label = text
            case "choices":
                let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                design.items[i].choices = lines
                design.items[i].pick = min(design.items[i].pick, max(0, lines.count - 1))
                if design.items[i].kind == .radio {
                    DesignDrawing.fitRadio(&design.items[i])
                }
            default: design.items[i].title = text
            }
        }
        changed()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let ff = freeform, control === ff.field {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { finishFreeform() }
                else { textView.insertNewlineIgnoringFieldEditor(nil); fitFreeform() }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { finishFreeform(discard: true); return true }
            return false
        }
        guard let e = editor, control === e.field else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Choices and notes take a new line; elsewhere Return is done.
            if e.part == "choices" || e.part == "title" && item(e.id)?.kind == .note {
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { commitEdit(); return true }
                textView.insertNewlineIgnoringFieldEditor(nil)
                if e.part == "choices" {
                    let n = CGFloat(textView.string.components(separatedBy: "\n").count + 1)
                    e.field.frame.size.height = max(e.field.frame.height, n * 18 + 8)
                }
                return true
            }
            commitEdit()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
            commitEdit()
            return true
        }
        return false
    }

    // MARK: freeform

    func controlTextDidChange(_ obj: Notification) {
        if let ff = freeform, (obj.object as? NSTextField) === ff.field { fitFreeform() }
    }

    private func startFreeform(at p: CGPoint) {
        commitEdit()
        let f = NSTextField()
        f.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.isBordered = true
        f.drawsBackground = true
        f.backgroundColor = .white
        f.textColor = .black
        f.focusRingType = .exterior
        f.frame = CGRect(x: p.x, y: p.y, width: 420, height: 60)
        f.delegate = self
        addSubview(f)
        let win = design.items.filter { $0.kind == .window && $0.frame.contains(p) }.last?.id
        freeform = (f, p, win)
        window?.makeFirstResponder(f)
        needsDisplay = true
    }

    /// Test only: types `text` at `p` and finishes it.
    func typeFreeform(_ text: String, at p: CGPoint) {
        startFreeform(at: p)
        freeform?.field.stringValue = text
        finishFreeform()
    }

    /// Grows the typing box so every line shows.
    private func fitFreeform() {
        guard let ff = freeform else { return }
        let text = ff.field.currentEditor()?.string ?? ff.field.stringValue
        let n = CGFloat(max(3, text.components(separatedBy: "\n").count + 1))
        ff.field.frame.size.height = n * 17 + 8
    }

    /// Turns the typed lines into controls: in the window clicked, below what is in it, or in a new window there.
    private func finishFreeform(discard: Bool = false) {
        guard let ff = freeform else { return }
        freeform = nil
        let text = ff.field.currentEditor()?.string ?? ff.field.stringValue
        ff.field.removeFromSuperview()
        window?.makeFirstResponder(self)
        tool = .select
        needsDisplay = true
        guard !discard, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let lines = Freeform.parse(text, size: newSize)
        pushUndo()
        var area: CGRect, parent: String
        if let wid = ff.window, let w = item(wid) {
            let inside = descendants(of: [wid]).subtracting([wid])
            let bottom = design.items.filter { inside.contains($0.id) }.map { DesignDrawing.bounds($0).maxY }.max()
            let top = w.frame.minY + DesignDrawing.titleBarHeight(w) + 16
            area = CGRect(x: w.frame.minX + 16, y: bottom.map { max(top, $0 + 12) } ?? top, width: w.frame.width - 32, height: 0)
            parent = wid
        } else {
            var w = DesignItem.new(.window, at: CGRect(x: ff.at.x, y: ff.at.y, width: 340, height: 200), size: newSize, windowType: windowType)
            w.title = windowType.title
            design.items.append(w)
            area = CGRect(x: w.frame.minX + 16, y: w.frame.minY + DesignDrawing.titleBarHeight(w) + 16, width: w.frame.width - 32, height: 0)
            parent = w.id
        }
        var placed = Freeform.layout(lines, in: area, parent: parent, size: newSize)
        if let i = index(parent) {
            // The window grows to hold what was typed; a new one fits it.
            let isNew = ff.window == nil
            let f = design.items[i].frame
            let needW = placed.right + 16 - f.minX, needH = placed.bottom + 16 - f.minY
            if isNew {
                design.items[i].frame.size = CGSize(width: max(240, needW), height: max(80, needH))
                // Rows pushed right were placed against the first guess at the width; move them to the real edge.
                let shift = design.items[i].frame.maxX - (area.maxX + 16)
                if shift != 0 {
                    for k in placed.items.indices where placed.items[k].frame.maxX > area.maxX - 1 && placed.items[k].kind != .box {
                        placed.items[k].frame.origin.x += shift
                    }
                    for k in placed.items.indices where placed.items[k].kind == .box {
                        placed.items[k].frame.size.width += shift
                    }
                }
            } else {
                design.items[i].frame.size = CGSize(width: max(f.width, needW), height: max(f.height, needH))
            }
        }
        design.items += placed.items
        selection = Set(placed.items.filter { $0.parent == parent }.map(\.id))
        changed()
    }

    private func choosePicture(_ id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let dir = folder ?? needFolder?(), let i = index(id) else { return }
        let name = "picture-\(UUID().uuidString.prefix(8)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
        try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        folder = dir
        pushUndo()
        design.items[i].image = name
        changed()
    }
}
