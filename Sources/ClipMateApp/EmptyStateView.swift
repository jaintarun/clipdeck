import AppKit

/// Centered symbol + title + hint for surfaces with nothing to show. The
/// owning controller configures and shows/hides it; it draws nothing else.
@MainActor
final class EmptyStateView: NSView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        symbolView.contentTintColor = .tertiaryLabelColor
        titleField.font = .systemFont(ofSize: 15, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .center
        hintField.font = .systemFont(ofSize: 12)
        hintField.textColor = .tertiaryLabelColor
        hintField.alignment = .center

        let stack = NSStackView(views: [symbolView, titleField, hintField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: symbolView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(symbol: String, title: String, hint: String) {
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        titleField.stringValue = title
        hintField.stringValue = hint
    }
}
