# Dogfood notes

Running log of friction found by actually using ClipMate. Per the master guide Part 6.3,
**this file is the backlog** — Part 4's census supplies the verdicts, these notes supply the
priorities. Add anything: "reached for ⌘V because…", "wanted to keep a clip and couldn't…",
"copied a file and nothing happened".

L1 dogfood bar (guide Part 6.2): *"I use it daily for a week and never reach for ⌘V."*
Week started **2026-07-17** — the first day paste worked end-to-end.

---

## Found before the week started

These came out of building and first-run testing rather than daily use. Recorded because they
are real findings and they already reorder the roadmap.

### 1. Accessibility grant silently died on every rebuild — FIXED (commit 8990c9d)
System Settings showed the toggle ON while the app insisted it had no permission. TCC pins a
grant to the app's *designated requirement*, and an ad-hoc signature's requirement is the
binary's own `cdhash` — so every rebuild invalidated the grant while the UI kept claiming it was
fine. `bundle.sh` now signs with a codesigning identity when one exists, and warns loudly when
it has to fall back to ad-hoc.

**Deviation from guide Part 6.6** ("ad-hoc signed local bundle through L2"), taken deliberately:
that line assumed ad-hoc preserved the grant. It does not. This is still a local bundle — no
Developer ID distribution, no notarization. Revisit only when something leaves this machine.

### 2. A healthy database was reported as corrupt on launch — FIXED (commit 34774d5)
`PRAGMA auto_vacuum` ran on read-only pool connections, throwing SQLite error 8 on every read;
the blanket catch then quarantined a perfectly good history and told the user it was corrupted.
Tests missed it because they use `DatabaseQueue` (one read-write connection) while production
uses `DatabasePool` (read-only readers).

### 3. The look and feel is not polished — OPEN, deliberately deferred
Stated 2026-07-17: the target is a modern, polished native macOS app; the current UI is plain
AppKit with default rows and no visual hierarchy. Sequencing is the user's explicit call —
**features first, polish after.** Not a defect to fix mid-feature; a tranche of work to schedule
once functionality lands. The surfaces that matter are the QuickPanel and the Explorer.

---

## L1.5 manual gates — need a human, not a test

The code review passed clean, but five things in L1.5 are honestly untestable in-process (guide
5.5): they need real hardware, a real app switch, and a real sleep. **L1.5 is not "done" until
these are checked off.** Rebuild first (`./Scripts/bundle.sh && open build/ClipMate.app`).

- [ ] **Files paste back into Finder.** Copy 2-3 files in Finder → open the panel (⌃⌥⌘V) → the
      clip should read "3 files" → paste it into another Finder window. The files should land.
      Then copy the *same* selection again — history should bump it, not add a second row.
- [ ] **Menu recents.** Click the menu-bar icon: up to 8 recent titles, newest first. Clicking one
      copies it (no auto-paste from a menu, by design). The accessibility warning, if shown, must
      still be the first thing visible — not pushed below the clips.
- [ ] **Sleep/wake.** Copy something → sleep the Mac → wake it → copy something new. The new copy
      must be captured. Nothing copied *while asleep* should be silently lost.
- [ ] **Hijack cancel.** Open the panel, then Cmd-Tab to a different app before pressing Enter.
      It must refuse to paste rather than firing ⌘V into whatever app you landed on.
- [ ] **Hotkey override.** `defaults write com.clipmateclone.app hotkeyKeyCode -int 8` and
      `defaults write com.clipmateclone.app hotkeyModifiers -int 6400`, relaunch → ⌃⌥⌘**C** now
      opens the panel. `defaults delete` both keys to go back to ⌃⌥⌘V.
      (6400 = controlKey|optionKey|cmdKey. An earlier draft of this gate said 3840 — that value
      is wrong, it has no control bit, and it would have made a working feature look broken.)

---

## L2a manual gates — need a human, not a test

L2a (collections, retention cascade, storage caps, the sidebar, filing, Trash) passed its code
review clean and its final whole-branch review returned **MERGE**. But the UI paths and the
destructive-adjacent actions are honestly untestable in-process (guide 5.5): they need a real
window, a real drag, and a real click on a permanent-delete button. **L2a is not "done" until
these are checked off.** Rebuild first (`./Scripts/bundle.sh && open build/ClipMate.app`).

