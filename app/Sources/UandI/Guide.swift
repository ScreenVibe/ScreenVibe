import AppKit

/// The guide Claude reads once per chat, so each markup can stay short. Rewritten whenever the tools change.
enum Guide {
    static var url: URL { Output.root.appendingPathComponent("UandI-guide.md") }

    static func write() {
        try? FileManager.default.createDirectory(at: Output.root, withIntermediateDirectories: true)
        try? text().write(to: url, atomically: true, encoding: .utf8)
    }

    static func text() -> String {
        var s = """
        # How to read a UandI markup

        UandI is a menu bar app. The user freezes the screen, drags a box around part of it, marks it up with tools, and sends it to this chat. Each markup asks you to change the UI shown in the picture.

        ## What each markup holds

        - **Marked picture**: the boxed area with the marks drawn on it. Each mark has a numbered circle.
        - **Clean picture**: the same area with no marks, so you can see what is under them.
        - **App, Window, URL, Document**: what was in front when the screen froze: the app, its window title, the web address when it is a browser, and the open file when the app reports one. Each appears only when UandI could tell.
        - **Under the picture**: the app under the picture, when it is not the front app.
        - **Note**: the user's note about the whole markup, when there is one.
        - **Numbered lines**: one for each mark, matching the numbers in the marked picture.

        ## Reading a line

        `3. Wording: “Save”. Area 30,130 140×40. Words there: “Submit”.`

        - The tool's name comes first. It says what the user wants; each tool's meaning is under The tools below.
        - Words in quotes after the name are the user's answer to the tool's question, such as the new wording or a button's label.
        - Positions are in points from the top-left corner of the pictures, written `x,y width×height`. The markup says how many pixels make a point ("saved at 2×").
        - `→` points to where a Move or Copy+move goes. When the size there differs from the area's size, the piece should take the new size.
        - `Note:` at the end of a line is the user's own note on that mark. It adds to what the tool means.
        - "Words there" is text UandI read from the clean picture inside the mark. Use it to find the element in the code. It can contain small reading mistakes.

        ## The tools


        """
        for t in ToolStore.shared.tools {
            var intent = t.intent.trimmingCharacters(in: .whitespaces)
            while intent.hasSuffix(".") || intent.hasSuffix(":") { intent.removeLast() }
            var line = "- **\(t.name)**: \(look(of: t)). The request: “\(intent)”"
            line += t.ask.map { ", followed by the user's answer to “\($0)”." } ?? "."
            s += line + "\n"
        }
        s += """
        - **Pasted piece**: a part of the screen the user copied, sometimes from outside the box, and placed here. Put that content here.

        ## How to act

        - Find the code that draws this screen. Use the URL, document, window title, the words in the marks and the project you are working in.
        - Make each numbered change. Change nothing that is not marked.
        - Remove has no words on purpose: the highlighted thing goes away.
        - If a mark is unclear, or two marks disagree, ask before changing anything.
        - When you are done, say what you changed for each number.
        - If you can look at the running app, compare the result with the marked picture.

        """
        return s
    }

    private static func look(of t: ToolDef) -> String {
        var parts: [String] = []
        switch t.shape {
        case .box: parts.append("a box")
        case .oval: parts.append("an oval")
        case .arrow: parts.append("an arrow")
        case .boxArrow: parts.append("a box with an arrow to a dashed box where it goes")
        case .pen: parts.append("a free drawing")
        case .text: parts.append("a note bubble")
        }
        if t.dashed && t.shape != .boxArrow { parts.append("dashed") }
        if t.fill == .stripes { parts.append("striped") }
        if t.fill == .tint { parts.append("lightly filled") }
        parts.append("in \(t.colorHex)")
        if t.ask != nil && t.placement == .inside { parts.append("with the words inside it") }
        return parts.joined(separator: ", ")
    }
}
