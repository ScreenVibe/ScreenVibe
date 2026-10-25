import AppKit
import AVFoundation
import ScreenCaptureKit
import Vision

/// ⌘⇧7, then drag an area: a box shows that area magnified and live, beside it, and the area stays usable.
/// ⌘⇧7 and a click instead: a box that shows what's under it, opened where the mouse is, at the size and zoom
/// used last. Drag the box to move it, drag its corner to resize it.
/// The bar centered under it has + and − (zoom steps), the zoom, Speak (reads the words in the box aloud) and
/// Text (the whole text on the side). Esc closes it.
final class Magnifier: NSObject {
    static let steps: [CGFloat] = [1.5, 2, 3, 4, 6, 8]

    var onClose: (() -> Void)?
    var onDenied: (() -> Void)?
    private(set) var framesShown = 0
    private var spaceWatch: NSObjectProtocol?
    private let lens: LensPanel
    private let bar: Palette
    private let zoomLabel = NSTextField(labelWithString: "")
    private var speakTile: Tile!
    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID?
    private let output = FrameOutput()
    private let speech = AVSpeechSynthesizer()
    private var spoken: [(range: NSRange, box: CGRect)] = []   // each line's place in the spoken text and in the box

    /// The drawn area, in the display's points from its top-left corner, and its screen. Nil: the box shows what's under it.
    private var area: CGRect?
    private let areaScreen: NSScreen?
    private var outline: AreaFrame?
    /// The zoom asked for with + and − or the corner; the box shows less when the area is too big for it at that zoom.
    private var wanted: CGFloat = 1

    /// Saved only for the box that shows what's under it; a drawn area starts at the zoom that fits it.
    private var zoom: CGFloat {
        didSet { if area == nil { UserDefaults.standard.set(zoom, forKey: "magnifier.zoom") } }
    }