The L2 dogfood gate this all serves (defined before implementation, guide Part 6.2):
> **"My clips are organized the way I'd organize files, and I trust the app not to lose one."**

**Collections (Task 6):**

- [ ] **Create / rename / nest.** Open ClipMate (Explorer window) → make a collection, rename it,
      drag or nest one collection inside another. Restart the app → the tree is exactly as left.
- [ ] **Deleting a collection never loses a clip.** File a clip into a user collection, then delete
      that collection. Its clips must appear in **Trash**, not vanish. If the collection had nested
      children, the confirmation must say so ("deletes N nested collection(s)").
- [ ] **System collections are protected.** Try to rename InBox → the option is not offered at all
      (no disabled control that errors on click).
- [ ] **Rename-cancel actually reverts.** Double-click a collection, **type a new name**, press
      Escape. It must REVERT to the old name, not commit the half-typed one. (Escape with *no*
      change proves nothing — commit and revert look identical there. This is a known-unverified
      Minor; this gate is the only thing that can settle it.)

**Filing and Trash (Task 7):**

- [ ] **Drag to file.** Drag a clip from the list onto a collection in the sidebar → it leaves
      InBox and appears there. Drag onto Trash → it lands in Trash.
- [ ] **Restore.** Select Trash → Restore a clip → it returns to InBox (and its retention clock
      restarts, so it is not instantly re-trashed).
- [ ] **Filing survives a re-copy.** Copy the same content again → it bumps **where it is filed**;
      it does NOT jump back to InBox.
- [ ] **Empty Trash asks first.** The Empty Trash button must show a confirmation stating the count
      and that it cannot be undone — then really remove them. It must **never** fire on quit
      (ClipMate 5 wiped Trash on quit and users hated it).
- [ ] **Permanent delete asks first.** In Trash, right-click a clip → "Delete Immediately…" must
      confirm before it's gone. Outside Trash, the same Delete must move the clip to Trash
      (recoverable), not destroy it.
- [ ] **Dragging never pollutes the clipboard.** Throughout all of the above, confirm that dragging
      a clip never inserts anything new into the clipboard history — a drag is not a copy.

**Cascade and caps (acceptance checklist — needs the human to watch it happen):**

- [ ] **The cascade is visible, not silent.** Shrink InBox's budget, copy past it → clips land in
      Trash, they do not vanish.
- [ ] **Trash's grace is real.** A clip trashed today is still there tomorrow (6-day grace).
- ~~**Kept survives everything.** Pin a clip (⌘P), blow every budget → it stays.~~ —
      REMOVED 2026-07-21 (Task 2: Keep deleted entirely; Safe is now the only
      protection mechanism, already covered by the Safe + retention-sweep
      gates below).
- [ ] **Zero network connections** while all of this runs (guide 5.2 — verify with Little Snitch or
      `nettop`; the code review already grepped the source clean, this is the live confirmation).

_(Upgrade path was already verified automatically on 2026-07-17 against a copy of the real 11-clip
database — all 11 filed into InBox, FTS intact, no clip lost. That box does not need re-running.)_

---

## L2b manual gates — need a human, not a test

Rich capture, source URL, and rename touch AppKit and the real pasteboard, so they live here.

- [ ] **Rich text previews as plain text.** Copy a formatted selection from a web page (Safari) or
      Word, open the Explorer → the preview shows readable plain text, never raw markup, and shows at
      most a small format switcher (no duplicate identical tabs).
- [ ] **Rich paste keeps its formatting.** Paste that same clip into TextEdit or Mail → the
      formatting survives (the original RTF/HTML is relayed).
- [ ] **No web engine ever runs.** The HTML preview is inert — no images load, no layout, no network
      (guide §5.4). Plain text only.
- [ ] **Source URL shows and opens.** Copy a link/selection from Safari that carries a page URL →
      the preview shows the URL in link color; clicking it opens the page in the default browser. A
      clip with no source URL shows no URL row.
- [ ] **Source URL never leaks.** A Finder file copy shows no source URL (only a real web URL is
      kept); nothing about the URL appears in Console logs.
