import AppKit
import QuartzCore

class TabRowView: NSTableRowView {
    var selectionColor: NSColor?

    override func drawSelection(in dirtyRect: NSRect) {
        guard let color = selectionColor else {
            super.drawSelection(in: dirtyRect)
            return
        }
        let alpha: CGFloat = isEmphasized ? 0.35 : 0.15
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: UIConstants.defaultCornerRadius, yRadius: UIConstants.defaultCornerRadius).fill()
    }

    /// The inset rect the source list uses for its selection highlight
    var selectionRect: NSRect {
        // Source list selection is inset ~10pt horizontally, ~1pt vertically, with 6pt corner radius
        return bounds.insetBy(dx: 10, dy: 1)
    }
}

class TabCellView: NSTableCellView {
    enum LoadingIndicatorMode {
        case ringSpinner   // Option A: spinning ring around favicon -- not currently used, still buggy/incomplete
        case progressBar   // Option B: background progress bar
    }

    static var loadingMode: LoadingIndicatorMode = .progressBar

    let titleLabel = NSTextField(labelWithString: "")
    let faviconImageView = NSImageView()
    private let sleepBadge = NSImageView()
    private let closeButton: NSButton
    private let speakerButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var titleTrailingDefault: NSLayoutConstraint!
    private var titleTrailingHover: NSLayoutConstraint!
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var faviconLeadingConstraint: NSLayoutConstraint!
    private let hoverBackground = NSView()
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var indentLevel: Int = 0 {
        didSet {
            faviconLeadingConstraint.constant = 4 + CGFloat(indentLevel) * 16
        }
    }
    private var audioPlaying = false
    private var isHovered = false

    // Option A: Ring spinner layer
    private var ringLayer: CAShapeLayer?

    // Option B: Progress bar (frame set manually in layout())
    private let progressView = NSView()
    private var currentProgress: Double = 0

    override init(frame frameRect: NSRect) {
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: nil,
            action: nil
        )
        speakerButton = NSButton(
            image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Audio")!,
            target: nil,
            action: nil
        )
        super.init(frame: frameRect)
        wantsLayer = true

        // Progress bar (Option B) — frame managed in layout(), no constraints
        progressView.wantsLayer = true
        progressView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
        progressView.layer?.cornerRadius = UIConstants.defaultCornerRadius
        progressView.alphaValue = 0
        addSubview(progressView, positioned: .below, relativeTo: nil)

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        faviconImageView.wantsLayer = true
        faviconImageView.imageScaling = .scaleProportionallyUpOrDown
        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

        titleLabel.wantsLayer = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        speakerButton.bezelStyle = .inline
        speakerButton.isBordered = false
        speakerButton.isHidden = true
        speakerButton.target = self
        speakerButton.action = #selector(speakerTapped)
        speakerButton.translatesAutoresizingMaskIntoConstraints = false

        sleepBadge.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Sleeping")
        sleepBadge.translatesAutoresizingMaskIntoConstraints = false
        sleepBadge.imageScaling = .scaleProportionallyUpOrDown
        sleepBadge.contentTintColor = .tertiaryLabelColor
        sleepBadge.isHidden = true

        addSubview(faviconImageView)
        addSubview(sleepBadge)
        addSubview(speakerButton)
        addSubview(titleLabel)
        addSubview(closeButton)

