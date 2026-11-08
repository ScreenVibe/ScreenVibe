import AppKit

/// Draws a UI design into the current, flipped graphics context. Used on screen, for previews and for the sent picture.
enum DesignDrawing {
    static let page = NSColor(hex: "#EAF3FB")!
    static let gridMinor = NSColor(hex: "#D9E8F6")!
    static let gridMajor = NSColor(hex: "#BCD6EE")!
    static let accent = NSColor(hex: "#1A6FE0")!
    static let arrowColor = NSColor(hex: "#C4302B")!
    static let guideColor = NSColor(hex: "#FF2D95")!

    /// Light controls, or dark ones inside an Adobe panel.
    struct Theme {
        let window: NSColor, control: NSColor, border: NSColor, text: NSColor, dim: NSColor, bar: NSColor
        static let light = Theme(window: NSColor(hex: "#F4F4F6")!, control: .white, border: NSColor(hex: "#B9B9BE")!,
                                 text: NSColor(hex: "#1D1D1F")!, dim: NSColor(hex: "#6E6E73")!, bar: NSColor(hex: "#E8E8EC")!)
        static let dark = Theme(window: NSColor(hex: "#323232")!, control: NSColor(hex: "#454545")!, border: NSColor(hex: "#5C5C5C")!,
                                text: NSColor(hex: "#EEEEEE")!, dim: NSColor(hex: "#BBBBBB")!, bar: NSColor(hex: "#252525")!)
    }

    static func theme(of it: DesignItem, in items: [DesignItem]) -> Theme {
        var cur: DesignItem? = it
        var seen = Set<String>()
        while let c = cur, !seen.contains(c.id) {
            seen.insert(c.id)
            if c.kind == .window { return c.windowType == .adobe ? .dark : .light }
            cur = items.first { $0.id == c.parent }
        }
        return .light
    }

    // MARK: where things are

    static func labelFont(_ it: DesignItem) -> NSFont { it.size.font }

    /// The linked label: left of a popup, field or slider; above a list.
    static func labelRect(_ it: DesignItem) -> CGRect? {
        guard it.kind.hasLabel, !it.label.isEmpty else { return nil }
        let s = (it.label as NSString).size(withAttributes: [.font: labelFont(it)])
        if it.kind == .list {
            return CGRect(x: it.frame.minX, y: it.frame.minY - s.height - 4, width: ceil(s.width) + 2, height: ceil(s.height))
        }
        let midY = it.kind == .radio ? (rows(it).first?.midY ?? it.frame.midY) : it.frame.midY
        return CGRect(x: it.frame.minX - 8 - ceil(s.width), y: midY - s.height / 2, width: ceil(s.width) + 2, height: ceil(s.height))
    }

    /// The item with its label.
    static func bounds(_ it: DesignItem) -> CGRect {
        var r = labelRect(it).map { it.frame.union($0) } ?? it.frame
        if it.kind == .box, let t = titleRect(it) { r = r.union(t) }
        return r
    }

    static func titleBarHeight(_ it: DesignItem) -> CGFloat {
        guard it.kind == .window else { return 0 }
        switch it.windowType {
        case .panel: return 20
        case .adobe: return 26
        case .modal, .plain: return 28
        }
    }

