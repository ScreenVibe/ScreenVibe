import AppKit

/// Opens on Send: the marked picture, every numbered request (editable), a note for the whole markup and the session.
/// Return sends, Cancel goes back to the markup, Esc closes the markup.
final class SendWindow: NSPanel, NSTextFieldDelegate {
    /// `spots`: nil when Blur private info is off.
    var onSend: ((_ words: [String], _ markNotes: [String?], _ note: String, _ session: SessionInfo, _ spots: [Spot]?) -> Void)?
    var onCancel: (() -> Void)?
    var onQuit: (() -> Void)?

    private static let columnWidth: CGFloat = 480
    private var fields: [GrowingField] = []
    private var markNotes: [Int: GrowingField] = [:]   // only marks that have a note get a box for it
    private let note = GrowingField(minHeight: 64)
    private let popup = NSPopUpButton()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private var sessions: [SessionInfo] = []
    private var refresh: Timer?
    private let picture: PicturePreview
    private let blurBox = NSButton(checkboxWithTitle: "Blur private info", target: nil, action: nil)
    private let blurNote = NSTextField(labelWithString: "")

    /// `found`: the words read under each mark, to warn about a Wording box over empty space.
    /// `spots`: what looks private, in screen points; `origin`: the picture's top-left corner there.
    /// `picture` draws the marked picture with the given spots covered.
    init(marks: [Mark], found: [String], spots: [Spot], origin: CGPoint, picture: @escaping ([CGRect]) -> NSImage?) {
        self.picture = PicturePreview(spots: spots, origin: origin, draw: picture)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 960, height: 400), styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Send the markup"
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // The picture, as large as fits the left column, with what looks private covered. A click shows a spot again.
        let image = self.picture
        image.onChange = { [weak self] in self?.showBlurNote() }
        image.isBlurring = Private.isOn
        blurNote.font = .systemFont(ofSize: 12)
        blurNote.textColor = .secondaryLabelColor
        let left = NSStackView(views: [image, blurNote])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6