    /// `area`: a drawn area in screen coordinates (AppKit's), or nil for the box that shows what's under it.
    init(area drawn: CGRect? = nil) {
        if let drawn, let screen = NSScreen.screens.first(where: { $0.frame.intersects(drawn) }) {
            let sf = screen.frame, v = screen.visibleFrame
            area = CGRect(x: drawn.minX - sf.minX, y: sf.maxY - drawn.maxY, width: drawn.width, height: drawn.height)
            areaScreen = screen
            // As big as fits beside the area, up to 3×, never smaller than the area.
            let room = CGSize(width: max(v.maxX - drawn.maxX, drawn.minX - v.minX, v.width * 0.5) - 24, height: v.height * 0.8)
            zoom = max(1, min(3, room.width / drawn.width, room.height / drawn.height))
            let size = CGSize(width: drawn.width * zoom, height: drawn.height * zoom)
            var x = v.maxX - drawn.maxX - 16 >= size.width ? drawn.maxX + 16 : drawn.minX - 16 - size.width
            x = min(max(x, v.minX), v.maxX - size.width)
            let y = min(max(drawn.midY - size.height / 2, v.minY + 50), v.maxY - size.height)
            lens = LensPanel(frame: CGRect(x: x, y: y, width: size.width, height: size.height))
            lens.view.aspect = drawn.width / drawn.height
        } else {
            area = nil
            areaScreen = nil
            zoom = UserDefaults.standard.object(forKey: "magnifier.zoom") as? CGFloat ?? 2
            let saved = UserDefaults.standard.array(forKey: "magnifier.size") as? [Double]
            let size = saved.map { CGSize(width: $0[0], height: $0[1]) } ?? CGSize(width: 480, height: 220)
            let m = NSEvent.mouseLocation
            lens = LensPanel(frame: CGRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height))
        }
        bar = Palette(key: "magnifier")
        super.init()
        wanted = zoom
        if let drawn {
            outline = AreaFrame(around: drawn)
            outline?.onChange = { [weak self] r in self?.moveArea(to: r) }
        }
        speech.delegate = self
        lens.view.onMoved = { [weak self] in self?.followLens() }
        lens.view.onMoveEnded = { [weak self] in self?.saveAndRestartIfMoved() }
        lens.view.onZoomWheel = { [weak self] up in self?.step(up ? 1 : -1) }
        // A stream can stop when the screen changes under it (a full-screen app, another Space): start it again.
        output.onStopped = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self?.lens.isVisible == true { Task { await self?.startStream() } } }
        }
        spaceWatch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                       object: nil, queue: .main) { [weak self] _ in
            if self?.lens.isVisible == true { Task { await self?.startStream() } }
        }
        lens.onEscape = { [weak self] in self?.close() }
        output.onFrame = { [weak self] surface in self?.lens.view.show(surface); self?.framesShown += 1 }
        buildBar()
        if area == nil { clampToScreen() }
    }

    func show() {
        outline?.start()
        lens.orderFrontRegardless()
        lens.makeKey()
        lens.addChildWindow(bar, ordered: .above)
        followLens()
        bar.orderFrontRegardless()
        Task { await startStream() }
    }

    func close() {
        if let spaceWatch { NSWorkspace.shared.notificationCenter.removeObserver(spaceWatch) }
        output.writeLog()
        speech.stopSpeaking(at: .immediate)
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        lens.removeChildWindow(bar)
        bar.orderOut(nil)
        outline?.stop()
        lens.orderOut(nil)
        onClose?()
    }

    /// For --magnifier-test --area --resize: what the frame's edge does at a few points, and the box after moving and
    /// growing the area. Writes the frame's own window (nothing else on screen) to the scratch file it names.
    func checkAreaFrame() -> String {
        guard let o = outline, let start = Optional(o.area) else { return "no area" }
        var out: [String] = []
        let r = o.area
        for (name, p) in [("corner", CGPoint(x: r.maxX + 3, y: r.maxY + 3)), ("right middle", CGPoint(x: r.maxX + 4, y: r.midY)),
                          ("top edge", CGPoint(x: r.minX + 40, y: r.maxY + 5)), ("inside", CGPoint(x: r.midX, y: r.midY)),
                          ("far out", CGPoint(x: r.maxX + 40, y: r.midY))] {
            out.append("\(name): \(o.part(at: p).map { "x \($0.x) y \($0.y)" } ?? "app gets it")")
        }
        out.append("box before: \(Int(lens.frame.width))×\(Int(lens.frame.height)) at \(zoom)×")
        moveArea(to: CGRect(x: start.minX + 30, y: start.minY - 20, width: start.width * 1.5, height: start.height))
        out.append("box after 1.5× wider: \(Int(lens.frame.width))×\(Int(lens.frame.height)) at \(zoom)×, aspect \(lens.view.aspect ?? 0)")
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(o.windowNumber), [.boundsIgnoreFraming]),
           let png = Output.png(img) {
            let path = NSTemporaryDirectory() + "areaframe.png"
            try? png.write(to: URL(fileURLWithPath: path))
            out.append("wrote \(path)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: the bar

    private func buildBar() {
        let plus = Tile(symbol: "plus", label: "Zoom in", large: false)
        plus.onClick = { [weak self] in self?.step(1) }
        let minus = Tile(symbol: "minus", label: "Zoom out", large: false)
        minus.onClick = { [weak self] in self?.step(-1) }
        speakTile = Tile(symbol: "speaker.wave.2.fill", label: "Speak the words in the box", large: false)
        speakTile.onClick = { [weak self] in self?.toggleSpeaking() }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        showZoom()
        let text = Tile(symbol: "text.alignleft", label: "Show the whole text on the side", large: false)
        text.onClick = { [weak self] in self?.showText() }
        let row = NSStackView(views: [plus, minus, zoomLabel, speakTile, text])
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = bar.contentView!
        content.layer?.cornerRadius = 9
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        bar.setContentSize(row.fittingSize)
    }

    private func showZoom() {
        let z = zoom
        zoomLabel.stringValue = z == z.rounded() ? "\(Int(z))×" : String(format: "%.1f×", z)
    }

    private func step(_ by: Int) {
        let steps = Self.steps
        let i = by > 0 ? steps.firstIndex { $0 > zoom + 0.01 } ?? steps.count - 1
                       : steps.lastIndex { $0 < zoom - 0.01 } ?? 0
        zoom = steps[i]
        wanted = zoom
        showZoom()
        if area != nil { fitBox() } else { updateSource() }
    }

    /// A drawn area keeps showing all of itself: the box grows or shrinks, keeping its top-left corner.
    private func fitBox() {
        guard let area, let v = (lens.screen ?? areaScreen)?.visibleFrame else { return }
        zoom = max(1, min(wanted, v.width / area.width, (v.height - 60) / area.height))
        showZoom()
        let f = lens.frame
        let size = CGSize(width: area.width * zoom, height: area.height * zoom)
        var n = CGRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height)
        n.origin.x = min(max(n.minX, v.minX), v.maxX - n.width)
        n.origin.y = min(max(n.minY, v.minY + 50), v.maxY - n.height)
        lens.setFrame(n, display: true)
        followLens()
    }

    /// The area's frame was moved or resized (`drawn` in screen coordinates): show the new area at the same zoom.
    private func moveArea(to drawn: CGRect) {
        guard let s = areaScreen else { return }
        let sf = s.frame
        area = CGRect(x: drawn.minX - sf.minX, y: sf.maxY - drawn.maxY, width: drawn.width, height: drawn.height)
        lens.view.aspect = drawn.width / drawn.height
        fitBox()
    }

    /// The bar sits centered under the box, or over it when the box is near the bottom of the screen.
    private func followLens() {
        // Resizing the box of a drawn area changes the zoom, since it always shows all of the area.
        if let area, abs(lens.frame.width / area.width - zoom) > 0.01 {
            zoom = lens.frame.width / area.width
            wanted = zoom
            showZoom()
        }
        let f = lens.frame, b = bar.frame.size
        var p = CGPoint(x: f.midX - b.width / 2, y: f.minY - b.height - 8)
        if let s = lens.screen, p.y < s.visibleFrame.minY { p.y = f.maxY + 8 }
        bar.setFrameOrigin(p)
        updateSource()
    }

    private func clampToScreen() {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        var f = lens.frame
        f.origin.x = min(max(f.minX, s.visibleFrame.minX), s.visibleFrame.maxX - f.width)
        f.origin.y = min(max(f.minY, s.visibleFrame.minY + 50), s.visibleFrame.maxY - f.height)
        lens.setFrame(f, display: false)
    }

    private func saveAndRestartIfMoved() {
        guard area == nil else { updateSource(); return }
        UserDefaults.standard.set([Double(lens.frame.width), Double(lens.frame.height)], forKey: "magnifier.size")
        if displayID(of: lens.screen) != streamDisplay { Task { await startStream() } }
        else { updateSource() }
    }

    // MARK: the live picture

    private func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// What the box magnifies, in the display's points from its top-left corner: the box's middle, 1/zoom its size.
    private func source() -> (rect: CGRect, pixels: CGSize)? {
        if let area, let s = areaScreen {
            let k = s.backingScaleFactor
            return (area, CGSize(width: lens.frame.width * k, height: lens.frame.height * k))
        }
        guard let s = lens.screen else { return nil }
        let f = lens.frame, sf = s.frame, z = zoom
        let size = CGSize(width: f.width / z, height: f.height / z)
        var r = CGRect(x: f.midX - sf.minX - size.width / 2, y: sf.maxY - f.midY - size.height / 2,
                       width: size.width, height: size.height)
        r.origin.x = min(max(0, r.minX), sf.width - r.width)
        r.origin.y = min(max(0, r.minY), sf.height - r.height)
        let k = s.backingScaleFactor
        return (r, CGSize(width: f.width * k, height: f.height * k))
    }

    private func configuration() -> SCStreamConfiguration? {
        guard let (rect, px) = source() else { return nil }
        let c = SCStreamConfiguration()
        c.sourceRect = rect
        c.width = Int(px.width)
        c.height = Int(px.height)
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.queueDepth = 3
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        return c
    }

    @MainActor private func startStream() async {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let id = displayID(of: areaScreen ?? lens.screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first,
                  let config = configuration() else { return }
            // The box itself is left out of the picture, so it shows what's under it.
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let s = SCStream(filter: filter, configuration: config, delegate: output)
            try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await s.startCapture()
            stream = s
            streamDisplay = display.displayID
        } catch {
            close()
            onDenied?()
        }
    }

    private func updateSource() {
        guard let stream, let c = configuration() else { return }
        stream.updateConfiguration(c, completionHandler: nil)
    }

    // MARK: the whole text

    private func showText() {
        guard let screen = areaScreen ?? lens.screen, let (rect, _) = source() else { return }
        Task { @MainActor in
            let areas = await TextGrab.areas(around: rect, on: screen)
            guard !areas.isEmpty else { NSSound.beep(); return }
            TextPanel.show(areas, on: screen)
        }
    }

    // MARK: speaking

    private func toggleSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate); return }
        guard let image = output.latestImage() else { return }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        // Top to bottom, then left to right on a line.
        func before(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.midY - b.midY) > 0.02 ? a.midY > b.midY : a.minX < b.minX
        }
        let found: [(VNRecognizedTextObservation, VNRecognizedText)] = (req.results ?? []).compactMap { r in
            guard let c = r.topCandidates(1).first else { return nil }
            return (r, c)
        }
        let lines = found.sorted { before($0.0.boundingBox, $1.0.boundingBox) }
        guard !lines.isEmpty else { NSSound.beep(); return }
        var text = ""
        spoken = []
        var parts: [(NSRange, VNRecognizedText)] = []
        for (_, c) in lines {
            let start = (text as NSString).length
            text += c.string + "\n"
            parts.append((NSRange(location: start, length: (c.string as NSString).length), c))
        }
        // Each word's box, in the box view's points, for the highlight while it is spoken.
        let size = lens.view.bounds.size
        for (range, c) in parts {
            var i = c.string.startIndex
            for word in c.string.split(separator: " ") {
                guard let r = c.string.range(of: word, range: i..<c.string.endIndex) else { continue }
                i = r.upperBound
                guard let b = try? c.boundingBox(for: r)?.boundingBox else { continue }
                let local = NSRange(r, in: c.string)
                spoken.append((NSRange(location: range.location + local.location, length: local.length),
                               CGRect(x: b.minX * size.width, y: b.minY * size.height,
                                      width: b.width * size.width, height: b.height * size.height)))
            }
        }
        speakTile.fillColor = NSColor(hex: "#2A6EE8")
        speakTile.needsDisplay = true
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice()
        speech.speak(u)
    }

    /// The best voice installed for the Mac's language: Premium, then Enhanced, then the plain default.
    /// Better ones are downloaded in System Settings › Accessibility › Read & Speak › System voice › Manage Voices.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let base = String(lang.prefix(2))
        let mine = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(base) }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            (v.quality == .premium ? 4 : v.quality == .enhanced ? 2 : 0) + (v.language == lang ? 1 : 0)
        }
        return mine.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: lang)
    }

    fileprivate func speaking(_ range: NSRange) {
        lens.view.highlight = spoken.first { NSIntersectionRange($0.range, range).length > 0 }?.box
    }

    fileprivate func doneSpeaking() {
        lens.view.highlight = nil
        speakTile.fillColor = nil
        speakTile.needsDisplay = true
    }
}

