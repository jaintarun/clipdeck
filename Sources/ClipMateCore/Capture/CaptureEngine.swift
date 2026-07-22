import Foundation

public enum CaptureResult: Equatable, Sendable {
    case noChange
    case paused
    case rejectedConcealed
    case rejectedOwnWrite
    /// Carries the bundle ID so the UI can say which app was skipped.
    case rejectedBlockedApp(String)
    case rejectedTooLarge
    case rejectedUnsupported
    /// A textual copy that trims to nothing visible (Maccy G2) — stray ⌘C on
    /// an empty selection. Distinct from `rejectedUnsupported`: the types were
    /// fine, the content was blank.
    case rejectedEmpty
    case captured(Int64)
    case bumped(Int64)
}

/// Polls the pasteboard and stores what it finds.
///
/// macOS has no clipboard notification API — no KVO, no NSNotification. Every
/// clipboard manager on the platform polls. It is the only door, and it is
/// simpler than the viewer chain ClipMate fought for 30 years (spec §6).
///
/// Knows nothing about PasteService. Both go through ClipStore.
public final class CaptureEngine: @unchecked Sendable {
    /// Spec §5. Text above this is skipped; images above it are downscaled
    /// (Task 9).
    public static let maxPayloadBytes = 50 * 1024 * 1024

    public static let pollInterval: TimeInterval = 0.2

    /// G8: FTS indexes `searchText`, and tokenizing a 50 MB payload on every
    /// capture (and matching against it on every keystroke) is where large-
    /// history search perf goes to die. The INDEX is capped; the stored clip
    /// never is.
    public static let maxSearchTextChars = 10_000

    private let store: ClipStore
    private let pasteboard: any PasteboardReading
    private let collections: CollectionStore
    private let frontmostAppProvider: @Sendable () -> String?

    private var lastChangeCount: Int
    private var timer: Timer?

    /// F2 housekeeping timer. Same main-thread-only discipline as `timer`.
    private var maintenanceTimer: Timer?
    private let maintenanceInterval: TimeInterval
    private let maintenanceFirstDelay: TimeInterval

    /// Toggled by the menu bar. Paused capture still tracks changeCount so
    /// resuming does not retroactively grab what it skipped.
    public var isCapturing: Bool = true

    /// One-shot: skip exactly the next pasteboard change (menu's "Ignore Next
    /// Copy", Maccy G9). Main-thread only, like `isCapturing` — the menu
    /// writes it and detectChange() consumes it, both on main.
    public var ignoreNextChange = false

    /// Set while the machine is asleep. Separate from `isCapturing` so waking
    /// never re-enables capture the user deliberately switched off in the menu.
    private var isSuspended = false

    /// Bundle IDs we never capture from (spec §13 step 5). The concealed-type
    /// check already covers well-behaved password managers; this is the escape
    /// hatch for apps that don't set the marker but still hold secrets.
    public var blocklist: Set<String> = []

    /// Called on every non-.noChange result. The app uses this to refresh the
    /// UI and to surface rejections; never swallow silently (spec §9).
    /// Always delivered on the main queue — UI consumers need no hop of their own.
    public var onResult: (@Sendable (CaptureResult) -> Void)?

    /// Fired on the main queue when OCR retitled a clip (spec Feature 3), so
    /// open windows refresh — the sibling of onResult for title updates.
    public var onTitleUpdate: (@Sendable (Int64) -> Void)?

    public init(
        store: ClipStore,
        pasteboard: any PasteboardReading,
        collections: CollectionStore,
        frontmostAppProvider: @escaping @Sendable () -> String?,
        maintenanceInterval: TimeInterval = 7_200,
        maintenanceFirstDelay: TimeInterval = 60
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.collections = collections
        self.frontmostAppProvider = frontmostAppProvider
        self.lastChangeCount = pasteboard.changeCount
        self.maintenanceInterval = maintenanceInterval
        self.maintenanceFirstDelay = maintenanceFirstDelay
    }

    /// AMEND-3. Hashing, thumbnailing (a 30MB screenshot!), and the SQLite
    /// write must not run on the main run loop.
    private let processingQueue = DispatchQueue(
        label: "com.clipmateclone.capture.processing", qos: .utility)

