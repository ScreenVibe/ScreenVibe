import AppKit
import SwiftUI

final class ToolEditorWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "UandI Tools"
            w.contentView = NSHostingView(rootView: ToolEditorView())
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private let symbolChoices = [
    "eraser", "trash", "character.cursor.ibeam", "textformat", "plus.rectangle", "rectangle", "square", "circle",
    "arrow.right.square", "arrow.up.right", "plus.square.on.square", "pencil.tip", "scribble", "text.bubble",
    "exclamationmark.triangle", "star", "paintbrush", "photo", "rectangle.dashed", "arrow.left.and.right",
    "arrow.up.and.down", "line.3.horizontal", "checkmark.square", "questionmark.circle",
]

struct ToolEditorView: View {
    @State private var tools: [ToolDef] = ToolStore.shared.tools
    @State private var selection: String? = ToolStore.shared.tools.first?.id

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selection) {
                    ForEach(tools) { t in
                        HStack(spacing: 10) {
                            Image(systemName: t.symbol)
                                .foregroundStyle(Color(nsColor: t.color))
                                .frame(width: 22)
                            Text(t.name)
                        }
                        .tag(t.id)
                    }
                    .onMove { from, to in
                        tools.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                }
                HStack {
                    Button("New tool") { addTool() }
                    Button("Delete") { deleteSelected() }
                        .disabled(selection == nil)
                    Spacer()
                }
                .padding(10)
            }
            .frame(width: 230)
            Divider()
            if let i = tools.firstIndex(where: { $0.id == selection }) {
                ToolForm(tool: $tools[i]) { save() }
                    .id(tools[i].id)
            } else {
                Text("Pick a tool on the left, or make a new one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func save() { ToolStore.shared.replaceAll(tools) }

    private func addTool() {
        let t = ToolDef(name: "New tool", symbol: "square", shape: .box, colorHex: "#E0261B", intent: "Look at this.")
        tools.append(t)
        selection = t.id
        save()
    }

    private func deleteSelected() {
        guard let id = selection, let i = tools.firstIndex(where: { $0.id == id }) else { return }
        tools.remove(at: i)
        selection = tools.indices.contains(i) ? tools[i].id : tools.last?.id
        save()
    }
}

private struct ToolForm: View {
    @Binding var tool: ToolDef
    let onChange: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $tool.name)
            Picker("Symbol", selection: $tool.symbol) {
                ForEach(symbolChoices.contains(tool.symbol) ? symbolChoices : [tool.symbol] + symbolChoices, id: \.self) { s in
                    Label(s, systemImage: s).tag(s)
                }
            }
            Picker("Shape", selection: $tool.shape) {
                ForEach(ToolShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ColorPicker("Color", selection: Binding(
                get: { Color(nsColor: tool.color) },
                set: { tool.colorHex = NSColor($0).hexString }), supportsOpacity: false)
            HStack {
                Slider(value: $tool.lineWidth, in: 1...8, step: 0.5) { Text("Line width") }
                Text("\(tool.lineWidth, specifier: "%.1f") pt").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Toggle("Dashed line", isOn: $tool.dashed)
            Picker("Fill", selection: $tool.fill) {
                ForEach(ToolFill.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Intent, as Claude reads it", text: $tool.intent, axis: .vertical)
                .lineLimit(2...4)
            Toggle("Ask me for words when I draw it", isOn: Binding(
                get: { tool.ask != nil },
                set: { tool.ask = $0 ? (tool.ask ?? "What should it say?") : nil }))
            if tool.ask != nil {
                TextField("The question", text: Binding(get: { tool.ask ?? "" }, set: { tool.ask = $0 }))
                Picker("Show the words", selection: $tool.placement) {
                    ForEach(TextPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            TextField("Shortcut key", text: Binding(
                get: { tool.shortcut },
                set: { tool.shortcut = String($0.lowercased().suffix(1)) }))
                .frame(width: 200)
            Section("Preview") {
                ToolPreview(tool: tool)
                    .frame(height: 110)
            }
        }
        .formStyle(.grouped)
        .onChange(of: tool) { _, _ in onChange() }
    }
}

private struct ToolPreview: NSViewRepresentable {
    let tool: ToolDef

    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ v: PreviewView, context: Context) {
        v.tool = tool
        v.needsDisplay = true
    }

    final class PreviewView: NSView {
        var tool: ToolDef?
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            guard let t = tool else { return }
            var m = Mark(kind: .tool(t))
            m.rect = CGRect(x: 40, y: 22, width: 180, height: 52)
            m.text = t.ask == nil ? "" : "Sample words"
            switch t.shape {
            case .arrow, .line:
                m.start = CGPoint(x: 40, y: 80)
                m.end = CGPoint(x: 220, y: 30)
            case .boxArrow:
                m.rect = CGRect(x: 30, y: 30, width: 90, height: 44)
                m.end = CGPoint(x: 300, y: 52)
            case .pen:
                m.points = stride(from: 0.0, to: 200.0, by: 4).map { CGPoint(x: 40 + $0, y: 52 + sin($0 / 18) * 22) }
            case .text:
                m.rect = CGRect(x: 40, y: 34, width: 0, height: 0)
                m.text = "Sample note"
            default: break
            }
            MarkDrawing.draw(m, number: 1, selected: false)
        }
    }
}
