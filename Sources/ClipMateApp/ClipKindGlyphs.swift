import ClipMateCore

/// SF Symbol per kind for the Explorer's Type column (the word moves to the
/// cell's tooltip). App-target extension: ClipMateCore knows no symbol names.
extension ClipKind {
    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
