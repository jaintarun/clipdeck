import Testing
@testable import ClipMateCore

@Suite("Debouncer")
struct DebouncerTests {

    @MainActor
    @Test("a burst of calls runs only the last block, once")
    func coalescesBursts() async throws {
        let d = Debouncer(delay: .milliseconds(40))
        var runs: [Int] = []
        d.call { runs.append(1) }
        d.call { runs.append(2) }
        d.call { runs.append(3) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs == [3])
    }

    @MainActor
    @Test("cancel drops the pending block")
    func cancelDropsPending() async throws {
        let d = Debouncer(delay: .milliseconds(40))
        var ran = false
        d.call { ran = true }
        d.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!ran)
    }
}