        titleTrailingDefault = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        titleTrailingHover = titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4)
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)
        faviconLeadingConstraint = faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            faviconLeadingConstraint,
            faviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconImageView.widthAnchor.constraint(equalToConstant: 16),
            faviconImageView.heightAnchor.constraint(equalToConstant: 16),

            sleepBadge.trailingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 3),
            sleepBadge.bottomAnchor.constraint(equalTo: faviconImageView.bottomAnchor, constant: 3),
            sleepBadge.widthAnchor.constraint(equalToConstant: 8),
            sleepBadge.heightAnchor.constraint(equalToConstant: 8),

            speakerButton.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 4),
            speakerButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            speakerButton.widthAnchor.constraint(equalToConstant: 16),
            speakerButton.heightAnchor.constraint(equalToConstant: 16),

            titleLeadingConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailingDefault,

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        closeButton.isHidden = true
        hoverBackground.isHidden = true
        indentLevel = 0
        updateLayoutState()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 12, bounds.height > 2 else { return }
        hoverBackground.frame = bounds.insetBy(dx: -6, dy: 1)
        // Progress bar spans the full row area (same rect as hover background)
        let rowRect = bounds.insetBy(dx: -6, dy: 1)
        let progressWidth = rowRect.width * max(currentProgress, 0)
        progressView.frame = NSRect(
            x: rowRect.origin.x,
            y: rowRect.origin.y,
            width: progressWidth.isFinite ? progressWidth : 0,
            height: rowRect.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        closeButton.isHidden = false
        hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        hoverBackground.isHidden = false
        updateLayoutState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        hoverBackground.isHidden = true
        updateLayoutState()
    }

    /// Re-evaluate hover state using the current mouse position.
    /// Call this when scrolling moves cells under/away from the mouse,
    /// since NSTrackingArea doesn't reliably fire mouseExited in that case.
    func recheckHover() {
        guard let window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInSelf = convert(mouseInWindow, from: nil)
        let shouldHover = bounds.contains(mouseInSelf)
        guard shouldHover != isHovered else { return }
        if shouldHover {
            isHovered = true
            closeButton.isHidden = false
            hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
            hoverBackground.isHidden = false
        } else {
            isHovered = false
            closeButton.isHidden = true
            hoverBackground.isHidden = true
        }
        updateLayoutState()
    }

    func updateAudio(isPlaying: Bool, isMuted: Bool) {
        audioPlaying = isPlaying || isMuted

        // Update icon immediately (no animation needed for icon swap)
        if isMuted {
            speakerButton.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
        } else if isPlaying {
            speakerButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing Audio")
        }

        // Show button before animating in (hide after animating out in completion)
        if audioPlaying {
            speakerButton.isHidden = false
            speakerButton.alphaValue = 0
        }

        let targetConstant: CGFloat = audioPlaying ? 24 : 8

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            self.titleLeadingConstraint.animator().constant = targetConstant
            self.speakerButton.animator().alphaValue = self.audioPlaying ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.audioPlaying {
                self.speakerButton.isHidden = true
            }
        })
    }

    private func updateLayoutState() {
        // Leading: 8pt from favicon when no audio, 24pt (4+16+4) when speaker visible
        titleLeadingConstraint.constant = audioPlaying ? 24 : 8

        // Trailing: title ends before close button on hover, at edge otherwise
        titleTrailingDefault.isActive = false
        titleTrailingHover.isActive = false
        if isHovered {
            titleTrailingHover.isActive = true
        } else {
            titleTrailingDefault.isActive = true
        }
    }

    @objc private func speakerTapped() {
        onToggleMute?()
    }

    func updateFavicon(_ image: NSImage?) {
        faviconImageView.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
    }

    func updateSleeping(_ isSleeping: Bool) {
        sleepBadge.isHidden = !isSleeping
    }

    func updateLoading(_ isLoading: Bool) {
        switch Self.loadingMode {
        case .ringSpinner:
            if isLoading {
                showRingSpinner()
            } else {
                hideRingSpinner()
            }
        case .progressBar:
            if !isLoading {
                hideProgressBar()
            }
        }
    }

    func updateProgress(_ progress: Double) {
        guard Self.loadingMode == .progressBar else { return }
        let clampedProgress = min(max(progress, 0), 1)
        currentProgress = clampedProgress

        // Don't show at 0, and auto-hide when reaching 1.0
        if clampedProgress <= 0 || clampedProgress >= 1.0 {
            if progressView.alphaValue > 0 {
                hideProgressBar()
            }
            return
        }

        if progressView.alphaValue == 0 {
            progressView.alphaValue = 1
        }

        guard bounds.width > 0, bounds.height > 0 else { return }
        let rowRect = bounds.insetBy(dx: -6, dy: 1)
        let targetFrame = NSRect(
            x: rowRect.origin.x,
            y: rowRect.origin.y,
            width: rowRect.width * clampedProgress,
            height: rowRect.height
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressView.animator().frame = targetFrame
        }
    }

    // MARK: - Option A: Ring Spinner

    private func showRingSpinner() {
        guard ringLayer == nil else { return }
        wantsLayer = true
        guard let cellLayer = layer else { return }

        let diameter: CGFloat = 20
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)

        // Position the ring at the favicon's center in the cell's coordinate space
        let ff = faviconImageView.frame
        // AppKit layers are not flipped — convert from flipped view coords to layer coords
        ring.position = CGPoint(x: ff.midX, y: cellLayer.bounds.height - ff.midY)

        let path = CGPath(
            ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1),
            transform: nil
        )
        ring.path = path
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2
        ring.strokeStart = 0
        ring.strokeEnd = 0.3
        ring.lineCap = .round

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1
        rotation.repeatCount = .infinity

        ring.add(rotation, forKey: "spin")
        cellLayer.addSublayer(ring)
        ringLayer = ring
    }

    private func hideRingSpinner() {
        ringLayer?.removeFromSuperlayer()
        ringLayer = nil
    }

    // MARK: - Option B: Progress Bar

    private func hideProgressBar() {
        currentProgress = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            progressView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.progressView.frame.size.width = 0
        })
    }

    func updatePinnedMode(tab: BrowserTab?) {
        guard let tab, tab.isPinned else {
            // Normal tab: use xmark
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
            return
        }
        if tab.isNavigatedWithinPinnedHost {
            closeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Reset to Home")
        } else {
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

class SeparatorCellView: NSTableCellView {
    private let shadowLine = NSView()
    private let highlightLine = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        shadowLine.wantsLayer = true
        shadowLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowLine)

        highlightLine.wantsLayer = true
        highlightLine.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightLine)

        NSLayoutConstraint.activate([
            shadowLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shadowLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shadowLine.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            shadowLine.heightAnchor.constraint(equalToConstant: 1.5),

            highlightLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            highlightLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            highlightLine.topAnchor.constraint(equalTo: shadowLine.bottomAnchor),
            highlightLine.heightAnchor.constraint(equalToConstant: 1.5),
        ])

        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        shadowLine.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        highlightLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.45).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}

class NewTabCellView: NSTableCellView {
    private let hoverBackground = NSView()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        let plusIcon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!)
        plusIcon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "New Tab")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(plusIcon)
        addSubview(label)

        NSLayoutConstraint.activate([
            plusIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            plusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            plusIcon.widthAnchor.constraint(equalToConstant: 16),
            plusIcon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: plusIcon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    override func layout() {
        super.layout()
        hoverBackground.frame = bounds.insetBy(dx: -6, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }

    func recheckHover() {
        guard let window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInSelf = convert(mouseInWindow, from: nil)
        let shouldHover = bounds.contains(mouseInSelf)
        if shouldHover {
            hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
            hoverBackground.isHidden = false
        } else {
            hoverBackground.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
