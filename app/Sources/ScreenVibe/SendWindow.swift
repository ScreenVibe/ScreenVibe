import AppKit

/// Opens on Send: the marked picture, every numbered request (editable), a note for the whole markup and the session.
/// Return sends, Esc goes back to the markup.
final class SendWindow: NSPanel, NSTextFieldDelegate {
    var onSend: ((_ words: [String], _ markNotes: [String?], _ note: String, _ session: SessionInfo) -> Void)?
    var onCancel: (() -> Void)?

    private static let columnWidth: CGFloat = 480
    private var fields: [GrowingField] = []
    private var markNotes: [Int: GrowingField] = [:]   // only marks that have a note get a box for it
    private let note = GrowingField(minHeight: 64)
    private let popup = NSPopUpButton()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private var sessions: [SessionInfo] = []
    private var refresh: Timer?

    /// `found`: the words read under each mark, to warn about a Wording box over empty space.
    init(preview: NSImage, marks: [Mark], found: [String]) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 960, height: 400), styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Send the markup"
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // The picture, as large as fits the left column.
        let pictureWidth: CGFloat = 430
        let ratio = preview.size.height / max(1, preview.size.width)
        let image = NSImageView(image: preview)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.borderWidth = 1
        image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: pictureWidth).isActive = true
        image.heightAnchor.constraint(equalToConstant: min(560, pictureWidth * ratio)).isActive = true

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
            let empty = m.tool?.id == "wording" && (i >= found.count || found[i].isEmpty)
            column.addArrangedSubview(row(number: i + 1, color: m.color, name: Output.name(of: m), field: field,
                                          note: noteField,
                                          warning: empty ? "No words were found under this box. Say in a note what it replaces." : nil))
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

        let top = NSStackView(views: [image, scroll])
        top.alignment = .top
        top.spacing = 20

        // Session, Cancel, Send.
        let sendTo = NSTextField(labelWithString: "Send to")
        popup.target = self
        popup.action = #selector(pickedSession)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.bezelColor = NSColor(hex: "#D6342C")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [sendTo, popup, spacer, cancel, sendButton])
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

    private func validate() {
        sendButton.isEnabled = !sessions.isEmpty
    }

    @objc private func sendPressed() {
        let i = popup.indexOfSelectedItem
        guard sendButton.isEnabled, i >= 0, i < sessions.count else { return }
        let extras = fields.indices.map { markNotes[$0]?.text }
        onSend?(fields.map(\.text), extras, note.text, sessions[i])
    }

    @objc private func cancelPressed() { onCancel?() }

    func controlTextDidChange(_ obj: Notification) {
        (obj.object as? GrowingField)?.fit()
        validate()
    }
}

/// A text box that wraps and grows down as the words need more lines. ⌥Return starts a new line.
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