extension Magnifier: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking(range) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.doneSpeaking() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.doneSpeaking() }
    }
}

/// Receives the stream's frames off the main thread and hands the picture to the box.
/// Also counts what the stream sent, by kind, and why it stopped: written to ~/.screenvibe/magnifier.log on close,
/// to find out why the box stays dark over some apps. No picture is kept.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "screenvibe.magnifier")
    var onFrame: ((IOSurface) -> Void)?   // called on the main thread
    var onStopped: (() -> Void)?
    private var latest: CVPixelBuffer?
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var events: [String] = []

    private func note(_ kind: String) { lock.lock(); counts[kind, default: 0] += 1; lock.unlock() }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); events.append("stopped: \(error.localizedDescription)"); lock.unlock()
        DispatchQueue.main.async { self.onStopped?() }
    }

    func writeLog() {
        lock.lock(); defer { lock.unlock() }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let line = "\(Date()) front app: \(app); frames: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"
            + (events.isEmpty ? "" : "; " + events.joined(separator: "; ")) + "\n"
        let url = Output.root.appendingPathComponent("magnifier.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        counts = [:]
        events = []
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { note("unreadable"); return }
        guard status == .complete else {
            note(status == .idle ? "idle" : status == .blank ? "blank" : status == .suspended ? "suspended"
                 : status == .started ? "started" : status == .stopped ? "stopped" : "other")
            return
        }
        guard let pixels = buffer.imageBuffer, let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { note("no picture"); return }
        note("complete")
        lock.lock(); latest = pixels; lock.unlock()
        let s = surface as IOSurface
        let hand = onFrame
        DispatchQueue.main.async { hand?(s) }
    }

    func latestImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let latest else { return nil }
        let ci = CIImage(cvPixelBuffer: latest)
        return CIContext().createCGImage(ci, from: ci.extent)
    }
}

