import AppKit

/// The drawn form a tool makes.
enum ToolShape: String, Codable, CaseIterable {
    case box, oval, arrow, line, boxArrow, pen, text, popup, dots

    /// Drawn from a start point to an end point.
    var isLine: Bool { self == .arrow || self == .line }

    var title: String {
        switch self {
        case .box: return "Box"
        case .oval: return "Oval"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .boxArrow: return "Box + arrow"
        case .pen: return "Free pen"
        case .text: return "Text"
        case .popup: return "Popup"
        case .dots: return "⋯ menu"
        }
    }
}

enum ToolFill: String, Codable, CaseIterable {
    case none, tint, stripes

    var title: String {
        switch self {
        case .none: return "None"
        case .tint: return "Tint"
        case .stripes: return "Stripes"
        }
    }
}

/// Where the words a tool asks for are drawn.
enum TextPlacement: String, Codable, CaseIterable {
    case callout, inside

    var title: String { self == .callout ? "Under the mark" : "Inside, as a button" }
}

/// A tool is a look plus an intent. The intent is what Claude reads for every mark made with it.
struct ToolDef: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var symbol: String
    var shape: ToolShape
    var colorHex: String
    var lineWidth: Double = 2.5
    var dashed: Bool = false
    var fill: ToolFill = .none
    var intent: String
    var ask: String? = nil
    var placement: TextPlacement = .callout
    var shortcut: String = ""

    var color: NSColor { NSColor(hex: colorHex) ?? .systemRed }

    /// The plain drawing tools. They share one Draw tile on the palette, and only they take a picked color.
    static let drawIDs = ["rect", "oval", "line", "arrow", "pen"]
    var isDraw: Bool { Self.drawIDs.contains(id) }
}

final class ToolStore {
    static let shared = ToolStore()
    static let didChange = Notification.Name("ScreenVibeToolsChanged")

    private(set) var tools: [ToolDef] = []

    private var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".screenvibe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ToolDef].self, from: data), !saved.isEmpty {
            tools = saved
            addNewBuiltIns()
        } else {
            tools = ToolStore.builtIns
        }
    }

    /// Built-in tools added after someone saved their tools: each is added once, after Button, and stays deleted if
    /// they delete it.
    private func addNewBuiltIns() {
        let key = "toolsAdded"
        var added = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var changed = false
        for id in ["popup", "dots"] where !added.contains(id) {
            added.insert(id)
            guard !tools.contains(where: { $0.id == id }), let t = Self.builtIns.first(where: { $0.id == id }) else { continue }
            let after = tools.lastIndex { $0.id == "button" || $0.id == "popup" }.map { $0 + 1 } ?? tools.count
            tools.insert(t, at: after)
            changed = true
        }
        UserDefaults.standard.set(Array(added), forKey: key)
        if changed { save() }
    }

    /// The Draw tools in the order the Draw row shows them: Rect, Oval, Line, Arrow, Pen.
    var drawTools: [ToolDef] {
        tools.filter(\.isDraw).sorted { ToolDef.drawIDs.firstIndex(of: $0.id)! < ToolDef.drawIDs.firstIndex(of: $1.id)! }
    }

    func replaceAll(_ newTools: [ToolDef]) {
        tools = newTools
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(tools) { try? data.write(to: url) }
        Guide.write()
        NotificationCenter.default.post(name: ToolStore.didChange, object: nil)
    }

    static let builtIns: [ToolDef] = [
        ToolDef(id: "remove", name: "Remove", symbol: "eraser", shape: .box, colorHex: "#E0261B",
                fill: .stripes, intent: "Remove this.", shortcut: "x"),
        ToolDef(id: "wording", name: "Wording", symbol: "character.cursor.ibeam", shape: .box, colorHex: "#1A6FE0",
                intent: "Change the wording to", ask: "What should it say?", shortcut: "w"),
        ToolDef(id: "button", name: "Button", symbol: "plus.rectangle", shape: .box, colorHex: "#18A050",
                dashed: true, fill: .tint, intent: "Add a button here, labeled", ask: "What is the button's label?",
                placement: .inside, shortcut: "b"),
        ToolDef(id: "popup", name: "Popup", symbol: "chevron.down.square", shape: .popup, colorHex: "#18A050",
                dashed: true, fill: .tint, intent: "Add a pop-up menu here, with these choices",
                ask: "What are the choices? Put one on each line. The first one is what it shows when closed.",
                placement: .inside, shortcut: "u"),
        ToolDef(id: "dots", name: "⋯ menu", symbol: "ellipsis.circle", shape: .dots, colorHex: "#18A050",
                dashed: true, fill: .tint, intent: "Add a round ⋯ button here that opens a menu, with these items",
                ask: "What is in the menu? Put one item on each line.", placement: .inside, shortcut: "d"),
        ToolDef(id: "move", name: "Move", symbol: "arrow.right.square", shape: .boxArrow, colorHex: "#EF8A00",
                intent: "Move this to where the arrow points.", shortcut: "m"),
        ToolDef(id: "copymove", name: "Copy+move", symbol: "plus.square.on.square", shape: .boxArrow, colorHex: "#EF8A00",
                dashed: true, intent: "Copy this to where the arrow points, and keep the original too.", shortcut: "c"),
        ToolDef(id: "pen", name: "Pen", symbol: "pencil.tip", shape: .pen, colorHex: "#D61F8C", lineWidth: 3,
                intent: "Look at this drawing.", shortcut: "p"),
        ToolDef(id: "note", name: "Note", symbol: "text.bubble", shape: .text, colorHex: "#D61F8C",
                intent: "Note", ask: "What is the note?", shortcut: "n"),
        ToolDef(id: "rect", name: "Rect", symbol: "rectangle", shape: .box, colorHex: "#E0261B", lineWidth: 3,
                intent: "Look here.", shortcut: "r"),
        ToolDef(id: "line", name: "Line", symbol: "line.diagonal", shape: .line, colorHex: "#E0261B", lineWidth: 3,
                intent: "Look along this line.", shortcut: "l"),
        ToolDef(id: "arrow", name: "Arrow", symbol: "arrow.up.right", shape: .arrow, colorHex: "#E0261B", lineWidth: 3,
                intent: "Look where this points.", shortcut: "a"),
        ToolDef(id: "oval", name: "Oval", symbol: "circle", shape: .oval, colorHex: "#E0261B", lineWidth: 3,
                intent: "Look here.", shortcut: "o"),
    ]
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Light enough that words on it need to be dark (yellow, white).
    var isLight: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