        // The numbered requests, then the note for the whole markup.
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        for (i, m) in marks.enumerated() {
            let field = GrowingField(minHeight: 0)
            // A tool's own words when it asks for them; otherwise the mark's note.
            field.stringValue = m.asksForWords ? m.text : m.extra
            field.delegate = self
            fields.append(field)
            var noteField: GrowingField?
            if m.asksForWords, !m.extra.isEmpty {
                let f = GrowingField(minHeight: 0)
                f.stringValue = m.extra
                f.delegate = self
                markNotes[i] = f
                noteField = f
            }
            column.addArrangedSubview(row(number: i + 1, color: m.color, name: Output.name(of: m), field: field,
                                          note: noteField, warning: nil))
        }
        let noteLabel = NSTextField(labelWithString: "Note for the whole markup")
        noteLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        if !marks.isEmpty { column.setCustomSpacing(18, after: column.arrangedSubviews.last!) }
        column.addArrangedSubview(noteLabel)
        note.delegate = self
        note.width = Self.columnWidth
        column.addArrangedSubview(note)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.columnWidth + 4),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        let fit = scroll.heightAnchor.constraint(equalTo: doc.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true

        let top = NSStackView(views: [left, scroll])
        top.alignment = .top
        top.spacing = 20

        // Session, Cancel, Send.
        let sendTo = NSTextField(labelWithString: "Send to")
        popup.target = self
        popup.action = #selector(pickedSession)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelColor = NSColor(hex: "#D6342C")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        blurBox.state = Private.isOn ? .on : .off
        blurBox.target = self
        blurBox.action = #selector(blurToggled)
        let foot = NSStackView(views: [sendTo, popup, blurBox, spacer, cancel, sendButton])
        foot.setCustomSpacing(22, after: popup)
        foot.spacing = 10

        let all = NSStackView(views: [top, foot])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 18
        all.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        all.translatesAutoresizingMaskIntoConstraints = false
        foot.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        let content = NSView()
        content.addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            all.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            all.topAnchor.constraint(equalTo: content.topAnchor),
            all.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content

        loadSessions()
        validate()
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.loadSessions() }
        for f in fields + Array(markNotes.values) + [note] { f.fit() }
        layoutIfNeeded()
        setContentSize(content.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func present(on screen: NSScreen) {
        let f = frame
        setFrameOrigin(CGPoint(x: screen.frame.midX - f.width / 2, y: screen.frame.midY - f.height / 2))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(note)
    }

    override func close() {
        refresh?.invalidate()
        super.close()
    }

    private func row(number: Int, color: NSColor, name: String, field: GrowingField, note: GrowingField?,
                     warning: String?) -> NSView {
        let dot = NumberDot(number: number, color: color)
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        field.width = Self.columnWidth - 36
        var parts: [NSView] = [label, field]
        if let warning {
            let w = NSTextField(wrappingLabelWithString: warning)
            w.font = .systemFont(ofSize: 12)
            w.textColor = .systemOrange
            w.preferredMaxLayoutWidth = Self.columnWidth - 36
            parts.append(w)
        }
        if let note {
            let noteLabel = NSTextField(labelWithString: "Note")
            noteLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            noteLabel.textColor = .secondaryLabelColor
            note.width = Self.columnWidth - 36
            parts += [noteLabel, note]
        }
        let right = NSStackView(views: parts)
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 3
        let row = NSStackView(views: [dot, right])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    // MARK: sessions

    private func loadSessions() {
        let live = Sessions.alive()
        guard live.map(\.sessionId) != sessions.map(\.sessionId) || popup.numberOfItems == 0 else { return }
        let keep = popup.indexOfSelectedItem >= 0 && popup.indexOfSelectedItem < sessions.count
            ? sessions[popup.indexOfSelectedItem].sessionId : Sessions.lastId
        sessions = live
        popup.removeAllItems()
        if live.isEmpty {
            popup.addItem(withTitle: "No sessions. Type /screenvibe in a Claude Code session to link it.")
            popup.isEnabled = false
            sendButton.isEnabled = false
            return
        }
        for s in live { popup.addItem(withTitle: s.menuTitle) }
        popup.isEnabled = true
        validate()
        popup.selectItem(at: live.firstIndex { $0.sessionId == keep } ?? 0)
    }

    @objc private func pickedSession() {}

    @objc private func blurToggled() {
        Private.isOn = blurBox.state == .on
        picture.isBlurring = Private.isOn
    }

    private func showBlurNote() {
        let all = picture.spots.count, on = picture.spots.filter(\.isOn).count
        blurNote.stringValue = !picture.isBlurring ? "Blur is off. Nothing is hidden."
            : all == 0 ? "Nothing private found."
            : on == all ? "\(all) \(all == 1 ? "spot" : "spots") blurred. Click one to show it again."
            : "\(on) of \(all) spots blurred. Click a spot to blur or show it."
    }

    private func validate() {
        sendButton.isEnabled = !sessions.isEmpty
    }

    @objc private func sendPressed() {
        let i = popup.indexOfSelectedItem
        guard sendButton.isEnabled, i >= 0, i < sessions.count else { return }
        let extras = fields.indices.map { markNotes[$0]?.text }
        onSend?(fields.map(\.text), extras, note.text, sessions[i], picture.isBlurring ? picture.spots : nil)
    }

    @objc private func cancelPressed() { onCancel?() }

    override func cancelOperation(_ sender: Any?) { onQuit?() }

    func controlTextDidChange(_ obj: Notification) {
        (obj.object as? GrowingField)?.fit()
        validate()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onQuit?(); return true }
        guard selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
}

/// A text box that wraps and grows down as the words need more lines. Shift-Return (or ⌥Return) starts a new line.
final class GrowingField: NSTextField {
    var width: CGFloat = 400 { didSet { widthConstraint.constant = width; fit() } }
    private let minHeight: CGFloat
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: width)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 30)

    init(minHeight: CGFloat) {
        self.minHeight = minHeight
        super.init(frame: .zero)
        font = .systemFont(ofSize: 14)
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        isBezeled = true
        bezelStyle = .roundedBezel
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint.isActive = true
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String { currentEditor()?.string ?? stringValue }

    func fit() {
        let s = (text.isEmpty ? " " : text) as NSString
        let b = s.boundingRect(with: CGSize(width: width - 12, height: 10_000), options: [.usesLineFragmentOrigin],
                               attributes: [.font: font!])
        heightConstraint.constant = max(minHeight, ceil(b.height) + 10)
    }
}

