import Foundation
import Testing
@testable import ClipMateCore

@Suite("FileClip")
struct FileClipTests {

    @Test("round-trips a single url")
    func roundTripsOne() {
        let urls = [URL(fileURLWithPath: "/tmp/alpha.txt")]
        #expect(FileClip.decode(FileClip.encode(urls)) == urls)
    }

    @Test("round-trips several urls, preserving order")
    func roundTripsMany() {
        let urls = [
            URL(fileURLWithPath: "/tmp/alpha.txt"),
            URL(fileURLWithPath: "/tmp/beta.txt"),
            URL(fileURLWithPath: "/tmp/gamma.txt"),
        ]
        #expect(FileClip.decode(FileClip.encode(urls)) == urls)
    }

    @Test("survives a path containing spaces and unicode")
    func roundTripsAwkwardPath() {
        let urls = [URL(fileURLWithPath: "/tmp/my report — final draft.txt")]
        let decoded = FileClip.decode(FileClip.encode(urls))
        #expect(decoded == urls)
        #expect(decoded.first?.lastPathComponent == "my report — final draft.txt")
    }

    @Test("one file is titled with its filename")
    func titlesOneFile() {
        #expect(FileClip.title(for: [URL(fileURLWithPath: "/tmp/alpha.txt")]) == "alpha.txt")
    }

    @Test("several files are titled by count — the L1 bug was showing only the first")
    func titlesManyFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/alpha.txt"),
            URL(fileURLWithPath: "/tmp/beta.txt"),
        ]
        #expect(FileClip.title(for: urls) == "2 files")
    }

    @Test("a folder is titled with its own name, not its parent's")
    func titlesFolder() {
        #expect(FileClip.title(for: [URL(fileURLWithPath: "/tmp/Projects/")]) == "Projects")
    }

    @Test("empty decodes to nothing rather than a bogus url")
    func decodesEmpty() {
        #expect(FileClip.decode(Data()).isEmpty)
        #expect(FileClip.decode(Data("\n\n".utf8)).isEmpty)
    }

    @Test("a non-file url is refused — only file references belong in a file clip")
    func rejectsNonFileURL() {
        #expect(FileClip.decode(Data("https://example.com/x".utf8)).isEmpty)
    }
}