    /// Where a window's or box's title is drawn, for editing it.
    static func titleRect(_ it: DesignItem) -> CGRect? {
        let f = it.frame
        switch it.kind {
        case .window:
            let h = titleBarHeight(it)
            if it.windowType == .adobe {
                let w = (it.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 24
                return CGRect(x: f.minX + 6, y: f.minY + 4, width: max(60, w), height: h - 4)
            }
            return CGRect(x: f.minX + 70, y: f.minY, width: max(40, f.width - 140), height: h)
        case .box:
            let w = (it.title as NSString).size(withAttributes: [.font: boxFont]).width + 12
            return CGRect(x: f.minX + 2, y: f.minY - 19, width: max(40, w), height: 16)
        default: return nil
        }
    }

    static let boxFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// The rows of a radio group or list, and the tabs of a tab view.
    static func rows(_ it: DesignItem) -> [CGRect] {
        let f = it.frame
        switch it.kind {
        case .radio where it.across == true:
            let d = checkSquare(it).width
            var x = f.minX
            return it.choices.map { c in
                let w = d + 7 + ceil((c as NSString).size(withAttributes: [.font: it.size.font]).width) + 18
                defer { x += w }
                return CGRect(x: x, y: f.minY, width: w, height: f.height)
            }
        case .radio:
            return it.choices.indices.map { CGRect(x: f.minX, y: f.minY + CGFloat($0) * it.size.rowGap, width: f.width, height: it.size.rowGap) }
        case .list:
            let h = it.size.rowGap
            return it.choices.indices.map { CGRect(x: f.minX + 1, y: f.minY + 1 + CGFloat($0) * h, width: f.width - 2, height: h) }
        case .tabs:
            let font = it.size.font
            let ws = it.choices.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 24 }
            var x = f.midX - ws.reduce(0, +) / 2
            return ws.map { w in defer { x += w }; return CGRect(x: x, y: f.minY, width: w, height: it.size.height) }
        default: return []
        }
    }

    /// Radio buttons sized to their choices: one row each, or side by side.
    static func fitRadio(_ it: inout DesignItem) {
        if it.across == true {
            it.frame.size.height = it.size.height
            var probe = it
            probe.frame.size.width = 0
            it.frame.size.width = max(40, rows(probe).last.map { $0.maxX - probe.frame.minX - 10 } ?? 40)
        } else {
            it.frame.size.height = it.size.rowGap * CGFloat(max(1, it.choices.count))
        }
    }

    static func checkSquare(_ it: DesignItem) -> CGRect {
        let d: CGFloat = it.size == .s ? 12 : it.size == .m ? 14 : 17
        return CGRect(x: it.frame.minX, y: it.frame.midY - d / 2, width: d, height: d)
    }

    // MARK: drawing

    static func drawGrid(_ r: CGRect) {
        page.setFill()
        r.fill()
        for (step, color) in [(CGFloat(20), gridMinor), (CGFloat(100), gridMajor)] {
            color.setFill()
            var x = floor(r.minX / step) * step
            while x <= r.maxX { CGRect(x: x, y: r.minY, width: 1, height: r.height).fill(); x += step }
            var y = floor(r.minY / step) * step
            while y <= r.maxY { CGRect(x: r.minX, y: y, width: r.width, height: 1).fill(); y += step }
        }
    }

    /// Items in drawing order: each window or box, then what sits in it.
    static func ordered(_ items: [DesignItem]) -> [DesignItem] {
        var out: [DesignItem] = []
        var seen = Set<String>()
        func add(_ it: DesignItem) {
            guard !seen.contains(it.id) else { return }
            seen.insert(it.id)
            out.append(it)
            for c in items where c.parent == it.id { add(c) }
        }
        for it in items where it.parent == nil || !items.contains(where: { $0.id == it.parent }) { add(it) }
        for it in items { add(it) }
        return out
    }

    static func drawAll(_ d: Design, folder: URL?, hiddenText: (id: String, part: String)? = nil) {
        for it in ordered(d.items) {
            draw(it, theme: theme(of: it, in: d.items), folder: folder, hide: hiddenText?.id == it.id ? hiddenText?.part : nil)
        }
        for l in d.links {
            guard let a = d.items.first(where: { $0.id == l.from }), let b = d.items.first(where: { $0.id == l.to }) else { continue }
            drawLink(route(from: a.frame, to: b.frame, id: l.id), text: hiddenText?.id == l.id ? "" : l.text)
        }
    }

