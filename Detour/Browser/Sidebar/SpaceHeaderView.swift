import AppKit

class SpaceHeaderView: NSView {
    private let emojiLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        emojiLabel.font = .systemFont(ofSize: 13)
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.setContentHuggingPriority(.required, for: .horizontal)
        emojiLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(emojiLabel)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            emojiLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 19),
            emojiLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    func update(emoji: String, name: String) {
        emojiLabel.stringValue = emoji
        nameLabel.stringValue = name
    }
}
