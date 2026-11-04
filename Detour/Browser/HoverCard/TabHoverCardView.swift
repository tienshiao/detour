import AppKit

/// The sidebar's tab hover card (TASK-190): the full title, the URL with its
/// host emphasised, and a thumbnail of the page when one exists. Hosted in a
/// `TabHoverCardPanel` beside the sidebar.
final class TabHoverCardView: NSView {
    static let width: CGFloat = 260
    private static let padding = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
    static var contentWidth: CGFloat { width - padding.left - padding.right }
    private static let maxThumbnailHeight: CGFloat = 160

    private let glass = GlassContainerView(cornerRadius: 12)
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let thumbnailView = HoverCardThumbnailView()
    private let stack = NSStackView()
    private var thumbnailHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        addSubview(glass)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.preferredMaxLayoutWidth = Self.contentWidth
        titleLabel.isSelectable = false

        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.maximumNumberOfLines = 1
        urlLabel.cell?.usesSingleLineMode = true
        urlLabel.isSelectable = false
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailHeight = thumbnailView.heightAnchor.constraint(equalToConstant: 0)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = Self.padding
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(urlLabel)
        stack.addArrangedSubview(thumbnailView)
        stack.setCustomSpacing(10, after: urlLabel)
        glass.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),

            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),

            titleLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            urlLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth),
            thumbnailView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            thumbnailHeight,
        ])
    }

    func configure(text: HoverCardText, thumbnail: NSImage?) {
        titleLabel.stringValue = text.title
        if let line = text.url {
            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(string: line.host, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]))
            attributed.append(NSAttributedString(string: line.rest, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributed.addAttribute(.paragraphStyle, value: paragraph,
                                    range: NSRange(location: 0, length: attributed.length))
            urlLabel.attributedStringValue = attributed
            urlLabel.isHidden = false
        } else {
            urlLabel.attributedStringValue = NSAttributedString()
            urlLabel.isHidden = true
        }
        setThumbnail(thumbnail)
    }

    /// Shows `image` below the text at the content width, aspect preserved and
    /// its height capped (a tall page is cropped from the top); with none the
    /// card is text only, with no empty box.
    func setThumbnail(_ image: NSImage?) {
        thumbnailView.image = image
        if let image, image.size.width > 0, image.size.height > 0 {
            let height = (Self.contentWidth * image.size.height / image.size.width).rounded()
            thumbnailHeight.constant = min(height, Self.maxThumbnailHeight)
            thumbnailView.isHidden = false
        } else {
            thumbnailView.isHidden = true
        }
        // The last visible view before the thumbnail gets its gap.
        stack.setCustomSpacing(urlLabel.isHidden ? 10 : 3, after: titleLabel)
        stack.setCustomSpacing(10, after: urlLabel)
        needsLayout = true
    }

    var hasThumbnail: Bool { !thumbnailView.isHidden }
}

/// The page picture: scaled to the view's width, aligned to the top and
/// clipped to a rounded rectangle with a hairline edge.
final class HoverCardThumbnailView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private static let cornerRadius: CGFloat = 6

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0 else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let height = bounds.width * image.size.height / image.size.width
        image.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        edge.lineWidth = 0.5
        edge.stroke()
    }
}

/// A borderless, non-activating, click-through child panel for the card.
final class TabHoverCardPanel: NSPanel {
    let cardView = TabHoverCardView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: TabHoverCardView.width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let container = NSView()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: container.topAnchor),
            cardView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card's size for its current content.
    var fittingCardSize: NSSize {
        cardView.layoutSubtreeIfNeeded()
        let size = cardView.fittingSize
        return NSSize(width: TabHoverCardView.width, height: ceil(size.height))
    }
}
