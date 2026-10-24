import AppKit
import AVFoundation
import ScreenCaptureKit

/// The magnifier's Text button: the text the box sits on, read off the screen, even the parts outside the box,
/// one area at a time. The area most of the box shows comes first; others the box only touches follow.
enum TextGrab {
    /// `source`: the part of the screen the box shows, in the display's points from its top-left corner.
    @MainActor
    static func areas(around source: CGRect, on screen: NSScreen) async -> [String] {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return [] }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return [] }
        return await Task.detached { areas(in: image, scale: scale, around: source) }.value
    }

    static func areas(in image: CGImage, scale: CGFloat, around source: CGRect) -> [String] {
        let whole = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let seen = Output.read(image, crop: whole, scale: scale)
        return pick(groups(seen), around: source).compactMap { reread($0, in: image, scale: scale) }
    }

    /// Lines that belong together: one just above or below another, overlapping it sideways, at a similar size.
    /// Two pieces on the same line stay apart: the screen reader already joins the words of one line.
    static func groups(_ seen: [Seen]) -> [[Seen]] {
        var group = Array(seen.indices)
        func root(_ i: Int) -> Int { group[i] == i ? i : root(group[i]) }
        for i in seen.indices {
            for j in seen.indices where j > i {
                let a = seen[i].rect, b = seen[j].rect
                let h = max(a.height, b.height)
                let gap = max(a.minY - b.maxY, b.minY - a.maxY)
                let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let similar = a.height < b.height * 2.2 && b.height < a.height * 2.2
                // A heading may sit a little further above its text.
                let upper = a.minY < b.minY ? a : b, lower = a.minY < b.minY ? b : a
                let reach = upper.height > lower.height * 1.15 ? 2.2 : 1.5
                if similar, gap < h * reach, overlap > min(a.width, b.width) * 0.3 { group[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: seen.indices, by: root).values.map { $0.map { seen[$0] } }
    }

    /// The areas the box touches: the one it shows most of first, then the others, nearest first.
    static func pick(_ groups: [[Seen]], around source: CGRect) -> [[Seen]] {
        func shown(_ g: [Seen]) -> CGFloat {
            g.reduce(0) { t, l in let r = l.rect.intersection(source); return t + (r.isNull ? 0 : r.width * r.height) }
        }
        let touched = groups.filter { shown($0) > 0 }
        guard let main = touched.max(by: { shown($0) < shown($1) }) else { return [] }
        let c = CGPoint(x: source.midX, y: source.midY)
        func distance(_ g: [Seen]) -> CGFloat {
            g.map { hypot($0.rect.midX - c.x, $0.rect.midY - c.y) }.min() ?? .infinity
        }
        let rest = touched.filter { $0.first?.rect != main.first?.rect }.sorted { distance($0) < distance($1) }
        return [main] + rest
    }

    /// Reads an area again, enlarged, so small text comes out right.
    static func reread(_ lines: [Seen], in image: CGImage, scale: CGFloat) -> String? {
        let box = lines.map(\.rect).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -6, dy: -6)
        let px = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let lineHeight = lines.map(\.rect.height).sorted()[lines.count / 2] * scale
        let k = min(4, max(1, 48 / max(1, lineHeight)))
        guard let piece = image.cropping(to: px) else { return text(of: lines) }
        let w = Int(CGFloat(piece.width) * k), h = Int(CGFloat(piece.height) * k)
        guard k > 1.2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return text(of: Output.read(piece, crop: CGRect(x: 0, y: 0, width: px.width, height: px.height), scale: 1))
                ?? text(of: lines)
        }
        ctx.interpolationQuality = .high
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let big = ctx.makeImage() else { return text(of: lines) }
        let again = Output.read(big, crop: CGRect(x: 0, y: 0, width: w, height: h), scale: 1)
        // Enlarging usually reads small text better, but not always: keep whichever reading is surer of itself.
        func sure(_ l: [Seen]) -> Float { l.isEmpty ? 0 : l.reduce(0) { $0 + $1.confidence } / Float(l.count) }
        return sure(again) > sure(lines) ? text(of: again) : text(of: lines)
    }

    /// Lines in reading order, joined into paragraphs. A wider gap than usual starts a new paragraph.
    static func text(of lines: [Seen]) -> String? {
        guard !lines.isEmpty else { return nil }
        let sorted = lines.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) / 2 ? a.rect.midY < b.rect.midY : a.rect.minX < b.rect.minX
        }
        let usual = sorted.map(\.rect.height).sorted()[sorted.count / 2]
        let widest = sorted.map(\.rect.width).max() ?? 0
        var out = ""
        var last: CGRect?
        for l in sorted {
            if let p = last {
                if abs(l.rect.midY - p.midY) < usual / 2 { out += " " }
                else if l.rect.minY - p.maxY > usual * 0.65 || p.width < widest * 0.6 { out += "\n" }   // a gap, or a list
                else if out.hasSuffix("-") { out.removeLast() }
                else { out += " " }
            }
            out += l.text
            last = l.rect
        }
        return out
    }
}