/// The box's window. It takes keys only for Esc.
private final class LensPanel: NSPanel {
    let view: LensView
    var onEscape: (() -> Void)?

    init(frame: CGRect) {
        view = LensView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The magnified picture, its frame, the resize corner and the highlight on the word being spoken.
private final class LensView: NSView {
    /// Width over height to keep while resizing (a drawn area), or nil.
    var aspect: CGFloat?
    var onMoved: (() -> Void)?
    var onMoveEnded: (() -> Void)?
    var onZoomWheel: ((_ up: Bool) -> Void)?
    var highlight: CGRect? {
        get { marks.highlight }
        set { marks.highlight = newValue }
    }
    private let marks = LensMarks()
    private let picture = CALayer()
    private let border = CALayer()
    private var grabbed: CGPoint?
    private var resizing = false
    private var wheel: CGFloat = 0
    private let corner: CGFloat = 18
    static let minSize = CGSize(width: 160, height: 80)

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        picture.contentsGravity = .resize
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        border.borderColor = NSColor(hex: "#2A6EE8")!.cgColor
        border.borderWidth = 3
        border.cornerRadius = 10
        border.actions = ["bounds": NSNull(), "position": NSNull()]
        border.zPosition = 10
        layer?.addSublayer(border)
        marks.frame = bounds
        marks.autoresizingMask = [.width, .height]
        addSubview(marks)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        picture.frame = bounds
        border.frame = bounds
    }

    func show(_ surface: IOSurface) { picture.contents = surface }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(CGRect(x: bounds.maxX - corner, y: 0, width: corner, height: corner), cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        resizing = p.x > bounds.maxX - corner && p.y < corner
        grabbed = NSEvent.mouseLocation
        window?.makeKey()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let g = grabbed else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - g.x, dy = m.y - g.y
        grabbed = m
        var f = w.frame
        if resizing {
            // The top-left corner stays; the bottom-right follows the mouse.
            let width = max(Self.minSize.width, f.width + dx)
            let height = aspect.map { width / $0 } ?? max(Self.minSize.height, f.height - dy)
            f = CGRect(x: f.minX, y: f.maxY - height, width: width, height: height)
        } else {
            f.origin.x += dx
            f.origin.y += dy
        }
        w.setFrame(f, display: true)
        onMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        grabbed = nil
        onMoveEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        wheel += event.scrollingDeltaY
        if abs(wheel) > 12 { onZoomWheel?(wheel > 0); wheel = 0 }
    }

}

/// Drawn over the picture: the highlight on the word being spoken, and the resize corner.
private final class LensMarks: NSView {
    var highlight: CGRect? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let h = highlight {
            NSColor(hex: "#FFE680")!.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: h.insetBy(dx: -3, dy: -2), xRadius: 3, yRadius: 3).fill()
        }
        // The resize corner.
        NSColor(hex: "#2A6EE8")!.setStroke()
        let p = NSBezierPath()
        p.lineWidth = 2
        p.move(to: CGPoint(x: bounds.maxX - 14, y: 5))
        p.line(to: CGPoint(x: bounds.maxX - 5, y: 5))
        p.line(to: CGPoint(x: bounds.maxX - 5, y: 14))
        p.stroke()
    }
}