private final class NumberDot: NSView {
    private let number: Int
    private let color: NSColor

    init(number: Int, color: NSColor) {
        self.number = number
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 42).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Sits level with the text box, under the tool's name.
        MarkDrawing.tag(number, at: CGPoint(x: 13, y: 29), color: color)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}



/// The marked picture in the Send window. Covered spots get a small tag saying why; a click shows or covers one.
private final class PicturePreview: NSView {
    private(set) var spots: [Spot]
    var isBlurring = true { didSet { redraw() } }
    var onChange: (() -> Void)?
    private let draw: ([CGRect]) -> NSImage?
    private var image: NSImage?
    private let width: CGFloat = 430

    init(spots: [Spot], origin: CGPoint, draw: @escaping ([CGRect]) -> NSImage?) {
        self.spots = spots
        self.origin = origin
        self.draw = draw
        super.init(frame: .zero)
        image = draw([])
        let size = image?.size ?? CGSize(width: 1, height: 1)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: min(560, width * size.height / max(1, size.width))).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func redraw() {
        image = draw(isBlurring ? spots.filter(\.isOn).map(\.rect) : [])
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onChange?()
    }

    /// Where the picture sits in the view, and how a spot (screen points) maps into it.
    private var fitted: CGRect {
        guard let s = image?.size, s.width > 0, s.height > 0 else { return bounds }
        let k = min(bounds.width / s.width, bounds.height / s.height)
        return CGRect(x: (bounds.width - s.width * k) / 2, y: (bounds.height - s.height * k) / 2,
                      width: s.width * k, height: s.height * k)
    }

    private let origin: CGPoint
    private func place(_ r: CGRect) -> CGRect {
        guard let s = image?.size, s.width > 0 else { return .zero }
        let f = fitted, k = f.width / s.width
        return CGRect(x: f.minX + (r.minX - origin.x) * k, y: f.minY + (r.minY - origin.y) * k,
                      width: r.width * k, height: r.height * k)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        image?.draw(in: fitted)
        guard isBlurring else { return }
        for s in spots {
            let r = place(s.rect)
            if !s.isOn {
                let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                p.lineWidth = 1.5
                p.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.systemBlue.setStroke()
                p.stroke()
            }
            tag(s.isOn ? s.why.rawValue : "shown", at: r)
        }
    }

    private func tag(_ text: String, at r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: r.maxX + 4, y: r.midY - (size.height + 2) / 2, width: size.width + 10, height: size.height + 2)
        if box.maxX > bounds.maxX - 2 { box.origin.x = max(2, r.maxX - box.width) ; box.origin.y = r.minY - box.height - 2 }
        if box.minY < 2 { box.origin.y = r.maxY + 2 }
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 5, y: box.minY + 1), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard isBlurring else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = spots.indices.last(where: { place(spots[$0].rect).insetBy(dx: -3, dy: -3).contains(p) }) else { return }
        spots[i].isOn.toggle()
        redraw()
    }

    override func resetCursorRects() {
        guard isBlurring else { return }
        for s in spots { addCursorRect(place(s.rect), cursor: .pointingHand) }
    }
}
