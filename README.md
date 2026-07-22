# ClipDeck

A fast, native macOS clipboard manager that lives in your menu bar. Everything you copy is saved, searchable, and one keystroke away, and there's exactly **one idea** to learn.

---

## Download

**[Download ClipDeck 1.0.0](https://github.com/jaintarun/clipdeck/releases/latest)** for macOS 13 or later.

The app is signed and notarized by Apple, so it opens with a normal double-click, no security warnings. Unzip it, drag **ClipDeck** into your Applications folder, and launch it. On first run, grant Accessibility permission (System Settings, Privacy and Security, Accessibility) so it can paste for you.

---

## The mental model

ClipDeck has a single idea at its core. Learn this and the whole app falls into place:

> ### The highlighted (blue) clip **is** your clipboard.

Once that clicks, everything else is obvious:

- Your clipboard **history is a list.** The **blue** row is what's on your clipboard *right now*.
- **Select a clip and it becomes your clipboard.** Move the highlight with ↑ / ↓ (or click), and browsing *is* loading. There is no separate "copy this one" step.
- Press **Return** to paste the highlighted clip straight into the app you were just using.
- Press **Escape** to close ClipDeck and stay right where you were.
- Text clips are **editable in place**: click into the preview, change the text, and the clip updates. `⌘⏎` pastes your edit immediately.

You're not managing a database. You're scrolling through your own clipboard, and whatever is blue is live.

---

## How it compares

ClipDeck is:

- **Fast.** Native AppKit and SQLite; your whole history opens and searches in a fraction of a second.
- **Free.** No price, no upgrade prompts.
- **Open source.** The entire app is right here to read, build, and fork.
- **Uncluttered.** A menu-bar icon and a keyboard-first palette, not a busy dashboard.
- **Private.** Everything stays on your Mac: no account, no sync, no telemetry.

That puts it in the same camp as [Maccy](https://maccy.org), which is also free and open source. What ClipDeck adds on top:

- **Editable clips.** Fix a typo or trim a URL right in the preview, and the clip updates. Minimalist managers are usually read-only.
- **Combine clips.** Select several text clips and *Append to new item* fuses them into one.
- **Search inside screenshots.** Images are run through OCR, so a search matches the text *in the picture*, not just the title.
- **A browsing window, not just a popup.** A preview pane, smart views (Today, This Week, Images), a protected **Safe** collection, and a **Trash** so nothing disappears by accident.

And unlike the paid, closed-source options (**Paste**, which syncs via iCloud, and **Pastebot**, which adds transformation filters), ClipDeck is free, open, and stays entirely on your machine.

---

## Summon it from anywhere

Press **⌃⌥⌘V** (Control-Option-Command-V) in any app. ClipDeck pops up over whatever you're doing. Start typing to search your whole history, then hit **Return** to paste. The panel never steals focus from the app behind it, so the paste lands exactly where your cursor was.

The hotkey is configurable:

```bash
defaults write com.clipmateclone.app hotkeyKeyCode -int 9      # the key
defaults write com.clipmateclone.app hotkeyModifiers -int 6400 # ⌃⌥⌘
```

---

## Keyboard-first

| Key | Action |
|-----|--------|
| **⌃⌥⌘V** | Summon ClipDeck |
| **↑ / ↓** | Move the highlight; *the highlighted clip becomes your clipboard* |
| **Return** | Paste the highlighted clip into your previous app |
| **Escape** | Dismiss |
| *type* | Search your entire history |
| **⌘T** | Move the clip to the top of the list |
| **⌫** | Move a clip to Trash |
| **⌥⌫** | Delete a clip permanently |
| **⌘R** | Rename a clip (main window) |
| **⌘F** | Jump to the search field (main window) |
| **⌘⏎** | While editing a text clip, paste the edited text |

---

## What it keeps, and how it protects it

- **Everything you copy**: plain text, rich text, images, and file references. Screenshots are run through OCR, so you can **search for text *inside* a picture**.
- **Safe** is a protected collection that is never auto-cleaned. Drag a clip in (or "Move to Safe") and it stays forever, filed at the bottom so Safe reads top-down like a notebook.
- **Trash** holds deletions first (kept ~6 days) so nothing disappears by accident. Empty it yourself whenever you like.
- **Smart views**: Today, This Week, Images, and Everything, computed on the fly.
- A rolling storage budget keeps the database lean without you ever thinking about it.

**Nothing is ever deleted silently.** The only ways a clip leaves for good are: you empty the Trash, you permanently delete it (`⌥⌫`), or it ages out of the Trash.

---

## Private by design

- **Zero network.** ClipDeck makes no connections: not for sync, not for telemetry, not even to fetch its icon. Your clipboard never leaves your Mac.
- Everything lives in a single local **SQLite** database in your Application Support folder.
- **Logs never contain** clip contents, titles, or your search text.
- The only "open" ClipDeck ever performs is following a source URL *you* click, never on its own.

---

## Under the hood

- **Swift 6.2**, strict concurrency, warnings-as-errors.
- An **AppKit** menu-bar app (`LSUIElement`: no Dock icon, no window clutter).
- **GRDB / SQLite** in WAL mode, with a full-text search index and a versioned, append-only migration chain.
- Pasting uses the macOS **Accessibility** API to fire `⌘V` into the frontmost app, so a clip lands exactly where you're typing.

---

## Build & run

Requires **macOS 13+** (Ventura) and a **Swift 6.2** toolchain (Xcode 16).

```bash
git clone https://github.com/jaintarun/clipdeck.git
cd clipdeck
swift build
./Scripts/bundle.sh          # builds and code-signs the app into build/
open build/ClipMate.app
```

On first launch, grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility) so ClipDeck can paste for you. Without it, ClipDeck still copies to your clipboard; you just press `⌘V` yourself.

Run the test suite with:

```bash
swift test
```

---

## Status

A personal project, built in the open with [Claude Code](https://claude.com/claude-code). Written from scratch and **independent. Not affiliated with, or derived from, the commercial "ClipMate" product.**