/// The dashed frame around a drawn area. Dragging its edge moves the area; its dots at the corners and the middle of
/// each side resize it. Inside the frame, clicks reach the app as usual: the frame takes the mouse only near its edge.
private final class AreaFrame: NSPanel {
    static let band: CGFloat = 10                    // the grab band, outside the area
    static let inside: CGFloat = 4                   // and this much inside it
    static let minSize = CGSize(width: 40, height: 24)
    var onChange: ((CGRect) -> Void)?
    private(set) var area: CGRect
    private var watch: Timer?
    private var drag: (part: Part, start: CGPoint, area: CGRect)?

    /// Which part of the frame: x and y say which side (-1 left or bottom, 1 right or top, 0 neither); both 0 = move.
    struct Part: Equatable { var x = 0, y = 0 }

    init(around r: CGRect) {
        area = r
        super.init(contentRect: r.insetBy(dx: -Self.band, dy: -Self.band), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let v = AreaFrameView(frame: CGRect(origin: .zero, size: frame.size))
        v.autoresizingMask = [.width, .height]
        v.owner = self
        contentView = v
    }

    func start() {
        orderFrontRegardless()
        // The frame takes the mouse only while it's over the edge, so the area underneath keeps working.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.watchMouse() }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    func stop() {
        watch?.invalidate()
        orderOut(nil)
    }

    /// The part of the frame under a point in screen coordinates, or nil when it's not near the edge.
    func part(at m: CGPoint) -> Part? {
        let outer = area.insetBy(dx: -Self.band, dy: -Self.band), inner = area.insetBy(dx: Self.inside, dy: Self.inside)
        guard outer.contains(m), !inner.contains(m) else { return nil }
        let dot: CGFloat = 14
        // Which edge the point is near: -1 the left (or bottom), 1 the right (or top), 0 neither.
        let ex = abs(m.x - area.minX) < Self.band + 1 ? -1 : abs(m.x - area.maxX) < Self.band + 1 ? 1 : 0
        let ey = abs(m.y - area.minY) < Self.band + 1 ? -1 : abs(m.y - area.maxY) < Self.band + 1 ? 1 : 0
        let cornerX = abs(m.x - area.minX) < dot ? -1 : abs(m.x - area.maxX) < dot ? 1 : 0
        let cornerY = abs(m.y - area.minY) < dot ? -1 : abs(m.y - area.maxY) < dot ? 1 : 0
        // On a dot it resizes: a corner, or the middle of a side. Elsewhere on the edge it moves.
        if cornerX != 0 && cornerY != 0 && (ex != 0 || ey != 0) { return Part(x: cornerX, y: cornerY) }
        if ex != 0 && abs(m.y - area.midY) < dot { return Part(x: ex, y: 0) }
        if ey != 0 && abs(m.x - area.midX) < dot { return Part(x: 0, y: ey) }
        return Part()
    }

    private func cursor(for p: Part) -> NSCursor {
        if p == Part() { return drag == nil ? .openHand : .closedHand }
        if p.x == 0 { return .resizeUpDown }
        if p.y == 0 { return .resizeLeftRight }
        return .crosshair
    }

    private func watchMouse() {
        if let drag { cursor(for: drag.part).set(); return }
        let p = part(at: NSEvent.mouseLocation)
        if ignoresMouseEvents != (p == nil) { ignoresMouseEvents = p == nil }
        if let p { cursor(for: p).set() }
    }

    fileprivate func mouseDown() {
        let m = NSEvent.mouseLocation
        guard let p = part(at: m) else { return }
        drag = (p, m, area)
        cursor(for: p).set()
    }

    fileprivate func mouseDragged() {
        guard let d = drag, let s = screen ?? NSScreen.screens.first(where: { $0.frame.intersects(area) }) else { return }
        let m = NSEvent.mouseLocation, sf = s.frame
        let dx = m.x - d.start.x, dy = m.y - d.start.y
        var r = d.area
        if d.part == Part() {
            r.origin.x = min(max(r.minX + dx, sf.minX), sf.maxX - r.width)
            r.origin.y = min(max(r.minY + dy, sf.minY), sf.maxY - r.height)
        } else {
            // The side being dragged follows the mouse; the opposite side stays.
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            if d.part.x < 0 { minX = min(max(minX + dx, sf.minX), maxX - Self.minSize.width) }
            if d.part.x > 0 { maxX = max(min(maxX + dx, sf.maxX), minX + Self.minSize.width) }
            if d.part.y < 0 { minY = min(max(minY + dy, sf.minY), maxY - Self.minSize.height) }
            if d.part.y > 0 { maxY = max(min(maxY + dy, sf.maxY), minY + Self.minSize.height) }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        guard r != area else { return }
        area = r
        setFrame(r.insetBy(dx: -Self.band, dy: -Self.band), display: true)
        onChange?(r)
    }

    fileprivate func mouseUp() { drag = nil }
}

private final class AreaFrameView: NSView {
    weak var owner: AreaFrame?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp() }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor(hex: "#2A6EE8")!
        let r = bounds.insetBy(dx: AreaFrame.band, dy: AreaFrame.band)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 4, yRadius: 4)
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        blue.setStroke()
        p.stroke()
        // The dots that resize: at the corners and the middle of each side.
        let e: CGFloat = 2.5
        for x in [r.minX - e, r.midX, r.maxX + e] {
            for y in [r.minY - e, r.midY, r.maxY + e] where !(x == r.midX && y == r.midY) {
                let d = NSBezierPath(ovalIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                NSColor.white.setFill()
                d.fill()
                d.lineWidth = 1.5
                blue.setStroke()
                d.stroke()
            }
        }
    }
}

