import AppKit
import ClipMateCore

/// An NSSplitView that reports its first real layout, so the controller can set
/// an initial divider position once. `autosaveName` handles every run after.
@MainActor
final class InitialPositionSplitView: NSSplitView {
    var onFirstLayout: ((NSSplitView) -> Void)?
    private var reported = false
    override func layout() {
        super.layout()
        if !reported, bounds.height > 0 {
            reported = true
            onFirstLayout?(self)
        }
    }
}

/// The Explorer's window. It's the app's summoned surface now, so it behaves
/// like the QuickPanel: Escape dismisses it (routed to `onCancel`). Its
/// traffic-light buttons are hidden by the controller; you Quit from the menu
/// bar. A titled window is key/main-eligible by default, so nothing else is
/// needed to let it take keyboard focus.
@MainActor
final class ExplorerWindow: NSWindow {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Column header with a solid background. The stock header is translucent
/// glass on macOS 26, and the system's scroll-edge machinery renders row
/// content into the band behind it — stray text/icons above the list (user
/// report, 2026-07-18). Filling first buries anything composited behind.
@MainActor
private final class OpaqueHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// The clip table. Return / keypad-Enter (with or without ⌘ — the keyCode
/// check ignores modifiers, so Feature 6's ⌘⏎ works from the list too)
/// auto-pastes the selected clip — the
/// "Enter also auto-pastes" half of ClipMate's selection model. NSTableView has
/// no default Return action, and this app is LSUIElement with no main menu to
/// hang a key equivalent on, so a small subclass scopes the key to "this table
/// has focus".
@MainActor
final class ClipTableView: NSTableView {
    var onEnter: (() -> Void)?
    /// ⌘R renames the selected clip. Scoped to this view's focus via keyDown,
    /// so it only fires while the clip list itself has focus.
    var onRenameKey: (() -> Void)?
    /// ⌘F focuses the toolbar search field (UI Polish 2 §1).
    var onFindKey: (() -> Void)?
    /// ⌫ moves the selection to Trash; ⌥⌫ permanently deletes it, no dialog
    /// (user decision, spec 2026-07-19). keyCode 51 is Delete (backspace);
    /// 117 is forward delete — the dedicated Delete key on Windows keyboards
    /// (fn+⌫ on compact Mac keyboards) — treated identically by user request.
    var onDeleteKey: (() -> Void)?
    var onOptionDeleteKey: (() -> Void)?
    /// ⌘T moves the selection to the top of the list (spec 2026-07-21).
    var onMoveToTopKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { // Return, keypad Enter
            onEnter?()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "r" {
            onRenameKey?()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFindKey?()
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "t" {
            onMoveToTopKey?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if event.modifierFlags.contains(.option) { onOptionDeleteKey?() }
            else { onDeleteKey?() }
            return
        }
        super.keyDown(with: event)
    }
}

/// The Trash row pinned below the sidebar's scrolling tree (user decision,
/// spec 2026-07-21: Trash lives alone at the bottom-left, not among the main
/// items). Selectable like a source-list row, and a drag destination for
/// clips — both delegate to the controller, which owns the stores.
final class TrashAnchorView: NSView {
    var onClick: (() -> Void)?
    var onDropClipIDs: (([Int64]) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    var badgeText: String? {
        didSet { badgeField.stringValue = badgeText ?? "" }
    }
    private var isDropHighlighted = false { didSet { needsDisplay = true } }
    private let badgeField = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([ClipListDataSource.clipIDPasteboardType])

        let icon = NSImageView(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Trash") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: "Trash")
        label.font = .systemFont(ofSize: 13)
        badgeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badgeField.textColor = .secondaryLabelColor
        for v in [icon, label, badgeField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isDropHighlighted {
            let inset = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)
            (isDropHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                               : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropHighlighted = true
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropHighlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        let clipIDs = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: ClipListDataSource.clipIDPasteboardType).flatMap(Int64.init)
        }
        guard !clipIDs.isEmpty else { return false }
        onDropClipIDs?(clipIDs)
        return true
    }
}

/// The 3-pane window. DIAGRAMS.md §2.3.
///
/// NSMenuDelegate so the context menu's Move to/Restore/Delete/Append items
/// can update their title, visibility, and enabled state for the row the
/// menu was opened on.
///
/// @MainActor: an NSWindowController driving live AppKit UI, constructed and
/// driven entirely from the main thread by AppDelegate — same reasoning as
/// QuickPanel.
@MainActor
final class ExplorerWindowController: NSWindowController, NSMenuDelegate, NSSplitViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    private let store: ClipStore
    private let collections: CollectionStore
    private let paste: PasteService
    private let clipboardProbe: ClipboardProbe
    /// Combines 2+ selected clips' text into a new clip (menuNeedsUpdate hides it
    /// for a single selection).
    private let appendItem = NSMenuItem(title: "Append to new item", action: #selector(appendToNewClicked), keyEquivalent: "")
    /// Direct "Move to Safe" — the only filing destination since user
    /// collections were removed (spec 2026-07-21). representedObject is
    /// refreshed with Safe's id on every menuNeedsUpdate.
    private let moveToItem = NSMenuItem(title: "Move to Safe", action: #selector(moveToCollectionClicked(_:)), keyEquivalent: "")
    /// Jumps the clicked-or-selected clips to the top of the list (spec
    /// 2026-07-21). ⌘T also reaches this from the clip list via keyDown.
    private let moveToTopItem = NSMenuItem(title: "Move to Top", action: #selector(moveToTopClicked), keyEquivalent: "t")
    /// Only shown while viewing Trash (Task 7 Step 3).
    private let restoreItem = NSMenuItem(title: "Restore", action: #selector(restoreClicked), keyEquivalent: "")
    /// Retitled between "Delete" and "Delete Immediately…" depending on
    /// whether we're viewing Trash — see menuNeedsUpdate (Task 7 Step 4).
    private let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: "")
    /// Toolbar search (UI Polish 2 §1): a non-empty query switches the list to
    /// a global FTS search; clearing returns to the selected collection.
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .clipSearch)
    private var searchQuery = ""

    private let outlineView = NSOutlineView()
    private let tableView = ClipTableView()
    private let treeSource = CollectionTreeDataSource()
    private let listSource = ClipListDataSource()
    private let preview = PreviewPaneController()
    /// Trash's dedicated row, pinned below the sidebar's scroll view rather
    /// than living in the outline tree (Task 3).
    private let trashAnchor = TrashAnchorView()
    private let emptyTrashButton = NSButton()
    /// Shown centered over the clip list when it has no rows (UI Polish 2 §3).
    private let listEmptyState = EmptyStateView()
    /// Row IDs as last displayed — reload() diffs against this to detect the
    /// "one new capture prepended" case and slide it in instead of repainting.
    private var lastShownIDs: [Int64] = []
    /// The Trash-only bottom bar. 0pt (gone) outside Trash, 34pt in Trash.
    private let emptyTrashRow = NSView()
    private var emptyTrashBarHeight: NSLayoutConstraint!

    /// The list-over-preview split. Held so present() can rescue the preview if
    /// it ever restores collapsed, and so the divider can be re-centered.
    private var listPreviewSplit: InitialPositionSplitView!

    // Placeholder only — the real default (the system InBox) isn't known
    // until CollectionStore can be queried, so init() resolves it below.
    private var currentCollection: SidebarSelection = .smart(.everything)
    /// Cached from the last reload() — reused by the context menu (Move to…'s
    /// submenu, Restore's visibility) and the Empty Trash button so neither
    /// needs its own database round trip.
    private var allCollections: [Collection] = []
    /// The id of the clip currently shown in the preview pane, so reload()
    /// can restore or clear it — see reload() below.
    private var previewedClipID: Int64?
    /// Guards against outlineViewSelectionDidChange re-entering reload()
    /// while reload() is itself the one calling selectRowIndexes (Step 2's
    /// "fall back to InBox if the selected collection vanished" case).
    private var isReloading = false
    /// True while reload() is programmatically re-selecting a row. ClipMate's
    /// model puts the selected clip on the system clipboard, but only the
    /// user's own navigation should do that — a capture-driven reload
    /// re-selecting the same row must not clobber what the user just copied.
    private var suppressClipboardCopy = false

    /// nil for a smart collection or a user collection with no `kind`
    /// (ordinary, user-made). Drives Restore's visibility in the context
    /// menu and the Empty Trash button — both only make sense while looking
    /// at Trash.
    private var currentCollectionKind: CollectionKind? {
        guard case .user(let id) = currentCollection else { return nil }
        return allCollections.first(where: { $0.id == id })?.kind
    }

    init(store: ClipStore, collections: CollectionStore, paste: PasteService,
         clipboardProbe: ClipboardProbe) {
        self.store = store
        self.collections = collections
        self.paste = paste
        self.clipboardProbe = clipboardProbe

        let window = ExplorerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipDeck"
        // A generous floor so the window can never be dragged down to the tiny,
        // unusable size earlier builds sometimes restored.
        window.minSize = NSSize(width: 900, height: 600)
        super.init(window: window)

        // Remember where the user put the window and how big it was, across
        // launches (the "keep the same size" request). The ".v3" suffix discards
        // frames saved by earlier builds (which were too short). On a genuine
        // first run (no saved frame), open centered at the default size instead
        // of the bottom-left origin AppKit would otherwise use.
        let autosaveName = "ClipMate.Explorer.window.v3"
        window.setFrameAutosaveName(autosaveName)
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }

        // Real macOS chrome (UI Polish 2 §1): traffic lights visible, Escape
        // still hides, and the close button HIDES the app (windowShouldClose)
        // rather than quitting — the Explorer is summonable, never destroyed.
        window.onCancel = { [weak self] in self?.hide() }
        window.delegate = self
        let toolbar = NSToolbar(identifier: "ClipMate.Explorer.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        searchItem.preferredWidthForSearchField = 220
        searchItem.searchField.placeholderString = "Search all clips"
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searchChanged)

        // The Explorer should default to the real system InBox (membership),
        // where captures land and which is the sidebar's first row — not the
        // SMART query slot, which is a dead duplicate of Everything (see
        // CollectionTreeDataSource's smartGroup comment).
        do {
            let inbox = try collections.collection(kind: .inbox)
            guard let id = inbox.id else { throw CollectionError.notFound }
            currentCollection = .user(id)
        } catch {
            // Never silent (spec §9).
            NSLog("[ClipMate] system InBox lookup failed: \(error)")
            currentCollection = .smart(.everything)
        }

        buildLayout()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildLayout() {
        // Sidebar
        let sidebarColumn = NSTableColumn(identifier: .init("collection"))
        sidebarColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(sidebarColumn)
        outlineView.outlineTableColumn = sidebarColumn
        outlineView.headerView = nil
        outlineView.style = .sourceList        // the modern Mac look
        outlineView.rowHeight = 28
        outlineView.backgroundColor = .clear   // let the sidebar vibrancy through
        outlineView.dataSource = treeSource
        outlineView.delegate = treeSource
        outlineView.target = self
        treeSource.onSelect = { [weak self] selection in
            guard let self, !self.isReloading else { return }
            self.currentCollection = selection
            self.trashAnchor.isSelected = false
            self.reload()
        }
        // Drop target (Task 7 Step 2): registerForDraggedTypes is what makes
        // an NSOutlineView accept a drag at all; CollectionTreeDataSource's
        // validateDrop/acceptDrop then decide per-row whether it's a legal
        // destination.
        outlineView.registerForDraggedTypes([ClipListDataSource.clipIDPasteboardType])
        treeSource.onDrop = { [weak self] clipIDs, collectionID in
            guard let self else { return }
            do {
                try self.collections.moveClips(clipIDs, to: collectionID)
            } catch {
                // Never silent (spec §9).
                self.presentCollectionError(error)
            }
            self.reload()
        }
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = outlineView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false   // vibrant sidebar, not gray

        // Trash anchor (Task 3): a hairline separates it from the scrolling
        // tree above, pinned to the sidebar container's bottom-left.
        let trashSeparator = NSBox()
        trashSeparator.boxType = .separator
        trashAnchor.onClick = { [weak self] in
            guard let self else { return }
            do {
                let trash = try self.collections.collection(kind: .trash)
                guard let id = trash.id else { throw CollectionError.notFound }
                self.outlineView.deselectAll(nil)
                self.currentCollection = .user(id)
                self.reload()
            } catch {
                self.presentCollectionError(error)   // Never silent (spec §9).
            }
        }
        trashAnchor.onDropClipIDs = { [weak self] clipIDs in
            guard let self else { return }
            do {
                let trash = try self.collections.collection(kind: .trash)
                guard let id = trash.id else { throw CollectionError.notFound }
                try self.collections.moveClips(clipIDs, to: id)
            } catch {
                self.presentCollectionError(error)   // Never silent (spec §9).
            }
            self.reload()
        }

        let sidebarContainer = NSView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        trashSeparator.translatesAutoresizingMaskIntoConstraints = false
        trashAnchor.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sidebarScroll)
        sidebarContainer.addSubview(trashSeparator)
        sidebarContainer.addSubview(trashAnchor)
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: trashSeparator.topAnchor),
            trashSeparator.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            trashSeparator.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            trashSeparator.bottomAnchor.constraint(equalTo: trashAnchor.topAnchor),
            trashAnchor.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            trashAnchor.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            trashAnchor.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            trashAnchor.heightAnchor.constraint(equalToConstant: 36),
        ])

