# UandI

Mark up any part of the screen and send it straight to a Claude Code session. No screenshot, no Preview, no copy and paste.

## Use

- Click **U&I** in the menu bar. The screen freezes.
- Drag a box around the part you want to change.
- Mark it with the tools: Remove, Wording, Button, Move, Copy+move, Pen, Note, Red frame, or your own.
- **Select (V)** moves marks. It also picks any part of the frozen screen, even outside the box: ⌘C copies it and ⌘V pastes it into the box.
- Click **Send** (or press Return) for the last session, or **▾** to pick a session.
- **Copy** puts the picture and the words on the clipboard. **Discard** (or Esc) closes.

Each palette has a ⋯ menu for Orientation (Vertical or Horizontal) and Size (Large or Small). Drag a palette by its dotted corner. Right-click the menu bar icon for **Edit tools…**.

## What a session receives

Two pictures (marked and clean) saved in `~/.uandi/markups/<time>/`, and a numbered list. Each line gives the tool's intent, your words, where the mark is, and the words found under it.

## Parts

- `app/` is the menu bar app (Swift). `./build.sh` builds it, signs it, installs it to `~/Applications/UandI.app` and starts it. The first use asks for Screen Recording permission.
- `mod/` is the Claude Code add-on. Each session that loads it shows up in the Send menu. When a markup arrives, it starts a turn as soon as the session is idle. It was installed with:

```
claude plugin marketplace add ~/Documents/GitHub/UandI/mod
claude plugin install uandi@uandi-local --scope user
```

Your tools are saved in `~/.uandi/tools.json`.

For checking the look without clicking: `UandI --demo <picture.png>` opens the overlay on a saved picture, with sample marks.