/// ⌘⇧7's first step: drag an area to magnify, or click to get the box that shows what's under it. Esc cancels.
final class AreaPicker: NSPanel {
    /// Called with the drawn area in screen coordinates, or nil after a click; not called after Esc.
    private let done: (CGRect?) -> Void
    private let view = PickerView()

    init(done: @escaping (CGRect?) -> Void) {
        self.done = done
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        view.frame = CGRect(origin: .zero, size: screen.frame.size)
        view.onDone = { [weak self] r in
            guard let self else { return }
            self.orderOut(nil)
            self.done(r.map { CGRect(x: $0.minX + self.frame.minX, y: $0.minY + self.frame.minY, width: $0.width, height: $0.height) })
        }
        contentView = view
    }

    func show() {
        orderFrontRegardless()
        makeKey()
        invalidateCursorRects(for: view)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }
}

private final class PickerView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    private var drawn: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start }
    override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let r = drawn
        start = nil
        current = nil
        needsDisplay = true
        onDone?(r.flatMap { $0.width >= 12 && $0.height >= 8 ? $0 : nil })
    }

    override func draw(_ dirtyRect: NSRect) {
        // A light veil says "pick an area"; the area being drawn is clear, with a dashed frame.
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        guard let r = drawn else { return }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        let p = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
        p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        NSColor(hex: "#2A6EE8")!.setStroke()
        p.stroke()
    }
}
