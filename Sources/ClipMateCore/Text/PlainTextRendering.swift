import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Reduces captured rich formats to PLAIN TEXT for the preview.
///
/// SECURITY FLOOR (master guide §5.4): captured HTML renders as plain text
/// until a dedicated sanitized-renderer review — NO WKWebView, NO
/// `NSAttributedString(html:)` (a WebKit path that can issue remote loads and
/// run scripts), NO script execution, NO remote loads. `fromHTML` is a local
/// tag stripper. `fromRTF` uses the local RTF document parser (an explicit
/// `.rtf` document type, distinct from the banned `.html` one).
public enum PlainTextRendering {

    /// Strip HTML to readable text with no web engine. Deletes `<script>` and
    /// `<style>` elements including their contents, turns block-level closers
    /// into newlines, drops all remaining tags, decodes the handful of entities
    /// that actually appear, and collapses whitespace. Pure and deterministic.
    public static func fromHTML(_ html: String) -> String {
        var s = html

        // 1. Remove <script>…</script> and <style>…</style> including content.
        //    [\s\S] matches across newlines (`.` would not).
        for tag in ["script", "style"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        // 2. In HTML source, ALL whitespace (including newlines) is equivalent
        //    to a single space — only tags introduce structure. Collapse it
        //    FIRST so source line breaks don't survive as fake paragraph breaks.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // 3. Block-level closers/breaks become real newlines so structure survives.
        for br in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>",
                   "</tr>", "</h1>", "</h2>", "</h3>", "</h4>"] {
            s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        // 4. Drop every remaining tag.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // 5. Decode entities (after tag removal, so decoded < > are not re-parsed).
        for (from, to) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                           ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                           ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = decodeNumericEntities(s)
        // 6. Trim each line, drop the empties, and stitch back together.
        let lines = s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// Parse RTF to plain text via the local Cocoa parser, discarding styling.
    /// Returns nil for bytes that are not valid RTF. AppKit-only.
    public static func fromRTF(_ data: Data) -> String? {
        #if canImport(AppKit)
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return attr.string
        #else
        return nil
        #endif
    }

    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var result = ""
        var rest = Substring(s)
        while let range = rest.range(of: "&#[0-9]+;", options: .regularExpression) {
            result += rest[rest.startIndex..<range.lowerBound]
            let digits = rest[range].dropFirst(2).dropLast()   // "&#8217;" -> "8217"
            if let code = UInt32(digits), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }
}
