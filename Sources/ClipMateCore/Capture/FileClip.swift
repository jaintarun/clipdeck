import Foundation

/// How a file clip is stored.
///
/// The `PasteboardReading` seam carries one `Data` per UTI, but a file copy
/// carries N URLs, so the `public.file-url` payload is the newline-joined
/// `absoluteString`s of the resolved URLs. Newline is safe as a separator
/// because a URL's `absoluteString` is percent-encoded — a literal newline in
/// a filename arrives as `%0A`.
///
/// We store URL STRINGS ONLY — never file bytes (master guide 5.4). If the
/// file moves or is deleted the paste fails, which is the honest behavior for
/// a reference, and is what Finder's own clipboard does.
public enum FileClip {

    /// Joined `absoluteString`s. Resolved paths, never Finder's opaque
    /// `file:///.file/id=…` URLs — those render as an ID rather than a name.
    public static func encode(_ urls: [URL]) -> Data {
        Data(urls.map(\.absoluteString).joined(separator: "\n").utf8)
    }

    /// Tolerant by design: a clip that fails to decode should surface as
    /// "nothing to paste", never as a crash or a bogus URL.
    public static func decode(_ data: Data) -> [URL] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(separator: "\n")
            .map(String.init)
            .compactMap { URL(string: $0) }
            .filter(\.isFileURL)
    }

    /// One file shows its name; several show a count.
    ///
    /// L1 titled a two-file Finder copy "alpha.txt" — it captured the
    /// filenames as text and `makeTitle` kept the first line, so the title
    /// silently lied about how much was copied.
    ///
    /// `lastPathComponent` is right for a directory too: `/tmp/Projects/`
    /// yields "Projects".
    public static func title(for urls: [URL]) -> String {
        switch urls.count {
        case 0:  return "No files"
        case 1:  return urls[0].lastPathComponent
        default: return "\(urls.count) files"
        }
    }
}
