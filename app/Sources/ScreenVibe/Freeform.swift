import AppKit

/// Freeform: controls typed as text, one row per line, turned into real controls.
///
///     [Export]                    button
///     [x] Shadow   [ ] Outline    checkboxes
///     Flavor: [Bubble v | Glossy] popup with its label
///     Format: (o) PNG  ( ) PDF    radio buttons side by side (one per line: stacked)
///     Name: [_Team logo_]  [__]   text fields
///     Depth: [--o--]              slider
///     <Fill | Stroke>             tabs
///     Fonts: {Arial | Times}      list
///     == Effects  …  ==           a box around the lines between
///     > [Cancel] [OK]             a row pushed to the right
///     -> [x] Related              indented one step (->-> two)
///     other words                 a label
enum Freeform {
    struct Line {
        var indent = 0
        var right = false
        var kind: Kind
    }

    enum Kind {
        case row([DesignItem])
        case boxStart(String)
        case boxEnd
        case space
    }

    private static let token = try! NSRegularExpression(
        pattern: #"\[[xX✓ ]\]|\((?:o|O|•|\*| )\)|\[[^\]]*\]|<[^>]*>|\{[^}]*\}"#)

    static func parse(_ text: String, size: ControlSize) -> [Line] {
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            var line = Line(kind: .space)
            while s.hasPrefix("->") || s.hasPrefix("→") {
                line.indent += 1
                s = String(s.dropFirst(s.hasPrefix("->") ? 2 : 1)).trimmingCharacters(in: .whitespaces)
            }
            if s.isEmpty { lines.append(line); continue }
            if s.hasPrefix("==") {
                let title = s.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                line.kind = title.isEmpty ? .boxEnd : .boxStart(title)
                lines.append(line)
                continue
            }
            if s.hasPrefix(">") {
                line.right = true
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line.kind = .row(items(in: s, size: size))
            lines.append(line)
        }
        return stackRadios(lines)
    }

    private static func make(_ k: ItemKind, _ size: ControlSize) -> DesignItem {
        var it = DesignItem.new(k, at: .zero, size: size, windowType: .panel)
        it.label = ""
        it.title = ""
        it.choices = []
        return it
    }

    private static func split(_ s: String) -> [String] {
        s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The controls on one line, left to right.
    private static func items(in s: String, size: ControlSize) -> [DesignItem] {
        let ns = s as NSString
        let matches = token.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out: [DesignItem] = []
        var cursor = 0
        var radio: DesignItem?
        func text(_ a: Int, _ b: Int) -> String {
            b > a ? ns.substring(with: NSRange(location: a, length: b - a)).trimmingCharacters(in: .whitespaces) : ""
        }
        func flushRadio() { if let r = radio { out.append(r); radio = nil } }
        func plain(_ t: String) { if !t.isEmpty { var l = make(.label, size); l.title = t; out.append(l) } }
        var i = 0
        while i < matches.count {
            let m = matches[i]
            let tok = ns.substring(with: m.range)
            let pre = text(cursor, m.range.location)
            let next = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let isCheck = tok.count == 3 && tok.hasPrefix("[") && "xX✓ ".contains(tok[tok.index(after: tok.startIndex)])
            let isRadio = tok.count == 3 && tok.hasPrefix("(")
            // Words ending in a colon right before a control are its label.
            var label = ""
            if pre.hasSuffix(":") { label = String(pre.dropLast()).trimmingCharacters(in: .whitespaces) }
            if isRadio {
                let choice = text(m.range.location + m.range.length, next)
                if radio == nil {
                    if label.isEmpty { flushRadio(); plain(pre) }
                    radio = make(.radio, size)
                    radio!.pick = -1   // none chosen until an (o)
                    radio!.label = label
                    radio!.across = true
                }
                if tok == "(o)" || tok == "(O)" || tok == "(•)" || tok == "(*)" { radio!.pick = radio!.choices.count }
                radio!.choices.append(choice)
                cursor = next
                i += 1
                continue
            }
            flushRadio()
            if label.isEmpty { plain(pre) } else if !hasLabel(tok) { plain(pre) ; label = "" }
            if isCheck {
                var c = make(.checkbox, size)
                c.on = tok != "[ ]"
                c.title = text(m.range.location + m.range.length, next)
                out.append(c)
                cursor = next
                i += 1
                continue
            }
            let inner = String(tok.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            var it: DesignItem
            if tok.hasPrefix("<") {
                it = make(.tabs, size)
                it.choices = split(inner)
            } else if tok.hasPrefix("{") {
                it = make(.list, size)
                it.choices = split(inner)
            } else if inner.isEmpty || inner.allSatisfy({ $0 == "_" }) || inner.hasPrefix("_") && inner.hasSuffix("_") {
                it = make(.field, size)
                it.title = inner.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
            } else if inner.range(of: #"^-*[oO●]-*$"#, options: .regularExpression) != nil {
                it = make(.slider, size)
                let k = inner.firstIndex { "oO●".contains($0) }!
                it.value = Double(inner.distance(from: inner.startIndex, to: k)) / Double(max(1, inner.count - 1))
            } else if inner.contains("|") || inner.hasSuffix(" v") || inner.hasSuffix("▾") {
                it = make(.popup, size)
                it.choices = split(inner).map { c in
                    var c = c
                    for end in [" v", "▾"] where c.hasSuffix(end) { c = String(c.dropLast(end.count)).trimmingCharacters(in: .whitespaces) }
                    return c
                }
            } else {
                it = make(.button, size)
                it.title = inner
            }
            it.label = label
            out.append(it)
            cursor = m.range.location + m.range.length
            i += 1
        }
        flushRadio()
        plain(text(cursor, ns.length))
        return out
    }

    private static func hasLabel(_ tok: String) -> Bool { !tok.hasPrefix("<") }

    /// Lines that are each one radio button, one after another, make one stacked group.
    private static func stackRadios(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for l in lines {
            if case .row(let items) = l.kind, items.count == 1, items[0].kind == .radio, items[0].choices.count == 1,
               let last = out.last, last.indent == l.indent, !l.right,
               case .row(var prev) = last.kind, prev.count == 1, prev[0].kind == .radio, items[0].label.isEmpty {
                prev[0].choices.append(items[0].choices[0])
                prev[0].across = false
                if items[0].pick == 0 { prev[0].pick = prev[0].choices.count - 1 }
                out[out.count - 1].kind = .row(prev)
                continue
            }
            out.append(l)
        }
        return out
    }

    // MARK: layout

    /// Places the lines from the top-left of `area`, labels in one column, rows evenly spaced, inside `parent`.
    /// Returns the items, and the bottom and right edge of what was placed.
    static func layout(_ lines: [Line], in area: CGRect, parent: String?, size: ControlSize) -> (items: [DesignItem], bottom: CGFloat, right: CGFloat) {
        let font = size.font
        let step: CGFloat = 20
        let gap: CGFloat = size == .s ? 8 : size == .m ? 10 : 12
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
        let labelW = lines.flatMap { l -> [DesignItem] in if case .row(let its) = l.kind { return its } else { return [] } }
            .filter { $0.kind != .list && !$0.label.isEmpty }.map { width($0.label) }.max() ?? 0
        var out: [DesignItem] = []
        var y = area.minY, maxRight = area.minX
        var x0 = area.minX, right = area.maxX
        var boxes: [(index: Int, x0: CGFloat, right: CGFloat, parent: String?)] = []
        var parentNow = parent
        for l in lines {
            let indent = CGFloat(l.indent) * step
            switch l.kind {
            case .space:
                y += gap
            case .boxStart(let title):
                y += 20
                var b = DesignItem.new(.box, at: CGRect(x: x0 + indent, y: y, width: right - x0 - indent, height: 40), size: size, windowType: .panel)
                b.title = title
                b.parent = parentNow
                out.append(b)
                boxes.append((out.count - 1, x0, right, parentNow))
                parentNow = b.id
                x0 = x0 + indent + 12
                right -= 12
                y += 12
            case .boxEnd:
                guard let top = boxes.popLast() else { continue }
                out[top.index].frame.size.height = max(30, y - out[top.index].frame.minY + 2)
                x0 = top.x0
                right = top.right
                parentNow = top.parent
                y = out[top.index].frame.maxY + gap
            case .row(var items):
                // Sizes first, then left to right (or pushed right), each centered in the row.
                for k in items.indices { items[k].frame.size = natural(items[k], width: width) }
                let h = items.map(\.frame.height).max() ?? size.height
                let labelled = items.first.map { !$0.label.isEmpty && $0.kind != .list } ?? false
                var x = x0 + indent + (labelled ? labelW + 8 : 0)
                if l.right {
                    let total = items.reduce(0) { $0 + $1.frame.width + ($1.label.isEmpty || $1.kind == .list ? 0 : width($1.label) + 8) } + CGFloat(max(0, items.count - 1)) * 8
                    x = right - total
                }
                var listTop: CGFloat = 0
                for k in items.indices {
                    if k > 0, !items[k].label.isEmpty, items[k].kind != .list { x += width(items[k].label) + 8 }
                    if items[k].kind == .list, !items[k].label.isEmpty { listTop = max(listTop, ceil(font.boundingRectForFont.height) + 4) }
                    items[k].frame.origin = CGPoint(x: x, y: y + listTop + (h - items[k].frame.height) / 2)
                    items[k].parent = parentNow
                    x += items[k].frame.width + 8
                }
                for it in items { maxRight = max(maxRight, it.frame.maxX); out.append(it) }
                y += listTop + h + gap
            }
        }
        while let top = boxes.popLast() {
            out[top.index].frame.size.height = max(30, y - out[top.index].frame.minY + 2)
            y = out[top.index].frame.maxY + gap
        }
        for b in out where b.kind == .box { maxRight = max(maxRight, b.frame.maxX) }
        return (out, y - gap, maxRight)
    }

    /// The size a control takes from its words.
    private static func natural(_ it: DesignItem, width: (String) -> CGFloat) -> CGSize {
        let h = it.size.height
        switch it.kind {
        case .button: return CGSize(width: max(70, width(it.title) + 32), height: h)
        case .popup: return CGSize(width: max(120, (it.choices.map(width).max() ?? 0) + 40), height: h)
        case .checkbox: return CGSize(width: DesignDrawing.checkSquare(it).width + 7 + width(it.title) + 6, height: h)
        case .field: return CGSize(width: max(160, width(it.title) + 24), height: h)
        case .slider: return CGSize(width: 150, height: h)
        case .label: return CGSize(width: width(it.title) + 4, height: h)
        case .tabs: return CGSize(width: max(260, it.choices.map(width).reduce(0) { $0 + $1 + 24 } + 40), height: 150)
        case .list: return CGSize(width: max(160, (it.choices.map(width).max() ?? 0) + 24), height: CGFloat(max(3, it.choices.count)) * it.size.rowGap + 2)
        case .radio:
            var r = it
            DesignDrawing.fitRadio(&r)
            return r.frame.size
        default: return DesignItem.defaultSize(it.kind, size: it.size, windowType: .panel)
        }
    }
}
