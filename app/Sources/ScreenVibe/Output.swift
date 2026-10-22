import AppKit
import Vision

/// A finished markup on disk: the two pictures and the words Claude reads.
struct MarkupOutput {
    let folder: URL
    let marked: NSImage
    let prompt: String
}

enum Output {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".screenvibe") }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    /// The marked picture alone, for the Send window.
    static func preview(frozen: Frozen, crop: CGRect, marks: [Mark]) -> NSImage? {
        let s = frozen.scale
        let px = CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s, height: crop.height * s).integral
        guard let clean = frozen.image.cropping(to: px), let marked = render(clean: clean, crop: crop, scale: s, marks: marks)
        else { return nil }
        return NSImage(cgImage: marked, size: crop.size)
    }

    /// `briefed`: this chat has already been pointed at the guide.
    /// The words read under each mark, for the Send window's warnings.
    static func wordsUnder(frozen: Frozen, crop: CGRect, marks: [Mark]) -> [String] {
        let s = frozen.scale
        let px = CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s, height: crop.height * s).integral
        guard let clean = frozen.image.cropping(to: px) else { return [] }
        return recognize(clean, crop: crop, scale: s, marks: marks)
    }

    static func make(frozen: Frozen, crop: CGRect, marks: [Mark], note: String = "", briefed: Bool = false) -> MarkupOutput? {
        let s = frozen.scale
        let px = CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s, height: crop.height * s).integral
        guard let clean = frozen.image.cropping(to: px), let marked = render(clean: clean, crop: crop, scale: s, marks: marks)
        else { return nil }

        let folder = root.appendingPathComponent("markups").appendingPathComponent(stamp())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let markedURL = folder.appendingPathComponent("marked.png")
        let cleanURL = folder.appendingPathComponent("clean.png")
        try? png(marked)?.write(to: markedURL)
        try? png(clean)?.write(to: cleanURL)

        let words = recognize(clean, crop: crop, scale: s, marks: marks)
        let prompt = describe(frozen: frozen, crop: crop, marks: marks, words: words, markedURL: markedURL, cleanURL: cleanURL,
                              note: note, briefed: briefed)
        try? prompt.write(to: folder.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        return MarkupOutput(folder: folder, marked: NSImage(cgImage: marked, size: crop.size), prompt: prompt)
    }

    // MARK: pictures

    static func render(clean: CGImage, crop: CGRect, scale: CGFloat, marks: [Mark]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: clean.width, height: clean.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(clean, in: CGRect(x: 0, y: 0, width: clean.width, height: clean.height))
        ctx.translateBy(x: 0, y: CGFloat(clean.height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        MarkDrawing.drawAll(marks, within: crop)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: words under each mark

    /// Reads the whole clean picture once, then gives each mark the words whose middle sits inside it.
    static func recognize(_ clean: CGImage, crop: CGRect, scale: CGFloat, marks: [Mark]) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: clean).perform([req])
        let w = CGFloat(clean.width) / scale, h = CGFloat(clean.height) / scale
        let found: [(String, CGPoint)] = (req.results ?? []).compactMap { r in
            guard let s = r.topCandidates(1).first?.string else { return nil }
            let b = r.boundingBox
            return (s, CGPoint(x: crop.minX + b.midX * w, y: crop.minY + (1 - b.midY) * h))
        }
        return marks.map { m in
            guard m.tool != nil, m.tool?.shape != .text else { return "" }
            let a = m.area.insetBy(dx: -2, dy: -2)
            // A big box holds a whole screen of words; the first few are enough to find it.
            let inside = found.filter { a.contains($0.1) }.map { $0.0 }
            let joined = inside.prefix(5).joined(separator: " / ")
            return joined.count > 100 ? String(joined.prefix(100)) + "…" : joined + (inside.count > 5 ? " / …" : "")
        }
    }

    // MARK: the message

    static func name(of m: Mark) -> String { m.tool?.name ?? "Pasted piece" }

    static func describe(frozen: Frozen, crop: CGRect, marks: [Mark], words: [String], markedURL: URL, cleanURL: URL,
                         note: String, briefed: Bool) -> String {
        func n(_ v: CGFloat) -> Int { Int(v.rounded()) }
        func pt(_ p: CGPoint) -> String { "\(n(p.x - crop.minX)),\(n(p.y - crop.minY))" }
        func box(_ r: CGRect) -> String { "\(pt(r.origin)) \(n(r.width))×\(n(r.height))" }
        var lines: [String] = []
        lines.append(briefed
            ? "ScreenVibe markup (how to read it: \(Guide.url.path))."
            : "ScreenVibe markup. Before acting, read the guide once: \(Guide.url.path). Later markups in this chat use the same format.")
        let c = frozen.context
        if !c.app.isEmpty { lines.append("App: \(c.app)\(c.bundleID.isEmpty ? "" : " (\(c.bundleID))").") }
        if !c.window.isEmpty { lines.append("Window: \(c.window)") }
        if let u = c.url { lines.append("URL: \(u)") }
        if let d = c.document { lines.append("Document: \(d)") }
        if let w = window(under: crop, frozen: frozen), w.app != c.app {
            lines.append("Under the picture: \(w.title.isEmpty ? w.app : "\(w.app) — \(w.title)").")
        }
        lines.append("Picture: \(n(crop.width))×\(n(crop.height)) points, saved at \(Int(frozen.scale.rounded()))×.")
        lines.append("Marked: \(markedURL.path)")
        lines.append("Clean: \(cleanURL.path)")
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines.append("Note: \(note)") }
        lines.append("")
        if marks.isEmpty { lines.append("No marks: the picture\(note.isEmpty ? "" : " and the note") is the whole message.") }
        for (i, m) in marks.enumerated() {
            // The tool's name says what it means (the guide has each one); only the user's own words follow it.
            let said = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var line = "\(i + 1). \(name(of: m))\(m.paint.map { ", \($0.name)" } ?? "")" + (said.isEmpty ? "." : ": “\(said)”.")
            switch m.kind {
            case .pasted(_, let source):
                line += " Area \(box(m.rect))."
                if !source.isNull { line += " Copied from \(box(source))\(crop.contains(source) ? "" : ", outside the picture")." }
            case .tool(let t):
                switch t.shape {
                case .arrow: line += " Arrow \(pt(m.start)) → \(pt(m.end))."
                case .line: line += " Line \(pt(m.start)) to \(pt(m.end))."
                case .boxArrow: line += " Area \(box(m.rect)) → \(box(m.target))."
                case .text: line += " At \(pt(m.rect.origin))."
                default: line += " Area \(box(m.area))."
                }
            }
            if i < words.count, !words[i].isEmpty { line += " Words there: “\(words[i])”." }
            let extra = m.extra.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extra.isEmpty { line += " Note: \(extra)\(extra.hasSuffix(".") || extra.hasSuffix("?") || extra.hasSuffix("!") ? "" : ".")" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func window(under crop: CGRect, frozen: Frozen) -> WindowInfo? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frozen.screen.frame.height
        let f = frozen.screen.frame
        let center = CGPoint(x: f.minX + crop.midX, y: primaryHeight - f.maxY + crop.midY)
        return frozen.windows.first { $0.frame.contains(center) }
    }

    // MARK: copy

    static func copyToPasteboard(_ out: MarkupOutput) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let tiff = out.marked.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            item.setData(data, forType: .png)
        }
        item.setString(out.prompt, forType: .string)
        pb.writeObjects([item])
    }
}

