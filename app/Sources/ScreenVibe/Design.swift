import AppKit

/// What the Window tool makes.
enum WindowType: String, Codable, CaseIterable {
    case panel, adobe, modal, plain

    var title: String {
        switch self {
        case .panel: return "Panel"
        case .adobe: return "Adobe panel"
        case .modal: return "Modal"
        case .plain: return "Plain"
        }
    }
}

enum ItemKind: String, Codable, CaseIterable {
    case window, box, button, popup, checkbox, radio, field, slider, label, tabs, list, picture, note

    var title: String {
        switch self {
        case .window: return "Window"
        case .box: return "Box"
        case .button: return "Button"
        case .popup: return "Popup"
        case .checkbox: return "Checkbox"
        case .radio: return "Radio"
        case .field: return "Field"
        case .slider: return "Slider"
        case .label: return "Label"
        case .tabs: return "Tabs"
        case .list: return "List"
        case .picture: return "Picture"
        case .note: return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .window: return "macwindow"
        case .box: return "square.dashed"
        case .button: return "capsule"
        case .popup: return "chevron.up.chevron.down"
        case .checkbox: return "checkmark.square"
        case .radio: return "smallcircle.filled.circle"
        case .field: return "character.cursor.ibeam"
        case .slider: return "slider.horizontal.3"
        case .label: return "textformat"
        case .tabs: return "menubar.rectangle"
        case .list: return "list.bullet.rectangle"
        case .picture: return "photo"
        case .note: return "note.text"
        }
    }

    /// Holds other items, which move with it.
    var isContainer: Bool { self == .window || self == .box }

    /// Has a label linked to its left (or above, for a list), which moves with it.
    var hasLabel: Bool { self == .popup || self == .field || self == .slider || self == .list || self == .radio }

    /// Choices typed one per line.
    var hasChoices: Bool { self == .popup || self == .radio || self == .tabs || self == .list }

    /// One line high: the size (S/M/L) sets the height; a drag sets only the width.
    var isOneLine: Bool { [.button, .popup, .checkbox, .field, .slider, .label].contains(self) }
}

enum ControlSize: String, Codable, CaseIterable {
    case s, m, l

    var height: CGFloat { self == .s ? 20 : self == .m ? 24 : 30 }
    var font: NSFont { .systemFont(ofSize: self == .s ? 11 : self == .m ? 13 : 15) }
    var rowGap: CGFloat { self == .s ? 18 : self == .m ? 22 : 28 }
}

struct DesignItem: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: ItemKind
    var frame: CGRect
    var title = ""          // window or box title, button, checkbox, label, field and note words
    var label = ""          // the linked label of a popup, field, slider or list
    var choices: [String] = []
    var on = false          // a checkbox drawn checked
    var pick = 0            // the chosen radio, tab or list row
    var value = 0.4         // a slider's knob, 0...1
    var size = ControlSize.m
    var windowType = WindowType.panel
    var parent: String?     // the window or box it sits in
    var image: String?      // a picture's file in the design's folder
    var across: Bool?       // radio buttons side by side, not stacked

    /// What a new item starts with.
    static func new(_ kind: ItemKind, at r: CGRect, size: ControlSize, windowType: WindowType) -> DesignItem {
        var it = DesignItem(kind: kind, frame: r)
        it.size = size
        it.windowType = windowType
        switch kind {
        case .window: it.title = windowType == .modal ? "Dialog" : windowType == .adobe ? "Panel" : "Window"
        case .box: it.title = "Box"
        case .button: it.title = "Button"
        case .popup: it.label = "Label:"; it.choices = ["Item 1", "Item 2"]
        case .checkbox: it.title = "Label"
        case .radio: it.choices = ["Option 1", "Option 2"]
        case .field: it.label = "Label:"
        case .slider: it.label = "Label:"
        case .label: it.title = "Label"
        case .tabs: it.choices = ["Tab 1", "Tab 2"]
        case .list: it.choices = ["Row 1", "Row 2", "Row 3"]
        case .picture: break
        case .note: it.title = "Note"
        }
        return it
    }

    /// Its size when placed with a click instead of a drag.
    static func defaultSize(_ kind: ItemKind, size: ControlSize, windowType: WindowType) -> CGSize {
        let h = size.height
        switch kind {
        case .window: return windowType == .adobe ? CGSize(width: 260, height: 300) : CGSize(width: 360, height: 240)
        case .box: return CGSize(width: 240, height: 140)
        case .button: return CGSize(width: 90, height: h)
        case .popup: return CGSize(width: 140, height: h)
        case .checkbox: return CGSize(width: 120, height: h)
        case .radio: return CGSize(width: 120, height: size.rowGap * 2)
        case .field: return CGSize(width: 160, height: h)
        case .slider: return CGSize(width: 140, height: h)
        case .label: return CGSize(width: 80, height: h)
        case .tabs: return CGSize(width: 260, height: 160)
        case .list: return CGSize(width: 180, height: 110)
        case .picture: return CGSize(width: 160, height: 110)
        case .note: return CGSize(width: 160, height: 70)
        }
    }
}

/// An arrow from one item to another; it follows them when they move.
struct DesignLink: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var from: String
    var to: String
    var text = ""
}

struct Design: Codable {
    var title: String
    var items: [DesignItem] = []
    var links: [DesignLink] = []
    var modified = Date()
}

/// UI designs in ~/Documents/ScreenVibe/UI designs, one folder each: design.json, preview.png and pasted pictures.
enum DesignStore {
    static var folder: URL {
        if let t = ProcessInfo.processInfo.environment["SCREENVIBE_DESIGN_DIR"] { return URL(fileURLWithPath: t).appendingPathComponent("UI designs") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ScreenVibe/UI designs")
    }

    struct Entry {
        let url: URL
        let title: String
        let date: Date
        var preview: URL { url.appendingPathComponent("preview.png") }
    }

    static func list() -> [Entry] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Entry? in
            guard let d = load(dir) else { return nil }
            return Entry(url: dir, title: d.title, date: d.modified)
        }
        .sorted { $0.date > $1.date }
    }

    static func load(_ dir: URL) -> Design? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("design.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Design.self, from: data)
    }

    /// A new, empty folder named after the title ("Untitled design 2" when taken).
    static func newFolder(for title: String) -> URL {
        let base = safeName(title)
        var url = folder.appendingPathComponent(base), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func safeName(_ title: String) -> String {
        let t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled design" : String(t.prefix(80))
    }

    static func save(_ d: Design, to dir: URL, preview: CGImage?) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? enc.encode(d).write(to: dir.appendingPathComponent("design.json"))
        if let preview { try? Output.png(preview)?.write(to: dir.appendingPathComponent("preview.png")) }
    }

    /// Moves the folder to match a new title; returns where it is now.
    static func rename(_ dir: URL, to title: String) -> URL {
        let base = safeName(title)
        guard base != dir.lastPathComponent else { return dir }
        var url = folder.appendingPathComponent(base), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        return (try? FileManager.default.moveItem(at: dir, to: url)) != nil ? url : dir
    }
}