- [ ] **Rename commits.** Select a clip, ⌘R → the title becomes editable; type a new name, Return →
      the list shows it and it survives reopening the Explorer; searching the new title finds it.
- [ ] **Rename-cancel gate.** ⌘R, edit, then Escape → the title reverts to the original and nothing
      is written.
- [ ] **⌘R doesn't collide.** ⌘R with the sidebar focused still renames the *collection*; ⌘R with
      the clip list focused renames the *clip*.

---

## L2b.2 manual gates — need a human, not a test

Edit and combine touch AppKit and the real pasteboard.

- [ ] **Plain-text clips edit like a notepad.** Select a plain-text clip, click
      into the preview and type; **Return inserts a newline** (no save prompt).
      Click a different clip → the edit is saved: the list title updates, it
      survives reopening the Explorer, and searching the new text finds it.
- [ ] **Edited text is the clipboard when you leave.** Edit a plain-text clip,
      then switch to a text editor (ClipMate loses focus) and ⌘V → the EDITED
      text pastes, not the old text. Same via **Escape**: it commits, hides the
      app, and the edited text is on the clipboard for ⌘V.
- [ ] **No change, no write.** Click into a plain-text clip's preview and click
      away without typing → nothing changes (title, content, and search intact).
- [ ] **Formatted clips are read-only.** A clip copied from Safari/Word (shows as
      plain text) cannot be typed into — the cursor doesn't edit it, so its
      formatting is safe. Same for image clips.
- [ ] **Capture mid-edit doesn't clobber.** Start typing in a plain-text clip,
      copy something new in another app → your in-progress text is NOT discarded;
      the new clip shows up after you click away.
- [ ] **Append to new item.** Select 2+ text clips, right-click → "Append to new
      item" → a new clip appears holding all their text (newline-separated, top
      row first), the originals stay put, and the new clip is on the clipboard.
- [ ] **Append is multi-only.** Right-click a single clip → no "Append to new
      item" item.
- [ ] **Append is text-only.** Select a mix of text and an image, append → the
      result is plain text with the image skipped; nothing about it is a picture.

---

## UI Polish 2 manual gates — need a human, not a test

- [ ] **Close hides, never quits.** Red close button → app vanishes; hotkey
      brings it back with state intact; nothing quit.
- [ ] **Search feels instant.** ⌘F, type — results filter live across ALL
      collections; Escape once clears, Escape again hides the window.
- [ ] **Edit-in-place unchanged.** Plain-text clips still edit like a notepad
      inside the new card; blur/Escape/app-switch still put the EDITED text on
      the clipboard.
- [ ] **File clips show their files.** A Finder/CleanShot file copy previews as
      icon + name + path rows; the paths are right; nothing loads file
      contents (no beachball on a huge file).
- [ ] **Capture slides in.** Copy in another app with the Explorer visible —
      the new row slides in at top, selected and blue.
- [ ] **Selection is blue after ClipMate's own copy.** Click a row (which puts
      it on the clipboard) — the row is BLUE, not gray (fix(core) this tranche;
      the machine-verified tests cover the hash, this covers the pixels).
- [ ] **Nothing pollutes the clipboard.** Toolbar search, sidebar toggle,
      empty states, Trash bar — none of them change what ⌘V pastes.
- [ ] **Dark mode.** Flip appearance — every pane, card, and empty state
      follows; no unreadable text.
- [ ] **Wide and narrow windows.** At the 900pt minimum all five columns fit
      with full dates; widened to ~1400 only Title grows; nothing truncates
      that didn't before.

---

## Maccy robustness — manual gates (2026-07-18)

- [ ] **First paste after this build works.** Panel Enter or Explorer
      double-click lands in the target app. This is the live gate for the
      G5/G6 posting rewrite (layout-aware keycode, local-event suppression,
      0x000008 flag, session tap) — the mechanics are verbatim
      Maccy/Clipy/Flycut and unit-tested, but only a real paste proves the
      chord still lands. If it ever misses: the clip is on the clipboard,
      ⌘V by hand, and file the miss here.
