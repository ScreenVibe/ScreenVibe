import AppKit
import AVFoundation
import ScreenCaptureKit

/// The magnifier's Text button: the whole block of text the box sits on, read off the screen, even the parts
/// outside the box.
enum TextGrab {
    /// `source`: the part of the screen the box shows, in the display's points from its top-left corner.
    @MainActor
    static func block(around source: CGRect, on screen: NSScreen) async -> String? {
        guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        else { return nil }
        let whole = CGRect(origin: .zero, size: screen.frame.size)
        let seen = await Task.detached { Output.read(image, crop: whole, scale: scale) }.value
        return text(of: grow(seen, from: source))
    }

    /// Starts from the lines in the box, then takes every line that sits just above or below one already taken
    /// and overlaps it sideways: a paragraph, or a column of them, but not the text beside it.
    static func grow(_ seen: [Seen], from source: CGRect) -> [Seen] {
        var taken = Set(seen.indices.filter { seen[$0].rect.intersects(source) })
        guard !taken.isEmpty else { return [] }
        var changed = true
        while changed {
            changed = false
            for i in seen.indices where !taken.contains(i) {
                let r = seen[i].rect
                let near = taken.contains { j in
                    let t = seen[j].rect
                    let h = max(r.height, t.height)
                    let gap = max(r.minY - t.maxY, t.minY - r.maxY)
                    let overlap = min(r.maxX, t.maxX) - max(r.minX, t.minX)
                    let similar = r.height < t.height * 2.2 && t.height < r.height * 2.2
                    let sameLine = abs(r.midY - t.midY) < h / 2 && max(r.minX - t.maxX, t.minX - r.maxX) < h * 1.5
                    return similar && (sameLine || gap < h * 1.6 && overlap > min(r.width, t.width) * 0.2)
                }
                if near { taken.insert(i); changed = true }
            }
        }
        return taken.map { seen[$0] }
    }

    /// Lines in reading order, joined into paragraphs. A wider gap than usual starts a new paragraph.
    static func text(of lines: [Seen]) -> String? {
        guard !lines.isEmpty else { return nil }
        let sorted = lines.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) / 2 ? a.rect.midY < b.rect.midY : a.rect.minX < b.rect.minX
        }
        let usual = sorted.map(\.rect.height).sorted()[sorted.count / 2]
        var out = ""
        var last: CGRect?
        for l in sorted {
            if let p = last {
                if abs(l.rect.midY - p.midY) < usual / 2 { out += " " }
                else if l.rect.minY - p.maxY > usual * 0.9 { out += "\n" }
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

    private var fontSize: CGFloat {
        get { UserDefaults.standard.object(forKey: "textPanel.size") as? CGFloat ?? 22 }
        set { UserDefaults.standard.set(newValue, forKey: "textPanel.size") }
    }

    static func show(_ text: String, on screen: NSScreen) {
        let p = shared ?? TextPanel(screen: screen)
        shared = p
        p.set(text)
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
