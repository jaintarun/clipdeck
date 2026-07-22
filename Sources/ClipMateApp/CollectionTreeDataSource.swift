import AppKit
import ClipMateCore

/// What the sidebar can be showing. Smart collections (SMART) are queries;
/// the system collections under MY CLIPS (InBox, Safe — and Trash, selected
/// via its bottom anchor rather than a tree row) are membership. Deliberately
/// not merged — they are different mechanisms and pretending otherwise would
/// force one to fake the other.
enum SidebarSelection: Equatable {
    case smart(SmartCollection)
    case user(Int64)
}

/// The sidebar. Two groups: MY CLIPS (InBox and Safe — real stored rows) and
/// SMART (queries, unchanged from L1). Trash is not one of the tree's rows;
/// it's anchored below the scroll view (Task 3).
///
/// @MainActor: this toolchain infers NSOutlineViewDataSource/Delegate methods
/// as MainActor-isolated (AppKit's stricter default here), so the type must
/// declare the isolation explicitly — same reasoning as QuickPanelViewController.
@MainActor
final class CollectionTreeDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// A class, not a struct: NSOutlineView identifies items by pointer, so
    /// value types break expansion state and selection. The three Group
    /// instances are created once and never replaced; only `.items` is
    /// mutated on reload, so their own expand state survives too.
    final class Group: NSObject {
        let title: String
        var items: [Any]
        init(title: String, items: [Any] = []) {
            self.title = title
            self.items = items
        }
    }

    /// Wraps a stored Collection (system or user) as a class, mutated in
    /// place across reload() rather than replaced. NSOutlineView tracks
    /// selection and expansion by item identity — a fresh object every
    /// reload (e.g. because a rename changed `name`) would look like a
    /// brand-new item and silently drop the user's selection.
    final class CollectionNode: NSObject {
        var collection: Collection
        var children: [CollectionNode] = []
        init(_ collection: Collection) { self.collection = collection }
    }

    private let myClipsGroup = Group(title: "My Clips")
    // Every SmartCollection case except .inbox: SmartCollection.inbox and
    // .everything run the identical query (ClipStore.clips(in:) has
    // `case .inbox, .everything:` sharing one ORDER BY lastUsedAt DESC), so a
    // SMART "InBox" row would be a dead duplicate of SMART's "Everything" —
    // and it clashes by name with the real system InBox under MY CLIPS,
    // which queries by membership instead. Fixed for the data source's
    // whole lifetime.
    private let smartGroup = Group(title: "Smart", items: [
        SmartCollection.today, SmartCollection.thisWeek, SmartCollection.images,
        SmartCollection.everything,
    ])
    private var groups: [Group] { [myClipsGroup, smartGroup] }

    /// Every known CollectionNode, system and user, keyed by id — reused
    /// across update(with:) calls so pointer identity survives a reload.
    private var nodesByID: [Int64: CollectionNode] = [:]

    var onSelect: ((SidebarSelection) -> Void)?

    /// Fired when clip IDs are dropped on a valid target collection (Task 7
    /// Step 2). The controller does the actual move (it owns CollectionStore)
    /// and the reload; this data source only decodes the drop and picks the
    /// destination.
    var onDrop: (([Int64], Int64) -> Void)?

    /// Rebuilds the two groups from a fresh `CollectionStore.all()` fetch.
    /// Reuses existing CollectionNode objects where the id already exists
    /// (mutating `.collection` in place) so item-identity selection and
    /// expansion survive the reload — see CollectionNode's doc comment.
    func update(with collections: [Collection]) {
        var seen = Set<Int64>()
        func node(for c: Collection) -> CollectionNode {
            guard let id = c.id else { return CollectionNode(c) }
            seen.insert(id)
            if let existing = nodesByID[id] {
                existing.collection = c
                return existing
            }
            let created = CollectionNode(c)
            nodesByID[id] = created
            return created
        }

        // Trash lives at the sidebar's bottom anchor, not in the tree (Task 3).
        let system = collections.filter { $0.isSystem && $0.kind != .trash }.sorted { $0.sortKey < $1.sortKey }
        myClipsGroup.items = system.map(node(for:))

        // Drop nodes for collections that no longer exist, so the cache
        // doesn't grow without bound over a long-running session.
        nodesByID = nodesByID.filter { seen.contains($0.key) }
    }

    func node(forID id: Int64) -> CollectionNode? { nodesByID[id] }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? Group { return group.items.count }
        if let node = item as? CollectionNode { return node.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        if let group = item as? Group { return group.items[index] }
        return (item as! CollectionNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is Group { return true }
        if let node = item as? CollectionNode { return !node.children.isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SmartCollection || item is CollectionNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? Group {
            // Native source-list header styling (UI Polish 2 §2).
            let label = NSTextField(labelWithString: group.title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        if let smart = item as? SmartCollection {
            return makeCell(icon: smart.systemImageName, title: smart.title, badge: smart.retentionBadge, node: nil)
        }
        if let node = item as? CollectionNode {
            return makeCell(icon: Self.iconName(for: node.collection), title: node.collection.name, badge: nil, node: node)
        }
        return nil
    }

    private static func iconName(for collection: Collection) -> String {
        switch collection.kind {
        case .inbox:    return "tray"
        case .trash:    return "trash"
        case .safe:     return "lock.shield"
        case nil:       return "folder"
        }
    }

    /// Shared by SmartCollection and CollectionNode rows so both kinds of
    /// leaf look identical: an icon, a label, and an optional trailing badge.
    /// No row in this tree is inline-renameable — `node` is otherwise unused.
    private func makeCell(icon: String, title: String, badge: String?, node: CollectionNode?) -> NSView {
        let cell = NSTableCellView()
        let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
        // Accent-tinted sidebar glyphs — the Finder/Notes signature (UI Polish 2 §2).
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        let badgeField = NSTextField(labelWithString: badge ?? "")
        badgeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badgeField.textColor = .secondaryLabelColor
        badgeField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(badgeField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badgeField.leadingAnchor, constant: -4),
            badgeField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            badgeField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView else { return }
        let item = outline.item(atRow: outline.selectedRow)
        if let smart = item as? SmartCollection {
            onSelect?(.smart(smart))
        } else if let node = item as? CollectionNode, let id = node.collection.id {
            onSelect?(.user(id))
        }
    }

    func expandAll(_ outlineView: NSOutlineView) {
        for group in groups { outlineView.expandItem(group) }
    }

    // MARK: - Drop target (Task 7 Step 2)

    /// Safe accepts filed clips; InBox rejects — it is the ground state
    /// capture populates, not a filing cabinet. Safe is a destination on
    /// purpose: promoting a clip to never-purged is a filing gesture. Trash
    /// is no longer a tree row (Task 3) — its drop target is the bottom
    /// anchor, not this outline.
    private func isDropTarget(_ node: CollectionNode) -> Bool {
        node.collection.kind == .trash || node.collection.kind == .safe
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = item as? CollectionNode, isDropTarget(node) else { return [] }
        // File INTO the collection, never reorder or nest among its children.
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        guard let node = item as? CollectionNode, isDropTarget(node), let collectionID = node.collection.id
        else { return false }
        let clipIDs = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: ClipListDataSource.clipIDPasteboardType).flatMap(Int64.init)
        }
        guard !clipIDs.isEmpty else { return false }
        onDrop?(clipIDs, collectionID)
        return true
    }
}
