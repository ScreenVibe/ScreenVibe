import AppKit
import AVFoundation
import ScreenCaptureKit
import Vision

/// ⌘⇧7: a box that shows what's under it, magnified and live. Drag it to move, drag its corner to resize.
/// The bar centered under it has + and − (zoom steps), the zoom, and Speak (reads the words in the box aloud).
/// Esc closes it. It opens where the mouse is, at the size and zoom used last.
final class Magnifier: NSObject {
    static let steps: [CGFloat] = [1.5, 2, 3, 4, 6, 8]

    var onClose: (() -> Void)?
    var onDenied: (() -> Void)?
    private(set) var framesShown = 0
    private let lens: LensPanel
    private let bar: Palette
    private let zoomLabel = NSTextField(labelWithString: "")
    private var speakTile: Tile!
    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID?
    private let output = FrameOutput()
    private let speech = AVSpeechSynthesizer()
    private var spoken: [(range: NSRange, box: CGRect)] = []   // each line's place in the spoken text and in the box

    private var zoom: CGFloat {
        get { UserDefaults.standard.object(forKey: "magnifier.zoom") as? CGFloat ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "magnifier.zoom") }
    }

    override init() {
        let saved = UserDefaults.standard.array(forKey: "magnifier.size") as? [Double]
        let size = saved.map { CGSize(width: $0[0], height: $0[1]) } ?? CGSize(width: 480, height: 220)
        let m = NSEvent.mouseLocation
        lens = LensPanel(frame: CGRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height))
        bar = Palette(key: "magnifier")
        super.init()
        speech.delegate = self
        lens.view.onMoved = { [weak self] in self?.followLens() }
        lens.view.onMoveEnded = { [weak self] in self?.saveAndRestartIfMoved() }
        lens.view.onZoomWheel = { [weak self] up in self?.step(up ? 1 : -1) }
        lens.onEscape = { [weak self] in self?.close() }
        output.onFrame = { [weak self] surface in self?.lens.view.show(surface); self?.framesShown += 1 }
        buildBar()
        clampToScreen()
    }

    func show() {
        lens.orderFrontRegardless()
        lens.makeKey()
        lens.addChildWindow(bar, ordered: .above)
        followLens()
        bar.orderFrontRegardless()
        Task { await startStream() }
    }

    func close() {
        speech.stopSpeaking(at: .immediate)
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        lens.removeChildWindow(bar)
        bar.orderOut(nil)
        lens.orderOut(nil)
        onClose?()
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
        let row = NSStackView(views: [plus, minus, zoomLabel, speakTile])
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
        let i = steps.firstIndex { $0 >= zoom - 0.01 } ?? steps.count - 1
        zoom = steps[max(0, min(steps.count - 1, i + by))]
        showZoom()
        updateSource()
    }

    /// The bar sits centered under the box, or over it when the box is near the bottom of the screen.
    private func followLens() {
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
            let id = displayID(of: lens.screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first,
                  let config = configuration() else { return }
            // The box itself is left out of the picture, so it shows what's under it.
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let s = SCStream(filter: filter, configuration: config, delegate: nil)
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
        speech.speak(AVSpeechUtterance(string: text))
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
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "screenvibe.magnifier")
    var onFrame: ((IOSurface) -> Void)?   // called on the main thread
    private var latest: CVPixelBuffer?
    private let lock = NSLock()

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = buffer.imageBuffer, let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
        else { return }
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
            let height = max(Self.minSize.height, f.height - dy)
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