/// A Claude Code session that has the ScreenVibe add-on loaded.
struct SessionInfo {
    let sessionId: String
    let label: String
    let cwd: String
    let name: String?
    let status: String?

    var menuTitle: String {
        var t = label
        if let name, !name.isEmpty { t += " — \(name)" }
        if let status, status == "busy" { t += " (working)" }
        return t
    }
}

enum Sessions {
    static var lastId: String? {
        get { UserDefaults.standard.string(forKey: "lastSession") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSession") }
    }

    /// Sessions whose add-on wrote its card in the last 15 seconds.
    static func alive() -> [SessionInfo] {
        let fm = FileManager.default
        let dir = Output.root.appendingPathComponent("sessions")
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let claude = claudeSessions()
        return files.compactMap { url -> (SessionInfo, Date)? in
            guard url.pathExtension == "json",
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(mod) < 15,
                  let data = try? Data(contentsOf: url),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = j["sessionId"] as? String else { return nil }
            let c = claude[sid]
            return (SessionInfo(sessionId: sid, label: j["label"] as? String ?? "Session", cwd: j["cwd"] as? String ?? "",
                                name: c?["name"] as? String, status: c?["status"] as? String), mod)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }

    static func lastAlive() -> SessionInfo? {
        guard let id = lastId else { return nil }
        return alive().first { $0.sessionId == id }
    }

    /// Claude Code's own session cards, for the session's name and whether it is working.
    private static func claudeSessions() -> [String: [String: Any]] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        var out: [String: [String: Any]] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = j["sessionId"] as? String { out[sid] = j }
        }
        return out
    }

    /// Whether this chat has already been pointed at the guide.
    static func isBriefed(_ s: SessionInfo) -> Bool {
        FileManager.default.fileExists(atPath: briefedURL(s).path)
    }

    private static func briefedURL(_ s: SessionInfo) -> URL {
        Output.root.appendingPathComponent("briefed").appendingPathComponent(s.sessionId)
    }

    static func deliver(_ out: MarkupOutput, to s: SessionInfo) throws {
        let dir = Output.root.appendingPathComponent("inbox").appendingPathComponent(s.sessionId)
            .appendingPathComponent(out.folder.lastPathComponent)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try out.prompt.write(to: dir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("ready"))
        try? FileManager.default.createDirectory(at: briefedURL(s).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: briefedURL(s))
    }
}
