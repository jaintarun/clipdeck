import AppKit
import ClipMateCore

/// The daily driver.
///
/// .nonactivatingPanel is load-bearing: showing this window MUST NOT deactivate
/// the app behind it, or the paste target is lost before we can paste (spec §4).
///
/// @MainActor: an NSPanel driving live AppKit UI, constructed and driven
/// entirely from the main thread by AppDelegate.
@MainActor
final class QuickPanel: NSPanel {
    private let controller: QuickPanelViewController
    private let paste: PasteService
    private let tracker: TargetTracker

    init(store: ClipStore, paste: PasteService, tracker: TargetTracker) {
        self.paste = paste
        self.tracker = tracker
        self.controller = QuickPanelViewController(store: store)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        // Clear the window so the controller's NSVisualEffectView is what the
        // user sees — a frosted panel, not a flat gray box.
        isOpaque = false
        backgroundColor = .clear
        // A command palette has no window chrome: you dismiss it with Escape or
        // the hotkey, never with the traffic lights. Hide them but keep the
        // style mask (and thus the load-bearing key/nonactivating behavior).
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        // A transient palette belongs to the space you summoned it on —
        // .canJoinAllSpaces made it follow space switches like a pinned
        // window (Maccy's popup lineage settled on move-to-active, G10).
        collectionBehavior = [.moveToActiveSpace, .stationary, .fullScreenAuxiliary]
        contentViewController = controller

        controller.onPaste = { [weak self] id in self?.performPaste(id) }
        controller.onDismiss = { [weak self] in self?.orderOut(nil) }
    }

    /// A nonactivating panel is not key by default; we need typing to reach the
    /// search field, so opt in explicitly.
    override var canBecomeKey: Bool { true }

    /// Spotlight/Raycast behavior (G10): clicking anywhere else dismisses the
    /// palette instead of leaving a floating orphan. The modal guard keeps an
    /// alert (which steals key) from vaporizing the panel mid-interaction.
    override func resignKey() {
        super.resignKey()
        if NSApp.modalWindow == nil { orderOut(nil) }
    }

    /// ⌥⌫ permanently deletes the highlighted clip (spec 2026-07-19).
    /// Intercepted in sendEvent, NOT performKeyEquivalent: AppKit only
    /// routes Command chords through the key-equivalent chain, so an
    /// ⌥-only chord would reach the search field's editor first, where
    /// ⌥⌫ means "delete word backward". keyCode 51 is Delete (backspace);
    /// 117 is forward delete — the Delete key on Windows keyboards (fn+⌫
    /// on compact Mac keyboards) — treated identically by user request.
    /// Plain 51/117 stay with the search field for text editing.
    override func sendEvent(_ event: NSEvent) {
        // Compare only real chord modifiers — Caps Lock (and fn) state must not break the match.
        if event.type == .keyDown,
           event.keyCode == 51 || event.keyCode == 117,
           event.modifierFlags.intersection([.shift, .control, .option, .command]) == .option {
            controller.deleteSelectionPermanently()
            return
        }
        super.sendEvent(event)
    }

    /// ⌘T — Move to Top (spec 2026-07-21). Same key-equivalent route ⌘P used:
    /// the search field is first responder and owns plain keys; command
    /// chords arrive here first. Mask per the 2026-07-19 Caps Lock lesson.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "t" {
            controller.moveSelectionToTop()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { show() }
    }

    /// AMEND-5. Appear on the display the pointer is on — center() targets the
    /// wrong screen in multi-monitor use, and the hotkey is pressed where the
    /// user is working.
    func show() {
        controller.prepareForDisplay(targetName: tracker.current?.localizedName)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                        ?? NSScreen.main {
            let f = screen.visibleFrame
            // Clamped, not just centered: multi-monitor positioning is never
            // done (Maccy's literally-latest commit still fixes it — G10).
            setFrameOrigin(NSPoint(
                x: max(f.minX, min(f.midX - frame.width / 2, f.maxX - frame.width)),
                y: max(f.minY, min(f.midY - frame.height / 2, f.maxY - frame.height))))
        } else {
            center()
        }
        // Gives us keyboard focus WITHOUT deactivating the target app.
        makeKeyAndOrderFront(nil)
    }

    private func performPaste(_ clipID: Int64) {
        let fidelity = PastePreference.currentFidelity()   // read ⌥ at Enter time, not inside the Task
        orderOut(nil)
        Task { @MainActor in
            do {
                try await paste.paste(clipID: clipID, fidelity: fidelity)
            } catch let error as PasteError {
                // Never silent (spec §9).
                let alert = NSAlert()
                alert.messageText = "Couldn't paste"
                alert.informativeText = error.userMessage
                // AMEND-7: the denial IS the moment to offer the fix — the user
                // just tried the feature, so the value is visible.
                if error == .accessibilityDenied {
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Not Now")
                    if alert.runModal() == .alertFirstButtonReturn {
                        PasteService.requestAccessibility()
                    }
                } else {
                    alert.runModal()
                }
            } catch {
                NSLog("[ClipMate] paste failed: \(error)")
            }
        }
    }
}
