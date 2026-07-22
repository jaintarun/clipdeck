import AppKit
import ClipMateCore

/// The clip list: Title | Source | Date. ClipMate's ClipList, modern clothes.
///
/// @MainActor: this toolchain infers NSTableViewDataSource/Delegate methods
/// as MainActor-isolated (AppKit's stricter default here), so the type must
/// declare the isolation explicitly — same reasoning as QuickPanelViewController.
@MainActor
final class ClipListDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// PRIVATE — carries clip IDs only, never content. A drag is not a copy:
    /// content on a shared pasteboard type would round-trip through our own
    /// CaptureEngine (which polls NSPasteboard.general) and re-capture the
    /// drag as a brand-new clip — an infinite-feedback bug and a privacy leak.
    /// Also used by CollectionTreeDataSource, the drop target.
    static let clipIDPasteboardType = NSPasteboard.PasteboardType("com.clipmateclone.clipIDs")

    var clips: [Clip] = []
    /// clipID -> thumbnail bytes. Only thumbs are loaded for the list; the
    /// full blob is the preview pane's problem.
    var thumbnails: [Int64: Data] = [:]
    /// clipID -> total payload bytes, for the size shown in each row's subtitle.
    var byteSizes: [Int64: Int] = [:]
    /// clipID -> kind (Text / Image / File), for the Type column.
    var kinds: [Int64: ClipKind] = [:]
    /// The primary-content hash of whatever is on the system clipboard right
    /// now, or nil if the clipboard holds something we have no clip for. The row
    /// whose `contentHash` equals this draws its selection blue (emphasized) —
    /// ClipMate's "this row IS your clipboard" signal — while any other selected
    /// row draws gray. Set by ExplorerWindowController on reload and on
    /// selection-driven copies.
    var clipboardHash: Data?

    var onSelect: ((Clip) -> Void)?
    /// Fired when an inline title edit commits: (clipID, newTitle). The
    /// controller performs the store write and reloads. Nil-safe.
    var onRename: ((Int64, String) -> Void)?

    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }

    /// Inline title edit finished. tag carries the clip id (set in viewFor). On
    /// Escape the field already reverted its text and the movement is `.cancel`,
    /// so nothing is written — the rename-cancel gate. Any other ending (Return,
    /// Tab, click-away) commits.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.tag >= 0 else { return }
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue { return }
        onRename?(Int64(field.tag), field.stringValue)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }

        switch columnID {
        case "title":
            let cell = NSTableCellView()
            // Leading icon: thumbnail for image clips, else the source app's
            // icon, else a clipboard glyph — the polish carries over into the
            // columnar table.
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.wantsLayer = true
            icon.layer?.cornerRadius = 4
            icon.layer?.masksToBounds = true
            icon.translatesAutoresizingMaskIntoConstraints = false
            if let clipID = clip.id, let thumb = thumbnails[clipID], let image = NSImage(data: thumb) {
                icon.image = image
                icon.layer?.borderWidth = 0.5
                icon.layer?.borderColor = NSColor.separatorColor.cgColor
            } else if let appIcon = AppNameResolver.shared.icon(for: clip.sourceApp) {
                icon.image = appIcon
            } else {
                icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
                icon.contentTintColor = .secondaryLabelColor
            }
            cell.addSubview(icon)

            let label = NSTextField(labelWithString: clip.title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            // Inline rename: the field stays a label (isEditable false) until ⌘R
            // flips it in the controller's beginRename; tag correlates the commit
            // back to this clip — the same convention as the sidebar's rename.
            label.tag = clip.id.map(Int.init) ?? -1
            label.delegate = self
            cell.addSubview(label)
            cell.textField = label

            let labelTrailing = label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                labelTrailing,
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "type":
            // A glyph, not a word (UI Polish 2 §3) — the word lives in the tooltip.
            let cell = NSTableCellView()
            let iv = NSImageView()
            if let kind = clip.id.flatMap({ kinds[$0] }) {
                iv.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.label)
                iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                iv.contentTintColor = .secondaryLabelColor
                cell.toolTip = kind.label
            }
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case "source":
            let name = AppNameResolver.shared.displayName(for: clip.sourceApp) ?? "—"
            return Self.makeTextCell(name, alignment: .left)

        case "date":
            // lastUsedAt (AMEND-1), as an absolute date + time rather than a
            // relative "2 hr. ago" — the user asked to see the actual timestamp.
            return Self.makeTextCell(CompactDate.string(from: clip.lastUsedAt), alignment: .left,
                                     font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))

        case "size":
            let bytes = clip.id.flatMap { byteSizes[$0] }
            // Sub-KB reads "863 B", not ByteCountFormatter's "863 bytes" — the
            // long form overflows the Size column's 58pt budget.
            let text = bytes.map {
                $0 < 1024 ? "\($0) B"
                          : ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "—"
            return Self.makeTextCell(text, alignment: .right,
                                     font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))

        default:
            return nil
        }
    }

    /// A plain columnar text cell whose single-line label is vertically centered
    /// in the row. Returning a bare NSTextField from viewFor sizes it to the full
    /// row height and draws its line at the TOP — the "text sticks to the top"
    /// bug. Wrapping in an NSTableCellView with a centerY constraint fixes it;
    /// assigning `.textField` lets the cell invert the text to white on a
    /// selected (emphasized) row, matching the Title column.
    private static func makeTextCell(_ string: String, alignment: NSTextAlignment,
                                     font: NSFont = .systemFont(ofSize: 12)) -> NSView {
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alignment = alignment
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Column sorting

    /// The user clicked a column header. Sort in place and redraw. Order isn't
    /// persisted per collection yet (that's L2c); a reload re-applies whatever
    /// sort is active via applyCurrentSort().
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key else { return }
        currentSortKey = key
        currentSortAscending = sort.ascending
        sortClips(key: key, ascending: sort.ascending)
        tableView.reloadData()
    }

    /// Re-apply the active sort after a reload replaced `clips` with a freshly
    /// fetched (lastUsedAt-ordered) list, so a user's chosen sort survives a
    /// capture. No-op until the user has sorted at least once.
    func applyCurrentSort() {
        guard let key = currentSortKey else { return }
        sortClips(key: key, ascending: currentSortAscending)
    }

    private var currentSortKey: String?
    private var currentSortAscending = true

    private func sortClips(key: String, ascending: Bool) {
        let ordered: (Clip, Clip) -> Bool
        switch key {
        case "title":  ordered = { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case "type":   ordered = { (self.kinds[$0.id ?? -1]?.label ?? "").localizedCaseInsensitiveCompare(self.kinds[$1.id ?? -1]?.label ?? "") == .orderedAscending }
        case "source": ordered = {
            (AppNameResolver.shared.displayName(for: $0.sourceApp) ?? "")
                .localizedCaseInsensitiveCompare(AppNameResolver.shared.displayName(for: $1.sourceApp) ?? "") == .orderedAscending
        }
        case "date":   ordered = { $0.lastUsedAt < $1.lastUsedAt }
        case "size":   ordered = { (self.byteSizes[$0.id ?? -1] ?? 0) < (self.byteSizes[$1.id ?? -1] ?? 0) }
        default: return
        }
        clips.sort { ascending ? ordered($0, $1) : ordered($1, $0) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              // A multi-row selection (append/move-to targets) must not drive
              // the preview or the selection-copies-to-clipboard model — acting
              // on "the" selected clip is only meaningful when there is one.
              table.selectedRowIndexes.count == 1,
              table.selectedRow >= 0, table.selectedRow < clips.count else { return }
        onSelect?(clips[table.selectedRow])
    }

    /// A ClipRowView per row so the selection's blue-vs-gray is driven by
    /// clipboard-match, not window focus (see ClipRowView). Cheap — one small
    /// object per visible row.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = ClipRowView()
        rowView.matchesClipboard = matchesClipboard(row)
        return rowView
    }

    /// True when this row's clip is exactly what's on the system clipboard.
    func matchesClipboard(_ row: Int) -> Bool {
        guard row < clips.count, let hash = clipboardHash else { return false }
        return clips[row].contentHash == hash
    }

    // MARK: - Drag source (Task 7 Step 2)

    /// Implementing this alone is what makes NSTableView drag rows — no
    /// separate registration call needed on the source side (only a drop
    /// TARGET calls registerForDraggedTypes). One NSPasteboardItem per
    /// dragged row; NSTableView aggregates them into a single session when
    /// several selected rows are dragged together, so the drop side reads
    /// `draggingPasteboard.pasteboardItems`, not a single item.
    ///
    /// See the type's doc comment: IDs only, never content, never the
    /// general pasteboard — this is the ONLY place a clip drag writes
    /// anything, and it writes to the ephemeral drag pasteboard, not
    /// NSPasteboard.general.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < clips.count, let id = clips[row].id else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(id), forType: Self.clipIDPasteboardType)
        return item
    }

    /// Filing a clip into a collection is a move, not a copy — this also
    /// keeps the drag cursor's badge honest.
    func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        sourceOperationMaskForDraggingContext context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }
}

/// A clip row whose emphasized state — the blue accent selection vs. the gray
/// unfocused one — is decided by whether the clip matches the system clipboard,
/// NOT by whether the window has focus. Blue means "pasting right now gives you
/// this"; gray means the selected clip is not (yet) on the clipboard. Overriding
/// `isEmphasized` is what detaches the selection colour from focus; because it
/// also feeds the cell's backgroundStyle, the text still inverts to white on the
/// blue row and stays dark on the gray one.
@MainActor
final class ClipRowView: NSTableRowView {
    var matchesClipboard = false
    override var isEmphasized: Bool {
        get { matchesClipboard }
        set { }
    }
}
