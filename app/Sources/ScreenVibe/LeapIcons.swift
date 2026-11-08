import AppKit

/// The LEAP bar icons a button can carry, in the app's Resources/Icons folder: <id>.png (48 px) and <id>_S.png (29 px),
/// drawn at their own pixel size on a Retina screen, never scaled.
enum LeapIcons {
    static let all: [(id: String, name: String)] = [
        ("edit", "Edit"), ("refresh", "Refresh"), ("warning", "Warning"), ("color", "Color"), ("delete", "Delete"),
        ("close", "Close"), ("previous", "Previous"), ("next", "Next"), ("up", "Up"), ("down", "Down"), ("move", "Move"),
        ("settings", "Settings"), ("sync", "Sync"), ("log", "Log"), ("measure", "Measure"), ("add", "Add"), ("remove", "Remove"),
    ]

    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }

    /// The icon's file, which Claude is given.
    static func url(_ id: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Icons/\(id).png")
    }

    private static var cache: [String: NSImage] = [:]

    /// The icon at half its pixel size in points, so each pixel is one Retina pixel.
    static func image(_ id: String, small: Bool = false) -> NSImage? {
        let key = small ? id + "_S" : id
        if let i = cache[key] { return i }
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(key).png"), let i = NSImage(contentsOf: u),
              let rep = i.representations.first else { return nil }
        i.size = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        cache[key] = i
        return i
    }

    /// Draws it unscaled, centered on `p`.
    static func draw(_ id: String, small: Bool = false, centeredAt p: CGPoint) {
        guard let img = image(id, small: small) else { return }
        let r = CGRect(x: (p.x - img.size.width / 2).rounded(), y: (p.y - img.size.height / 2).rounded(),
                       width: img.size.width, height: img.size.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The round badge that opens the picker: + until an icon is picked, then that icon.
    static func drawBadge(at p: CGPoint, icon: String?) {
        let r = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
        let green = NSColor(hex: "#18A050")!
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = 3
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.set()
        (icon == nil ? green : .white).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        (icon == nil ? NSColor.white : green).setStroke()
        ring.stroke()
        if let icon {
            draw(icon, small: true, centeredAt: p)
        } else {
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: p.x - 4.5, y: p.y)); plus.line(to: CGPoint(x: p.x + 4.5, y: p.y))
            plus.move(to: CGPoint(x: p.x, y: p.y - 4.5)); plus.line(to: CGPoint(x: p.x, y: p.y + 4.5))
            plus.lineWidth = 2
            plus.lineCapStyle = .round
            NSColor.white.setStroke()
            plus.stroke()
        }
    }
}

/// The grid of LEAP icons, None first. One click picks and closes it.
final class IconPicker: NSView {
    private let current: String?
    private let onPick: (String?) -> Void
    private var hover: Int?
    private static let cols = 6, cell = CGSize(width: 58, height: 56), pad: CGFloat = 8

    static var size: CGSize {
        let rows = (LeapIcons.all.count + 1 + cols - 1) / cols
        return CGSize(width: CGFloat(cols) * cell.width + 2 * pad, height: CGFloat(rows) * cell.height + 2 * pad)
    }

    init(at origin: CGPoint, current: String?, onPick: @escaping (String?) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(frame: CGRect(origin: origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(hex: "#262629")!.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 11
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func cellRect(_ k: Int) -> CGRect {
        CGRect(x: Self.pad + CGFloat(k % Self.cols) * Self.cell.width, y: Self.pad + CGFloat(k / Self.cols) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    /// Cell 0 is None; cell k is icon k-1.
    private func index(at p: CGPoint) -> Int? {
        (0...LeapIcons.all.count).first { cellRect($0).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(white: 0.8, alpha: 1)]
        for k in 0...LeapIcons.all.count {
            let r = cellRect(k), id = k == 0 ? nil : LeapIcons.all[k - 1].id
            if k == hover || id == current {
                NSColor.white.withAlphaComponent(k == hover ? 0.22 : 0.14).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            let ir = CGRect(x: r.midX - 12, y: r.minY + 8, width: 24, height: 24)
            if let id {
                LeapIcons.draw(id, centeredAt: CGPoint(x: ir.midX, y: ir.midY))
            } else {
                let ring = NSBezierPath(ovalIn: ir.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.5
                ring.setLineDash([3, 2.5], count: 2, phase: 0)
                NSColor(white: 0.55, alpha: 1).setStroke()
                ring.stroke()
            }
            let name = (id.map(LeapIcons.name) ?? "None") as NSString
            let w = name.size(withAttributes: attrs).width
            name.draw(at: CGPoint(x: r.midX - w / 2, y: r.minY + 36), withAttributes: attrs)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let k = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick(k == 0 ? nil : LeapIcons.all[k - 1].id)
        removeFromSuperview()
    }

    /// For checking the look: a picture of the grid alone.
    func dump(to path: String) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
