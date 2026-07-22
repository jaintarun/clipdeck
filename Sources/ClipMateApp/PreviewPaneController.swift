import AppKit
import ClipMateCore

/// The preview pane. A clip with a single representation shows it straight, with
/// no tab chrome; a clip with several (text + image, and RTF/HTML once L2
/// capture lands) gets a small segmented format switcher instead of AppKit's
/// dated floating tab buttons. HTML/RTF will preview as PLAIN TEXT — no web
/// view — per the security floor (DIAGRAMS.md §5.5).
///
/// @MainActor: an NSViewController driving live AppKit UI, constructed and
/// driven entirely from the main thread by ExplorerWindowController — same
/// reasoning as QuickPanelViewController.
@MainActor
final class PreviewPaneController: NSViewController {
    private let headerIcon = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let headerDate = NSTextField(labelWithString: "")
    private let headerRule = NSBox()
    private let formatPicker = NSSegmentedControl()
    private let card = NSBox()
    private let tabView = NSTabView()
    private let footerRule = NSBox()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Right side of the footer status line: whether this clip's text can be
    /// edited in place. Plain-text-only clips are editable; images, files, and
    /// rich text are not (a huge text clip renders read-only too — see show()).
    private let editabilityLabel = NSTextField(labelWithString: "")
    /// The clip's source URL, shown in link color in the footer. Clicking it
    /// opens the page in the user's browser — the only sanctioned "open",
    /// gated behind an explicit click (the app itself makes no connection).
    private let sourceButton = NSButton(title: "", target: nil, action: nil)
    private var currentSourceURL: URL?
    /// Feature 6: visible only while editing — "you're editing; ⌘⏎ pastes".
    /// Lives in the header row's trailing slot so showing it never changes the
    /// pane's height (user feedback 2026-07-18). That slot is guaranteed free:
    /// editable clips are plain-text-only, which renders a single tab, and the
    /// format picker only appears at 2+ tabs.
    private let editHintLabel = NSTextField(labelWithString: "")

    /// Fired when an edit is committed (the editable text view loses focus with
    /// changed text) with the new text. The Explorer persists it and refreshes
    /// the clipboard. Only plain-text clips are editable.
    var onCommitEdit: ((String) -> Void)?
    /// ⌘⏎ while editing: the text-view hook has already committed; the
    /// Explorer pastes the previewed clip.
    var onPasteWhileEditing: (() -> Void)?
    /// True while the editable text view holds keyboard focus — the Explorer
    /// reads this to defer a capture-driven re-select so typing isn't discarded.
    private(set) var isEditing = false
    /// The current clip's editable plain-text view, if any. Held so an edit can
    /// be committed from triggers that DON'T fire resignFirstResponder — the app
    /// losing focus (switching to the paste target) and Escape.
    private weak var editableTextView: FocusReportingTextView?
    private var resignObserver: NSObjectProtocol?

    /// G8: NSTextView layout on a multi-megabyte string beachballs the
    /// Explorer. The preview is a *view*; the clip stores and pastes in full.
    private static let previewCharacterCap = 100_000

    /// The view Tab should land on when cycling into the preview pane — the
    /// current text view, or nil for an image-only clip (Tab then skips the
    /// preview). Rebuilt on every show(), so the Explorer re-wires its key-view
    /// loop after each show.
    private(set) var focusableView: NSView?

