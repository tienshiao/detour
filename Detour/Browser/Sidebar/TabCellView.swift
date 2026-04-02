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

class TabCellView: NSTableCellView, NSTextFieldDelegate {
    enum LoadingIndicatorMode {
        case ringSpinner   // Option A: spinning ring around favicon -- not currently used, still buggy/incomplete
        case progressBar   // Option B: background progress bar
    }

    static var loadingMode: LoadingIndicatorMode = .progressBar

    let titleLabel = NSTextField(labelWithString: "")
    let faviconImageView = NSImageView()
    private let sleepBadge = NSImageView()
    private let closeButton: HoverButton
    private let speakerButton: NSButton
    private let peekFaviconImageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var faviconLeadingConstraint: NSLayoutConstraint!
    private var closeButtonWidthConstraint: NSLayoutConstraint!
    private var closeButtonTrailingConstraint: NSLayoutConstraint!
    private var peekFaviconWidthConstraint: NSLayoutConstraint!
    private let hoverBackground = NSView()
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onRename: ((String) -> Void)?
    private var isEditing = false
    private var originalEditingValue: String?
    var indentLevel: Int = 0 {
        didSet {
            faviconLeadingConstraint.constant = 4 + CGFloat(indentLevel) * 16
        }
    }
    private var audioPlaying = false
    private var isHovered = false
    private var hasPeek = false

    // Option A: Ring spinner layer
    private var ringLayer: CAShapeLayer?

    // Option B: Progress bar (frame set manually in layout())
    private let progressView = NSView()
    private var currentProgress: Double = 0

    override init(frame frameRect: NSRect) {
        closeButton = HoverButton()
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))!
        closeButton.fixedHoverSize = 20
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
        closeButton.imagePosition = .imageOnly
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

        peekFaviconImageView.wantsLayer = true
        peekFaviconImageView.imageScaling = .scaleProportionallyUpOrDown
        peekFaviconImageView.translatesAutoresizingMaskIntoConstraints = false
        peekFaviconImageView.isHidden = true

        addSubview(faviconImageView)
        addSubview(sleepBadge)
        addSubview(speakerButton)
        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(peekFaviconImageView)

        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)
        faviconLeadingConstraint = faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        closeButtonWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 0)
        closeButtonTrailingConstraint = closeButton.trailingAnchor.constraint(equalTo: peekFaviconImageView.leadingAnchor, constant: 0)
        peekFaviconWidthConstraint = peekFaviconImageView.widthAnchor.constraint(equalToConstant: 0)

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

            // Fixed chain: title → closeButton → peekFavicon → trailing
            titleLeadingConstraint,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButtonTrailingConstraint,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButtonWidthConstraint,
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            peekFaviconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            peekFaviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            peekFaviconWidthConstraint,
            peekFaviconImageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        hasPeek = false
        closeButton.isHidden = true
        peekFaviconImageView.isHidden = true
        peekFaviconImageView.image = nil
        hoverBackground.isHidden = true
        indentLevel = 0
        onRename = nil
        if isEditing { endEditing(commit: false) }
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
        let newAudioPlaying = isPlaying || isMuted
        guard newAudioPlaying != audioPlaying else { return }
        audioPlaying = newAudioPlaying

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
        titleLeadingConstraint.constant = audioPlaying ? 24 : 8
        closeButtonWidthConstraint.constant = isHovered ? 16 : 0
        closeButtonTrailingConstraint.constant = hasPeek ? -4 : 0
        peekFaviconWidthConstraint.constant = hasPeek ? 16 : 0
    }

    @objc private func speakerTapped() {
        onToggleMute?()
    }

    func updateFavicon(_ image: NSImage?) {
        faviconImageView.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
    }

    func updatePeekFavicon(_ image: NSImage?) {
        hasPeek = image != nil
        peekFaviconImageView.image = image
        peekFaviconImageView.isHidden = !hasPeek
        updateLayoutState()
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

    func updatePinnedMode(entry: PinnedEntry?) {
        guard let entry else {
            // Normal tab: use xmark
            let boldConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(boldConfig)
            return
        }
        if entry.isLive {
            // Live pinned tab: minus to make dormant
            let boldConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            closeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Close Tab")?.withSymbolConfiguration(boldConfig)
        } else {
            // Dormant pinned entry: xmark to remove entirely
            let boldConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove Pin")?.withSymbolConfiguration(boldConfig)
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Inline Rename

    func beginEditing() {
        isEditing = true
        originalEditingValue = titleLabel.stringValue
        titleLabel.isEditable = true
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.focusRingType = .none
        titleLabel.delegate = self
        titleLabel.selectText(nil)
    }

    private func endEditing(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        titleLabel.isEditable = false
        if !commit, let original = originalEditingValue {
            titleLabel.stringValue = original
        }
        originalEditingValue = nil
        if commit {
            let newName = titleLabel.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                onRename?(newName)
                pulseCommit()
            }
        }
    }

    private func pulseCommit() {
        hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        hoverBackground.isHidden = false
        hoverBackground.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverBackground.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.isHovered {
                self.hoverBackground.isHidden = true
            }
            self.hoverBackground.alphaValue = 1
        })
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        endEditing(commit: true)
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            endEditing(commit: false)
            window?.makeFirstResponder(enclosingScrollView?.documentView)
            return true
        }
        return false
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

        let plusIcon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))!)
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
