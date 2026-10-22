import AppKit

/// One thing drawn on the frozen screen. Coordinates are screen points, top-left origin.
struct Mark {
    enum Kind {
        case tool(ToolDef)
        case pasted(NSImage, source: CGRect)
    }

    var kind: Kind
    var rect: CGRect = .zero          // box, oval, text anchor, pasted piece, bounds of pen/arrow
    var start: CGPoint = .zero        // arrow start
    var end: CGPoint = .zero          // arrow end, or where a box+arrow points
    var points: [CGPoint] = []        // pen
    var text: String = ""
    var targetSize: CGSize?           // where a box+arrow points, once sized on its own; else the source's size

    var tool: ToolDef? {
        if case .tool(let t) = kind { return t }
        return nil
    }

    var color: NSColor {
        switch kind {
        case .tool(let t): return t.color
        case .pasted: return NSColor(hex: "#7A4FE0")!
        }
    }

    /// The area the mark covers, for hit testing and for the message.
    var area: CGRect {
        guard let t = tool else { return rect }
        switch t.shape {
        case .arrow: return CGRect(p1: start, p2: end)
        case .pen:
            guard let f = points.first else { return .zero }
            return points.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        case .text: return CGRect(origin: rect.origin, size: textSize)
        default: return rect
        }
    }

    var textSize: CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let b = s.boundingRect(with: CGSize(width: 320, height: 1000), options: [.usesLineFragmentOrigin],
                               attributes: [.font: MarkDrawing.calloutFont])
        return CGSize(width: ceil(b.width) + 18, height: ceil(b.height) + 10)
    }

    /// The ghost box a box+arrow mark leaves where it points.
    var target: CGRect {
        let sz = targetSize ?? rect.size
        return CGRect(x: end.x - sz.width / 2, y: end.y - sz.height / 2, width: sz.width, height: sz.height)
    }

    var isBoxArrow: Bool { tool?.shape == .boxArrow }

    func hit(_ p: CGPoint) -> Bool {
        if case .tool(let t) = kind, t.shape == .boxArrow, target.insetBy(dx: -4, dy: -4).contains(p) { return true }
        return area.insetBy(dx: -6, dy: -6).contains(p)
    }

    mutating func offset(by d: CGVector) {
        rect = rect.offsetBy(dx: d.dx, dy: d.dy)
        start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

extension CGRect {
    /// Top-left, top-right, bottom-left, bottom-right (flipped coordinates).
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)]
    }

    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}

/// Draws marks into the current, flipped graphics context. Used on screen and for the sent picture.
enum MarkDrawing {
    static let calloutFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let tagFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    /// Draws every mark: the shapes first, then all the words, then the numbers, so later marks never cover words.
    static func drawAll(_ marks: [Mark], selected: Int? = nil, hideWordsOf hidden: Int? = nil) {
        for m in marks { draw(m, number: nil, selected: false, words: false) }
        for (i, m) in marks.enumerated() where i != hidden { words(m) }
        for (i, m) in marks.enumerated() {
            tag(i + 1, at: tagPoint(m), color: m.color)
            if selected == i { handles(m) }
        }
    }

    static func words(_ m: Mark) {
        guard let t = m.tool else { return }
        switch t.shape {
        case .box, .oval: drawWords(m, tool: t)
        case .text: bubble(m.text, at: m.rect.origin, color: m.color)
        default: break
        }
    }

    static func draw(_ m: Mark, number: Int?, selected: Bool, words showWords: Bool = true) {
        let color = m.color
        switch m.kind {
        case .pasted(let img, _):
            img.draw(in: m.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            stroke(NSBezierPath(rect: m.rect), color: color, width: 2, dashed: true)
        case .tool(let t):
            switch t.shape {
            case .box, .oval:
                let path = t.shape == .box ? NSBezierPath(rect: m.rect) : NSBezierPath(ovalIn: m.rect)
                fill(path, rect: m.rect, color: color, fill: t.fill)
                stroke(path, color: color, width: t.lineWidth, dashed: t.dashed)
            case .boxArrow:
                let path = NSBezierPath(rect: m.rect)
                fill(path, rect: m.rect, color: color, fill: t.fill)
                stroke(path, color: color, width: t.lineWidth, dashed: t.dashed)
                if m.end != .zero {
                    let ghost = NSBezierPath(rect: m.target)
                    color.withAlphaComponent(0.12).setFill()
                    ghost.fill()
                    stroke(ghost, color: color, width: t.lineWidth, dashed: true)
                    arrow(from: edgePoint(of: m.rect, toward: m.end), to: edgePoint(of: m.target, toward: m.rect.center),
                          color: color, width: t.lineWidth + 0.5)
                }
            case .arrow:
                arrow(from: m.start, to: m.end, color: color, width: t.lineWidth + 0.5)
            case .pen:
                guard m.points.count > 1 else { break }
                let path = NSBezierPath()
                path.move(to: m.points[0])
                for p in m.points.dropFirst() { path.line(to: p) }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                stroke(path, color: color, width: t.lineWidth, dashed: false)
            case .text:
                break
            }
        }
        if showWords { words(m) }
        if let n = number { tag(n, at: tagPoint(m), color: color) }
        if selected { handles(m) }
    }

    private static func tagPoint(_ m: Mark) -> CGPoint {
        if let t = m.tool, t.shape == .arrow { return m.start }
        let a = m.area
        return CGPoint(x: a.minX, y: a.minY)
    }

    private static func drawWords(_ m: Mark, tool t: ToolDef) {
        guard !m.text.isEmpty else { return }
        if t.placement == .inside {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                        .foregroundColor: t.color.blended(withFraction: 0.3, of: .black)!]
            let s = m.text as NSString
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            var a = attrs
            a[.paragraphStyle] = para
            let wrap = max(20, m.rect.width - 34)
            let sz = s.boundingRect(with: CGSize(width: wrap, height: 10_000),
                                    options: [.usesLineFragmentOrigin], attributes: a).size
            let w = ceil(sz.width) + 26, h = ceil(sz.height) + 12
            let b = CGRect(x: m.rect.midX - w / 2, y: m.rect.midY - h / 2, width: w, height: h)
            let pill = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
            NSColor.white.setFill()
            pill.fill()
            stroke(pill, color: t.color, width: 1.5, dashed: true)
            s.draw(with: CGRect(x: b.midX - wrap / 2, y: b.minY + 6, width: wrap, height: ceil(sz.height) + 2),
                   options: [.usesLineFragmentOrigin], attributes: a)
        } else {
            bubble("“\(m.text)”", at: CGPoint(x: m.rect.minX, y: m.rect.maxY + 6), color: t.color)
        }
    }

