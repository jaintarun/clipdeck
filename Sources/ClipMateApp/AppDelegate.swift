import AppKit
import ClipMateCore

/// Composition root. Builds the object graph and owns it.
///
/// @MainActor: every method here touches AppKit (NSAlert, NSApp, NSWorkspace)
/// and is only ever called from the main thread — main.swift's top-level code,
/// NSApplicationDelegate callbacks, and the menu's explainer action are all
/// main-thread by construction. This declares that reality to the compiler
/// rather than working around it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    /// G9: the capture toggle survives relaunch. Written by the menu, read at
    /// launch — a user who paused before handling secrets must not be
    /// silently re-enabled by a restart.
    static let captureEnabledKey = "captureEnabled"

    var store: ClipStore!
    var collections: CollectionStore!
    var engine: CaptureEngine!
    var tracker: TargetTracker!
    var paste: PasteService!
    /// Reads the current clipboard's fingerprint for the Explorer's blue
    /// "this row is your clipboard" highlight. Its own SystemPasteboard —
    /// reads NSPasteboard.general, same as the engine's.
    var clipboardProbe: ClipboardProbe!
    var menuBar: MenuBarController!
    var panel: QuickPanel!
    var hotKey: HotKey?
    var explorer: ExplorerWindowController?
    private var sleepObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AMEND-6. Two instances double-capture every copy and race retention.
        let mine = Bundle.main.bundleIdentifier ?? "com.clipmateclone.app"
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: mine)
        if twins.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSLog("[ClipMate] another instance is running — quitting this one")
            NSApp.terminate(nil)
            return
        }

        do {
            (store, collections) = try openStore()
        } catch {
            presentFatal("ClipDeck can't open its database.\n\n\(error.localizedDescription)")
            return
        }

        tracker = TargetTracker()
        tracker.start()

        paste = PasteService(store: store, tracker: tracker)

        engine = CaptureEngine(
            store: store,
            pasteboard: SystemPasteboard(),
            collections: collections,
            frontmostAppProvider: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        )
        engine.blocklist = BlocklistStore.load()
        engine.isCapturing = UserDefaults.standard.object(forKey: Self.captureEnabledKey) as? Bool ?? true
        // onResult is already delivered on the main queue by CaptureEngine —
        // no extra hop needed here (and self isn't Sendable, so wrapping it
        // in another @Sendable closure wouldn't type-check anyway).
        engine.onResult = { [weak self] result in
            MainActor.assumeIsolated { self?.handle(result) }
        }
        // OCR retitled a clip moments after capture — refresh the same
        // surfaces a capture refreshes. reload() already defers while the
        // preview is mid-edit.
        engine.onTitleUpdate = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var currentClipTitle: String?
                do {
                    currentClipTitle = try self.store.recentClips(limit: 1).first?.title
                } catch {
                    NSLog("[ClipMate] recent clips read failed: \(error)")
                }
                self.menuBar.refresh(currentClipTitle: currentClipTitle)
                self.explorer?.reload()
            }
        }
        engine.start()

        clipboardProbe = ClipboardProbe(pasteboard: SystemPasteboard())
        // Old-ClipMate behaviour: on launch, read the clipboard and store it, so
        // the Explorer opens already holding (and highlighting) it. Runs after
        // start() so the timer's changeCount baseline is in place first.
        engine.captureCurrentAtLaunch()

        // NSWorkspace lives in the app, not in ClipMateCore — the engine stays
        // testable without a workspace.
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak engine] _ in
                engine?.suspend()
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak engine] _ in
                engine?.resume()
            },
        ]

        panel = QuickPanel(store: store, paste: paste, tracker: tracker)

        menuBar = MenuBarController(
            store: store,
            paste: paste,
            engine: engine,
            tracker: tracker,
            onOpenExplorer: { [weak self] in self?.ensureExplorer().present() },
            onShowPanel: { [weak self] in self?.panel.toggle() },
            onExplainAccessibility: { [weak self] in self?.promptForAccessibility() }
        )

        // ⌃⌥⌘V by default; overridable via UserDefaults (HotkeyPreference).
        // No recorder UI until the L2 Settings window. The hotkey opens the
        // Explorer — the user's main surface. The QuickPanel is still reachable
        // from the menu bar's "Show Quick Panel".
        let hk = HotkeyPreference.current
        hotKey = HotKey(
            keyCode: hk.keyCode,
            modifiers: hk.modifiers
        ) { [weak self] in
            DispatchQueue.main.async { self?.toggleExplorer() }
        }
        if hotKey == nil {
            // Never silent (guide 5.3): a hotkey that failed to register is
            // indistinguishable from a broken app unless we say so. G11: an
            // NSLog nobody reads is still silence — tell the user once.
            NSLog("[ClipMate] global hotkey registration failed — another app may already own it")
            presentWarning("""
                ClipDeck couldn't register its global hotkey — another app may \
                already be using the same combination.

                Everything else works: open ClipDeck from its menu bar icon.
                """)
        }

        // AMEND-7: no prompt at launch. We ask when the user tries the feature
        // that needs it, with the value visible — never nag at login. The menu
        // carries a persistent attention item until it's granted.
    }

    func applicationWillTerminate(_ notification: Notification) {
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
        engine?.stop()
        tracker?.stop()
        hotKey?.unregister()
    }

    // MARK: - Explorer

    /// Lazily build the Explorer the first time it's summoned (menu or hotkey),
    /// then reuse it — the window controller keeps its own state and autosaved
    /// frame across summons.
    private func ensureExplorer() -> ExplorerWindowController {
        if explorer == nil {
            explorer = ExplorerWindowController(
                store: store, collections: collections, paste: paste,
                clipboardProbe: clipboardProbe)
        }
        return explorer!
    }

    /// The hotkey's action. Like the QuickPanel's toggle: if the Explorer is
    /// already frontmost, dismiss it (Escape's behaviour); otherwise bring it
    /// forward. `hide()` leaves the last-selected clip on the clipboard, so the
    /// hotkey doubles as ClipMate's "grab and go".
    private func toggleExplorer() {
        let controller = ensureExplorer()
        if controller.window?.isVisible == true, NSApp.isActive {
            controller.hide()
        } else {
            controller.present()
        }
    }

    // MARK: - Database

    /// Corruption is not silent: the database is the only copy of the user's
    /// history, so if it's unreadable we say so before starting clean (spec §9).
    ///
    /// Only genuine corruption (per `AppDatabase.isCorruption`) or a failed
    /// integrity check quarantines the file. Everything else — permissions, a
    /// full disk, a transient lock, a migration bug — is NOT corruption:
    /// falsely accusing the file and moving it aside is worse than the
    /// original error, so those are rethrown untouched for
    /// `applicationDidFinishLaunching`'s `presentFatal` to show as-is.
    ///
    /// Returns a ClipStore and CollectionStore, both built from the same pool,
    /// rather than the pool itself, so no GRDB type is ever named in this
    /// target — ClipMateApp depends on ClipMateCore, not on GRDB.
    private func openStore() throws -> (ClipStore, CollectionStore) {
        let url = try AppDatabase.defaultURL()
        do {
            let pool = try AppDatabase.makePool(at: url)
            if try !AppDatabase.integrityCheck(pool) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (ClipStore(pool), CollectionStore(pool))
        } catch {
            let failedIntegrityCheck = (error as? CocoaError)?.code == .fileReadCorruptFile
            guard AppDatabase.isCorruption(error) || failedIntegrityCheck else {
                throw error
            }
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            presentWarning("""
                ClipDeck's clip history was corrupted and could not be opened.

                The damaged file has been moved to:
                \(backup.lastPathComponent)

                ClipDeck has started with an empty history.
                """)
            let freshPool = try AppDatabase.makePool(at: url)
            return (ClipStore(freshPool), CollectionStore(freshPool))
        }
    }

    // MARK: - Results

    private func handle(_ result: CaptureResult) {
        switch result {
        case .captured(let id), .bumped(let id):
            var currentClipTitle: String?
            do {
                currentClipTitle = try store.recentClips(limit: 1).first?.title
            } catch {
                // Never silent (spec §9). A failed read here would otherwise leave
                // the menu silently showing stale text after a real capture.
                NSLog("[ClipMate] recent clips read failed: \(error)")
            }
            menuBar.refresh(currentClipTitle: currentClipTitle)
            // The captured/bumped clip is now the clipboard content — select it in
            // the Explorer rather than leaving the stale prior selection.
            explorer?.reload(selecting: id)
        case .rejectedTooLarge:
            NSLog("[ClipMate] skipped an oversized clip")
        case .rejectedBlockedApp(let bundleID):
            NSLog("[ClipMate] skipped a clip from blocklisted \(bundleID)")
        default:
            break
        }
    }

    // MARK: - Permission

    /// The explainer. Reached from the menu's attention item (AMEND-7), never
    /// fired unprompted at launch.
    func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "ClipDeck needs Accessibility permission"
        alert.informativeText = """
            ClipDeck pastes into the app you were last using, which macOS only \
            allows with Accessibility permission.

            Without it ClipDeck can still copy a clip to your clipboard, but you'll \
            have to press ⌘V yourself.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            PasteService.requestAccessibility()
        }
    }

    private func presentWarning(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipDeck"
        alert.informativeText = text
        alert.runModal()
    }

    private func presentFatal(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ClipDeck can't start"
        alert.informativeText = text
        alert.runModal()
        NSApp.terminate(nil)
    }
}
