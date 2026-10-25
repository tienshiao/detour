import AppKit

/// What the now-playing bar draws (TASK-192). Built by the window from the
/// playing tab; the page's Media Session supplies title, artist and artwork
/// when it has them.
struct NowPlayingBarModel: Equatable {
    var tabID: UUID
    var favicon: NSImage?
    var title: String
    var artist: String?
    var artwork: NSImage?
    var isPlaying: Bool
    var isMuted: Bool
    var canGoPrevious: Bool
    var canGoNext: Bool
    /// This WebKit can mute a page; the mute button is hidden otherwise.
    var canMute: Bool
}

enum NowPlayingBarAction: Equatable {
    case selectTab, previous, playPause, next, toggleMute, dismiss
}

/// The now-playing bar at the bottom of the sidebar: a glass card with the
/// playing tab's favicon, Previous, Play/Pause, Next and Mute. Hovering grows
/// it upward — over the bottom of the tab list, which does not move — with
/// the title (and artist and artwork when the page provides them) and a ×.
/// The view's own height is the card's: the sidebar pins only its bottom and
/// sides, so the hover tracking area grows with it.
final class NowPlayingBarView: NSView {
    static let compactHeight: CGFloat = 34
    static let titleRowHeight: CGFloat = 40

    var onAction: ((NowPlayingBarAction, UUID) -> Void)?
    private(set) var model: NowPlayingBarModel?
    private(set) var isExpanded = false

    /// The rows' highlight radius, so the card reads as one of them.
    private let card = GlassContainerView(cornerRadius: UIConstants.defaultCornerRadius)
    private var cardHeight: NSLayoutConstraint!
    private let controlsRow = NSStackView()
    private let titleRow = NSView()
    private let faviconButton = HoverButton()
    private let previousButton = HoverButton()
    private let playPauseButton = HoverButton()
    private let nextButton = HoverButton()
    private let muteButton = HoverButton()
    private let closeButton = HoverButton()
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private var artworkWidth: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var collapseWorkItem: DispatchWorkItem?

    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Now Playing")

        addSubview(card)
        cardHeight = card.heightAnchor.constraint(equalToConstant: Self.compactHeight)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardHeight,
        ])

        configure(faviconButton, symbol: nil, label: "Go to Playing Tab", action: #selector(selectTabClicked))
        faviconButton.imageScaling = .scaleProportionallyDown
        configure(previousButton, symbol: "backward.end.fill", label: "Previous Track", action: #selector(previousClicked))
        configure(playPauseButton, symbol: "pause.fill", label: "Pause", action: #selector(playPauseClicked))
        configure(nextButton, symbol: "forward.end.fill", label: "Next Track", action: #selector(nextClicked))
        configure(muteButton, symbol: "speaker.wave.2.fill", label: "Mute", action: #selector(muteClicked))
        configure(closeButton, symbol: "xmark", label: "Dismiss", action: #selector(closeClicked))

        controlsRow.orientation = .horizontal
        controlsRow.distribution = .equalSpacing
        controlsRow.alignment = .centerY
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [faviconButton, previousButton, playPauseButton, nextButton, muteButton] {
            controlsRow.addArrangedSubview(button)
        }

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 4
        artworkView.layer?.masksToBounds = true
        artworkView.setAccessibilityElement(false)

        for label in [titleLabel, artistLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor

        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.alphaValue = 0
        titleRow.isHidden = true
        let textStack = NSStackView(views: [titleLabel, artistLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(artworkView)
        titleRow.addSubview(textStack)
        titleRow.addSubview(closeButton)

        let content = card.contentView
        content.addSubview(titleRow)
        content.addSubview(controlsRow)

        artworkWidth = artworkView.widthAnchor.constraint(equalToConstant: 0)
        textLeading = textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            controlsRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            controlsRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            controlsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
            controlsRow.heightAnchor.constraint(equalToConstant: 28),

            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            titleRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            titleRow.heightAnchor.constraint(equalToConstant: Self.titleRowHeight - 8),

            artworkView.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            artworkView.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            artworkView.heightAnchor.constraint(equalToConstant: 28),
            artworkWidth,
            textLeading,
            textStack.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
        ])
    }

    private func configure(_ button: HoverButton, symbol: String?, label: String, action: Selector) {
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(Self.symbolConfig)
        }
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.circular = true
        button.fixedHoverSize = 26
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    // MARK: Model

    func apply(_ model: NowPlayingBarModel) {
        self.model = model
        faviconButton.image = (model.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil))
            .map(Self.faviconImage)
        faviconButton.setAccessibilityLabel("Go to \(model.title)")
        faviconButton.toolTip = model.title

        let playLabel = model.isPlaying ? "Pause" : "Play"
        playPauseButton.image = NSImage(systemSymbolName: model.isPlaying ? "pause.fill" : "play.fill",
                                        accessibilityDescription: playLabel)?.withSymbolConfiguration(Self.symbolConfig)
        playPauseButton.setAccessibilityLabel(playLabel)
        playPauseButton.toolTip = playLabel

        let muteLabel = model.isMuted ? "Unmute" : "Mute"
        muteButton.image = NSImage(systemSymbolName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   accessibilityDescription: muteLabel)?.withSymbolConfiguration(Self.symbolConfig)
        muteButton.setAccessibilityLabel(muteLabel)
        muteButton.toolTip = muteLabel
        muteButton.isHidden = !model.canMute

        previousButton.isEnabled = model.canGoPrevious
        nextButton.isEnabled = model.canGoNext
        previousButton.alphaValue = model.canGoPrevious ? 1 : 0.35
        nextButton.alphaValue = model.canGoNext ? 1 : 0.35

        titleLabel.stringValue = model.title
        artistLabel.stringValue = model.artist ?? ""
        artistLabel.isHidden = model.artist == nil
        artworkView.image = model.artwork
        artworkWidth.constant = model.artwork == nil ? 0 : 28
        textLeading.constant = model.artwork == nil ? 0 : 8
        setAccessibilityLabel(model.artist.map { "Now Playing: \(model.title), \($0)" } ?? "Now Playing: \(model.title)")
    }

    /// The favicon at the bar's 16 pt, so a large site icon does not fill the button.
    private static func faviconImage(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    // MARK: Hover

    /// A bar fading out takes no clicks, even before its fade completes.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.5 ? nil : super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        collapseWorkItem?.cancel()
        setExpanded(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setExpanded(false, animated: true) }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        let height = Self.compactHeight + (expanded ? Self.titleRowHeight : 0)
        if expanded { titleRow.isHidden = false }
        let apply = {
            self.cardHeight.animator().constant = height
            self.titleRow.animator().alphaValue = expanded ? 1 : 0
        }
        guard animated else {
            cardHeight.constant = height
            titleRow.alphaValue = expanded ? 1 : 0
            titleRow.isHidden = !expanded
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            apply()
        }, completionHandler: { [weak self] in
            guard let self, !self.isExpanded else { return }
            self.titleRow.isHidden = true
        })
    }

    // MARK: Actions

    private func send(_ action: NowPlayingBarAction) {
        guard let tabID = model?.tabID else { return }
        onAction?(action, tabID)
    }

    @objc private func selectTabClicked() { send(.selectTab) }
    @objc private func previousClicked() { send(.previous) }
    @objc private func playPauseClicked() { send(.playPause) }
    @objc private func nextClicked() { send(.next) }
    @objc private func muteClicked() { send(.toggleMute) }
    @objc private func closeClicked() { send(.dismiss) }
}