- [ ] **Pasting from RDP/remote-desktop sessions** (if ever used): the
      0x000008 scan-code bit exists for exactly this — worth one try.
- [ ] **QuickPanel dismisses on outside click** and opens on the screen the
      pointer is on, fully on-screen.
- [ ] **Pause capture, quit, relaunch** — capture stays paused (G9).

---

## PowerPaste tranche — manual gates (2026-07-18)

- [ ] Plain default: copy formatted text from a browser; panel-Enter into TextEdit pastes PLAIN. ⌥Enter pastes formatted. Toggle "Paste Plain Text by Default" off and the two invert.
- [ ] File clip with plain default ON still pastes as real files in Finder (the Maccy #962 guard).
- ~~PasteStack~~ — REMOVED 2026-07-18 (user verdict after trial: too complicated; feature deleted entirely).
- [ ] Append source: multi-select clips → "Append to new item" → the combined clip's source shows ClipMate (not a bare dash).
- [ ] OCR: screenshot something with visible text (⇧⌘4) → within ~a second the clip's title becomes the text and search finds it. Rename an image clip fast — the rename must stick.
- [ ] Rows: 30pt list with light zebra striping; nothing clipped; the blue clipboard row still reads over a stripe.
- [ ] Editing: Tab into the preview, type — a muted "Press ⌘⏎ to paste" hint appears in the header row WITHOUT anything in the pane moving or resizing; ⌘⏎ pastes exactly the edited text; plain Enter inserts newlines.
- [ ] Editing + app-switch: Cmd-Tab away while editing a clip in the preview (no Escape/click-away), copy something in another app, come back — the editing hint may still be showing and the new capture may not appear until you click into the window (pre-existing willResignActive gap; verifying its real-hardware impact).
- [ ] No reorder on paste: scroll down, Enter-paste an old clip — it stays exactly where it was in the list (re-COPYING it elsewhere still floats it to the top; that's dedupe, unchanged).

---

## Safe + retention-sweep gates (2026-07-18)

- [ ] Drag a clip from the list onto Safe in the sidebar → it files there.
- [ ] Right-click a clip → Move to → Safe is the FIRST item, separator below it → it files there.
- [ ] A clip in Safe survives sweeps and stays put for days.
- [ ] Trash contents disappear on their own within ~6 days without copying anything first (sweep runs every ~2 h; first fire ~60 s after launch).

---

## Week one

_(Add entries as they happen. Date each one. Raw is fine — this is a complaint log, not prose.)_

| Date | Friction | What I wanted instead |
|---|---|---|
| | | |

---

## Overflow removal + delete gestures (2026-07-19)

- [ ] Sidebar shows InBox / Trash / Safe — no Overflow anywhere.
- [ ] Select clips in Explorer, press ⌫ → they land in Trash.
- [ ] ⌥⌫ in the QuickPanel → highlighted clip is gone for real, instantly, no dialog; selection moves to the next row.
- [ ] ⌥⌫ in Explorer → same: instant permanent delete, no dialog.
- [ ] ⌫ on clips already in Trash → the Delete Immediately alert appears (pluralized for a multi-selection).
- [ ] (Windows keyboard) The dedicated Delete key does exactly what Backspace does in every gate above — Explorer plain + ⌥, panel ⌥. On a MacBook keyboard, fn+⌫ is the same test.

---

## Five-piece simplify (2026-07-21)

- [ ] Sidebar has no COLLECTIONS group and no "+" footer; right-click shows a single "Move to Safe".
- [ ] No "Kept" sidebar row; no Keep in the right-click menu; ⌘P in the panel does nothing.
- [ ] Trash sits alone at the sidebar's bottom-left, separated from the tree; clicking it shows Trash (Restore/Empty Trash work); the tree deselects.
- [ ] Dragging clips onto the bottom Trash anchor moves them to Trash; the anchor highlights during the drag.
- [ ] Move a clip to Safe → it appears at the BOTTOM of Safe; moving several keeps their order.
- [ ] Right-click → Move to Top (or ⌘T) in Explorer, and ⌘T in the panel → clip jumps to the top everywhere.
- [ ] Finder shows the ClipMate icon (clipboard on blue) on build/ClipMate.app; the About panel shows it too.
