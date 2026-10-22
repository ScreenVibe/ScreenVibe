import AppKit

/// A clickable square on a palette: symbol, and in Large size a name under it.
final class Tile: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    var fillColor: NSColor?
    private let symbol: String
    private let label: String
    private let tint: NSColor
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
            size = large ? CGSize(width: 62, height: 52) : CGSize(width: 34, height: 34)
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
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
        let conf = NSImage.SymbolConfiguration(pointSize: large && !wide ? 17 : 15, weight: .medium)
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

/// The dotted corner a palette is dragged by.
final class Grip: NSView {
    var onMoved: (() -> Void)?

    init(vertical: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: vertical ? 34 : 16).isActive = true
        heightAnchor.constraint(equalToConstant: vertical ? 16 : 34).isActive = true
        toolTip = "Drag to move"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onMoved?()
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
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func rebuild() {
        let keepTopLeft = frame.size == .zero ? nil : CGPoint(x: frame.minX, y: frame.maxY)
        effect.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let grip = Grip(vertical: vertical)
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
        m.addItem(item("Large, with names", on: large) { $0.large = true })
        m.addItem(item("Small, symbols only", on: !large) { $0.large = false })
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
