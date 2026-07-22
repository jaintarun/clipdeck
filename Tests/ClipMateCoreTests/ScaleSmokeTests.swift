import Foundation
import Testing
@testable import ClipMateCore

/// G14: ClipMate deliberately has no global row ceiling (Safe/user collections
/// are `.never`), so the query layer must stay responsive as the library
/// grows. Maccy raised its cap to 9999 and reverted two weeks later because
/// search/scroll died at ~2k items — this test is the tripwire that keeps
/// ClipMate honest at 5k. Bounds are generous (machines vary); the point is
/// catching O(n)-per-render regressions, not benchmarking.
@Suite("Scale smoke")
struct ScaleSmokeTests {

    @Test("5,000 clips: list, search, and smart-collection queries stay fast")
    func fiveThousandClipsStayResponsive() throws {
        let writer = try AppDatabase.makeInMemory()
        let store = ClipStore(writer)

        for i in 0..<5_000 {
            let body = "clip body number \(i) lorem ipsum dolor"
            let clip = Clip(title: "clip \(i)", sourceApp: "com.apple.Safari",
                            contentHash: ContentHasher.hash(Data(body.utf8)),
                            searchText: body)
            let rep = ClipRepresentation(clipID: 0, utiIdentifier: SupportedTypes.plainText,
                                         data: Data(body.utf8))
            _ = try store.insertOrBump(clip, representations: [rep])
        }
        #expect(try store.count() == 5_000)

        let clock = ContinuousClock()
        let list = try clock.measure { _ = try store.recentClips(limit: 200) }
        let search = try clock.measure { _ = try store.search("lorem", limit: 200) }
        let smart = try clock.measure { _ = try store.clips(in: .everything) }

        #expect(list < .seconds(0.5), "recents took \(list)")
        #expect(search < .seconds(0.5), "search took \(search)")
        #expect(smart < .seconds(0.5), "smart collection took \(smart)")
    }
}