        // Clip list
        // A sortable, columnar table (Title with icon | Type glyph | Source |
        // Date | Size). Clicking a header sorts via sortDescriptorsDidChange.
        // Column budget fits the 900pt minimum window (UI Polish 2 §3). The
        // .inset style spends ~98pt beyond the widths themselves (4 gaps of
        // ~17.5pt intercell spacing + edge insets), so widths must sum ≤ ~600
        // for the ~700pt pane: 240+44+108+144+58 = 594. Title alone flexes and
        // absorbs all slack; Date gets the room to never truncate, Source
        // truncates before Date does.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width, sortKey) in [
            ("title", "Title", 240.0, "title"),
            ("type", "Type", 44.0, "type"),
            ("source", "Source", 108.0, "source"),
            ("date", "Date", 144.0, "date"),
            ("size", "Size", 58.0, "size"),
        ] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
            if id == "title" {
                col.minWidth = 240
                col.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                col.resizingMask = .userResizingMask
            }
            // The Size values are right-aligned; align its header to match.
            if id == "size" { col.headerCell.alignment = .right }
            tableView.addTableColumn(col)
        }
        tableView.dataSource = listSource
        tableView.delegate = listSource
        // Feature 4: between the old 36 and Finder's ~24 — "closer to Finder,
        // but not that much". Fonts stay (13/12pt single lines fit 30 cleanly).
        tableView.rowHeight = 30
        tableView.style = .inset
        // Opaque header: the stock header is translucent, and macOS 26's
        // scroll-edge machinery ghosts row content through that band (see
        // hideTitlebarScrollMirrors). A solid fill makes the band
        // deterministic in both light and dark mode.
        tableView.headerView = OpaqueHeaderView(frame: tableView.headerView?.frame ?? .zero)
        // Feature 5: Finder's own very-light zebra striping, automatic in dark
        // mode. ClipRowView only overrides the selection's emphasized state, so
        // the system draws the stripes for unselected rows untouched.
        tableView.usesAlternatingRowBackgroundColors = true
        // Multi-selection serves "Append to new item" and "Move to…" on several
        // clips at once. Preview and selection-copies stay single-selection-
        // driven (see the guard in ClipListDataSource.tableViewSelectionDidChange).
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelected)
        tableView.onEnter = { [weak self] in self?.pasteSelected() }
        tableView.onRenameKey = { [weak self] in self?.renameSelectedClip() }
        tableView.onFindKey = { [weak self] in self?.searchItem.beginSearchInteraction() }
        tableView.onDeleteKey = { [weak self] in self?.deleteSelectionToTrash() }
        tableView.onOptionDeleteKey = { [weak self] in self?.deleteSelectionPermanently() }
        tableView.onMoveToTopKey = { [weak self] in
            guard let self else { return }
            self.moveClipsToTop(self.selectedClipIDs())
        }
        preview.onCommitEdit = { [weak self] newText in self?.commitEdit(newText) }
        preview.onPasteWhileEditing = { [weak self] in
            guard let self, let id = self.previewedClipID else { return }
            self.pasteClip(id: id)
        }
        tableView.menu = makeContextMenu()
        listSource.onRename = { [weak self] id, newTitle in
            guard let self else { return }
            do { try self.store.rename(clipID: id, to: newTitle) }
            catch { NSSound.beep() }
            self.reload()
        }
        listSource.onSelect = { [weak self] clip in
            guard let self else { return }
            self.showPreview(clip)
            // ClipMate's model: browsing the list puts the selected clip on the
            // system clipboard, so Escape-then-⌘V pastes it. Suppressed during a
            // reload's programmatic re-selection, or every capture would overwrite
            // the just-copied clip with the previously selected one.
            if !self.suppressClipboardCopy { self.copySelectionToClipboard(clip) }
        }
        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true

        // Trash-only bottom bar (UI Polish 2 §3): hairline + confirming button,
        // 34pt in Trash, 0pt (gone) everywhere else — no dead strip. Behind a
        // confirming NSAlert, and never run automatically (never on quit —
        // guide Part 4.2).
        emptyTrashButton.title = "Empty Trash…"
        emptyTrashButton.bezelStyle = .rounded
        emptyTrashButton.controlSize = .small
        emptyTrashButton.target = self
        emptyTrashButton.action = #selector(emptyTrashClicked)
        let trashRule = NSBox()
        trashRule.boxType = .separator
        trashRule.translatesAutoresizingMaskIntoConstraints = false
        emptyTrashButton.translatesAutoresizingMaskIntoConstraints = false
        emptyTrashRow.isHidden = true
        emptyTrashRow.addSubview(trashRule)
        emptyTrashRow.addSubview(emptyTrashButton)
        NSLayoutConstraint.activate([
            trashRule.topAnchor.constraint(equalTo: emptyTrashRow.topAnchor),
            trashRule.leadingAnchor.constraint(equalTo: emptyTrashRow.leadingAnchor),
            trashRule.trailingAnchor.constraint(equalTo: emptyTrashRow.trailingAnchor),
            emptyTrashButton.trailingAnchor.constraint(equalTo: emptyTrashRow.trailingAnchor, constant: -8),
            emptyTrashButton.centerYAnchor.constraint(equalTo: emptyTrashRow.centerYAnchor),
        ])

        let listContainer = NSView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        emptyTrashRow.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listScroll)
        listContainer.addSubview(emptyTrashRow)
        emptyTrashBarHeight = emptyTrashRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            // Top is pinned to the window's contentLayoutGuide after install
            // (end of buildLayout) — this floor alone would let the list slide
            // under the unified toolbar and bleed scrolled rows into the title
            // bar (user report, 2026-07-18).
            listScroll.topAnchor.constraint(greaterThanOrEqualTo: listContainer.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: emptyTrashRow.topAnchor),
            emptyTrashRow.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            emptyTrashRow.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            emptyTrashRow.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyTrashBarHeight,
        ])

        // Empty-state overlay, sized to the list scroll area only so the
        // Trash bar (when present) stays clear of it.
        listEmptyState.isHidden = true
        listEmptyState.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listEmptyState)
        NSLayoutConstraint.activate([
            listEmptyState.topAnchor.constraint(equalTo: listScroll.topAnchor),
            listEmptyState.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            listEmptyState.trailingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            listEmptyState.bottomAnchor.constraint(equalTo: listScroll.bottomAnchor),
        ])

        // Right side: list over preview. autosaveName persists the divider
        // across launches; onFirstLayout seeds a sensible first-run ratio so the
        // preview isn't a large empty void before the user has dragged anything.
        let rightSplit = InitialPositionSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        // A delegate that clamps both panes to a minimum height so the preview
        // can NEVER be dragged (or restored) to zero — the recurring "detail
        // pane is gone" bug. ".v3" discards the collapsed position earlier
        // builds saved before this clamp existed.
        rightSplit.delegate = self
        rightSplit.autosaveName = "ClipMate.Explorer.rightSplit.v3"
        rightSplit.addArrangedSubview(listContainer)
        rightSplit.addArrangedSubview(preview.view)
        rightSplit.onFirstLayout = { split in
            // Open with the list and preview sharing the height equally. Runs
            // once; the user's later drags persist via autosaveName.
            let key = "ClipMate.Explorer.rightSplit.initialized.v3"
            guard !UserDefaults.standard.bool(forKey: key), split.bounds.height > 0 else { return }
            split.setPosition(split.bounds.height * 0.5, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: key)
        }
        listPreviewSplit = rightSplit

        // Whole window: sidebar | right, via NSSplitViewController. The split
        // view CONTROLLER (not a bare NSSplitView) is what gives the sidebar its
        // real macOS treatment — translucent vibrancy, the correct source-list
        // material, and automatic traffic-light insets. A plain NSVisualEffectView
        // in an opaque window can't reproduce behind-window sidebar vibrancy.
        // Only the container changes; every pane and its wiring is untouched.
        let sidebarVC = NSViewController()
        sidebarVC.view = sidebarContainer
        let contentVC = NSViewController()
        contentVC.view = rightSplit

        let splitVC = NSSplitViewController()
        splitVC.splitView.isVertical = true
        splitVC.splitView.autosaveName = "ClipMate.Explorer.mainSplit"
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 320
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))

        window?.contentViewController = splitVC

        // The sidebar item switched the window to full-size content (that is
        // what buys its full-height vibrancy), which slides the right pane
        // under the unified toolbar — and scrolled-off rows bled through the
        // title bar. contentLayoutGuide tracks the toolbar's bottom edge
        // dynamically; pinning the list's top to it hard-clips rows out of
        // the title bar. Activated only now: the guide lives on the window's
        // content view, so both ends must share a window first.
        if let guide = window?.contentLayoutGuide as? NSLayoutGuide {
            listScroll.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true
        }
        treeSource.expandAll(outlineView)

        // Own the Tab loop explicitly (sidebar → list → preview), so AppKit's
        // geometry-based recalculation can't drop the sidebar again.
        window?.autorecalculatesKeyViewLoop = false
        window?.initialFirstResponder = tableView
        wireKeyViewLoop()
    }

    /// `selectID`, when given, is a just-captured clip that is now the clipboard
    /// content — the list should land on it (highlighted, scrolled into view)
    /// rather than keep the stale prior selection. Falls back to preserving the
    /// prior selection when that clip isn't in the collection being viewed.
    func reload(selecting selectID: Int64? = nil) {
        // Never yank selection/preview out from under a live edit. The captured
        // clip is safely stored; it appears on the next reload after the edit
        // resolves (commit or cancel).
        guard !preview.isEditing else { return }

        isReloading = true
        defer { isReloading = false }

        do {
            allCollections = try collections.all()
        } catch {
            // Never silent (spec §9).
            NSLog("[ClipMate] collection list read failed: \(error)")
            allCollections = []
        }

        // A collection the user had selected can vanish out from under them
        // (deleted just now, via deleteSelected()) — falling back to InBox
        // beats silently showing a stale, now-meaningless list. allCollections
        // is already in hand, so no new throwing lookup is needed here.
        if case .user(let id) = currentCollection, !allCollections.contains(where: { $0.id == id }) {
            currentCollection = allCollections.first(where: { $0.kind == .inbox })?.id.map(SidebarSelection.user) ?? .smart(.everything)
        }

        var trashCount = 0
        if let trashID = allCollections.first(where: { $0.kind == .trash })?.id {
            do {
                trashCount = try collections.clipIDs(in: trashID).count
            } catch {
                // Never silent (spec §9) — the badge just shows no count.
                NSLog("[ClipMate] trash count read failed: \(error)")
            }
        }
        treeSource.update(with: allCollections)
        outlineView.reloadData()
        syncOutlineSelection()
        trashAnchor.badgeText = trashCount > 0 ? "\(trashCount)" : nil
        trashAnchor.isSelected = (currentCollectionKind == .trash)

        let clips: [Clip]
        do {
            if searchQuery.isEmpty {
                switch currentCollection {
                case .smart(let s): clips = try store.clips(in: s)
                case .user(let id): clips = try store.clips(inCollection: id)
                }
            } else {
                clips = try store.search(searchQuery, limit: 200)
            }
        } catch {
            // Never silent (spec §9). A failed read here would otherwise leave
            // the list showing stale clips with no indication anything went wrong.
            NSLog("[ClipMate] clip list read failed: \(error)")
            clips = []
        }
        listSource.clips = clips
        // One query, thumbnails only — never the full blob (spec §5, AMEND-8).
        do {
            listSource.thumbnails = try store.thumbnails(for: clips.compactMap(\.id))
        } catch {
            NSLog("[ClipMate] thumbnail read failed: \(error)")
            listSource.thumbnails = [:]
        }
        // Sizes for the Size column — LENGTH() only, no blobs loaded.
        do {
            listSource.byteSizes = try store.byteSizes(for: clips.compactMap(\.id))
        } catch {
            NSLog("[ClipMate] size read failed: \(error)")
            listSource.byteSizes = [:]
        }
        // Kinds for the Type column — one round trip over representation UTIs.
        do {
            listSource.kinds = try store.kinds(for: clips.compactMap(\.id))
        } catch {
            NSLog("[ClipMate] kind read failed: \(error)")
            listSource.kinds = [:]
        }
        // What's on the clipboard right now, so the matching row draws blue.
        // Cached by changeCount inside the probe, so this is cheap when the
        // clipboard hasn't moved since the last reload.
        listSource.clipboardHash = clipboardProbe.currentHash()
        // Re-apply the user's chosen column sort over the freshly fetched list.
        listSource.applyCurrentSort()

        // NSTableView.reloadData() resets selectedRow to -1 and does NOT fire
        // tableViewSelectionDidChange, even when the row count is unchanged —
        // so without this, the highlighted row vanishes on every capture/
        // Delete/sidebar click while the preview pane keeps showing
        // whatever was selected before the reload. Mirrors
        // QuickPanelViewController.reload(preservingSelection:).
        //
        // This re-selection is programmatic, so suppress the clipboard-copy —
        // only the user's own navigation should change the clipboard.
        // A just-captured clip is now the clipboard content, so the list lands
        // on it — but only if it's in the collection being viewed (a clip
        // captured into InBox while viewing "Images" isn't here; don't yank the
        // user's selection somewhere in that case).
        let capturedRow = selectID.flatMap { id in listSource.clips.firstIndex(where: { $0.id == id }) }
        let keepRow = previewedClipID.flatMap { id in listSource.clips.firstIndex(where: { $0.id == id }) }
        suppressClipboardCopy = true
        // One new capture prepended to an otherwise-unchanged list slides in;
        // anything else repaints as before (UI Polish 2 §3).
        let newIDs = listSource.clips.compactMap(\.id)
        let isPrepend = selectID != nil
            && newIDs.first == selectID
            && newIDs.count == lastShownIDs.count + 1
            && Array(newIDs.dropFirst()) == lastShownIDs
        if isPrepend {
            tableView.beginUpdates()
            tableView.insertRows(at: [0], withAnimation: .slideDown)
            tableView.endUpdates()
            // Rows shifted down carry stale blue/gray flags — the new capture
            // owns the clipboard now.
            refreshClipboardHighlight()
        } else {
            tableView.reloadData()
        }
        lastShownIDs = newIDs
        if let row = capturedRow {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            // A new clip — refresh the preview to it (programmatic selection does
            // not fire the selection delegate, so this must be explicit).
            showPreview(listSource.clips[row])
        } else if let row = keepRow {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else if !listSource.clips.isEmpty {
            // No prior selection — a fresh launch, or the previewed clip vanished.
            // Default to the top row so the Explorer opens showing its newest
            // clip rather than a blank preview. Suppressed, so merely opening the
            // window doesn't overwrite the clipboard; the user's own navigation
            // still does.
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
            showPreview(listSource.clips[0])
        } else {
            // Empty list — clear any stale preview.
            previewedClipID = nil
            preview.show(clip: nil, representations: [])
            wireKeyViewLoop()
        }
        suppressClipboardCopy = false

        let collectionName: String
        switch currentCollection {
        case .smart(let s): collectionName = s.title
        case .user(let id): collectionName = allCollections.first(where: { $0.id == id })?.name ?? "Collection"
        }
        // App name leads; the subtitle names what you're looking at. macOS
        // renders window.title/window.subtitle as "ClipDeck — Inbox".
        window?.title = "ClipDeck"
        window?.subtitle = searchQuery.isEmpty ? collectionName : "Search Results"

        // Empty Trash only makes sense while looking at Trash (Task 7 Step 3);
        // search results hide it even there.
        let showTrashBar = currentCollectionKind == .trash && searchQuery.isEmpty
        emptyTrashRow.isHidden = !showTrashBar
        emptyTrashBarHeight.constant = showTrashBar ? 34 : 0

        if listSource.clips.isEmpty {
            if !searchQuery.isEmpty {
                listEmptyState.configure(symbol: "magnifyingglass", title: "No Results",
                                         hint: "No clips match “\(searchQuery)”.")
            } else if currentCollectionKind == .trash {
                listEmptyState.configure(symbol: "trash", title: "Trash Is Empty",
                                         hint: "Deleted clips wait here for 6 days.")
            } else {
                listEmptyState.configure(symbol: "doc.on.clipboard", title: "No Clips",
                                         hint: "Everything you copy will appear here.")
            }
        }
        listEmptyState.isHidden = !listSource.clips.isEmpty
    }

    /// Explicitly re-selects the outline row for `currentCollection` rather
    /// than trusting NSOutlineView's own reload-preserves-selection
    /// behavior — cheaper to verify than to assume, and the `row !=
    /// selectedRow` guard means this is a no-op on the common path (a
    /// reload triggered by a capture, with the same row already selected).
    /// Trash has no tree row (Task 3) — its own highlight lives on the
    /// bottom anchor, so this is a no-op while Trash is selected.
    private func syncOutlineSelection() {
        guard currentCollectionKind != .trash else { return }
        let target: Any?
        switch currentCollection {
        case .smart(let s): target = s
        case .user(let id): target = treeSource.node(forID: id)
        }
        guard let target else { return }
        let row = outlineView.row(forItem: target)
        guard row >= 0, row != outlineView.selectedRow else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func showPreview(_ clip: Clip) {
        guard let id = clip.id else { return }
        previewedClipID = id
        do {
            let reps = try store.representations(for: id)
            preview.show(clip: clip, representations: reps)
        } catch {
            // Never silent (spec §9).
            NSLog("[ClipMate] representations read failed: \(error)")
        }
        // The preview's focusable text view was just rebuilt — re-wire the Tab
        // loop so it lands there (or skips the preview for an image-only clip).
        wireKeyViewLoop()
    }

    /// Tab cycles the three panes: sidebar → list → preview → sidebar; Shift-Tab
    /// reverses. AppKit's inferred loop skipped the sidebar, so wire it
    /// explicitly. Re-run whenever the preview rebuilds, since its focusable
    /// view changes per clip (and is nil for an image-only clip).
    private func wireKeyViewLoop() {
        outlineView.nextKeyView = tableView
        if let previewView = preview.focusableView {
            tableView.nextKeyView = previewView
            previewView.nextKeyView = outlineView
        } else {
            tableView.nextKeyView = outlineView
        }
    }

    /// ClipMate's selection-sets-the-clipboard model: moving the selection puts
    /// that clip on the system pasteboard, so dismissing the Explorer and
    /// pressing ⌘V in the target app pastes it. Copy-only — no synthetic
    /// keystroke — and PasteService stamps the ownership marker so CaptureEngine
    /// won't re-capture our own write as a new clip.
    private func copySelectionToClipboard(_ clip: Clip) {
        guard let id = clip.id else { return }
        do {
            try paste.copyToPasteboard(clipID: id, fidelity: PastePreference.currentFidelity())
            // The clipboard now holds this clip, so it becomes the blue row. Set
            // the hash directly rather than re-reading the pasteboard — we know
            // exactly what we just wrote.
            listSource.clipboardHash = clip.contentHash
            refreshClipboardHighlight()
        } catch {
            // Never silent (spec §9). A failed copy is otherwise invisible — the
            // user dismisses, hits ⌘V, and gets the wrong (stale) clip.
            NSLog("[ClipMate] selection copy failed: \(error)")
        }
    }

    /// Repaint the visible rows' emphasized (blue vs gray) state after the
    /// clipboard changed, without a full reload that would disturb selection.
    private func refreshClipboardHighlight() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let clipRow = rowView as? ClipRowView else { return }
            clipRow.matchesClipboard = self.listSource.matchesClipboard(row)
            clipRow.needsDisplay = true
        }
    }

    // MARK: - NSSplitViewDelegate (list/preview only)

    /// Keep the list (top pane) at least this tall — the divider can't be
    /// dragged above it.
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    /// Keep the preview (bottom pane) at least 160pt tall — it must never be
    /// dragged to zero, the recurring "detail pane vanished" bug.
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 160)
    }

    /// Neither pane may be collapsed away entirely.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    /// Dismiss the Explorer the way Escape and a completed paste both want:
    /// hide the whole app so focus returns to the app the user came from (the
    /// paste target), leaving the last-selected clip on the clipboard.
    func hide() {
        NSApp.hide(nil)
    }

    // MARK: - Window & toolbar chrome (UI Polish 2 §1)

    /// Close hides the whole app (the Explorer is a summoned surface, never
    /// destroyed); Quit lives in the menu bar.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .clipSearch]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        itemIdentifier == .clipSearch ? searchItem : nil
    }

    /// One query per typing pause, not per keystroke (Maccy G7 — their search
    /// died at ~2k items on exactly this). A pending reload firing after
    /// hide() is harmless: reload on a hidden window is cheap.
    private let searchDebouncer = Debouncer(delay: .milliseconds(200))

    @objc private func searchChanged() {
        searchQuery = searchItem.searchField.stringValue
        searchDebouncer.call { [weak self] in self?.reload() }
    }

    private func presentCollectionError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't complete that action"
        alert.informativeText = (error as? CollectionError).map(Self.message(for:)) ?? error.localizedDescription
        alert.runModal()
    }

    private static func message(for error: CollectionError) -> String {
        switch error {
        case .systemCollectionImmutable: return "System collections can't be renamed, deleted, or moved."
        case .notFound: return "That collection no longer exists."
        }
    }

    // MARK: - Context menu (AMEND-4)

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        moveToTopItem.keyEquivalentModifierMask = [.command]
        moveToTopItem.target = self
        menu.addItem(moveToTopItem)

        let renameItem = NSMenuItem(title: "Rename", action: #selector(renameClicked), keyEquivalent: "r")
        renameItem.keyEquivalentModifierMask = [.command]
        renameItem.target = self
        menu.addItem(renameItem)

        appendItem.target = self
        menu.addItem(appendItem)

        moveToItem.target = self
        menu.addItem(moveToItem)

        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    /// Begin an inline title edit on `row`. The title field is a label until
    /// now — flip it editable (and give it a visible edit box) so editColumn
    /// can start the field editor; ClipListDataSource commits or cancels on end.
    private func beginRename(row: Int) {
        guard row >= 0, row < listSource.clips.count,
              let col = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" })
        else { return }
        if let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: true) as? NSTableCellView,
           let field = cell.textField {
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
        }
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    /// ⌘R (in the clip list) renames the selected clip. Sidebar rows have no
    /// rename of their own — system collections are immutable, and user
    /// collections no longer exist.
    func renameSelectedClip() { beginRename(row: tableView.selectedRow) }

    /// Context-menu rename acts on the right-clicked row, matching Delete.
    @objc private func renameClicked() { beginRename(row: tableView.clickedRow) }

    /// Persist a plain-text edit committed when the preview lost focus. Refreshes
    /// the clipboard to match (a selected clip IS the clipboard) and updates the
    /// edited row's title in place — no full reload, so a concurrent selection
    /// change isn't disturbed. Empty text is left unsaved (the clip keeps its
    /// previous content) rather than beeping mid-blur.
    private func commitEdit(_ newText: String) {
        guard let id = previewedClipID,
              !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try store.editText(clipID: id, to: newText)
        } catch {
            return
        }
        guard let updated = try? store.clip(id: id) else { return }
        copySelectionToClipboard(updated)
        if let row = listSource.clips.firstIndex(where: { $0.id == id }) {
            listSource.clips[row] = updated
            tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                 columnIndexes: IndexSet(integersIn: 0..<max(1, tableView.numberOfColumns)))
        }
    }

    /// Combine the clicked-or-selected clips' text into a new plain-text clip
    /// (top-to-bottom order), then select it — which puts it on the clipboard.
    @objc private func appendToNewClicked() {
        let ids = targetClipIDs()
        guard ids.count >= 2 else { return }
        do {
            // Attributed to ClipMate itself: the combined clip was made here,
            // not captured from another app (user feedback 2026-07-18 — an
            // empty source rendered as a bare dash).
            let newID = try store.appendToNewClip(clipIDs: ids, sourceApp: Bundle.main.bundleIdentifier)
            reload(selecting: newID)
        } catch {
            NSSound.beep()   // CombineError.noText (all-image selection)
        }
    }

    /// The row the menu was opened on — NOT the selected row. Right-clicking a
    /// row you haven't selected must act on the row under the cursor.
    private func clickedClip() -> Clip? {
        let row = tableView.clickedRow
        guard row >= 0, row < listSource.clips.count else { return nil }
        return listSource.clips[row]
    }

    /// Move to…/Restore's target set (Task 7 Step 1): the full selection when
    /// the clicked row is part of it, otherwise the clicked row alone — the
    /// standard Finder behavior. Move-to, Append, and Delete act on the
    /// clicked-or-selected set.
    private func targetClipIDs() -> [Int64] {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < listSource.clips.count else { return [] }
        let selected = tableView.selectedRowIndexes
        let rows = selected.contains(clickedRow) ? selected : IndexSet([clickedRow])
        return rows.compactMap { $0 < listSource.clips.count ? listSource.clips[$0].id : nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard clickedClip() != nil else { return }

        // Single destination: Safe, resolved by kind — never by name or id.
        // InBox stays off (ground state), Trash is reached via Delete.
        moveToItem.representedObject = allCollections.first(where: { $0.kind == .safe })?.id
        moveToItem.isEnabled = moveToItem.representedObject != nil

        restoreItem.isHidden = currentCollectionKind != .trash
        deleteItem.title = currentCollectionKind == .trash ? "Delete Immediately…" : "Delete"

        // Append needs at least two clips (clicked-or-selected set).
        appendItem.isHidden = targetClipIDs().count < 2
    }

    @objc private func moveToTopClicked() { moveClipsToTop(targetClipIDs()) }

    private func moveClipsToTop(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        do {
            try store.moveToTop(clipIDs: ids)
        } catch {
            presentCollectionError(error)   // Never silent (spec §9).
        }
        reload()
    }

    @objc private func moveToCollectionClicked(_ sender: NSMenuItem) {
        guard let collectionID = sender.representedObject as? Int64 else { return }
        let ids = targetClipIDs()
        guard !ids.isEmpty else { return }
        do {
            try collections.moveClips(ids, to: collectionID)
        } catch {
            // Never silent (spec §9).
            presentCollectionError(error)
        }
        reload()
    }

    /// Moves clips back to InBox (Task 7 Step 3). moveClips resets movedAt,
    /// so a restored clip starts its retention clock over rather than being
    /// instantly re-evicted by whatever made it cascade in the first place.
    @objc private func restoreClicked() {
        let ids = targetClipIDs()
        guard !ids.isEmpty else { return }
        do {
            let inbox = try collections.collection(kind: .inbox)
            guard let inboxID = inbox.id else { throw CollectionError.notFound }
            try collections.moveClips(ids, to: inboxID)
        } catch {
            // Never silent (spec §9).
            presentCollectionError(error)
        }
        reload()
    }

    /// The deliberate exception to "a clip is never lost by accident" (Task 7
    /// Step 3): destructive, so it is gated behind a confirming NSAlert that
    /// states the true count, and it is NEVER invoked on quit.
    @objc private func emptyTrashClicked() {
        let count: Int
        do {
            let trash = try collections.collection(kind: .trash)
            guard let trashID = trash.id else { throw CollectionError.notFound }
            count = try collections.clipIDs(in: trashID).count
        } catch {
            presentCollectionError(error)
            return
        }
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Empty Trash?"
        alert.informativeText = "This will permanently delete \(count) clip\(count == 1 ? "" : "s"). This cannot be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try collections.emptyTrash()
        } catch {
            // Never silent (spec §9).
            presentCollectionError(error)
        }
        reload()
    }

    /// Menu Delete and ⌫ share deleteClips: outside Trash a MOVE
    /// (recoverable); inside Trash the existing Delete Immediately alert
    /// guards the plain gesture — the un-modified key never destroys
    /// silently. The menu acts on the clicked-or-selected set
    /// (targetClipIDs, Finder semantics); the keyboard acts on the
    /// selection.
    @objc private func deleteClicked() {
        deleteClips(targetClipIDs())
    }

    private func deleteSelectionToTrash() {
        deleteClips(selectedClipIDs())
    }

    private func deleteSelectionPermanently() {
        deleteClipsPermanently(selectedClipIDs())
    }

    private func selectedClipIDs() -> [Int64] {
        tableView.selectedRowIndexes.compactMap {
            $0 < listSource.clips.count ? listSource.clips[$0].id : nil
        }
    }

    private func deleteClips(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        guard currentCollectionKind != .trash else {
            confirmThenDeletePermanently(ids)
            return
        }
        do {
            let trash = try collections.collection(kind: .trash)
            guard let trashID = trash.id else { throw CollectionError.notFound }
            try collections.moveClips(ids, to: trashID)
        } catch {
            // Never silent (spec §9).
            presentCollectionError(error)
        }
        reload()
    }

    /// ⌥⌫ — instant, no dialog (user decision, spec 2026-07-19): the ⌥
    /// modifier is the deliberate signal, matching Maccy.
    private func deleteClipsPermanently(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        do {
            try store.delete(clipIDs: ids)
        } catch {
            // Never silent (spec §9).
            presentCollectionError(error)
        }
        reload()
    }

    private func confirmThenDeletePermanently(_ ids: [Int64]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ids.count == 1
            ? "Delete Immediately?"
            : "Delete \(ids.count) Clips Immediately?"
        alert.informativeText = ids.count == 1
            ? "This will permanently delete this clip. This cannot be undone."
            : "This will permanently delete \(ids.count) clips. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteClipsPermanently(ids)
    }

    /// Enter or double-click: auto-paste into the app the user came from.
    /// Dismiss first (like the QuickPanel orders itself out before pasting) so
    /// the Explorer isn't the frontmost app when PasteService re-activates the
    /// target and synthesizes ⌘V.
    @objc private func pasteSelected() {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < listSource.clips.count,
              let id = listSource.clips[tableView.selectedRow].id else { return }
        pasteClip(id: id)
    }

    /// Enter, double-click, and ⌘⏎ (list or editing preview) all land here.
    private func pasteClip(id: Int64) {
        let fidelity = PastePreference.currentFidelity()   // read ⌥ now, not inside the Task
        // Resign so isEditing clears and reload() works while hidden — must precede hide().
        window?.makeFirstResponder(nil)
        hide()
        Task { @MainActor in
            do {
                try await paste.paste(clipID: id, fidelity: fidelity)
            } catch let error as PasteError {
                let alert = NSAlert()
                alert.messageText = "Couldn't paste"
                alert.informativeText = error.userMessage
                alert.runModal()
            } catch {
                NSLog("[ClipMate] paste failed: \(error)")
            }
        }
    }

    /// macOS 26's scroll-edge effect portals scrolled-off list rows into the
    /// glass titlebar: the theme frame grows a BackdropView (plus
    /// NSScrollPocket machinery) that re-renders the rows' image cells over
    /// the toolbar — the stray "mirror-like icons" the user reported. Every
    /// public lever failed to remove it (frame pinned below the titlebar,
    /// clipsToBounds, automaticallyAdjustsContentInsets=false, removing
    /// .fullSizeContentView, a hard-style titlebar accessory), so hide the
    /// mirror hosts themselves. Private classes matched by NAME, no private
    /// API: if a future macOS renames them the sweep finds nothing and the
    /// app is merely back to showing the system effect.
    private func hideTitlebarScrollMirrors() {
        guard let content = window?.contentView, let frame = content.superview else { return }
        let stripFloor = content.frame.maxY - 0.5
        func sweep(_ v: NSView) {
            let name = String(describing: type(of: v))
            if name.contains("ScrollPocket") || name.contains("ScrollViewMirror") {
                v.isHidden = true
                return
            }
            // The row-copy hosts are bare "BackdropView"s: one placed in the
            // titlebar strip of the theme frame, and one the scroll view
            // grows over its column-header band. Backdrops elsewhere are real
            // material — leave those alone.
            if name == "BackdropView",
               (v.superview === frame && v.convert(v.bounds, to: nil).minY >= stripFloor)
                || v.superview is NSScrollView {
                v.isHidden = true
                return
            }
            for s in v.subviews { sweep(s) }
        }
        sweep(frame)
    }

    /// Named present(), not showWindow() — NSWindowController already has
    /// showWindow(_:) and an arity-only overload is a recursion trap.
    func present() {
        // The Explorer is for managing, so unlike the QuickPanel it is allowed
        // to take focus.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        reload()
        // The clip list is the primary pane: focus it so arrow keys drive the
        // list, not the sidebar.
        window?.makeFirstResponder(tableView)
        // Layout settles a tick after showWindow; rescue the preview THEN.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rescuePreviewIfCollapsed()
            self.window?.makeFirstResponder(self.tableView)
            self.hideTitlebarScrollMirrors()
        }
    }

    /// If the preview pane has been squeezed to almost nothing (a bad restored
    /// divider position), re-center the split so the detail pane is never lost —
    /// a belt-and-suspenders backstop to the min-height delegate constraints.
    private func rescuePreviewIfCollapsed() {
        guard let split = listPreviewSplit, split.bounds.height > 0 else { return }
        if preview.view.frame.height < 80 {
            split.setPosition(split.bounds.height * 0.5, ofDividerAt: 0)
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let clipSearch = NSToolbarItem.Identifier("ClipMate.search")
}
