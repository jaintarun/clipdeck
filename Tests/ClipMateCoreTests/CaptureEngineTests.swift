import Foundation
import AppKit
import Testing
import GRDB
@testable import ClipMateCore

/// Scripted pasteboard. This is why PasteboardReading exists — the entire
/// capture policy is tested with no real clipboard.
final class FakePasteboard: PasteboardReading, @unchecked Sendable {
    var changeCount: Int = 0
    var types: [String] = []
    var payloads: [String: Data] = [:]

    func snapshot() -> PasteboardSnapshot? {
        PasteboardSnapshot(changeCount: changeCount, types: types, payloads: payloads)
    }

    /// Simulate a copy.
    func put(text: String) {
        changeCount += 1
        types = [SupportedTypes.plainText]
        payloads = [SupportedTypes.plainText: Data(text.utf8)]
    }

    /// Arbitrary shape for corner-case tests.
    func put(types: [String], payloads: [String: Data]) {
        changeCount += 1
        self.types = types
        self.payloads = payloads
    }

    func put(imageBytes: Data, uti: String = SupportedTypes.png) {
        changeCount += 1
        types = [uti]
        payloads = [uti: imageBytes]
    }

    /// Simulate a Finder copy. Measured shape: Finder puts the filenames on
    /// the pasteboard as text ALONGSIDE the file URLs, which is why L1
    /// captured a misleading text-only clip.
    func put(fileURLs: [URL], alsoText: String? = nil) {
        changeCount += 1
        types = [SupportedTypes.fileURL] + (alsoText != nil ? [SupportedTypes.plainText] : [])
        payloads = [SupportedTypes.fileURL: FileClip.encode(fileURLs)]
        if let alsoText { payloads[SupportedTypes.plainText] = Data(alsoText.utf8) }
    }

    /// Simulate a password manager copy.
    func putConcealed(text: String) {
        changeCount += 1
        types = [PasteboardMarkers.concealed, SupportedTypes.plainText]
        payloads = [:]   // a real concealed read yields nothing
    }

    /// Simulate our own PasteService write. The payload IS present (a real
    /// snapshot reads own-writes — ClipboardProbe needs them); the engine
    /// must reject by the ownership marker alone.
    func putOurOwn(text: String) {
        changeCount += 1
        types = [PasteboardMarkers.ownership, SupportedTypes.plainText]
        payloads = [SupportedTypes.plainText: Data(text.utf8)]
    }
}

/// Bridges a value written inside a `@Sendable` `onResult` callback back to
/// the awaiting test body. Two reasons this exists rather than a plain
/// captured `var`:
/// - Swift 6 strict concurrency forbids mutating a captured local `var`
///   from inside a `@Sendable` closure (mirrors why `FakePasteboard` above
///   is `@unchecked Sendable`).
/// - `#expect`/`Issue.record` calls made *inside* a closure that `onResult`
///   reaches via `DispatchQueue.main.async` lose Swift Testing's test-local
///   attribution and get reported against no test at all (confirmed by
///   temporarily breaking the main-queue dispatch: the resulting failure
///   showed up as `Test «unknown» recorded an issue`, not against the named
///   test). Recording the raw value here and asserting on it back in the
///   test body avoids that.
///
/// Every write and read below happens on the main thread in practice —
/// `onResult` always fires there, and these tests only touch this box from
/// `@MainActor` bodies — so the `@unchecked` carries no real race.
final class CaptureBox<Value>: @unchecked Sendable {
    var value: Value?
}

@Suite("CaptureEngine")
struct CaptureEngineTests {

    private func makeEngine(
        _ pb: FakePasteboard,
        app: String? = "com.apple.Safari"
    ) throws -> (CaptureEngine, ClipStore) {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(
            store: store,
            pasteboard: pb,
            collections: CollectionStore(writer),
            frontmostAppProvider: { app }
        )
        return (engine, store)
    }