    private static func say(_ s: String, in r: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let h = (s as NSString).size(withAttributes: a).height
        (s as NSString).draw(with: CGRect(x: r.minX, y: r.midY - h / 2, width: max(4, r.width), height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
    }

    private static func rounded(_ r: CGRect, _ radius: CGFloat, fill: NSColor?, stroke: NSColor?, width: CGFloat = 1) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        if let fill { fill.setFill(); p.fill() }
        if let stroke { stroke.setStroke(); p.lineWidth = width; p.stroke() }
    }

    /// `hide`: "title", "label" or "choices", being edited in a field over it.
    static func draw(_ it: DesignItem, theme t: Theme, folder: URL?, hide: String? = nil) {
        let f = it.frame, font = it.size.font
        let title = hide == "title" ? "" : it.title
        if let lr = labelRect(it), hide != "label" {
            say(it.label, in: lr, font: font, color: t.dim, align: it.kind == .list ? .left : .right)
        }
        switch it.kind {
        case .window:
            drawWindow(it, title: title)
        case .box:
            rounded(CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height), 6, fill: t.text.withAlphaComponent(0.03), stroke: t.border)
            if let tr = titleRect(it) { say(title, in: tr, font: boxFont, color: t.text) }
        case .button:
            rounded(f, min(7, f.height / 3), fill: t.control, stroke: t.border)
            if let icon = it.icon, let img = LeapIcons.image(icon, small: true) {
                // The small LEAP icon left of the words, the two centered together.
                let a: [NSAttributedString.Key: Any] = [.font: font]
                let gap: CGFloat = title.isEmpty ? 0 : 5
                let tw = min(max(0, f.width - 16 - img.size.width - gap), ceil((title as NSString).size(withAttributes: a).width))
                let x0 = f.midX - (img.size.width + gap + tw) / 2
                LeapIcons.draw(icon, small: true, centeredAt: CGPoint(x: x0 + img.size.width / 2, y: f.midY))
                if !title.isEmpty { say(title, in: CGRect(x: x0 + img.size.width + gap, y: f.minY, width: tw + 1, height: f.height), font: font, color: t.text) }
            } else {
                say(title, in: f.insetBy(dx: 8, dy: 0), font: font, color: t.text, align: .center)
            }
        case .popup:
            rounded(f, min(6, f.height / 3), fill: t.control, stroke: t.border)
            if hide != "choices" { say(it.choices.first ?? "", in: CGRect(x: f.minX + 9, y: f.minY, width: f.width - 30, height: f.height), font: font, color: t.text) }
            let c = CGPoint(x: f.maxX - 13, y: f.midY), v = NSBezierPath()
            v.move(to: CGPoint(x: c.x - 3.5, y: c.y - 1.5)); v.line(to: CGPoint(x: c.x, y: c.y - 5)); v.line(to: CGPoint(x: c.x + 3.5, y: c.y - 1.5))
            v.move(to: CGPoint(x: c.x - 3.5, y: c.y + 1.5)); v.line(to: CGPoint(x: c.x, y: c.y + 5)); v.line(to: CGPoint(x: c.x + 3.5, y: c.y + 1.5))
            v.lineWidth = 1.4; v.lineCapStyle = .round; v.lineJoinStyle = .round
            t.dim.setStroke(); v.stroke()
        case .checkbox:
            let sq = checkSquare(it)
            rounded(sq, 3.5, fill: it.on ? accent : t.control, stroke: it.on ? accent : t.border, width: 1.2)
            if it.on { check(in: sq) }
            say(title, in: CGRect(x: sq.maxX + 7, y: f.minY, width: f.width - sq.width - 7, height: f.height), font: font, color: t.text)
        case .radio:
            for (i, r) in rows(it).enumerated() where hide != "choices" {
                let d = checkSquare(it).width, c = CGRect(x: r.minX, y: r.midY - d / 2, width: d, height: d)
                let p = NSBezierPath(ovalIn: c.insetBy(dx: 0.6, dy: 0.6))
                (i == it.pick ? accent : t.control).setFill(); p.fill()
                (i == it.pick ? accent : t.border).setStroke(); p.lineWidth = 1.2; p.stroke()
                if i == it.pick { NSColor.white.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: d * 0.33, dy: d * 0.33)).fill() }
                say(it.choices[i], in: CGRect(x: c.maxX + 7, y: r.minY, width: r.width - d - 7, height: r.height), font: font, color: t.text)
            }
        case .field:
            rounded(f, 4, fill: t.control, stroke: t.border)
            say(title, in: f.insetBy(dx: 7, dy: 0), font: font, color: t.text)
        case .slider:
            let track = CGRect(x: f.minX + 7, y: f.midY - 2, width: f.width - 14, height: 4)
            rounded(track, 2, fill: t.border, stroke: nil)
            let x = track.minX + CGFloat(min(1, max(0, it.value))) * track.width
            rounded(CGRect(x: track.minX, y: track.minY, width: x - track.minX, height: 4), 2, fill: accent, stroke: nil)
            let k: CGFloat = it.size == .s ? 12 : it.size == .m ? 15 : 18
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
            NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: x - k / 2, y: f.midY - k / 2, width: k, height: k)).fill()
            NSGraphicsContext.restoreGraphicsState()
        case .label:
            say(title, in: f, font: font, color: t.text)
        case .tabs:
            let tabs = rows(it), top = it.size.height / 2
            rounded(CGRect(x: f.minX, y: f.minY + top, width: f.width, height: f.height - top), 6, fill: t.text.withAlphaComponent(0.03), stroke: t.border)
            if let first = tabs.first, let last = tabs.last, hide != "choices" {
                rounded(CGRect(x: first.minX, y: f.minY, width: last.maxX - first.minX, height: it.size.height), 6, fill: t.control, stroke: t.border)
                for (i, r) in tabs.enumerated() {
                    if i == it.pick { rounded(r.insetBy(dx: 2, dy: 2), 4, fill: accent, stroke: nil) }
                    say(it.choices[i], in: r, font: font, color: i == it.pick ? .white : t.text, align: .center)
                }
            }
        case .list:
            rounded(f, 4, fill: t.control, stroke: t.border)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: f.insetBy(dx: 1, dy: 1)).addClip()
            for (i, r) in rows(it).enumerated() where hide != "choices" {
                if i == it.pick { accent.setFill(); r.fill() }
                say(it.choices[i], in: r.insetBy(dx: 8, dy: 0), font: font, color: i == it.pick ? .white : t.text)
            }
            NSGraphicsContext.restoreGraphicsState()
        case .picture:
            if let name = it.image, let folder, let img = NSImage(contentsOf: folder.appendingPathComponent(name)) {
                img.draw(in: f, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                rounded(f, 4, fill: t.control, stroke: t.border)
                let p = NSBezierPath()
                p.move(to: CGPoint(x: f.minX, y: f.minY)); p.line(to: CGPoint(x: f.maxX, y: f.maxY))
                p.move(to: CGPoint(x: f.maxX, y: f.minY)); p.line(to: CGPoint(x: f.minX, y: f.maxY))
                t.border.setStroke(); p.lineWidth = 1; p.stroke()
                say("Picture", in: f, font: .systemFont(ofSize: 12, weight: .semibold), color: t.dim, align: .center)
            }
        case .note:
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 5; sh.shadowOffset = NSSize(width: 0, height: -2)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.18); sh.set()
            NSColor(hex: "#FFF4A8")!.setFill(); NSBezierPath(rect: f).fill()
            NSGraphicsContext.restoreGraphicsState()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(hex: "#3A3300")!]
            (title as NSString).draw(with: f.insetBy(dx: 8, dy: 7), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
        }
    }

    private static func check(in sq: CGRect) {
        let v = NSBezierPath()
        v.move(to: CGPoint(x: sq.minX + sq.width * 0.24, y: sq.midY))
        v.line(to: CGPoint(x: sq.minX + sq.width * 0.43, y: sq.maxY - sq.height * 0.27))
        v.line(to: CGPoint(x: sq.maxX - sq.width * 0.22, y: sq.minY + sq.height * 0.27))
        v.lineWidth = 1.8; v.lineCapStyle = .round; v.lineJoinStyle = .round
        NSColor.white.setStroke(); v.stroke()
    }

    private static func drawWindow(_ it: DesignItem, title: String) {
        let f = it.frame, bar = titleBarHeight(it)
        let t: Theme = it.windowType == .adobe ? .dark : .light
        let radius: CGFloat = it.windowType == .adobe ? 4 : it.windowType == .panel ? 8 : 10
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 14; sh.shadowOffset = NSSize(width: 0, height: -5)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.2); sh.set()
        t.window.setFill(); NSBezierPath(roundedRect: f, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: f, xRadius: radius, yRadius: radius).addClip()
        let barRect = CGRect(x: f.minX, y: f.minY, width: f.width, height: bar)
        if it.windowType == .adobe {
            t.bar.setFill(); barRect.fill()
            if let tr = titleRect(it) {
                let tab = CGRect(x: tr.minX, y: tr.minY, width: tr.width, height: tr.height)
                NSBezierPath(roundedRect: tab.insetBy(dx: 0, dy: 0), xRadius: 3, yRadius: 3).fill(with: t.window)
                t.window.setFill(); CGRect(x: tab.minX, y: tab.midY, width: tab.width, height: tab.height / 2).fill()
                say(title, in: tab, font: .systemFont(ofSize: 12), color: t.text, align: .center)
            }
        } else {
            t.bar.withAlphaComponent(0.6).setFill(); barRect.fill()
            t.border.withAlphaComponent(0.6).setFill(); CGRect(x: f.minX, y: f.minY + bar - 1, width: f.width, height: 1).fill()
            if it.windowType == .plain {
                for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                    NSColor(hex: hex)!.setFill()
                    NSBezierPath(ovalIn: CGRect(x: f.minX + 10 + CGFloat(i) * 19, y: f.minY + bar / 2 - 6, width: 12, height: 12)).fill()
                }
            }
            let tf: NSFont = it.windowType == .panel ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13, weight: .semibold)
            say(title, in: CGRect(x: f.minX + 70, y: f.minY, width: f.width - 140, height: bar), font: tf, color: t.text, align: .center)
        }
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (it.windowType == .adobe ? NSColor(hex: "#1A1A1A")! : NSColor(hex: "#C6C6CC")!).setStroke()
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: arrows

    /// Which way a link runs, kept per link so it does not flip back and forth at a corner.
    enum Way { case right, left, down, up }
    static var lastWay: [String: Way] = [:]

    /// A right-angled route from one box to another: straight, or with two bends, leaving a small gap at each end.
    static func route(from a: CGRect, to b: CGRect, id: String? = nil) -> [CGPoint] {
        let gap: CGFloat = 4, clear: CGFloat = 16
        var way: Way
        if b.minX > a.maxX + clear { way = .right }
        else if b.maxX < a.minX - clear { way = .left }
        else if b.minY > a.maxY + clear { way = .down }
        else if b.maxY < a.minY - clear { way = .up }
        else { way = b.midX >= a.midX ? .right : .left }
        // Keep the way it ran before while it still fits, so it does not flip at a diagonal.
        if let id, let w = lastWay[id], w != way {
            let fits: Bool
            switch w {
            case .right: fits = b.minX > a.maxX + 4
            case .left: fits = b.maxX < a.minX - 4
            case .down: fits = b.minY > a.maxY + 4
            case .up: fits = b.maxY < a.minY - 4
            }
            if fits { way = w }
        }
        if let id { lastWay[id] = way }
        switch way {
        case .right, .left:
            let lo = max(a.minY, b.minY), hi = min(a.maxY, b.maxY)
            let (y1, y2) = hi - lo > 12 ? ((lo + hi) / 2, (lo + hi) / 2) : (a.midY, b.midY)
            let s = CGPoint(x: way == .right ? a.maxX + gap : a.minX - gap, y: y1)
            let e = CGPoint(x: way == .right ? b.minX - gap : b.maxX + gap, y: y2)
            if abs(y1 - y2) < 1 { return [s, e] }
            let mx = (s.x + e.x) / 2
            return [s, CGPoint(x: mx, y: s.y), CGPoint(x: mx, y: e.y), e]
        case .down, .up:
            let lo = max(a.minX, b.minX), hi = min(a.maxX, b.maxX)
            let (x1, x2) = hi - lo > 12 ? ((lo + hi) / 2, (lo + hi) / 2) : (a.midX, b.midX)
            let s = CGPoint(x: x1, y: way == .down ? a.maxY + gap : a.minY - gap)
            let e = CGPoint(x: x2, y: way == .down ? b.minY - gap : b.maxY + gap)
            if abs(x1 - x2) < 1 { return [s, e] }
            let my = (s.y + e.y) / 2
            return [s, CGPoint(x: s.x, y: my), CGPoint(x: e.x, y: my), e]
        }
    }

    /// The middle of a route, where its words go.
    static func middle(_ pts: [CGPoint]) -> CGPoint {
        guard pts.count >= 2 else { return pts.first ?? .zero }
        let k = pts.count / 2
        return CGPoint(x: (pts[k - 1].x + pts[k].x) / 2, y: (pts[k - 1].y + pts[k].y) / 2)
    }

    static func drawLink(_ pts: [CGPoint], text: String, color: NSColor = arrowColor, dashed: Bool = false) {
        guard pts.count >= 2 else { return }
        let p = NSBezierPath()
        p.move(to: pts[0])
        for i in 1..<pts.count - 1 {
            let a = pts[i - 1], b = pts[i], c = pts[i + 1]
            let r = min(6, hypot(b.x - a.x, b.y - a.y) / 2, hypot(c.x - b.x, c.y - b.y) / 2)
            p.appendArc(from: b, to: c, radius: r)
        }
        p.line(to: pts[pts.count - 1])
        p.lineWidth = 2
        if dashed { p.setLineDash([5, 4], count: 2, phase: 0) }
        color.setStroke()
        p.stroke()
        NSBezierPath(ovalIn: CGRect(x: pts[0].x - 3.5, y: pts[0].y - 3.5, width: 7, height: 7)).fill(with: color)
        // The head: a V along the last leg.
        let e = pts[pts.count - 1], b = pts[pts.count - 2]
        let ang = atan2(e.y - b.y, e.x - b.x), len: CGFloat = 9, spread: CGFloat = 0.5
        let h = NSBezierPath()
        h.move(to: CGPoint(x: e.x - len * cos(ang - spread), y: e.y - len * sin(ang - spread)))
        h.line(to: e)
        h.line(to: CGPoint(x: e.x - len * cos(ang + spread), y: e.y - len * sin(ang + spread)))
        h.lineWidth = 2; h.lineCapStyle = .round; h.lineJoinStyle = .round
        h.stroke()
        guard !text.isEmpty else { return }
        let m = middle(pts)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: a)
        let r = CGRect(x: m.x - s.width / 2 - 5, y: m.y - s.height / 2 - 2, width: s.width + 10, height: s.height + 4)
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill(with: page.withAlphaComponent(0.92))
        (text as NSString).draw(at: CGPoint(x: r.minX + 5, y: r.minY + 2), withAttributes: a)
    }

    /// The design as a picture, `scale` pixels per point, cut to what is drawn plus a margin.
    static func picture(_ d: Design, folder: URL?, scale: CGFloat = 2, grid: Bool = false) -> (image: CGImage, origin: CGPoint)? {
        guard var r = d.items.map({ bounds($0) }).reduce(nil as CGRect?, { acc, r in acc.map { $0.union(r) } ?? r }) else { return nil }
        for l in d.links {
            if let a = d.items.first(where: { $0.id == l.from }), let b = d.items.first(where: { $0.id == l.to }) {
                for p in route(from: a.frame, to: b.frame) { r = r.union(CGRect(origin: p, size: .zero)) }
            }
        }
        r = r.insetBy(dx: -24, dy: -24).integral
        let w = Int(r.width * scale), h = Int(r.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if grid { drawGrid(r) } else { NSColor(hex: "#F7F9FC")!.setFill(); r.fill() }
        drawAll(d, folder: folder)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, r.origin)
    }
}

private extension NSBezierPath {
    func fill(with c: NSColor) { c.setFill(); fill() }
}
