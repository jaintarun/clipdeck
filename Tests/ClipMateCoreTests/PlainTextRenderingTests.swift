import Foundation
import AppKit
import Testing
@testable import ClipMateCore

@Suite("PlainTextRendering")
struct PlainTextRenderingTests {

    @Test("HTML tags are stripped to readable text")
    func stripsTags() {
        #expect(PlainTextRendering.fromHTML("<p>Hello <b>world</b></p>") == "Hello world")
    }

    @Test("script and style element contents are removed entirely")
    func removesScriptAndStyle() {
        let html = "<style>.a{color:red}</style><p>keep</p><script>alert(1)</script>"
        #expect(PlainTextRendering.fromHTML(html) == "keep")
    }

    @Test("block elements become line breaks")
    func blocksBecomeNewlines() {
        #expect(PlainTextRendering.fromHTML("<div>a</div><div>b</div>") == "a\nb")
    }

    @Test("named and numeric entities are decoded")
    func decodesEntities() {
        #expect(PlainTextRendering.fromHTML("a &amp; b &lt;c&gt; d&#8217;e") == "a & b <c> d’e")
    }

    @Test("runs of whitespace collapse")
    func collapsesWhitespace() {
        #expect(PlainTextRendering.fromHTML("<p>one     two\n\n\n   three</p>") == "one two three")
    }

    @Test("RTF is reduced to plain text, dropping styling")
    func rtfToPlainText() throws {
        let attributed = NSAttributedString(
            string: "Bold idea",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
        )
        let data = try #require(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        ))
        #expect(PlainTextRendering.fromRTF(data) == "Bold idea")
    }
}