    @Test("an unchanged pasteboard captures nothing")
    func noChangeDoesNothing() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)

        #expect(try engine.pollOnce() == .noChange)
        #expect(try store.count() == 0)
    }

    @Test("copying text captures it")
    func capturesText() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "hello clipboard")

        let result = try engine.pollOnce()

        guard case .captured = result else {
            Issue.record("expected .captured, got \(result)")
            return
        }
        #expect(try store.count() == 1)
        #expect(try store.recentClips().first?.title == "hello clipboard")
    }

    @Test("the captured clip records the source app")
    func recordsSourceApp() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb, app: "com.apple.mail")
        pb.put(text: "from mail")

        _ = try engine.pollOnce()

        #expect(try store.recentClips().first?.sourceApp == "com.apple.mail")
    }

    @Test("SECURITY: a concealed clip is never captured")
    func rejectsConcealed() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.putConcealed(text: "hunter2")

        #expect(try engine.pollOnce() == .rejectedConcealed)
        #expect(try store.count() == 0, "a password manager copy must never be stored")
    }

    @Test("SECURITY: transient and auto-generated clips are skipped too")
    func rejectsTransientAndAutoGenerated() throws {
        for marker in [PasteboardMarkers.transient, PasteboardMarkers.autoGenerated] {
            let pb = FakePasteboard()
            let (engine, store) = try makeEngine(pb)
            pb.changeCount += 1
            pb.types = [marker, SupportedTypes.plainText]
            pb.payloads = [SupportedTypes.plainText: Data("x".utf8)]

            #expect(try engine.pollOnce() == .rejectedConcealed)
            #expect(try store.count() == 0)
        }
    }

    @Test("THE LOOP: our own paste is not re-captured")
    func rejectsOwnWrite() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.putOurOwn(text: "we just pasted this")

        #expect(try engine.pollOnce() == .rejectedOwnWrite)
        #expect(try store.count() == 0, "pasting must not feed the history back into itself")
    }

    @Test("THE LOOP: repeated polls after our own write stay quiet")
    func ownWriteStaysQuietAcrossPolls() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.putOurOwn(text: "ours")

        for _ in 0..<5 { _ = try engine.pollOnce() }

        #expect(try store.count() == 0)
    }

    @Test("copying the same text twice does not duplicate it")
    func dedupesRepeatCopy() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)

        pb.put(text: "same thing")
        _ = try engine.pollOnce()
        pb.put(text: "same thing")
        let second = try engine.pollOnce()

        guard case .bumped = second else {
            Issue.record("expected .bumped, got \(second)")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("retention is enforced as clips arrive")
    func enforcesRetentionOnCapture() throws {
        let pb = FakePasteboard()
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let collections = CollectionStore(writer)
        let inbox = try collections.collection(kind: .inbox)
        try collections.setRetention(.length(3), for: inbox.id!)
        let engine = CaptureEngine(
            store: store,
            pasteboard: pb,
            collections: collections,
            frontmostAppProvider: { nil }
        )

        for i in 1...5 {
            pb.put(text: "clip \(i)")
            _ = try engine.pollOnce()
        }

        // The cascade MOVES, it does not delete: all 5 clips still exist, but
        // only the 3 newest remain filed in InBox — the rest moved to Trash.
        #expect(try store.count() == 5)
        #expect(try collections.clipIDs(in: inbox.id!).count == 3)
        #expect(try store.recentClips().first?.title == "clip 5")
    }

    @Test("an oversized text clip is skipped, not stored")
    func rejectsOversizedText() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText]
        pb.payloads = [SupportedTypes.plainText: Data(repeating: 0x41, count: CaptureEngine.maxPayloadBytes + 1)]

        #expect(try engine.pollOnce() == .rejectedTooLarge)
        #expect(try store.count() == 0)
    }

    @Test("a pasteboard with no type we support is ignored")
    func rejectsUnsupported() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = ["com.acme.weird"]
        pb.payloads = ["com.acme.weird": Data([0x01])]

        #expect(try engine.pollOnce() == .rejectedUnsupported)
        #expect(try store.count() == 0)
    }

    @Test("paused capture stores nothing but still tracks changeCount")
    func pauseStopsCapture() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        engine.isCapturing = false

        pb.put(text: "while paused")
        #expect(try engine.pollOnce() == .paused)
        #expect(try store.count() == 0)

        // Resuming must not retroactively grab what we skipped.
        engine.isCapturing = true
        #expect(try engine.pollOnce() == .noChange)
        #expect(try store.count() == 0)

        pb.put(text: "after resume")
        _ = try engine.pollOnce()
        #expect(try store.count() == 1)
        #expect(try store.recentClips().first?.title == "after resume")
    }

    @Test("an image is captured with its bytes")
    func capturesImage() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(imageBytes: Data(repeating: 0x89, count: 64))

        _ = try engine.pollOnce()

        let clip = try #require(try store.recentClips().first)
        let reps = try store.representations(for: #require(clip.id))
        #expect(reps.contains { $0.utiIdentifier == SupportedTypes.png })
    }

    @Test("the same text from a richer source still dedupes")
    func dedupesAcrossRepresentationSets() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)

        pb.put(text: "same words")
        _ = try engine.pollOnce()

        // Same text, but this time accompanied by an image representation.
        pb.changeCount += 1
        pb.types = [SupportedTypes.plainText, SupportedTypes.png]
        pb.payloads = [
            SupportedTypes.plainText: Data("same words".utf8),
            SupportedTypes.png: Data(repeating: 0x89, count: 16),
        ]
        let second = try engine.pollOnce()

        guard case .bumped = second else {
            Issue.record("expected .bumped, got \(second)")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("CRLF and LF versions of the same text dedupe")
    func dedupesAcrossLineEndings() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "a\nb")
        _ = try engine.pollOnce()
        pb.put(text: "a\r\nb")
        let second = try engine.pollOnce()
        guard case .bumped = second else {
            Issue.record("expected .bumped, got \(second)")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("a blocklisted app is never captured from")
    func rejectsBlockedApp() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb, app: "com.apple.Terminal")
        engine.blocklist = ["com.apple.Terminal"]
        pb.put(text: "secret token")

        #expect(try engine.pollOnce() == .rejectedBlockedApp("com.apple.Terminal"))
        #expect(try store.count() == 0)
    }

    @Test("the blocklist only blocks the apps it names")
    func blocklistIsNotOverbroad() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb, app: "com.apple.Safari")
        engine.blocklist = ["com.apple.Terminal"]
        pb.put(text: "ordinary text")

        _ = try engine.pollOnce()

        #expect(try store.count() == 1)
    }

    @Test("an unknown source app is never treated as blocked")
    func nilAppIsNotBlocked() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb, app: nil)
        engine.blocklist = ["com.apple.Terminal"]
        pb.put(text: "from who knows where")

        _ = try engine.pollOnce()

        #expect(try store.count() == 1, "we must not drop clips just because attribution failed")
    }

    // MARK: - start() / stop() / onResult (the timer-driven path)
    //
    // Everything above drives the engine through pollOnce(), which never
    // touches onResult. These three exercise start()'s RunLoop.main Timer
    // directly. `@MainActor func ... async` + `await` is required: start()
    // schedules the Timer on RunLoop.main in .common mode, which only fires
    // while the main run loop is spinning. Awaiting (Task.sleep) yields the
    // main thread so the run loop — and the timer — can actually run;
    // a synchronous test body would block main and the timer would never
    // fire, hanging the test.
    //
    // confirmation(...) is used because onResult is delivered via
    // DispatchQueue.main.async from a background queue's perspective (it's
    // scheduled from `processingQueue`, a background queue) — exactly the
    // callback-from-elsewhere shape confirmation() exists for. Every wait
    // below is capped (~1.5s, ~7.5x the 0.2s poll interval) so a broken
    // engine fails the test instead of hanging it; confirmation()'s own
    // "confirmed 0 times, expected 1" issue on timeout satisfies that.

    @Test("onResult is always delivered on the main thread")
    @MainActor
    func onResultDeliversOnMainThread() async throws {
        let pb = FakePasteboard()
        let (engine, _) = try makeEngine(pb)
        defer { engine.stop() }

        let wasMainThread = CaptureBox<Bool>()
        await confirmation("onResult fired") { confirm in
            engine.onResult = { _ in
                wasMainThread.value = Thread.isMainThread
                confirm()
            }
            engine.start()
            pb.put(text: "main thread check")

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        #expect(
            wasMainThread.value == true,
            "onResult must be delivered on the main thread — its doc promises this, and AppKit UI wiring depends on it never needing its own hop"
        )
    }

    @Test("start() captures a pasteboard change end-to-end through its timer")
    @MainActor
    func startCapturesThroughTimer() async throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        defer { engine.stop() }

        let delivered = CaptureBox<CaptureResult>()
        await confirmation("onResult fired") { confirm in
            engine.onResult = { result in
                delivered.value = result
                confirm()
            }
            engine.start()
            pb.put(text: "captured via timer")

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let result = try #require(delivered.value, "onResult never fired — the timer path did not deliver a result")
        guard case .captured = result else {
            Issue.record("expected .captured from the timer-driven capture, got \(result)")
            return
        }
        #expect(try store.count() == 1)
        #expect(try store.recentClips().first?.title == "captured via timer")
    }

    @Test("a captured image gets a thumbnail")
    func imageGetsThumbnail() throws {
        // A real PNG, so the thumbnail path actually runs.
        let image = NSImage(size: NSSize(width: 600, height: 400))
        image.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 600, height: 400))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))

        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(imageBytes: png)

        _ = try engine.pollOnce()

        let clip = try #require(try store.recentClips().first)
        let reps = try store.representations(for: #require(clip.id))
        let imageRep = try #require(reps.first { $0.utiIdentifier == SupportedTypes.png })
        let thumb = try #require(imageRep.thumbnail, "images must carry a thumbnail")
        #expect(thumb.count < png.count)
    }

    @Test("a text clip carries no thumbnail")
    func textHasNoThumbnail() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "just words")

        _ = try engine.pollOnce()

        let clip = try #require(try store.recentClips().first)
        let reps = try store.representations(for: #require(clip.id))
        #expect(reps[0].thumbnail == nil)
    }

    @Test("stop() halts further onResult delivery")
    @MainActor
    func stopStopsDelivery() async throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        defer { engine.stop() }

        // Phase 1: capture one clip while running, and wait for its delivery
        // to complete. This matters for the race stop()'s doc comment calls
        // out: stop() only invalidates the timer, it does not cancel a
        // capture already dispatched to processingQueue. Waiting for this
        // first delivery to finish guarantees no capture is still in flight
        // the moment we call stop() below, so the negative check in phase 2
        // isn't racing that documented tail.
        await confirmation("first capture delivered while running") { confirm in
            engine.onResult = { _ in confirm() }
            engine.start()
            pb.put(text: "first, while running")

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        #expect(try store.count() == 1, "setup: the first capture must land before we test stop()")

        engine.stop()

        // Phase 2: a pasteboard change after stop() must produce no callback
        // and no new stored clip.
        let deliveredAfterStop = CaptureBox<CaptureResult>()
        engine.onResult = { result in deliveredAfterStop.value = result }
        pb.put(text: "second, after stop")

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(
            deliveredAfterStop.value == nil,
            "onResult fired after stop() with \(String(describing: deliveredAfterStop.value)) — stop() must halt delivery"
        )
        #expect(try store.count() == 1, "stop() must prevent the second change from being captured")
    }

    @Test("a suspended engine captures nothing")
    func suspendedEngineCapturesNothing() throws {
        let pb = FakePasteboard()
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(store: store, pasteboard: pb, collections: CollectionStore(writer), frontmostAppProvider: { nil })

        engine.suspend()
        pb.put(text: "copied while asleep")

        #expect(try engine.pollOnce() == .paused)
        #expect(try store.count() == 0)
    }

    @Test("resuming captures what changed, rather than silently skipping it")
    @MainActor
    func resumeCapturesWhatChanged() async throws {
        let pb = FakePasteboard()
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(store: store, pasteboard: pb, collections: CollectionStore(writer), frontmostAppProvider: { nil })
        defer { engine.stop() }

        engine.suspend()
        pb.put(text: "copied around sleep")

        let delivered = CaptureBox<CaptureResult>()
        await confirmation("onResult fired on wake") { confirm in
            engine.onResult = { result in
                delivered.value = result
                confirm()
            }
            engine.resume()

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        _ = try #require(delivered.value, "onResult never fired — the wake path did not deliver a result")

        // "re-read changeCount on wake" must not mean "adopt the count and
        // drop the clip" — that would lose the user's data silently.
        #expect(try store.count() == 1)
    }

    @Test("suspend does not clobber the user's own capture toggle")
    func suspendPreservesUserPause() throws {
        let pb = FakePasteboard()
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(store: store, pasteboard: pb, collections: CollectionStore(writer), frontmostAppProvider: { nil })

        engine.isCapturing = false   // user turned capture off in the menu
        engine.suspend()
        engine.resume()              // machine woke up

        // Waking must not re-enable capture the user deliberately switched off.
        #expect(engine.isCapturing == false)
        pb.put(text: "should not be captured")
        #expect(try engine.pollOnce() == .paused)
        #expect(try store.count() == 0)
    }

    // MARK: - Feature 3: OCR titles for new image clips

    @Test("a new image clip gains an OCR title and becomes searchable")
    func imageClipGainsOCRTitle() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let png = renderTextImagePNG("CLIPMATE OCR 42")
        pb.put(types: [SupportedTypes.png], payloads: [SupportedTypes.png: png])

        let result = try engine.pollOnce()
        guard case .captured(let id) = result else {
            Issue.record("expected .captured, got \(result)")
            return
        }
        #expect(try store.clip(id: id)?.title.hasPrefix("Image ") == true)

        engine.drainOCRForTesting()

        let title = try store.clip(id: id)?.title
        #expect(title?.contains("CLIPMATE") == true)
        #expect(try store.search("CLIPMATE").map(\.id) == [id])
    }

    @Test("a clip with both text and an image is titled from its text, never OCR-retitled")
    func textWithImageIsNotOCRRetitled() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let png = renderTextImagePNG("SHOULD NOT APPEAR")
        pb.put(types: [SupportedTypes.plainText, SupportedTypes.png],
               payloads: [SupportedTypes.plainText: Data("real caption".utf8),
                          SupportedTypes.png: png])

        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured")
            return
        }
        #expect(try store.clip(id: id)?.title == "real caption")

        engine.drainOCRForTesting()

        #expect(
            try store.clip(id: id)?.title == "real caption",
            "a clip with a text representation must title from its text and never get OCR-retitled"
        )
    }

    // MARK: - Maintenance sweep (retention-sweep tranche F2)

    /// Files one clip, moves it to Trash, and backdates the move past the
    /// 6-day grace — so the next retention pass, using a real `now`, purges
    /// it. Age retention keys off clipCollection.movedAt, not the clip row.
    private func seedAgedTrashClip(
        engine: CaptureEngine, pb: FakePasteboard,
        collections: CollectionStore, writer: DatabaseQueue
    ) throws {
        pb.put(text: "doomed by the sweep")
        _ = try engine.pollOnce()
        let trash = try collections.collection(kind: .trash)
        let ids = try writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM clip")
        }
        try collections.moveClips(ids, to: trash.id!)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE clipCollection SET movedAt = ?",
                arguments: [Date().addingTimeInterval(-7 * 86_400)]
            )
        }
    }

    @Test("a sweep purges aged Trash with zero pasteboard activity")
    func sweepPurgesAgedTrash() throws {
        let writer = try AppDatabase.makeInMemory()
        let clips = ClipStore(writer)
        let collections = CollectionStore(writer)
        let pb = FakePasteboard()
        let engine = CaptureEngine(
            store: clips, pasteboard: pb,
            collections: collections, frontmostAppProvider: { nil }
        )
        try seedAgedTrashClip(engine: engine, pb: pb, collections: collections, writer: writer)
        #expect(try clips.count() == 1)

        // No pasteboard activity from here on: the sweep alone must purge.
        engine.sweepNowForTesting()

        #expect(try clips.count() == 0)
    }

    @Test("the maintenance timer sweeps on its own")
    @MainActor
    func maintenanceTimerSweepsOnItsOwn() async throws {
        let writer = try AppDatabase.makeInMemory()
        let clips = ClipStore(writer)
        let collections = CollectionStore(writer)
        let pb = FakePasteboard()
        // Injected short interval; tolerance is interval-proportional, so a
        // small interval also keeps the first fire prompt.
        let engine = CaptureEngine(
            store: clips, pasteboard: pb,
            collections: collections, frontmostAppProvider: { nil },
            maintenanceInterval: 0.2, maintenanceFirstDelay: 0.05
        )
        try seedAgedTrashClip(engine: engine, pb: pb, collections: collections, writer: writer)

        engine.start()
        defer { engine.stop() }

        // Condition-based wait: the timer fires on RunLoop.main (serviced by
        // the main actor here); poll the observable outcome with a deadline
        // so a dead timer fails the test instead of hanging it.
        let deadline = Date().addingTimeInterval(3)
        while try clips.count() > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try clips.count() == 0)
    }
}