    /// Feature 3: Vision's .accurate pass takes hundreds of ms; its own queue
    /// keeps OCR from delaying the next capture on processingQueue.
    private let ocrQueue = DispatchQueue(
        label: "com.clipmateclone.capture.ocr", qos: .utility)

    /// Main-thread only: `timer` is unsynchronized, and the timer is scheduled
    /// on `RunLoop.main`. A concurrent call could orphan a scheduled timer that
    /// `stop()` can then never invalidate.
    public func start() {
        stop()
        // Detect on main (NSPasteboard is not documented thread-safe),
        // process off main.
        let t = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let snapshot = self.detectChange() else { return }
            guard self.isCapturing, !self.isSuspended else { return }
            self.processingQueue.async {
                do {
                    let result = try self.process(snapshot)
                    if result != .noChange {
                        DispatchQueue.main.async { self.onResult?(result) }
                    }
                } catch {
                    // One bad clip must never kill the capture loop (spec §9).
                    NSLog("[ClipMate] capture failed: \(error)")
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // F2 (retention sweep): housekeeping for quiet machines. Without
        // this, retention only runs when something is captured — so on a
        // machine where nothing is copied, Trash never drains and an
        // over-budget library is never trimmed. First fire lands shortly
        // after start() so a briefly-woken machine still sweeps; the
        // generous tolerance is deliberate (housekeeping, not
        // timing-sensitive). suspend()/resume() call stop()/start(), so this
        // timer inherits the capture timer's sleep/wake discipline — and a
        // resume() restarts the clock, which is fine: first fire after wake
        // beats waiting out a stale 2-hour deadline.
        let m = Timer(
            fire: Date().addingTimeInterval(maintenanceFirstDelay),
            interval: maintenanceInterval,
            repeats: true
        ) { [weak self] _ in
            self?.runMaintenanceSweep()
        }
        m.tolerance = maintenanceInterval * 0.1
        RunLoop.main.add(m, forMode: .common)
        maintenanceTimer = m
    }

    /// Main-thread only, for the same reason as `start()`: `timer` is
    /// unsynchronized.
    ///
    /// Only invalidates the timer — it does not cancel a capture already
    /// dispatched to `processingQueue`. At most one in-flight capture can
    /// still deliver a final `onResult` call after `stop()` returns. No
    /// cancellation machinery is added for this (YAGNI); it's a one-shot
    /// tail, not an ongoing leak.
    public func stop() {
        timer?.invalidate()
        timer = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
    }

    /// Stop polling while the machine sleeps. Main-thread only, same reason as
    /// `start()`/`stop()`: `timer` is unsynchronized.
    ///
    /// There is no clipboard activity with the lid shut, so a 5-per-second
    /// timer is pure battery drain (guide 5.2: "no sustained idle wakeups").
    public func suspend() {
        isSuspended = true
        stop()
    }

    /// Resume on wake and poll ONCE immediately.
    ///
    /// The immediate poll is deliberate. Silently ADOPTING the current
    /// changeCount here — the other reading of "re-read changeCount on wake" —
    /// would discard a clip copied around the suspend. Skipping is only ever
    /// deliberate in this engine.
    ///
    /// Split the same way as start()'s timer (AMEND-3): detect on main, since
    /// NSPasteboard is not documented thread-safe, then process off main —
    /// waking with a 30MB screenshot on the pasteboard must not hash,
    /// thumbnail and commit it on the main run loop, because this is called
    /// straight from the didWake observer.
    public func resume() {
        isSuspended = false
        start()
        guard let snapshot = detectChange() else { return }
        guard isCapturing else { return }
        processingQueue.async {
            do {
                let result = try self.process(snapshot)
                if result != .noChange {
                    DispatchQueue.main.async { self.onResult?(result) }
                }
            } catch {
                // One bad clip must never kill the capture loop (guide 5.3).
                NSLog("[ClipMate] capture failed on wake: \(error)")
            }
        }
    }

    /// Capture whatever is on the clipboard right now, once, even though the
    /// changeCount hasn't advanced since init — so ClipMate opens already holding
    /// the current clipboard (old-ClipMate behaviour: "on launch it reads the
    /// clipboard and puts it inside itself"). If the content is already stored it
    /// dedupes to a `.bumped`, floating it to the top; either way the result
    /// carries the clip id so the UI can light it as the clipboard row.
    ///
    /// Split like resume(): the snapshot is taken here (NSPasteboard is not
    /// documented thread-safe) and processing runs off the main thread, because
    /// a 30MB screenshot on the clipboard must not hash on the main run loop.
    public func captureCurrentAtLaunch() {
        guard isCapturing, !isSuspended else { return }
        guard let snapshot = pasteboard.snapshot() else { return }
        // Adopt the changeCount so the timer doesn't immediately re-capture it.
        lastChangeCount = pasteboard.changeCount
        let input = CaptureInput(
            snapshot: snapshot,
            sourceApp: frontmostAppProvider(),
            blocklist: blocklist
        )
        processingQueue.async {
            do {
                let result = try self.process(input)
                if result != .noChange {
                    DispatchQueue.main.async { self.onResult?(result) }
                }
            } catch {
                // One bad clip must never kill the capture loop (spec §9).
                NSLog("[ClipMate] launch capture failed: \(error)")
            }
        }
    }

    /// One poll cycle, synchronous. Tests call this directly.
    @discardableResult
    public func pollOnce() throws -> CaptureResult {
        guard let snapshot = detectChange() else { return .noChange }
        guard isCapturing, !isSuspended else { return .paused }
        return try process(snapshot)
    }

    /// Everything gathered on the main thread and frozen, so `process` can run
    /// anywhere without reaching back for main-thread-only state.
    ///
    /// `blocklist` and `sourceApp` live in here rather than being read inside
    /// `process` for a reason: the menu mutates `blocklist` on main, and
    /// `frontmostAppProvider` calls NSWorkspace. Reading either from the
    /// processing queue would be a data race that `@unchecked Sendable` hides
    /// from the compiler.
    private struct CaptureInput: Sendable {
        var snapshot: PasteboardSnapshot
        var sourceApp: String?
        var blocklist: Set<String>
    }

    /// Cheap: one integer read, then a snapshot only if it moved. Main-thread
    /// only — this is the sole thing that touches NSPasteboard.
    /// Returns nil when nothing changed.
    ///
    /// Advances lastChangeCount even while paused, so resuming does not
    /// retroactively grab what it skipped.
    private func detectChange() -> CaptureInput? {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return nil }
        lastChangeCount = current
        // Consuming here (after adopting the changeCount) means the skipped
        // copy can never be retroactively grabbed later — the same guarantee
        // paused capture makes.
        if ignoreNextChange {
            ignoreNextChange = false
            return nil
        }
        guard let snapshot = pasteboard.snapshot() else { return nil }
        return CaptureInput(
            snapshot: snapshot,
            sourceApp: frontmostAppProvider(),
            blocklist: blocklist
        )
    }

    /// Everything after the snapshot: rejection rules, hashing, thumbnails,
    /// storage, retention. Safe off the main thread — it touches only the
    /// frozen input value and ClipStore, which is Sendable over GRDB's
    /// thread-safe DatabaseWriter.
    private func process(_ input: CaptureInput) throws -> CaptureResult {
        let snapshot = input.snapshot

        // Order matters. Concealed first, before touching any payload.
        let types = Set(snapshot.types)
        if types.contains(where: { PasteboardMarkers.allSkipped.contains($0) }) {
            return .rejectedConcealed
        }
        if types.contains(PasteboardMarkers.ownership) {
            return .rejectedOwnWrite
        }

        // Attribution is a heuristic (spec §6 step 3), so it may be nil. A nil
        // source is NOT blocked — failing to identify an app must never become
        // a reason to silently drop the user's clip.
        let sourceApp = input.sourceApp
        if let sourceApp, input.blocklist.contains(sourceApp) {
            return .rejectedBlockedApp(sourceApp)
        }

        var supported = snapshot.payloads.filter { SupportedTypes.all.contains($0.key) }

        // Universal Clipboard: the fileURL is a TEMP file macOS deletes
        // shortly after the Handoff — storing the reference makes a clip that
        // dies. Keep the inline bytes; if the remote copy carried ONLY the
        // doomed reference, skip it rather than store a lie (Maccy G4).
        if types.contains(PasteboardMarkers.remoteClipboard) {
            supported[SupportedTypes.fileURL] = nil
        }

        guard !supported.isEmpty else { return .rejectedUnsupported }

        // G2 (Maccy): a whitespace-only text copy with no image, no files and
        // no visually non-empty rich body is junk — stray ⌘C on an empty
        // selection, terminal artifacts. Suppression is deliberately
        // conservative: any doubt keeps the clip (a clip is never lost).
        if Self.isEffectivelyEmpty(supported) {
            return .rejectedEmpty
        }

        if supported.values.contains(where: { $0.count > Self.maxPayloadBytes }) {
            NSLog("[ClipMate] skipped a clip over \(Self.maxPayloadBytes) bytes")
            return .rejectedTooLarge
        }

        let representations: [ClipRepresentation] = supported
            .sorted { $0.key < $1.key }
            .map { uti, bytes in
                // Oversized screenshots get downscaled rather than committed
                // whole (spec §5). nil means "no downscale needed".
                let stored = ThumbnailMaker.downscaleIfNeeded(bytes, uti: uti) ?? bytes
                let thumb = SupportedTypes.images.contains(uti)
                    ? ThumbnailMaker.thumbnail(from: stored)
                    : nil
                return ClipRepresentation(
                    clipID: 0,
                    utiIdentifier: uti,
                    data: stored,
                    thumbnail: thumb
                )
            }

        let text = supported[SupportedTypes.plainText].flatMap { String(data: $0, encoding: .utf8) }

        // Files beat text. A Finder copy puts the filenames on the pasteboard
        // as text ALONGSIDE the URLs (measured), so if text won here the title
        // would name only the first of N files, and two same-named files in
        // different folders would hash identically and dedupe into one clip.
        let fileURLs = supported[SupportedTypes.fileURL].map { FileClip.decode($0) } ?? []
        let isFileClip = !fileURLs.isEmpty

        let title: String
        if isFileClip {
            title = FileClip.title(for: fileURLs)
        } else if let text {
            title = Clip.makeTitle(from: text)
        } else {
            title = Self.imageTitle()
        }

        // AMEND-2. Fingerprint the PRIMARY representation only: the file URLs
        // if this is a file clip, else plain text if present (line endings
        // normalized for hashing only — stored bytes are untouched), else the
        // largest image.
        //
        // Hashing all representations would make the same text copied from two
        // apps look distinct, because each app decorates it differently — one
        // sends text alone, another sends text + PNG. The user copied the same
        // words; it must dedupe.
        //
        // Shared with ClipboardMatcher so the Explorer's "is this clip on the
        // clipboard?" check fingerprints identically — `supported` is non-empty
        // here (guarded above), so primaryData is never nil.
        let primaryData = ClipboardMatcher.primaryData(payloads: snapshot.payloads) ?? Data()

        // Source URL is metadata, not a representation (it's not in
        // SupportedTypes.all, so it never reached `supported`). Keep only
        // http/https — a bare or non-web string is not a source URL. Never
        // logged (guide §5.3).
        let sourceURL = snapshot.payloads[SupportedTypes.sourceURL]
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(Self.sanitizedSourceURL)

        let clip = Clip(
            title: title,
            sourceApp: sourceApp,
            contentHash: ContentHasher.hash(primaryData),
            // File clips are findable by filename. Storing names (not bytes)
            // keeps "references, never contents" intact.
            searchText: isFileClip
                ? fileURLs.map(\.lastPathComponent).joined(separator: " ")
                : String((text ?? title).prefix(Self.maxSearchTextChars)),
            sourceURL: sourceURL
        )

        let outcome = try store.insertOrBump(clip, representations: representations)

        // Feature 3: a NEW image-only clip (generic "Image …" title — no text,
        // no files) gets an OCR pass. Bumped duplicates were already OCR'd on
        // first capture; file and text clips title themselves.
        if case .inserted(let newID) = outcome, !isFileClip, text == nil,
           let imageData = representations.first(where: {
               SupportedTypes.images.contains($0.utiIdentifier)
           })?.data {
            scheduleOCR(clipID: newID, insertedTitle: title, imageData: imageData)
        }

        // AMEND-3: this runs on processingQueue via every caller of process()
        // (start()'s timer, resume(), and pollOnce()), never on the main
        // thread — same call site enforce() occupied before it. The body is
        // shared with the maintenance sweep (F2), which runs identical work
        // on the same queue for machines where nothing is being copied.
        try enforceRetentionAndCaps()

        switch outcome {
        case .inserted(let id): return .captured(id)
        case .bumped(let id):   return .bumped(id)
        }
    }

    /// Retention cascade + library byte budget. Must run on `processingQueue`
    /// (AMEND-3) — called from `process()`'s tail and from the maintenance
    /// sweep.
    private func enforceRetentionAndCaps() throws {
        try collections.runRetention()

        // Task 5: the library-wide byte budget, on top of runRetention's
        // per-collection cascade. Different from maxPayloadBytes (which
        // rejects one oversized clip at capture) — this trims the whole
        // library once it grows past StorageCaps.l2Default.totalBytes.
        let trashedForSize = try collections.enforceStorageCaps(StorageCaps.l2Default)
        if trashedForSize == 0, try collections.activeStorageBytes() > StorageCaps.l2Default.totalBytes {
            // Guide 5.3: nothing fails silently. This means protected content
            // (filed in a .never collection) alone exceeds the budget, so
            // enforceStorageCaps skipped rather than purge what the user
            // explicitly protected. No clip bodies, URLs, or byte-level
            // content identifying anything — just that we're stuck.
            NSLog("[ClipMate] storage cap exceeded but protected content alone is over budget; nothing evicted")
        }
    }

    private func scheduleOCR(clipID: Int64, insertedTitle: String, imageData: Data) {
        ocrQueue.async {
            guard let text = ImageTextRecognizer.recognizeText(in: imageData) else { return }
            do {
                if try self.store.applyRecognizedText(
                    clipID: clipID, insertedTitle: insertedTitle, text: text) {
                    DispatchQueue.main.async { self.onTitleUpdate?(clipID) }
                }
            } catch {
                // Content-free by rule: recognized text is clipboard content.
                NSLog("[ClipMate] OCR write-back failed: \(error)")
            }
        }
    }

    /// Tests only: block until queued OCR work has drained.
    public func drainOCRForTesting() {
        ocrQueue.sync {}
    }

    /// F2: one maintenance sweep, dispatched to the serial queue so it can
    /// never interleave with a capture (AMEND-3). No isSuspended guard here:
    /// suspend() invalidates the timer on main before sleep, and the at most
    /// one sweep already in flight is the same work a capture would have
    /// done — harmless to finish.
    private func runMaintenanceSweep() {
        processingQueue.async {
            do {
                try self.enforceRetentionAndCaps()
            } catch {
                // A failed sweep must never kill the timer — the next tick
                // retries. Content-free by rule (no clip bodies in logs).
                NSLog("[ClipMate] maintenance sweep failed: \(error)")
            }
        }
    }

    /// Tests only: run one sweep and block until it completes.
    public func sweepNowForTesting() {
        runMaintenanceSweep()
        processingQueue.sync {}
    }

    private static func imageTitle() -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return "Image \(f.string(from: Date()))"
    }

    /// True only when the copy is *textual and visually empty*: a plain-text
    /// rep that trims to nothing, no file or image reps, and any rich reps
    /// rendering to nothing visible (HTML via the local tag stripper — the
    /// no-web-engine floor holds even here).
    static func isEffectivelyEmpty(_ supported: [String: Data]) -> Bool {
        guard let textData = supported[SupportedTypes.plainText],
              let text = String(data: textData, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard supported[SupportedTypes.fileURL] == nil,
              !SupportedTypes.images.contains(where: { supported[$0] != nil })
        else { return false }
        if let rtf = supported[SupportedTypes.rtf],
           let rendered = PlainTextRendering.fromRTF(rtf),
           !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if let htmlData = supported[SupportedTypes.html],
           let html = String(data: htmlData, encoding: .utf8),
           !PlainTextRendering.fromHTML(html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    private static func sanitizedSourceURL(_ s: String) -> String? {
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return s
    }
}
