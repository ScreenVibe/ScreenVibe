# ScreenVibe

Mark up any part of your screen and send it straight to a Claude Code session. No screenshot, no Preview, no copy and paste.

You freeze the screen, draw on it with tools that each mean something ("remove this", "change the wording to…", "move this there"), and press Send. The session gets the marked picture, a clean copy, what app and page you were looking at, and a short numbered list of what you asked for. Then it gets to work.

It is free and open source (MIT). It was built for one person's way of working; take it and make it yours.

## What it works with

- **Claude Code in the terminal.** This is what it is built and tested with.
- Claude Code in the desktop app or an IDE extension should work too, as long as the session runs on your Mac. Not tested yet.
- Sessions that run in the cloud (claude.ai/code on the web) can't receive markups: they can't see your Mac's files.
- Other AI apps: **Copy** puts the marked picture on the clipboard, so you can paste it anywhere. The words that come with it are written for Claude Code and point to files on your Mac.

Needs macOS 14 or newer.

## Install

You need the Xcode command line tools (`xcode-select --install`).

```
git clone https://github.com/cryptohanaan/ScreenVibe.git
cd ScreenVibe
./build.sh
```

That builds the menu bar app, installs it to `~/Applications/ScreenVibe.app` and starts it. It signs the app with your Apple developer certificate if you have one. Without one, macOS asks for the Screen Recording permission again after each rebuild.

Then add the Claude Code add-on:

```
claude plugin marketplace add cryptohanaan/ScreenVibe
claude plugin install screenvibe@screenvibe
```

In sessions that are already open, run `/reload-plugins`. Each session with the add-on shows up in ScreenVibe's Send menu.

## Use

- Click the **ScreenVibe** icon in the menu bar, or press ⌘⇧6. The screen freezes.
- The whole screen starts as the picture. To send less, pick **Crop (K)** and drag a box, or drag its edges and corners. Hold Space and drag to move the box, with any tool.
- Mark it with the tools: Remove, Wording, Button, Move, Copy+move, Pen, Note, Rect, Line, Arrow, Oval, or your own.
- Pick a color under the tools to color the next marks, or the selected mark. Click it again to go back to the tool's color. The message names the color, so your note can say what it means.
- Every mark has a round note button at its top-right corner. Click it to add a note for that mark.
- **Select (V)** moves marks. It also picks any part of the frozen screen, even outside the box: ⌘C copies it and ⌘V pastes it into the box.
- Click **Send** (or press Return). The Send window shows the picture and every numbered request, which you can edit, plus a box for a note about the whole markup and the session to send to. Return sends, Esc goes back to the markup.
- **Copy** puts the picture and the words on the clipboard. **Discard** (or Esc) closes.

Each palette has a ⋯ menu for Orientation (Vertical or Horizontal) and Size (Expanded, with names, or Condensed, symbols only). Drag a palette by its dotted corner. Right-click the menu bar icon for **Edit tools…** to change the tools or make new ones.

## Permissions

- **Screen Recording**, to freeze the screen. Asked on first use.
- **Accessibility**, to read the front app's window title and open file. Asked once, after your first markup.
- **Automation** of your browser, to read the address of the page you marked. Asked once per browser.

Only Screen Recording is required. Without the others, the markup just carries less context.

## Privacy

Everything stays on your Mac. Markups are saved in `~/.screenvibe/markups/` and read by your own Claude Code session. ScreenVibe itself sends nothing over the network. What the session does with a markup is up to Claude Code, like any prompt you type.

## How it works

The app and the add-on only share files in `~/.screenvibe/`:

1. Each Claude Code session with the add-on writes a small file to `~/.screenvibe/sessions/`, so the app can list it.
2. On Send, the app writes the pictures and the text to that session's folder in `~/.screenvibe/inbox/`.
3. The add-on checks its inbox and, when the session is idle, submits the markup as the next prompt.

How to read a markup is in `~/.screenvibe/ScreenVibe-guide.md`, which the app rewrites whenever the tools change. The first markup sent to a chat asks Claude to read it; later ones only name it. Your tools are saved in `~/.screenvibe/tools.json`.

## Make it yours

The code is small and plain. Where things live:

| File | What it does |
| --- | --- |
| `app/Sources/ScreenVibe/main.swift` | Menu bar icon, ⌘⇧6, start of a markup |
| `app/Sources/ScreenVibe/Overlay.swift` | The frozen screen, drawing, selecting, keys, the palettes' contents |
| `app/Sources/ScreenVibe/Marks.swift` | How each mark looks, and the colors |
| `app/Sources/ScreenVibe/Tools.swift` | The built-in tools and their meanings |
| `app/Sources/ScreenVibe/Palette.swift` | The floating palettes |
| `app/Sources/ScreenVibe/SendWindow.swift` | The Send window |
| `app/Sources/ScreenVibe/Output.swift` | The pictures and the text a session receives |
| `app/Sources/ScreenVibe/Guide.swift` | The guide Claude reads |
| `app/Sources/ScreenVibe/Context.swift` | Front app, window, file and web address |
| `mod/hooks/register.ts` | The Claude Code add-on |

Ideas people might build: an MCP server so other AI apps can fetch markups, a Copy that works well in web chats, more tools, Windows or Linux versions.

For checking the look without clicking: `ScreenVibe --demo <picture.png>` opens the overlay on a saved picture, with sample marks. `ScreenVibe --print-context` shows what ScreenVibe reads from the app in front after 3 seconds.

## License

MIT. See [LICENSE](LICENSE).