@Suite("Capture — file references")
struct FileCaptureTests {

    private func makeEngine(_ pb: FakePasteboard) throws -> (CaptureEngine, ClipStore) {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)
        let engine = CaptureEngine(
            store: store,
            pasteboard: pb,
            collections: CollectionStore(writer),
            frontmostAppProvider: { "com.apple.finder" }
        )
        return (engine, store)
    }

    @Test("captures a file copy as a file clip")
    func capturesFileCopy() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(fileURLs: [URL(fileURLWithPath: "/tmp/alpha.txt")], alsoText: "alpha.txt")

        let result = try engine.pollOnce()

        guard case .captured(let id) = result else {
            Issue.record("expected .captured, got \(result)")
            return
        }
        let reps = try store.representations(for: id)
        let fileRep = try #require(reps.first { $0.utiIdentifier == SupportedTypes.fileURL })
        #expect(FileClip.decode(fileRep.data) == [URL(fileURLWithPath: "/tmp/alpha.txt")])
    }

    @Test("titles a multi-file copy by count, not by the first filename")
    func titlesMultiFileCopy() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        // Exactly what Finder sends for two files: both URLs, and the two
        // filenames joined as text.
        pb.put(
            fileURLs: [URL(fileURLWithPath: "/tmp/alpha.txt"), URL(fileURLWithPath: "/tmp/beta.txt")],
            alsoText: "alpha.txt\rbeta.txt"
        )

        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("expected .captured")
            return
        }
        // L1 stored "alpha.txt" here — the title lied about how much was copied.
        #expect(try store.clip(id: id)?.title == "2 files")
    }

    @Test("same filename in different folders makes DISTINCT clips")
    func sameNameDifferentFoldersAreDistinct() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)

        // The L1 bug: both copies hashed the text "report.txt" and deduped
        // into one clip, silently losing the second file.
        pb.put(fileURLs: [URL(fileURLWithPath: "/tmp/a/report.txt")], alsoText: "report.txt")
        try engine.pollOnce()
        pb.put(fileURLs: [URL(fileURLWithPath: "/tmp/b/report.txt")], alsoText: "report.txt")
        try engine.pollOnce()

        #expect(try store.count() == 2)
    }

    @Test("copying the same file twice dedupes and bumps")
    func sameFileTwiceBumps() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let url = URL(fileURLWithPath: "/tmp/alpha.txt")

        pb.put(fileURLs: [url], alsoText: "alpha.txt")
        try engine.pollOnce()
        pb.put(fileURLs: [url], alsoText: "alpha.txt")
        let second = try engine.pollOnce()

        guard case .bumped = second else {
            Issue.record("expected .bumped, got \(second)")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("a file clip is findable by filename")
    func fileClipIsSearchable() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(fileURLs: [URL(fileURLWithPath: "/tmp/quarterly-report.pdf")], alsoText: "quarterly-report.pdf")
        try engine.pollOnce()

        #expect(try store.search("quarterly").count == 1)
    }

    @Test("a concealed file copy is still rejected before any read")
    func concealedFileCopyRejected() throws {
        let pb = FakePasteboard()
        let (engine, _) = try makeEngine(pb)
        pb.changeCount += 1
        pb.types = [PasteboardMarkers.concealed, SupportedTypes.fileURL]
        pb.payloads = [:]

        #expect(try engine.pollOnce() == .rejectedConcealed)
    }

    // MARK: - Maccy G2/G3: junk suppression + vendor denylist

    @Test("a 1Password-marked copy is rejected before any payload is stored")
    func vendorMarkedCopyIsRejected() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(types: ["com.agilebits.onepassword", SupportedTypes.plainText],
               payloads: [:])   // a real snapshot reads nothing past the marker

        #expect(try engine.pollOnce() == .rejectedConcealed)
        #expect(try store.count() == 0)
    }

    @Test("a spaces-only copy is junk, not a clip")
    func whitespaceOnlyCopyIsSuppressed() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "   ")

        #expect(try engine.pollOnce() == .rejectedEmpty)
        #expect(try store.count() == 0)
    }

    @Test("a newlines-only copy is junk, not a clip")
    func newlinesOnlyCopyIsSuppressed() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(text: "\n\n\t\n")

        #expect(try engine.pollOnce() == .rejectedEmpty)
        #expect(try store.count() == 0)
    }

    @Test("empty plain text with a non-empty RTF body is still a clip (Maccy carve-out)")
    func emptyTextWithRealRichBodyIsKept() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let rich = NSAttributedString(string: "rich words")
        let rtf = try #require(rich.rtf(from: NSRange(location: 0, length: rich.length),
                                        documentAttributes: [:]))
        pb.put(types: [SupportedTypes.plainText, SupportedTypes.rtf],
               payloads: [SupportedTypes.plainText: Data(" ".utf8),
                          SupportedTypes.rtf: rtf])

        guard case .captured = try engine.pollOnce() else {
            Issue.record("a visually non-empty rich copy must be captured")
            return
        }
        #expect(try store.count() == 1)
    }

    @Test("empty plain text alongside an image is still a clip")
    func emptyTextWithImageIsKept() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(types: [SupportedTypes.plainText, SupportedTypes.png],
               payloads: [SupportedTypes.plainText: Data(" ".utf8),
                          SupportedTypes.png: Data([0x89, 0x50, 0x4E, 0x47])])

        guard case .captured = try engine.pollOnce() else {
            Issue.record("an image copy must never be suppressed for its empty text rider")
            return
        }
        #expect(try store.count() == 1)
    }

    // MARK: - Maccy G9: one-shot ignore

    @Test("Ignore Next Copy skips exactly one change, then re-arms capture")
    func ignoreNextChangeIsOneShot() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        engine.ignoreNextChange = true

        pb.put(text: "the skipped one")
        #expect(try engine.pollOnce() == .noChange)
        #expect(try store.count() == 0)
        #expect(engine.ignoreNextChange == false)

        pb.put(text: "the kept one")
        guard case .captured = try engine.pollOnce() else {
            Issue.record("the copy AFTER the ignored one must capture")
            return
        }
        #expect(try store.recentClips().first?.title == "the kept one")
    }

    // MARK: - Maccy G8: large-text index cap

    @Test("giant text is FTS-indexed capped but STORED in full")
    func giantTextCapsSearchTextNotPayload() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let giant = String(repeating: "x", count: 50_000)
        pb.put(text: giant)

        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("giant text must still capture")
            return
        }
        #expect(try store.recentClips().first?.searchText.count == CaptureEngine.maxSearchTextChars)
        let reps = try store.representations(for: id)
        #expect(reps.first { $0.utiIdentifier == SupportedTypes.plainText }?.data.count == 50_000,
                "the cap is an INDEX cap — the clip itself is never truncated")
    }

    // MARK: - Maccy G4: Universal Clipboard

    @Test("a Universal Clipboard copy keeps its text and drops the temp-file reference")
    func remoteClipboardPrefersInlineBytes() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("handoff.txt")
        pb.put(types: [PasteboardMarkers.remoteClipboard, SupportedTypes.plainText, SupportedTypes.fileURL],
               payloads: [SupportedTypes.plainText: Data("from my iPhone".utf8),
                          SupportedTypes.fileURL: FileClip.encode([tempURL])])

        guard case .captured(let id) = try engine.pollOnce() else {
            Issue.record("remote copy with inline text must capture")
            return
        }
        let reps = try store.representations(for: id)
        #expect(!reps.contains { $0.utiIdentifier == SupportedTypes.fileURL },
                "the temp file dies minutes later — storing its reference is a clip that dies")
        #expect(try store.recentClips().first?.title == "from my iPhone")
    }

    @Test("a Universal Clipboard copy that is ONLY a temp-file reference is skipped, not doomed")
    func remoteClipboardFileOnlyIsSkipped() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("handoff.png")
        pb.put(types: [PasteboardMarkers.remoteClipboard, SupportedTypes.fileURL],
               payloads: [SupportedTypes.fileURL: FileClip.encode([tempURL])])

        #expect(try engine.pollOnce() == .rejectedUnsupported)
        #expect(try store.count() == 0)
    }

    @Test("empty plain text whose HTML renders to nothing visible is junk")
    func emptyTextWithMarkupOnlyHTMLIsSuppressed() throws {
        let pb = FakePasteboard()
        let (engine, store) = try makeEngine(pb)
        pb.put(types: [SupportedTypes.plainText, SupportedTypes.html],
               payloads: [SupportedTypes.plainText: Data(" ".utf8),
                          SupportedTypes.html: Data("<div><span> </span></div>".utf8)])

        #expect(try engine.pollOnce() == .rejectedEmpty)
        #expect(try store.count() == 0)
    }
}
