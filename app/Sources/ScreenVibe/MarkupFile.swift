import AppKit

/// Markups kept in ~/Documents/ScreenVibe/Markups, one folder each, so they can be opened again, changed and sent again.
/// (What a session reads stays in ~/.screenvibe, which is cleaned after 30 days; these copies stay until deleted.)
enum MarkupFile {
    static var folder: URL {
        if let t = ProcessInfo.processInfo.environment["SCREENVIBE_DESIGN_DIR"] { return URL(fileURLWithPath: t).appendingPathComponent("Markups") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ScreenVibe/Markups")
    }

    /// One saved markup, as the designer's list shows it.
    struct Entry {
        let url: URL
        let title: String
        let date: Date
        let how: String       // "sent" or "copied"
        var picture: URL { url.appendingPathComponent("marked.png") }
    }

    private struct Saved: Codable {
        var title: String
        var date: Date
        var how: String
        var screen: CGSize
        var scale: CGFloat
        var crop: CGRect
        var app: String
        var bundleID: String
        var window: String
        var document: String?
        var url: String?
        var marks: [SavedMark]
    }

    private struct SavedMark: Codable {
        var kind: String          // tool, pasted, filled
        var tool: ToolDef?
        var image: String?        // pasted: its picture's file
        var source: CGRect?
        var color: String?        // filled
        var rect: CGRect
        var start: CGPoint
        var end: CGPoint
        var points: [CGPoint]
        var text: String
        var extra: String
        var label: String
        var checked: Bool
        var targetSize: CGSize?
        var paint: String?
        var zoom: CGFloat?
        var spot: CGPoint?
        var icon: String?
    }

    /// Saves the markup beside the others; `how` is "sent" or "copied".
    static func save(frozen: Frozen, crop: CGRect, marks: [Mark], marked: NSImage, how: String) {
        guard let clean = Output.cleanPicture(frozen: frozen, crop: crop) else { return }
        let c = frozen.context
        var title = c.app.isEmpty ? "Markup" : c.app
        let place = c.window.isEmpty ? (c.document ?? "") : c.window
        if !place.isEmpty { title += " — " + place }
        let dir = folder.appendingPathComponent(Output.stamp())
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Output.png(clean)?.write(to: dir.appendingPathComponent("clean.png"))
        if let cg = marked.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try? Output.png(cg)?.write(to: dir.appendingPathComponent("marked.png"))
        }
        var saved: [SavedMark] = []
        for (i, m) in marks.enumerated() {
            var s = SavedMark(kind: "tool", rect: m.rect, start: m.start, end: m.end, points: m.points, text: m.text,
                              extra: m.extra, label: m.label, checked: m.checked, targetSize: m.targetSize, paint: m.paint?.name,
                              zoom: m.zoom, spot: m.spot, icon: m.icon)
            switch m.kind {
            case .tool(let t): s.tool = t
            case .pasted(let img, let source):
                s.kind = "pasted"
                s.source = source.isNull ? nil : source
                s.image = "piece-\(i + 1).png"
                if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    try? Output.png(cg)?.write(to: dir.appendingPathComponent(s.image!))
                }
            case .filled(let color):
                s.kind = "filled"
                s.color = color.hexString
            }
            saved.append(s)
        }
        let file = Saved(title: title, date: Date(), how: how, screen: frozen.screen.frame.size, scale: frozen.scale, crop: crop,
                         app: c.app, bundleID: c.bundleID, window: c.window, document: c.document, url: c.url, marks: saved)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(file).write(to: dir.appendingPathComponent("markup.json"))
    }

    static func list() -> [Entry] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Entry? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("markup.json")),
                  let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            return Entry(url: dir, title: s.title, date: s.date, how: s.how)
        }
        .sorted { $0.date > $1.date }
    }

    /// The frozen screen and marks of a saved markup. The picture goes back where it was; the rest of the screen is dark.
    static func load(_ dir: URL, on screen: NSScreen) -> (frozen: Frozen, crop: CGRect, marks: [Mark])? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("markup.json")),
              let s = try? JSONDecoder().decode(Saved.self, from: data),
              let clean = NSImage(contentsOf: dir.appendingPathComponent("clean.png"))?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = screen.frame.size, scale = s.scale
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // The crop is in top-down points; the context is bottom-up pixels.
        let crop = s.crop
        ctx.draw(clean, in: CGRect(x: crop.minX * scale, y: CGFloat(h) - crop.maxY * scale,
                                   width: crop.width * scale, height: crop.height * scale))
        guard let image = ctx.makeImage() else { return nil }
        var frozen = Frozen(screen: screen, image: image, scale: scale, windows: [])
        frozen.context = FrontContext(app: s.app, bundleID: s.bundleID, window: s.window, document: s.document, url: s.url)
        let tools = ToolStore.shared.tools
        let marks: [Mark] = s.marks.compactMap { sm in
            let kind: Mark.Kind
            switch sm.kind {
            case "pasted":
                guard let name = sm.image, let img = NSImage(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                img.size = sm.rect.size
                kind = .pasted(img, source: sm.source ?? .null)
            case "filled":
                kind = .filled(NSColor(hex: sm.color ?? "#FFFFFF") ?? .white)
            default:
                // The tool as it is now, if it still exists; else as it was saved.
                guard let t = sm.tool else { return nil }
                kind = .tool(tools.first { $0.id == t.id } ?? t)
            }
            var m = Mark(kind: kind)
            m.rect = sm.rect
            m.start = sm.start
            m.end = sm.end
            m.points = sm.points
            m.text = sm.text
            m.extra = sm.extra
            m.label = sm.label
            m.checked = sm.checked
            m.targetSize = sm.targetSize
            m.paint = Swatch.all.first { $0.name == sm.paint }
            m.zoom = sm.zoom ?? 2
            m.spot = sm.spot
            m.icon = sm.icon
            return m
        }
        return (frozen, crop, marks)
    }
}
