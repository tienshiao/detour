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
        NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6).fill()
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
    private let closeButton: NSButton
    private let speakerButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var titleTrailingDefault: NSLayoutConstraint!
    private var titleTrailingHover: NSLayoutConstraint!
    private var titleLeadingToFavicon: NSLayoutConstraint!
    private var titleLeadingToSpeaker: NSLayoutConstraint!
    private let hoverBackground = NSView()
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
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

        // Progress bar (Option B) — frame managed in layout(), no constraints
        progressView.wantsLayer = true
        progressView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.05).cgColor
        progressView.layer?.cornerRadius = 6
        progressView.alphaValue = 0
        addSubview(progressView, positioned: .below, relativeTo: nil)

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        faviconImageView.wantsLayer = true
        faviconImageView.imageScaling = .scaleProportionallyUpOrDown
        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

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

        addSubview(faviconImageView)
        addSubview(speakerButton)
        addSubview(titleLabel)
        addSubview(closeButton)

        titleTrailingDefault = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        titleTrailingHover = titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4)
        titleLeadingToFavicon = titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)
        titleLeadingToSpeaker = titleLabel.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            faviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconImageView.widthAnchor.constraint(equalToConstant: 16),
            faviconImageView.heightAnchor.constraint(equalToConstant: 16),

            speakerButton.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 4),
            speakerButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            speakerButton.widthAnchor.constraint(equalToConstant: 16),
            speakerButton.heightAnchor.constraint(equalToConstant: 16),

            titleLeadingToFavicon,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailingDefault,

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        hoverBackground.frame = bounds.insetBy(dx: -6, dy: 1)
        // Progress bar spans the full row area (same rect as hover background)
        let rowRect = bounds.insetBy(dx: -6, dy: 1)
        progressView.frame = NSRect(
            x: rowRect.origin.x,
            y: rowRect.origin.y,
            width: rowRect.width * currentProgress,
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
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        hoverBackground.isHidden = false
        updateLayoutState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        hoverBackground.isHidden = true
        updateLayoutState()
    }

    func updateAudio(isPlaying: Bool, isMuted: Bool) {
        audioPlaying = isPlaying || isMuted
        if !isPlaying && !isMuted {
            speakerButton.isHidden = true
        } else if isMuted {
            speakerButton.isHidden = false
            speakerButton.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
        } else {
            speakerButton.isHidden = false
            speakerButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing Audio")
        }
        updateLayoutState()
    }

    private func updateLayoutState() {
        // Deactivate all optional constraints first to avoid conflicts
        titleLeadingToFavicon.isActive = false
        titleLeadingToSpeaker.isActive = false
        titleTrailingDefault.isActive = false
        titleTrailingHover.isActive = false

        // Leading: title starts after speaker when audio, after favicon otherwise
        if audioPlaying {
            titleLeadingToSpeaker.isActive = true
        } else {
            titleLeadingToFavicon.isActive = true
        }

        // Trailing: title ends before close button on hover, at edge otherwise
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

    @objc private func closeTapped() {
        onClose?()
    }
}

class NewTabCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

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

    required init?(coder: NSCoder) { fatalError() }
}