/// The text, on the right quarter of the screen: bigger or smaller with + and −, read aloud with Speak, and
/// selectable to copy. Resize it by its edges; Esc closes it.
final class TextPanel: NSPanel, AVSpeechSynthesizerDelegate {
    private static var shared: TextPanel?
    private let textView = NSTextView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var speakTile: Tile!
    private let speech = AVSpeechSynthesizer()
    private var spokenRange: NSRange?
    private var areas: [String] = []

    private var fontSize: CGFloat {
        get { UserDefaults.standard.object(forKey: "textPanel.size") as? CGFloat ?? 22 }
        set { UserDefaults.standard.set(newValue, forKey: "textPanel.size") }
    }

    /// `areas`: the main area first, then the others the box touched, shown dimmer.
    static func show(_ areas: [String], on screen: NSScreen) {
        let p = shared ?? TextPanel(screen: screen)
        shared = p
        p.areas = areas
        p.set(areas.joined(separator: "\n"))
        p.orderFrontRegardless()
        p.makeKey()
    }

    private init(screen: NSScreen) {
        let v = screen.visibleFrame
        let frame = CGRect(x: v.maxX - v.width / 4, y: v.minY, width: v.width / 4, height: v.height)
        super.init(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "Text from the screen"
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = CGSize(width: 240, height: 200)
        speech.delegate = self

        // The bar: + and − change the size of the words, Speak reads them.
        let plus = Tile(symbol: "plus", label: "Bigger", large: false)
        plus.onClick = { [weak self] in self?.resize(by: 1) }
        let minus = Tile(symbol: "minus", label: "Smaller", large: false)
        minus.onClick = { [weak self] in self?.resize(by: -1) }
        speakTile = Tile(symbol: "speaker.wave.2.fill", label: "Speak", large: false)
        speakTile.onClick = { [weak self] in self?.toggleSpeaking() }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        let row = NSStackView(views: [plus, minus, sizeLabel, NSView(), speakTile])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(hex: "#262629")!.cgColor
        row.appearance = NSAppearance(named: .darkAqua)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = CGSize(width: 14, height: 14)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let all = NSStackView(views: [row, scroll])
        all.orientation = .vertical
        all.spacing = 0
        row.leadingAnchor.constraint(equalTo: all.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: all.trailingAnchor).isActive = true
        contentView = all
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        speech.stopSpeaking(at: .immediate)
        super.close()
    }

    private func set(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        textView.string = text
        applyFont()
        textView.scrollToBeginningOfDocument(nil)
    }

    private func resize(by step: Int) {
        let sizes: [CGFloat] = [14, 16, 18, 22, 26, 32, 40, 48, 60]
        let i = sizes.firstIndex { $0 >= fontSize } ?? sizes.count - 1
        fontSize = sizes[max(0, min(sizes.count - 1, i + step))]
        applyFont()
    }

    private func applyFont() {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = fontSize * 0.25
        p.paragraphSpacing = fontSize * 0.6
        textView.textStorage?.setAttributes([.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.textColor,
                                             .paragraphStyle: p],
                                            range: NSRange(location: 0, length: (textView.string as NSString).length))
        // The other areas, after the main one: dimmer, with more room before each.
        var at = 0
        for (i, a) in areas.enumerated() {
            let len = (a as NSString).length
            if i > 0, let ts = textView.textStorage, at + len <= ts.length {
                let q = p.mutableCopy() as! NSMutableParagraphStyle
                q.paragraphSpacingBefore = fontSize * 1.2
                let first = (a as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: at, length: len))
                ts.addAttribute(.paragraphStyle, value: q, range: NSRange(location: at, length: min(len, first.length)))
            }
            at += len + 1
        }
        sizeLabel.stringValue = "\(Int(fontSize)) pt"
        if let r = spokenRange { mark(r) }
    }

    // MARK: speaking

    private func toggleSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        // From the selection when there is one, else from the top.
        let sel = textView.selectedRange()
        let all = textView.string as NSString
        let start = sel.length > 0 ? sel.location : 0
        let range = sel.length > 0 ? sel : NSRange(location: 0, length: all.length)
        guard range.length > 0 else { return }
        offset = start
        let u = AVSpeechUtterance(string: all.substring(with: range))
        u.voice = Magnifier.bestVoice()
        speakTile.fillColor = NSColor(hex: "#2A6EE8")
        speakTile.needsDisplay = true
        speech.speak(u)
    }

    private var offset = 0

    private func mark(_ r: NSRange) {
        guard let lm = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor(hex: "#FFE680")!.withAlphaComponent(0.6), forCharacterRange: r)
        textView.scrollRangeToVisible(r)
    }

    private func doneSpeaking() {
        spokenRange = nil
        if let lm = textView.layoutManager {
            lm.removeTemporaryAttribute(.backgroundColor,
                                        forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }
        speakTile.fillColor = nil
        speakTile.needsDisplay = true
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            let r = NSRange(location: range.location + self.offset, length: range.length)
            self.spokenRange = r
            self.mark(r)
        }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.doneSpeaking() }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.doneSpeaking() }
    }
}
