import AppKit

/// A clickable square on a palette: symbol, and when Expanded a name under it.
final class Tile: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    /// Shows a small corner triangle: holding the tile, or clicking the triangle, calls `onHold`.
    var hasMore = false
    var onHold: (() -> Void)?
    private var holdTimer: Timer?
    private var held = false
    var fillColor: NSColor?
    private let symbol: String
    private let label: String
    var tint: NSColor { didSet { needsDisplay = true } }
    private let large: Bool
    private let wide: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    /// `wide` tiles show the label beside the symbol (the action buttons in Large size).
    init(symbol: String, label: String, tint: NSColor = .white, large: Bool, wide: Bool = false) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.large = large
        self.wide = wide
        super.init(frame: .zero)
        toolTip = label
        translatesAutoresizingMaskIntoConstraints = false
        let size: CGSize
        if wide && large {
            let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            size = CGSize(width: ceil(w) + (symbol.isEmpty ? 28 : 46), height: 36)
        } else {
            size = large ? CGSize(width: 62, height: 52) : CGSize(width: 28, height: 28)
        }
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        held = false
        guard hasMore else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.held = true
            self?.onHold?()
        }
    }
    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        guard !held else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if hasMore, p.x > bounds.maxX - 12, p.y < 12 { onHold?() } else { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: large ? 8 : 6, yRadius: large ? 8 : 6)
        if let f = fillColor {
            (hovering ? f.blended(withFraction: 0.15, of: .white)! : f).setFill()
            bg.fill()
        } else if isOn {
            NSColor.white.withAlphaComponent(0.22).setFill()
            bg.fill()
        } else if hovering {
            NSColor.white.withAlphaComponent(0.10).setFill()
            bg.fill()
        }
        if hasMore {
            let t = NSBezierPath()
            t.move(to: CGPoint(x: bounds.maxX - 4, y: 4))
            t.line(to: CGPoint(x: bounds.maxX - 4, y: 10))
            t.line(to: CGPoint(x: bounds.maxX - 10, y: 4))
            t.close()
            NSColor.white.withAlphaComponent(0.6).setFill()
            t.fill()
        }
        let conf = NSImage.SymbolConfiguration(pointSize: large ? (wide ? 15 : 17) : 13, weight: .medium)
        let img = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(conf)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: wide ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(wide ? 1 : 0.85)]
        let ls = (label as NSString).size(withAttributes: labelAttrs)

        if wide && large {
            var x = (bounds.width - ls.width - (img == nil ? 0 : 20)) / 2
            if let img {
                tinted(img).draw(in: CGRect(x: x, y: (bounds.height - img.size.height) / 2, width: img.size.width,
                                            height: img.size.height))
                x += 20
            }
            (label as NSString).draw(at: CGPoint(x: x, y: (bounds.height - ls.height) / 2), withAttributes: labelAttrs)
        } else if let img {
            let y = large ? bounds.height - img.size.height - 9 : (bounds.height - img.size.height) / 2
            tinted(img).draw(in: CGRect(x: (bounds.width - img.size.width) / 2, y: y, width: img.size.width,
                                        height: img.size.height))
            if large {
                (label as NSString).draw(at: CGPoint(x: (bounds.width - ls.width) / 2, y: 5), withAttributes: labelAttrs)
            }
        }
    }

    private func tinted(_ img: NSImage) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        CGRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}

/// The color dots under the tools, two to a row (two rows when the palette is horizontal), after a thin line.
final class Swatches: NSView {
    var current: (() -> Swatch?)?
    var onPick: ((Swatch) -> Void)?
    private let large: Bool
    private let vertical: Bool
    private var dot: CGFloat { large ? 22 : 11 }
    private var gap: CGFloat { large ? 8 : 4 }
    private var lead: CGFloat { large ? 12 : 7 }     // room for the line before the dots

    init(large: Bool, vertical: Bool) {
        self.large = large
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let tile: CGFloat = large ? 62 : 28
        let long = lead + 4 * dot + 3 * gap + (large ? 4 : 2)
        widthAnchor.constraint(equalToConstant: vertical ? tile : long).isActive = true
        heightAnchor.constraint(equalToConstant: vertical ? long : (large ? 52 : 28)).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(_ k: Int) -> CGRect {
        let along = k / 2, across = k % 2
        let a = lead + CGFloat(along) * (dot + gap)
        let mid = (vertical ? bounds.width : bounds.height) / 2
        let b = across == 0 ? mid - gap / 2 - dot : mid + gap / 2
        return vertical ? CGRect(x: b, y: a, width: dot, height: dot) : CGRect(x: a, y: b, width: dot, height: dot)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let k = Swatch.all.indices.first(where: { rect($0).insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) }) {
            onPick?(Swatch.all[k])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        let line = lead / 2 - 0.5
        (vertical ? CGRect(x: 6, y: line, width: bounds.width - 12, height: 1)
                  : CGRect(x: line, y: 6, width: 1, height: bounds.height - 12)).fill()
        let on = current?()
        for (k, w) in Swatch.all.enumerated() {
            let r = rect(k)
            w.color.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let edge = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
            if w == on {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: large ? -3 : -2, dy: large ? -3 : -2))
                ring.lineWidth = large ? 2 : 1.5
                ring.stroke()
            }
        }
    }
}

