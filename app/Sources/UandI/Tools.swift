import AppKit

/// The drawn form a tool makes.
enum ToolShape: String, Codable, CaseIterable {
    case box, oval, arrow, boxArrow, pen, text

    var title: String {
        switch self {
        case .box: return "Box"
        case .oval: return "Oval"
        case .arrow: return "Arrow"
        case .boxArrow: return "Box + arrow"
        case .pen: return "Free pen"
        case .text: return "Text"
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
}

final class ToolStore {
    static let shared = ToolStore()
    static let didChange = Notification.Name("UandIToolsChanged")

    private(set) var tools: [ToolDef] = []

    private var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".uandi")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tools.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ToolDef].self, from: data), !saved.isEmpty {
            tools = saved
        } else {
            tools = ToolStore.builtIns
        }
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
        ToolDef(id: "move", name: "Move", symbol: "arrow.right.square", shape: .boxArrow, colorHex: "#EF8A00",
                intent: "Move this to where the arrow points.", shortcut: "m"),
        ToolDef(id: "copymove", name: "Copy+move", symbol: "plus.square.on.square", shape: .boxArrow, colorHex: "#EF8A00",
                dashed: true, intent: "Copy this to where the arrow points, and keep the original too.", shortcut: "c"),
        ToolDef(id: "pen", name: "Pen", symbol: "pencil.tip", shape: .pen, colorHex: "#D61F8C", lineWidth: 3,
                intent: "Look at this drawing.", shortcut: "p"),
        ToolDef(id: "note", name: "Note", symbol: "text.bubble", shape: .text, colorHex: "#D61F8C",
                intent: "Note", ask: "What is the note?", shortcut: "n"),
        ToolDef(id: "redframe", name: "Red frame", symbol: "square", shape: .box, colorHex: "#E0261B", lineWidth: 3,
                intent: "Make this match the rest of the screen.", ask: "Match what?", shortcut: "r"),
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

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
