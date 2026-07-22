import AppKit
import ClipMateCore

/// Search field + list. See DIAGRAMS.md §2.2.
///
/// @MainActor: an NSViewController driving live AppKit UI, constructed and
/// driven entirely from the main thread by QuickPanel.
@MainActor
final class QuickPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: ClipStore
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let targetAppLabel = NSTextField(labelWithString: "")
    /// Shown centered over the list when it has no rows (UI Polish 2 §6).
    private let emptyState = EmptyStateView()

    private var clips: [Clip] = []
    /// clipID -> thumbnail bytes, so an image clip shows its own preview as the
    /// row icon instead of a generic glyph. Loaded per reload, capped by the
    /// store; the full blob stays the paste path's problem.
    private var thumbnails: [Int64: Data] = [:]

    var onPaste: ((Int64) -> Void)?
    var onDismiss: (() -> Void)?
    var targetName: String?

    init(store: ClipStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        // Frosted vibrancy behind the whole panel — the signature modern-macOS
        // material (Spotlight/Raycast). The window is cleared to transparent in
        // QuickPanel so this shows through; the table draws clear over it.
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active

        searchField.placeholderString = "Search clips"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 15)
        searchField.controlSize = .large
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell?.image =
            NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        // Hairline under the search field, separating query from results.
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        let column = NSTableColumn(identifier: .init("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelected)
        tableView.style = .inset
        tableView.backgroundColor = .clear          // let the vibrancy through
        tableView.selectionHighlightStyle = .regular // rounded accent selection

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Footer: a hairline above a compact hint line.
        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerDivider)

        // Static key hints live left; the dynamic paste target lives right —
        // two zones, so neither rewrites the other on every reload.
        targetLabel.stringValue = "↩ Paste · esc Dismiss"
        targetLabel.font = .systemFont(ofSize: 11)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(targetLabel)
        targetAppLabel.font = .systemFont(ofSize: 11)
        targetAppLabel.textColor = .tertiaryLabelColor
        targetAppLabel.lineBreakMode = .byTruncatingTail
        targetAppLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(targetAppLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -4),

            footerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: targetLabel.topAnchor, constant: -6),

            targetLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            targetLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            targetAppLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            targetAppLabel.centerYAnchor.constraint(equalTo: targetLabel.centerYAnchor),
            targetAppLabel.leadingAnchor.constraint(greaterThanOrEqualTo: targetLabel.trailingAnchor, constant: 12),
        ])

        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        view = container
    }

    /// Reload from the store. Plain typing filters — no prefix, no threshold.
    /// ClipMate needed '?' only because it had no search field (spec §8).
    ///
    /// Typing resets to the top result (row 0); a permanent delete must not,
    /// or ⌥⌫ would throw away your place in the list.
    func reload(preservingSelection: Bool = false) {
        let keepID = preservingSelection ? selectedClip()?.id : nil
        do {
            clips = try store.search(searchField.stringValue, limit: 200)
        } catch {
            // Never silent (spec §9). An empty list here means "no results" to
            // the user, so a failed read must at least be diagnosable.
            NSLog("[ClipMate] clip search failed: \(error)")
            clips = []
        }
        // Thumbnails for the row icons — one query, thumbs only, never the full
        // blob (spec §5, AMEND-8). A failed read just falls back to app icons.
        do {
            thumbnails = try store.thumbnails(for: clips.compactMap(\.id))
        } catch {
            NSLog("[ClipMate] thumbnail read failed: \(error)")
            thumbnails = [:]
        }
        tableView.reloadData()
        if !clips.isEmpty {
            let row = keepID.flatMap { id in clips.firstIndex(where: { $0.id == id }) } ?? 0
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        if clips.isEmpty {
            if searchField.stringValue.isEmpty {
                emptyState.configure(symbol: "doc.on.clipboard", title: "No Clips",
                                     hint: "Everything you copy will appear here.")
            } else {
                emptyState.configure(symbol: "magnifyingglass", title: "No Results",
                                     hint: "No clips match “\(searchField.stringValue)”.")
            }
        }
        emptyState.isHidden = !clips.isEmpty
        targetAppLabel.stringValue = targetName.map { "Pasting into \($0)" } ?? ""
    }

    private func selectedClip() -> Clip? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < clips.count else { return nil }
        return clips[tableView.selectedRow]
    }

    /// ⌥⌫ — permanent delete, instant, no confirmation (user decision, spec
    /// 2026-07-19). An explicit destruction path, never silent: the chord is
    /// the consent. Selection then lands on the next row, Maccy-style, so
    /// repeated ⌥⌫ walks down the list.
    func deleteSelectionPermanently() {
        guard let clip = selectedClip(), let id = clip.id else { return }
        let row = tableView.selectedRow
        do {
            try store.delete(clipIDs: [id])
        } catch {
            // Never silent (spec §9). Content-free by rule.
            NSLog("[ClipMate] permanent delete failed: \(error)")
        }
        reload(preservingSelection: false)
        if tableView.numberOfRows > 0 {
            let next = min(max(row, 0), tableView.numberOfRows - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        }
    }

    /// ⌘T — Move to Top (spec 2026-07-21). The clip jumps to row 0 in every
    /// list; selection follows it (preservingSelection tracks by id).
    func moveSelectionToTop() {
        guard let clip = selectedClip(), let id = clip.id else { return }
        do {
            try store.moveToTop(clipIDs: [id])
        } catch {
            NSLog("[ClipMate] move to top failed: \(error)")   // Never silent; content-free.
        }
        reload(preservingSelection: true)
        tableView.scrollRowToVisible(tableView.selectedRow)
    }

    func prepareForDisplay(targetName: String?) {
        self.targetName = targetName
        searchField.stringValue = ""
        // Opening must render instantly with the emptied query — never race a
        // stale pending keystroke reload from the previous showing.
        searchDebouncer.cancel()
        reload()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - NSSearchFieldDelegate

    /// One query per typing pause, not per keystroke (Maccy G7). Enter during
    /// the 200 ms window pastes the row the user SEES (the last rendered
    /// list) — that is the correct behavior, not staleness.
    private let searchDebouncer = Debouncer(delay: .milliseconds(200))

    func controlTextDidChange(_ obj: Notification) {
        searchDebouncer.call { [weak self] in self?.reload() }
    }

    /// Route Return / Escape / arrows from the search field to us, so the user
    /// never has to tab into the list.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            pasteSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = clips[row]
        let cell = NSTableCellView()

        // Leading icon (32pt): the clip's own thumbnail for image clips, else
        // the source app's icon, else a neutral clipboard glyph. A scannable
        // list needs a picture per row far more than it needs another word.
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 6
        icon.layer?.masksToBounds = true
        icon.layer?.borderWidth = 0.5
        icon.layer?.borderColor = NSColor.separatorColor.cgColor
        if let id = clip.id, let thumb = thumbnails[id], let image = NSImage(data: thumb) {
            icon.image = image
        } else if let appIcon = AppNameResolver.shared.icon(for: clip.sourceApp) {
            icon.image = appIcon
            icon.layer?.borderWidth = 0            // app icons carry their own shape
        } else {
            icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.layer?.borderWidth = 0
        }
        cell.addSubview(icon)

        let title = NSTextField(labelWithString: clip.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)

        // lastUsedAt, matching the sort order (AMEND-1) — a row that just
        // floated to the top must not caption itself "2 days ago".
        let subtitleText = [AppNameResolver.shared.displayName(for: clip.sourceApp), Self.relativeDate(clip.lastUsedAt)]
            .compactMap { $0 }
            .joined(separator: " · ")
        let subtitle = NSTextField(labelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(subtitle)

        let textTrailing = title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textTrailing,
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
        ])
        return cell
    }

    private static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    @objc func pasteSelected() {
        guard let id = selectedClip()?.id else { return }
        onPaste?(id)
    }

    private func moveSelection(by delta: Int) {
        guard !clips.isEmpty else { return }
        let next = max(0, min(clips.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

/// Spotlight-style: the selected row stays accent-emphasized even while the
/// search field is first responder — in a command palette, gray selection
/// reads as "not ready", which is never true here.
@MainActor
final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}
