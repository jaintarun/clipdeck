import AppKit
import ClipMateCore

/// The menu bar item — our translation of ClipMate's ClipBar. Same job
/// (always-visible current clip, one click to the list), native mechanism.
///
/// NSObject + NSMenuDelegate because the blocklist item's title depends on
/// which app you were just in, so it must be rebuilt each time the menu opens.
///
/// @MainActor: built and driven entirely from the main thread (constructed by
/// AppDelegate, its actions fire from AppKit's main-thread event loop).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let engine: CaptureEngine
    private let tracker: TargetTracker
    private let store: ClipStore
    private let paste: PasteService

    /// Rebuilt on every menu open. Held so menuNeedsUpdate can remove the
    /// previous batch before inserting the current one.
    private var recentItems: [NSMenuItem] = []
    private let onOpenExplorer: () -> Void
    private let onShowPanel: () -> Void

    private let onExplainAccessibility: () -> Void

    private let currentClipItem = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "Capture Enabled", action: nil, keyEquivalent: "")
    /// G9: one-shot skip — for copying a secret without pausing capture and
    /// forgetting to unpause.
    private let ignoreNextItem = NSMenuItem(title: "Ignore Next Copy", action: nil, keyEquivalent: "")
    /// Feature 1: plain-by-default fidelity. ⌥ on any paste/copy inverts.
    private let plainPasteItem = NSMenuItem(title: "Paste Plain Text by Default", action: nil, keyEquivalent: "")
    private let blockItem = NSMenuItem(title: "Never Capture From This App", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    /// AMEND-7. Persistent, quiet attention state instead of a launch nag.
    private let accessibilityItem = NSMenuItem(
        title: "⚠︎ Auto-paste needs Accessibility…", action: nil, keyEquivalent: "")

    /// The app blockItem currently refers to. Recomputed on menuNeedsUpdate.
    private var blockCandidate: String?

    init(
        store: ClipStore,
        paste: PasteService,
        engine: CaptureEngine,
        tracker: TargetTracker,
        onOpenExplorer: @escaping () -> Void,
        onShowPanel: @escaping () -> Void,
        onExplainAccessibility: @escaping () -> Void
    ) {
        self.store = store
        self.paste = paste
        self.engine = engine
        self.tracker = tracker
        self.onOpenExplorer = onOpenExplorer
        self.onShowPanel = onShowPanel
        self.onExplainAccessibility = onExplainAccessibility
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "ClipDeck"
        )
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Near the top so it's the first thing seen while auto-paste is dead.
        // Hidden entirely once granted — this is an attention state, not a nag.
        accessibilityItem.action = #selector(explainAccessibility)
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        currentClipItem.isEnabled = false
        menu.addItem(currentClipItem)
        menu.addItem(.separator())

        // The shortcut shown here is honest: the global ⌃⌥⌘V hotkey (Task 8's
        // Carbon registration) really opens the Explorer. The glyph is purely
        // informational — a status-menu key equivalent doesn't fire for an
        // LSUIElement app — so it must sit on the item the hotkey actually
        // triggers, which is now this one.
        let openItem = NSMenuItem(title: "Open ClipDeck…", action: #selector(openExplorer), keyEquivalent: "v")
        openItem.keyEquivalentModifierMask = [.control, .option, .command]
        openItem.target = self
        menu.addItem(openItem)

        // No shortcut shown: the Quick Panel has no registered hotkey now that
        // ⌃⌥⌘V opens the Explorer. Printing a shortcut we don't register would
        // be a lie.
        let panelItem = NSMenuItem(title: "Show Quick Panel", action: #selector(showPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(.separator())


        captureItem.action = #selector(toggleCapture)
        captureItem.target = self
        captureItem.state = engine.isCapturing ? .on : .off
        // G9: the toggle is restored from defaults before this runs — the
        // icon must reflect a paused relaunch, not just a live toggle.
        statusItem.button?.appearsDisabled = !engine.isCapturing
        menu.addItem(captureItem)

        ignoreNextItem.action = #selector(ignoreNextCopy)
        ignoreNextItem.target = self
        menu.addItem(ignoreNextItem)

        plainPasteItem.action = #selector(togglePlainPaste)
        plainPasteItem.target = self
        plainPasteItem.state = PastePreference.plainByDefault ? .on : .off
        menu.addItem(plainPasteItem)

        blockItem.action = #selector(toggleBlockCandidate)
        blockItem.target = self
        menu.addItem(blockItem)

        loginItem.action = #selector(toggleLoginItem)
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ClipDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Fires each time the menu opens, which is the only moment the blocklist
    /// item's target app is knowable.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Recomputed every open: the grant can be revoked at any time, and
        // granting it should make this disappear without a relaunch.
        accessibilityItem.isHidden = PasteService.isAccessibilityTrusted

        // Recomputed every open: the user can flip this in System Settings →
        // General → Login Items (or SMAppService can move to
        // .requiresApproval) without going through us, so a cached checkmark
        // would keep lying until relaunch.
        loginItem.state = LoginItem.isEnabled ? .on : .off

        // Recomputed every open: the engine consumes the one-shot flag when
        // the ignored copy arrives, and the checkmark must clear with it.
        ignoreNextItem.state = engine.ignoreNextChange ? .on : .off

        rebuildRecents(in: menu)

        // tracker.current is the last app that wasn't us — exactly the app the
        // user was in before reaching for the menu bar.
        blockCandidate = tracker.current?.bundleIdentifier
        let name = tracker.current?.localizedName

        if let blockCandidate, let name {
            blockItem.title = "Never Capture From \(name)"
            blockItem.state = engine.blocklist.contains(blockCandidate) ? .on : .off
            blockItem.isEnabled = true
        } else {
            blockItem.title = "Never Capture From This App"
            blockItem.state = .off
            blockItem.isEnabled = false
        }
    }

    /// The top few clips, directly in the status menu — ClipBar's dropdown,
    /// reinterpreted. Rebuilt per open because the history changes constantly.
    private func rebuildRecents(in menu: NSMenu) {
        for item in recentItems { menu.removeItem(item) }
        recentItems = []

        let clips: [Clip]
        do {
            clips = try store.recentClips(limit: 8)
        } catch {
            // Never silent (guide 5.3). A failed read must not masquerade as
            // an empty history.
            NSLog("[ClipMate] recent clips read failed: \(error)")
            return
        }
        guard !clips.isEmpty else { return }

        // Recents must land below the header, not at index 0: accessibilityItem
        // has to stay the first thing seen while auto-paste is dead, and
        // currentClipItem shouldn't be buried under a list that duplicates it.
        let headerIndex = menu.index(of: currentClipItem)
        guard headerIndex != -1 else { return }
        var index = headerIndex + 2 // past currentClipItem and its separator

        for clip in clips {
            guard let id = clip.id else { continue }
            let item = NSMenuItem(
                title: Self.menuTitle(clip.title),
                action: #selector(recentClipClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = id
            menu.insertItem(item, at: index)
            recentItems.append(item)
            index += 1
        }
        let sep = NSMenuItem.separator()
        menu.insertItem(sep, at: index)
        recentItems.append(sep)
    }

    /// Menus are not text views: a long clip would stretch the menu across the
    /// screen, and an embedded newline would break the row.
    private static func menuTitle(_ raw: String) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
                      .replacingOccurrences(of: "\r", with: " ")
                      .trimmingCharacters(in: .whitespaces)
        return flat.count <= 48 ? flat : String(flat.prefix(47)) + "…"
    }

    @objc private func recentClipClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        do {
            // Copy only, never auto-paste: clicking this menu already took
            // focus, so the app the user was in is no longer frontmost and
            // TargetTracker would name the wrong one.
            try paste.copyToPasteboard(clipID: id, fidelity: PastePreference.currentFidelity())
        } catch {
            // Never silent (guide 5.3).
            NSLog("[ClipMate] menu copy failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't copy that clip"
            alert.informativeText = (error as? PasteError)?.userMessage ?? error.localizedDescription
            alert.runModal()
        }
    }

    func refresh(currentClipTitle: String?) {
        if let title = currentClipTitle, !title.isEmpty {
            let short = title.count > 40 ? String(title.prefix(40)) + "…" : title
            currentClipItem.title = "Recent: \(short)"
        } else {
            currentClipItem.title = "No clips yet"
        }
    }

    @objc private func openExplorer() { onOpenExplorer() }
    @objc private func showPanel() { onShowPanel() }
    @objc private func explainAccessibility() { onExplainAccessibility() }

    @objc private func toggleCapture() {
        engine.isCapturing.toggle()
        captureItem.state = engine.isCapturing ? .on : .off
        statusItem.button?.appearsDisabled = !engine.isCapturing
        // G9: survive relaunch — a pause before handling secrets must not be
        // silently undone by a restart.
        UserDefaults.standard.set(engine.isCapturing, forKey: AppDelegate.captureEnabledKey)
    }

    /// One-shot skip; toggleable so a mis-click can be undone before the copy.
    @objc private func ignoreNextCopy() {
        engine.ignoreNextChange.toggle()
    }

    @objc private func togglePlainPaste() {
        UserDefaults.standard.set(!PastePreference.plainByDefault,
                                  forKey: PastePreference.plainByDefaultKey)
        plainPasteItem.state = PastePreference.plainByDefault ? .on : .off
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            loginItem.state = LoginItem.isEnabled ? .on : .off
        } catch {
            // Never silent (spec §9).
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleBlockCandidate() {
        guard let blockCandidate else { return }
        if engine.blocklist.contains(blockCandidate) {
            engine.blocklist.remove(blockCandidate)
        } else {
            engine.blocklist.insert(blockCandidate)
        }
        BlocklistStore.save(engine.blocklist)
    }
}
