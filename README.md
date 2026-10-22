# UandI

Mark up any part of the screen and send it straight to a Claude Code session. No screenshot, no Preview, no copy and paste.

## Use

- Click **U&I** in the menu bar, or press ⌘⇧6. The screen freezes.
- The whole screen starts as the picture. To send less, pick **Crop (K)** and drag a box, or drag its edges and corners. Hold Space and drag to move the box, with any tool.
- Mark it with the tools: Remove, Wording, Button, Move, Copy+move, Pen, Note, Red frame, or your own.
- Every mark has a round note button at its top-right corner. Click it to add a note for that mark.
- **Select (V)** moves marks. It also picks any part of the frozen screen, even outside the box: ⌘C copies it and ⌘V pastes it into the box.
- Click **Send** (or press Return). The Send window shows the picture and every numbered request, which you can edit, plus a box for a note about the whole markup and the session to send to. Return sends, Esc goes back to the markup.
- **Copy** puts the picture and the words on the clipboard. **Discard** (or Esc) closes.

Each palette has a ⋯ menu for Orientation (Vertical or Horizontal) and Size (Large or Small). Drag a palette by its dotted corner. Right-click the menu bar icon for **Edit tools…**.

## What a session receives

The front app, its window title, the web address (browsers) or the open file (document apps), two pictures (marked and clean) saved in `~/.uandi/markups/<time>/`, your note, and a short numbered list: the tool, the request, where the mark is, and the words found under it.

How to read all that is in `~/.uandi/UandI-guide.md`, which UandI rewrites whenever the tools change. The first markup sent to a chat asks Claude to read the guide; later ones only name it.

## Parts

- `app/` is the menu bar app (Swift). `./build.sh` builds it, signs it, installs it to `~/Applications/UandI.app` and starts it. The first use asks for Screen Recording permission.
- `mod/` is the Claude Code add-on. Each session that loads it shows up in the Send menu. When a markup arrives, it starts a turn as soon as the session is idle. It was installed with:

```
claude plugin marketplace add ~/Documents/GitHub/UandI/mod
claude plugin install uandi@uandi-local --scope user
```

Your tools are saved in `~/.uandi/tools.json`.

For checking the look without clicking: `UandI --demo <picture.png>` opens the overlay on a saved picture, with sample marks.

The app, window, address and file come from macOS Accessibility. UandI asks for it once, after your first markup closes. `UandI --print-context` shows what it reads from the app in front after 3 seconds.