    override func loadView() {
        // Inspector layout (UI Polish 2 §4): meta header, content card floating
        // on an under-page material, stats footer. Theme-aware everywhere; the
        // security floor is untouched — text-bearing formats still render as
        // plain text only.
        let container = NSVisualEffectView()
        container.material = .underPageBackground
        container.blendingMode = .withinWindow
        container.state = .followsWindowActiveState

        editHintLabel.isHidden = true
        editHintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        editHintLabel.textColor = .tertiaryLabelColor
        editHintLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editHintLabel)

        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerIcon)
        headerName.font = .systemFont(ofSize: 12, weight: .medium)
        headerName.lineBreakMode = .byTruncatingTail
        headerName.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerName)
        headerDate.font = .systemFont(ofSize: 12)
        headerDate.textColor = .secondaryLabelColor
        headerDate.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerDate)

        formatPicker.segmentStyle = .texturedRounded
        formatPicker.controlSize = .small
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged)
        formatPicker.isHidden = true
        formatPicker.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formatPicker)

        headerRule.boxType = .separator
        headerRule.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerRule)

        card.boxType = .custom
        card.cornerRadius = 8
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .textBackgroundColor
        card.titlePosition = .noTitle
        card.contentViewMargins = .zero
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)

        // No tab bar of its own — the segmented control drives selection.
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(tabView)

        footerRule.boxType = .separator
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerRule)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Yield first when the footer is tight: the size/char/word stats truncate
        // so the source link and the editability note keep their full text.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        sourceButton.isBordered = false
        sourceButton.bezelStyle = .inline
        sourceButton.contentTintColor = .linkColor
        sourceButton.font = .systemFont(ofSize: 11)
        sourceButton.alignment = .right
        sourceButton.lineBreakMode = .byTruncatingMiddle
        sourceButton.target = self
        sourceButton.action = #selector(openSource)
        sourceButton.isHidden = true
        sourceButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sourceButton)
        editabilityLabel.font = .systemFont(ofSize: 11)
        editabilityLabel.textColor = .secondaryLabelColor
        editabilityLabel.alignment = .right
        editabilityLabel.lineBreakMode = .byTruncatingTail
        editabilityLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        editabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editabilityLabel)

        let cardContent = card.contentView!
        NSLayoutConstraint.activate([
            headerIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerIcon.centerYAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalToConstant: 18),
            headerName.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 6),
            headerName.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            headerDate.leadingAnchor.constraint(equalTo: headerName.trailingAnchor, constant: 6),
            headerDate.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            headerDate.trailingAnchor.constraint(lessThanOrEqualTo: formatPicker.leadingAnchor, constant: -8),
            formatPicker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            formatPicker.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            editHintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            editHintLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            editHintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: headerDate.trailingAnchor, constant: 8),
            headerRule.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            headerRule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            card.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: footerRule.topAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            tabView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),

            footerRule.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -26),
            footerRule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
            editabilityLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            editabilityLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            editabilityLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            // Source link sits just left of the editability note; both hug the right.
            sourceButton.trailingAnchor.constraint(equalTo: editabilityLabel.leadingAnchor, constant: -8),
            sourceButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            sourceButton.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            sourceButton.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.5),
        ])
        view = container

        // Commit an in-progress edit the moment ClipMate loses focus — the user is
        // switching to the paste target, so the edited text must already be on the
        // clipboard. resignFirstResponder does NOT fire on app deactivation.
        // Not removed: this controller lives for the app's lifetime, and the
        // block's [weak self] no-ops if it ever outlived the controller.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingEdit() }
        }
    }

    @objc private func openSource() {
        guard let url = currentSourceURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Inline edit

    /// Only genuinely plain-text clips are editable: a clip carrying RTF/HTML or
    /// an image stays read-only so its formatting can't be flattened by a stray
    /// keystroke. The text view edits like a plain-text editor (Return inserts a
    /// newline), committing to the store when it loses focus.
    private static func isEditableClip(_ reps: [ClipRepresentation]) -> Bool {
        let hasPlainText = reps.contains { $0.utiIdentifier == SupportedTypes.plainText }
        let hasNonText = reps.contains { rep in
            rep.utiIdentifier == SupportedTypes.rtf
                || rep.utiIdentifier == SupportedTypes.html
                || rep.utiIdentifier == SupportedTypes.fileURL
                || SupportedTypes.images.contains(rep.utiIdentifier)
        }
        return hasPlainText && !hasNonText
    }

    /// Commit the in-progress plain-text edit if its text changed. Idempotent —
    /// called from every "editing is over" trigger: blur (resignFirstResponder),
    /// Escape, and app deactivation. Guarding on `originalText` means repeated
    /// calls (e.g. app-resign then blur) write at most once.
    func commitPendingEdit() {
        guard let tv = editableTextView, tv.isEditable, tv.string != tv.originalText else { return }
        tv.originalText = tv.string
        onCommitEdit?(tv.string)
    }

    private func setEditHint(visible: Bool) {
        // Text is set only while visible: an empty label has zero intrinsic
        // width, so the hidden hint reserves no header space and showing or
        // hiding it never moves anything else in the pane.
        editHintLabel.isHidden = !visible
        editHintLabel.stringValue = visible ? "Press ⌘⏎ to paste" : ""
    }

    func show(clip: Clip?, representations: [ClipRepresentation]) {
        setEditHint(visible: false)
        let hasContent = clip != nil
        for v: NSView in [headerIcon, headerName, headerDate, headerRule, card, footerRule, statusLabel, editabilityLabel] {
            v.isHidden = !hasContent
        }
        if let clip {
            headerIcon.image = AppNameResolver.shared.icon(for: clip.sourceApp)
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            headerName.stringValue = AppNameResolver.shared.displayName(for: clip.sourceApp) ?? "Clipboard"
            headerDate.stringValue = "· \(CompactDate.string(from: clip.lastUsedAt))"
        }
        if let s = clip?.sourceURL, let url = URL(string: s) {
            currentSourceURL = url
            sourceButton.title = s
            sourceButton.isHidden = false
        } else {
            currentSourceURL = nil
            sourceButton.isHidden = true
        }

        for item in tabView.tabViewItems { tabView.removeTabViewItem(item) }
        focusableView = nil
        editableTextView = nil

        // Render every text-bearing format to PLAIN TEXT (security floor: no web
        // engine — see PlainTextRendering) and dedupe by the rendered string, so a
        // clip carrying text + RTF + HTML of the same words shows one tab, not
        // three. Only genuinely different renderings earn their own tab.
        var textTabs: [(label: String, text: String)] = []
        func addText(_ label: String, _ text: String) {
            guard !textTabs.contains(where: { $0.text == text }) else { return }
            textTabs.append((label, text))
        }

        // A screenshot arrives as BOTH png and tiff (sometimes jpeg too); to the
        // user those are the same picture, so keep only the first.
        var imageRep: ClipRepresentation?
        for rep in representations {
            switch rep.utiIdentifier {
            case SupportedTypes.plainText:
                addText("Text", String(data: rep.data, encoding: .utf8) ?? "")
            case SupportedTypes.rtf:
                if let t = PlainTextRendering.fromRTF(rep.data) { addText("Rich Text", t) }
            case SupportedTypes.html:
                addText("HTML", PlainTextRendering.fromHTML(String(data: rep.data, encoding: .utf8) ?? ""))
            case SupportedTypes.png, SupportedTypes.tiff, SupportedTypes.jpeg:
                if imageRep == nil { imageRep = rep }
            default:
                break
            }
        }

        // Text tabs first, image last.
        let editable = Self.isEditableClip(representations)
        for (label, text) in textTabs {
            // G8: cap what the text view LAYS OUT, never what's stored. An
            // oversized clip must also render read-only — an edit committed
            // from a truncated view would write the truncation back and
            // destroy the tail.
            let truncated = text.count > Self.previewCharacterCap
            let shown = truncated
                ? String(text.prefix(Self.previewCharacterCap))
                  + "\n\n— Preview shows the first \(Self.previewCharacterCap.formatted()) of \(text.count.formatted()) characters. The clip is stored, and pastes, in full. —"
                : text
            let tabEditable = editable && !truncated
            let textView = FocusReportingTextView()
            textView.onFocusChange = { [weak self] focused in
                // Track focus of the editable view so the Explorer defers reloads
                // while the user is typing; the hint banner mirrors it.
                if tabEditable {
                    self?.isEditing = focused
                    self?.setEditHint(visible: focused)
                }
            }
            textView.string = shown
            textView.originalText = shown
            textView.isEditable = tabEditable
            textView.isSelectable = true
            textView.onEndEdit = { [weak self] in self?.commitPendingEdit() }
            if tabEditable {
                textView.onPasteKey = { [weak self] in
                    self?.commitPendingEdit()   // commit BEFORE paste — what lands is what was typed
                    self?.onPasteWhileEditing?()
                }
            }
            if tabEditable { editableTextView = textView }   // one text tab for plain-text clips
            textView.font = .systemFont(ofSize: 13)
            textView.textContainerInset = NSSize(width: 12, height: 10)
            textView.drawsBackground = false
            let scroll = NSScrollView()
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false

            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = scroll
            tabView.addTabViewItem(item)
            if focusableView == nil { focusableView = textView }   // Tab lands on the first text view
        }

        // Files (UI Polish 2 §4): show what a file clip actually references —
        // display-only, from the stored URL strings; file bytes are never read.
        // Skipped when the clip carries image data (a CleanShot/screenshot file
        // copy): the user wants the picture immediately, not a path list
        // (user feedback, 2026-07-18).
        if imageRep == nil,
           let fileRep = representations.first(where: { $0.utiIdentifier == SupportedTypes.fileURL }) {
            let urls = FileClip.decode(fileRep.data)
            if !urls.isEmpty {
                let item = NSTabViewItem(identifier: "files")
                item.label = "Files"
                item.view = Self.makeFileList(urls)
                tabView.addTabViewItem(item)
            }
        }

        if let imageRep {
            let imageView = NSImageView()
            imageView.image = NSImage(data: imageRep.data)
            imageView.imageScaling = .scaleProportionallyDown

            let item = NSTabViewItem(identifier: "image")
            item.label = "Image"
            item.view = imageView
            tabView.addTabViewItem(item)
        }

        // The switcher only earns its space when there's a real choice to make.
        let items = tabView.tabViewItems
        if items.count > 1 {
            formatPicker.isHidden = false
            formatPicker.segmentCount = items.count
            for (i, item) in items.enumerated() {
                formatPicker.setLabel(item.label, forSegment: i)
                formatPicker.setWidth(0, forSegment: i)   // size to fit
            }
            formatPicker.selectedSegment = 0
        } else {
            formatPicker.isHidden = true
        }

        statusLabel.stringValue = Self.statusText(representations: representations)
        // Right of the status line: the in-place edit affordance. Mirrors the
        // actual editable text view (nil for images, files, rich text, and
        // oversized text that rendered read-only), so it never over-promises.
        editabilityLabel.stringValue = editableTextView != nil
            ? "Text clip can be edited."
            : "Clip cannot be edited."
    }

    @objc private func formatChanged() {
        let index = formatPicker.selectedSegment
        guard index >= 0, index < tabView.numberOfTabViewItems else { return }
        tabView.selectTabViewItem(at: index)
    }

    /// One row per referenced file: Finder icon + name + parent path. Local
    /// metadata lookups only (NSWorkspace icon, path strings) — never contents.
    private static func makeFileList(_ urls: [URL]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for url in urls {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
            ])
            let name = NSTextField(labelWithString: url.lastPathComponent)
            name.font = .systemFont(ofSize: 13)
            let path = NSTextField(labelWithString: url.deletingLastPathComponent().path)
            path.font = .systemFont(ofSize: 11)
            path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let text = NSStackView(views: [name, path])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            let row = NSStackView(views: [icon, text])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // The document must be flipped or a shorter-than-viewport list anchors
        // to the card's bottom (AppKit y-up); the wrapper carries the 12pt
        // padding so no contentInsets math is needed.
        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -12),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    /// ClipMate's status line ("192 Bytes, 192 Chars, 33 Words"), extended:
    /// file clips count their files; image clips add pixel dimensions. An
    /// image-bearing file clip counts as an image — matching the preview,
    /// which shows the picture, not the path list.
    private static func statusText(representations: [ClipRepresentation]) -> String {
        let hasImage = representations.contains { SupportedTypes.images.contains($0.utiIdentifier) }
        if !hasImage,
           let fileRep = representations.first(where: { $0.utiIdentifier == SupportedTypes.fileURL }) {
            let n = FileClip.decode(fileRep.data).count
            return "\(n) file\(n == 1 ? "" : "s")"
        }
        let bytes = representations.reduce(0) { $0 + $1.data.count }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if let textRep = representations.first(where: { $0.utiIdentifier == SupportedTypes.plainText }),
           let text = String(data: textRep.data, encoding: .utf8) {
            let words = text.split { $0.isWhitespace || $0.isNewline }.count
            let chars = text.count
            return "\(size) · \(chars) char\(chars == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s")"
        }
        if let imageRep = representations.first(where: { SupportedTypes.images.contains($0.utiIdentifier) }),
           let bitmap = NSBitmapImageRep(data: imageRep.data) {
            return "\(size) · \(bitmap.pixelsWide) × \(bitmap.pixelsHigh) px"
        }
        return size
    }
}