/// The dotted corner a palette is dragged by.
final class Grip: NSView {
    var onMoved: (() -> Void)?

    init(vertical: Bool, large: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let across: CGFloat = large ? 34 : 28, along: CGFloat = large ? 16 : 10
        widthAnchor.constraint(equalToConstant: vertical ? across : along).isActive = true
        heightAnchor.constraint(equalToConstant: vertical ? along : across).isActive = true
        toolTip = "Drag to move"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    private var grabbed: CGPoint?   // where in the window the drag started

    // Moved by hand rather than performDrag, which returns before the drag ends, so the place saved was the old one.
    override func mouseDown(with event: NSEvent) { grabbed = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let g = grabbed else { return }
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(CGPoint(x: p.x - g.x, y: p.y - g.y))
    }
    override func mouseUp(with event: NSEvent) {
        if grabbed != nil { onMoved?() }
        grabbed = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.45).setFill()
        let cols = bounds.width > bounds.height ? 3 : 2, rows = bounds.width > bounds.height ? 2 : 3
        let gx = (bounds.width - CGFloat(cols - 1) * 5) / 2, gy = (bounds.height - CGFloat(rows - 1) * 5) / 2
        for c in 0..<cols {
            for r in 0..<rows {
                NSBezierPath(ovalIn: CGRect(x: gx + CGFloat(c) * 5 - 1.25, y: gy + CGFloat(r) * 5 - 1.25,
                                            width: 2.5, height: 2.5)).fill()
            }
        }
    }
}

/// A translucent floating strip of tiles with a drag grip and a settings popup.
/// `key` keeps each palette's Orientation, Size and position apart in the defaults.
final class Palette: NSPanel {
    let key: String
    var makeTiles: ((_ large: Bool) -> [NSView])?
    var onSettingsChanged: (() -> Void)?

    var vertical: Bool {
        get { UserDefaults.standard.object(forKey: "\(key).vertical") as? Bool ?? (key == "tools") }
        set { UserDefaults.standard.set(newValue, forKey: "\(key).vertical") }
    }
    var large: Bool {
        get { UserDefaults.standard.object(forKey: "\(key).large") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "\(key).large") }
    }
    /// Top-left corner in screen coordinates, once the person has dragged it.
    var placedTopLeft: CGPoint? {
        get {
            guard let a = UserDefaults.standard.array(forKey: "\(key).placed") as? [Double], a.count == 2 else { return nil }
            return CGPoint(x: a[0], y: a[1])
        }
        set {
            if let p = newValue { UserDefaults.standard.set([p.x, p.y], forKey: "\(key).placed") }
            else { UserDefaults.standard.removeObject(forKey: "\(key).placed") }
        }
    }

    private let effect = NSView()  // a solid frame: the palettes are not see-through

    init(key: String) {
        self.key = key
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor(hex: "#262629")!.cgColor
        effect.layer?.cornerRadius = 12  // 9 when Condensed, set in rebuild
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func rebuild() {
        let keepTopLeft = frame.size == .zero ? nil : CGPoint(x: frame.minX, y: frame.maxY)
        effect.subviews.forEach { $0.removeFromSuperview() }
        effect.layer?.cornerRadius = large ? 12 : 9
        let stack = NSStackView()
        stack.orientation = vertical ? .vertical : .horizontal
        let edge: CGFloat = large ? 6 : 3
        stack.spacing = large ? 3 : 1
        stack.edgeInsets = NSEdgeInsets(top: edge, left: edge, bottom: edge, right: edge)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let grip = Grip(vertical: vertical, large: large)
        grip.onMoved = { [weak self] in
            guard let self else { return }
            self.placedTopLeft = CGPoint(x: self.frame.minX, y: self.frame.maxY)
        }
        stack.addArrangedSubview(grip)
        for v in makeTiles?(large) ?? [] { stack.addArrangedSubview(v) }
        let more = Tile(symbol: "ellipsis.circle", label: "Settings", tint: NSColor.white.withAlphaComponent(0.7), large: false)
        more.onClick = { [weak self, weak more] in
            guard let self, let more else { return }
            self.settingsMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        stack.addArrangedSubview(more)
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
        ])
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        if let tl = keepTopLeft {
            setFrame(CGRect(x: tl.x, y: tl.y - size.height, width: size.width, height: size.height), display: true)
        } else {
            setContentSize(size)
        }
    }

    func moveTopLeft(to p: CGPoint) {
        setFrameTopLeftPoint(p)
    }

    private func settingsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(NSMenuItem.sectionHeader(title: "Orientation"))
        m.addItem(item("Vertical", on: vertical) { $0.vertical = true })
        m.addItem(item("Horizontal", on: !vertical) { $0.vertical = false })
        m.addItem(NSMenuItem.sectionHeader(title: "Size"))
        m.addItem(item("Expanded, with names", on: large) { $0.large = true })
        m.addItem(item("Condensed, symbols only", on: !large) { $0.large = false })
        if placedTopLeft != nil {
            m.addItem(.separator())
            m.addItem(item("Put it back beside the box", on: false) { $0.placedTopLeft = nil })
        }
        return m
    }

    private func item(_ title: String, on: Bool, _ apply: @escaping (Palette) -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            apply(self)
            self.rebuild()
            self.onSettingsChanged?()
        }
        i.state = on ? .on : .off
        return i
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