    static func bubble(_ text: String, at p: CGPoint, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: calloutFont, .foregroundColor: NSColor.white]
        let s = (text.isEmpty ? " " : text) as NSString
        let b = s.boundingRect(with: CGSize(width: 320, height: 1000), options: [.usesLineFragmentOrigin], attributes: attrs)
        let box = CGRect(x: p.x, y: p.y, width: ceil(b.width) + 18, height: ceil(b.height) + 10)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        // Drawn at the measured wrap width, so the lines break exactly as they were measured.
        s.draw(with: CGRect(x: box.minX + 9, y: box.minY + 5, width: 320, height: ceil(b.height) + 2),
               options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    static func tag(_ n: Int, at p: CGPoint, color: NSColor) {
        let r = CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = 3
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.set()
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
        let attrs: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: NSColor.white]
        let s = "\(n)" as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }

    static func handles(_ m: Mark) {
        var pts: [CGPoint]
        if let t = m.tool, t.shape == .arrow {
            pts = [m.start, m.end]
        } else {
            let a = m.area
            pts = [CGPoint(x: a.minX, y: a.minY), CGPoint(x: a.maxX, y: a.minY),
                   CGPoint(x: a.minX, y: a.maxY), CGPoint(x: a.maxX, y: a.maxY)]
            if m.isBoxArrow, m.end != .zero { pts += m.target.corners }
        }
        for p in pts {
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            r.fill()
            NSColor.darkGray.setStroke()
            NSBezierPath(rect: r).stroke()
        }
    }

    static func fill(_ path: NSBezierPath, rect: CGRect, color: NSColor, fill: ToolFill) {
        switch fill {
        case .none: break
        case .tint:
            color.withAlphaComponent(0.12).setFill()
            path.fill()
        case .stripes:
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            color.withAlphaComponent(0.08).setFill()
            path.fill()
            let stripes = NSBezierPath()
            stripes.lineWidth = 6
            var x = rect.minX - rect.height
            while x < rect.maxX {
                stripes.move(to: CGPoint(x: x, y: rect.maxY))
                stripes.line(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 14
            }
            color.withAlphaComponent(0.28).setStroke()
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func stroke(_ path: NSBezierPath, color: NSColor, width: Double, dashed: Bool) {
        path.lineWidth = width
        if dashed { path.setLineDash([8, 5], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    static func arrow(from a: CGPoint, to b: CGPoint, color: NSColor, width: Double) {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 2 else { return }
        let ang = atan2(b.y - a.y, b.x - a.x)
        let head = max(12, width * 4)
        let base = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: base)
        line.lineCapStyle = .round
        stroke(line, color: color, width: width, dashed: false)
        let tip = NSBezierPath()
        tip.move(to: b)
        tip.line(to: CGPoint(x: b.x - cos(ang - 0.45) * head, y: b.y - sin(ang - 0.45) * head))
        tip.line(to: CGPoint(x: b.x - cos(ang + 0.45) * head, y: b.y - sin(ang + 0.45) * head))
        tip.close()
        color.setFill()
        tip.fill()
    }

    /// Where a line from the box's center toward `p` leaves the box.
    static func edgePoint(of r: CGRect, toward p: CGPoint) -> CGPoint {
        let c = r.center
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let sx = dx == 0 ? CGFloat.infinity : (r.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (r.height / 2) / abs(dy)
        let s = min(sx, sy, 1)
        return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