/// Flipped so a scrollable list shorter than its viewport hugs the top edge.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// An NSTextView that reports keyboard focus, so the Explorer can ring the
/// preview as the active pane. Isolated here rather than on every text view the
/// preview builds, since the preview recreates its text view per clip.
@MainActor
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// The last-saved text. The controller commits only when the string differs,
    /// so merely clicking into a clip and out again never touches the store.
    var originalText = ""
    /// Called when editing ends (the view loses focus, or Escape) so the
    /// controller can commit the change.
    var onEndEdit: (() -> Void)?
    /// ⌘⏎ while editing: commit, then paste this clip (spec Feature 6).
    var onPasteKey: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            onFocusChange?(false)
            onEndEdit?()   // controller commits if changed (Return is a newline)
        }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Return / ⌘keypad-Enter pastes the clip being edited; plain Return
        // stays a newline (this branch never fires without ⌘).
        if isEditable, event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76 {
            onPasteKey?()
            return
        }
        // Escape while editing ends the edit like clicking away: resign (which
        // commits via onEndEdit), then dismiss the window as a normal Escape
        // would — grab-and-go with the edited text now on the clipboard. Caught
        // in keyDown (not cancelOperation) because an editable text view may map
        // Escape to `complete:` instead. Everything else — including Return,
        // which stays a newline — falls through to the text system.
        if isEditable, event.keyCode == 53 {   // Escape
            window?.makeFirstResponder(nil)     // resign → onEndEdit → commit
            window?.cancelOperation(nil)        // → ExplorerWindow.onCancel → hide()
            return
        }
        super.keyDown(with: event)
    }
}
