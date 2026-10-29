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
        return bounds.insetBy(dx: UIConstants.sidebarRowHighlightInset, dy: 1)
    }

    /// The table keeps every row view's `isSelected` in step with its
    /// selection, without reloading rows, so the row's cell follows it here
    /// (the dev-mode border shows only on the selected row, TASK-197).
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as TabCellView in subviews { cell.isRowSelected = isSelected }
        }
    }
}

/// Told when a tab row's hover changes: the sidebar's hover card (TASK-190)
/// follows `TabCellView`'s own hover state, including which split half and
/// whether the pointer is over the Peek badge (TASK-229).
protocol TabCellHoverDelegate: AnyObject {
    func tabCell(_ cell: TabCellView, hoverChanged hovering: Bool, splitSide: Int?, overPeekBadge: Bool)
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
    /// The Peek badge at the row's trailing end: a single tab's, or a split
    /// row's right pane's.
    private let peekFaviconImageView = NSImageView()
    /// A split row's left pane's Peek badge, before the divider (TASK-229).
    /// Exposed (internal) for `TabCellPeekBadgeHoverTests`.
    let leftPanePeekFaviconImageView = NSImageView()
    // Right-pane segment of a collapsed split row: favicon + title after a
    // divider centered in the cell, so both panes get equal width.
    // Each half has its own close button: `splitCloseButton` (left pane, before
    // the divider) fires `onCloseLeft`; the shared trailing `closeButton` fires
    // `onClose`, which a split row wires to the right pane.
    // Exposed (internal) so sidebar-collapse tests can observe cleared/hidden
    // state headlessly — mirrors titleLabel/faviconImageView being non-private.
    let splitFaviconImageView = NSImageView()
    let splitTitleLabel = NSTextField(labelWithString: "")
    private let splitCloseButton: HoverButton
    let splitDivider = NSView()
    /// Dev mode's second line under the title: the page's host (and port when
    /// not the default). Exposed (internal) for `DevModeTests`.
    let hostLineLabel = NSTextField(labelWithString: "")
    /// Dev mode's hazard borders, made on first use: the whole row, or a split
    /// row's left half; and a split row's right half.
    private var devModeBorder: HazardBorderView?
    private var devModeSplitBorder: HazardBorderView?
    private var devModeMarking: DevModeRowMarking = .none
    /// Whether the row is the window's selected row: only that row shows the
    /// dev-mode border (TASK-197). Set by the enclosing `TabRowView`, whose
    /// `isSelected` the table keeps in step with its selection.
    var isRowSelected = false {
        didSet {
            guard isRowSelected != oldValue else { return }
            applyDevModeBorders()
        }
    }
    private var trackingArea: NSTrackingArea?
    private var titleLeadingConstraint: NSLayoutConstraint!
    private var titleCenterYConstraint: NSLayoutConstraint!
    private var faviconLeadingConstraint: NSLayoutConstraint!
    private var closeButtonWidthConstraint: NSLayoutConstraint!
    private var closeButtonTrailingConstraint: NSLayoutConstraint!
    private var peekFaviconWidthConstraint: NSLayoutConstraint!
    private var leftPanePeekWidthConstraint: NSLayoutConstraint!
    private var splitCloseButtonTrailingConstraint: NSLayoutConstraint!
    private var splitFaviconWidthConstraint: NSLayoutConstraint!
    private var splitCloseButtonWidthConstraint: NSLayoutConstraint!
    // The left title ends at the close button for a single tab, at the left
    // pane's own close button for a split row — exactly one is active at a time.
    private var titleSingleTrailingConstraint: NSLayoutConstraint!
    private var titleSplitTrailingConstraint: NSLayoutConstraint!
    private let hoverBackground = NSView()
    var onClose: (() -> Void)?
    var onCloseLeft: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onRename: ((String) -> Void)?
    weak var hoverDelegate: TabCellHoverDelegate?
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
    private var hasLeftPanePeek = false
    private var hasSplit = false
    /// Which half of a split row the mouse is over (0 = left, 1 = right).
    /// Hover chrome (highlight + close button) applies to that half only.
    private var hoveredSplitSide: Int?
    /// Whether the mouse is over the Peek badge: the hover card is then the
    /// Peek's, not the row's (TASK-229).
    private var hoveredPeekBadge = false

    // Option A: Ring spinner layer
    private var ringLayer: CAShapeLayer?

    // Option B: Progress bar (frame set manually in layout())
    private let progressView = NSView()
    private var currentProgress: Double = 0

    override init(frame frameRect: NSRect) {
        closeButton = HoverButton()
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))!
        closeButton.fixedHoverSize = 20
        splitCloseButton = HoverButton()
        splitCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Left Pane")!.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))!
        splitCloseButton.fixedHoverSize = 20
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

        hostLineLabel.font = .systemFont(ofSize: Self.hostLineFontSize)
        hostLineLabel.textColor = .secondaryLabelColor
        hostLineLabel.lineBreakMode = .byTruncatingTail
        hostLineLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLineLabel.isHidden = true

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        splitCloseButton.bezelStyle = .inline
        splitCloseButton.isBordered = false
        splitCloseButton.imagePosition = .imageOnly
        splitCloseButton.isHidden = true
        splitCloseButton.target = self
        splitCloseButton.action = #selector(closeLeftTapped)
        splitCloseButton.translatesAutoresizingMaskIntoConstraints = false

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

        for imageView in [peekFaviconImageView, leftPanePeekFaviconImageView, splitFaviconImageView] {
            imageView.wantsLayer = true
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.isHidden = true
        }

        splitTitleLabel.wantsLayer = true
        splitTitleLabel.lineBreakMode = .byTruncatingTail
        splitTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        splitTitleLabel.isHidden = true

        splitDivider.wantsLayer = true
        splitDivider.translatesAutoresizingMaskIntoConstraints = false
        splitDivider.isHidden = true
        updateSplitDividerColor()

        addSubview(faviconImageView)
        addSubview(sleepBadge)
        addSubview(speakerButton)
        addSubview(titleLabel)
        addSubview(hostLineLabel)
        addSubview(closeButton)
        addSubview(splitCloseButton)
        addSubview(splitDivider)
        addSubview(splitFaviconImageView)
        addSubview(splitTitleLabel)
        addSubview(peekFaviconImageView)
        addSubview(leftPanePeekFaviconImageView)

        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)
        faviconLeadingConstraint = faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        closeButtonWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 0)
        // Trailing chain: title (or split right segment) → closeButton → peekFavicon → trailing
        closeButtonTrailingConstraint = closeButton.trailingAnchor.constraint(equalTo: peekFaviconImageView.leadingAnchor, constant: 0)
        splitFaviconWidthConstraint = splitFaviconImageView.widthAnchor.constraint(equalToConstant: 0)
        splitCloseButtonWidthConstraint = splitCloseButton.widthAnchor.constraint(equalToConstant: 0)
        peekFaviconWidthConstraint = peekFaviconImageView.widthAnchor.constraint(equalToConstant: 0)
        // Left pane of a split: title → splitCloseButton → its Peek badge → divider.
        leftPanePeekWidthConstraint = leftPanePeekFaviconImageView.widthAnchor.constraint(equalToConstant: 0)
        splitCloseButtonTrailingConstraint = splitCloseButton.trailingAnchor.constraint(
            equalTo: leftPanePeekFaviconImageView.leadingAnchor, constant: 0)
        titleSingleTrailingConstraint = titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4)
        titleSplitTrailingConstraint = titleLabel.trailingAnchor.constraint(equalTo: splitCloseButton.leadingAnchor, constant: -4)
        titleCenterYConstraint = titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)

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
            titleCenterYConstraint,
            titleSingleTrailingConstraint,

            // Dev mode's host line hangs under the title and follows its
            // leading edge (which the speaker button moves) and trailing edge.
            hostLineLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hostLineLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hostLineLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Self.hostLineSpacing),

            closeButtonTrailingConstraint,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButtonWidthConstraint,
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            // Split segments around the centered divider: each pane gets an
            // equal half, with its own close button at the half's trailing end.
            // The 14pt divider-side insets mirror the row's outer insets — the
            // half-highlight stops 4pt short of the divider, leaving content
            // ~10pt from the highlight edge on every side.
            splitCloseButtonTrailingConstraint,
            leftPanePeekFaviconImageView.trailingAnchor.constraint(equalTo: splitDivider.leadingAnchor,
                                                                   constant: -Self.splitDividerGap),
            leftPanePeekFaviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftPanePeekWidthConstraint,
            leftPanePeekFaviconImageView.heightAnchor.constraint(equalToConstant: Self.peekBadgeSize),
            splitCloseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitCloseButtonWidthConstraint,
            splitCloseButton.heightAnchor.constraint(equalToConstant: 16),

            splitDivider.centerXAnchor.constraint(equalTo: centerXAnchor),
            splitDivider.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitDivider.widthAnchor.constraint(equalToConstant: 1),
            splitDivider.heightAnchor.constraint(equalToConstant: 14),

            splitFaviconImageView.leadingAnchor.constraint(equalTo: splitDivider.trailingAnchor, constant: Self.splitDividerGap),
            splitFaviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitFaviconWidthConstraint,
            splitFaviconImageView.heightAnchor.constraint(equalToConstant: 16),

            splitTitleLabel.leadingAnchor.constraint(equalTo: splitFaviconImageView.trailingAnchor, constant: 8),
            splitTitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitTitleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            peekFaviconImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.peekBadgeTrailingInset),
            peekFaviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            peekFaviconWidthConstraint,
            peekFaviconImageView.heightAnchor.constraint(equalToConstant: Self.peekBadgeSize),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A cell joining a row takes the row's selection (the table may select
    /// the row view before or after adding the cell); out of a row it is
    /// unselected.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        isRowSelected = (superview as? NSTableRowView)?.isSelected ?? false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // The row this cell stood for is gone: its hover ends with it.
        if isHovered { hoverDelegate?.tabCell(self, hoverChanged: false, splitSide: nil, overPeekBadge: false) }
        isHovered = false
        hoveredSplitSide = nil
        hoveredPeekBadge = false
        hasPeek = false
        hasSplit = false
        closeButton.isHidden = true
        peekFaviconImageView.isHidden = true
        peekFaviconImageView.image = nil
        hasLeftPanePeek = false
        leftPanePeekFaviconImageView.isHidden = true
        leftPanePeekFaviconImageView.image = nil
        splitFaviconImageView.isHidden = true
        splitFaviconImageView.image = nil
        splitTitleLabel.isHidden = true
        splitTitleLabel.stringValue = ""
        splitCloseButton.isHidden = true
        splitDivider.isHidden = true
        titleLabel.textColor = .labelColor
        hoverBackground.isHidden = true
        indentLevel = 0
        onRename = nil
        onCloseLeft = nil
        updateDevMode(.none)
        if isEditing { endEditing(commit: false) }
        resetSplitRevealState()
        updateLayoutState()
    }

    /// Full row for a single tab; the hovered half (up to the centered divider,
    /// with a small gap around it) for a split row.
    private var hoverBackgroundFrame: NSRect {
        rowHighlightRect(splitSide: hasSplit ? hoveredSplitSide : nil)
    }

    /// The rect the hover background and the dev-mode border share: the whole
    /// row, or one half of a split row (0 = left, 1 = right).
    private func rowHighlightRect(splitSide side: Int?) -> NSRect {
        let rowRect = bounds.insetBy(dx: -UIConstants.sidebarRowHighlightOutset, dy: 1)
        guard let side else { return rowRect }
        let mid = bounds.midX
        if side == 0 {
            return NSRect(x: rowRect.minX, y: rowRect.minY,
                          width: mid - 4 - rowRect.minX, height: rowRect.height)
        }
        return NSRect(x: mid + 4, y: rowRect.minY,
                      width: rowRect.maxX - (mid + 4), height: rowRect.height)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 12, bounds.height > 2 else { return }
        hoverBackground.frame = hoverBackgroundFrame
        layoutDevModeBorders()
        // Progress bar spans the full row area regardless of hover
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
            // .mouseMoved so a split row can move hover chrome between halves
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Which half of a split row `point` falls in (0 = left, 1 = right) —
    /// the one place the half boundary is defined.
    private func splitSide(at point: NSPoint) -> Int {
        point.x < bounds.midX ? 0 : 1
    }

    /// Single source of truth for hover chrome. A split row scopes the
    /// highlight and close button to the half under `point`; a single row
    /// keeps the full-row treatment.
    private func updateHover(to hovering: Bool, at point: NSPoint?) {
        let wasHovered = isHovered
        let oldSide = hoveredSplitSide
        let wasOverPeekBadge = hoveredPeekBadge
        defer {
            if isHovered != wasHovered || hoveredSplitSide != oldSide || hoveredPeekBadge != wasOverPeekBadge {
                hoverDelegate?.tabCell(self, hoverChanged: isHovered, splitSide: hoveredSplitSide,
                                       overPeekBadge: hoveredPeekBadge)
            }
        }
        isHovered = hovering
        if hovering, hasSplit, let point {
            hoveredSplitSide = splitSide(at: point)
        } else {
            hoveredSplitSide = nil
        }
        hoveredPeekBadge = hovering && point.map(isOverPeekBadge(at:)) == true
        closeButton.isHidden = !(hovering && (!hasSplit || hoveredSplitSide == 1))
        splitCloseButton.isHidden = !(hovering && hasSplit && hoveredSplitSide == 0)
        if hovering {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
            }
            hoverBackground.frame = hoverBackgroundFrame
        }
        hoverBackground.isHidden = !hovering
        updateLayoutState()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(to: true, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard isHovered else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hoverRegionChanged(at: point) else { return }
        updateHover(to: true, at: point)
    }

    /// Whether `point`, in a hovered row, is in a different split half or on
    /// the other side of the Peek badge's edge than the hover state says.
    /// A row that stopped being a split while hovered still has a half on
    /// record, which counts as a change too.
    private func hoverRegionChanged(at point: NSPoint) -> Bool {
        (hasSplit ? splitSide(at: point) : nil) != hoveredSplitSide || isOverPeekBadge(at: point) != hoveredPeekBadge
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(to: false, at: nil)
    }

    /// A row removed from the table (or a page going away) sends no exit.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, isHovered { updateHover(to: false, at: nil) }
    }

    /// Re-evaluate hover state using the current mouse position.
    /// Call this when scrolling moves cells under/away from the mouse,
    /// since NSTrackingArea doesn't reliably fire mouseExited in that case.
    func recheckHover() {
        guard let window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInSelf = convert(mouseInWindow, from: nil)
        let shouldHover = bounds.contains(mouseInSelf)
        guard shouldHover != isHovered || (shouldHover && hoverRegionChanged(at: mouseInSelf)) else { return }
        updateHover(to: shouldHover, at: shouldHover ? mouseInSelf : nil)
    }

    func updateAudio(isPlaying: Bool, isMuted: Bool) {
        // Update icon immediately — must happen even when audioPlaying doesn't change
        if isMuted {
            speakerButton.image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
        } else if isPlaying {
            speakerButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing Audio")
        }

        let newAudioPlaying = isPlaying || isMuted
        guard newAudioPlaying != audioPlaying else { return }
        audioPlaying = newAudioPlaying

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
        closeButtonWidthConstraint.constant = (isHovered && (!hasSplit || hoveredSplitSide == 1)) ? 16 : 0
        closeButtonTrailingConstraint.constant = hasPeek ? -Self.peekBadgeLeadingGap : 0
        splitFaviconWidthConstraint.constant = (hasSplit || isCollapsingSplitSegment) ? 16 : 0
        splitCloseButtonWidthConstraint.constant = (isHovered && hasSplit && hoveredSplitSide == 0) ? 16 : 0
        peekFaviconWidthConstraint.constant = hasPeek ? Self.peekBadgeSize : 0
        // The left pane's badge exists only while the row is a split.
        let showsLeftPanePeek = hasSplit && hasLeftPanePeek
        leftPanePeekWidthConstraint.constant = showsLeftPanePeek ? Self.peekBadgeSize : 0
        splitCloseButtonTrailingConstraint.constant = showsLeftPanePeek ? -Self.peekBadgeLeadingGap : 0
        leftPanePeekFaviconImageView.isHidden = !showsLeftPanePeek
        // Deactivate before activating so both trailing rules never coexist.
        if hasSplit {
            titleSingleTrailingConstraint.isActive = false
            titleSplitTrailingConstraint.isActive = true
        } else {
            titleSplitTrailingConstraint.isActive = false
            titleSingleTrailingConstraint.isActive = true
        }
    }

    @objc private func speakerTapped() {
        onToggleMute?()
    }

    func updateFavicon(_ image: NSImage?) {
        faviconImageView.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
    }

    private static let peekBadgeSize: CGFloat = 16
    private static let peekBadgeTrailingInset: CGFloat = 4
    /// The gap between the close button and the Peek badge.
    private static let peekBadgeLeadingGap: CGFloat = 4

    /// Where the pointer counts as over the Peek badge (TASK-229): the badge,
    /// the inset to the row's trailing edge and half the gap to the close
    /// button, the row's full height. From the layout's constants, not the
    /// badge's frame, which lags a badge that has just appeared.
    static func peekBadgeHoverRect(in bounds: NSRect) -> NSRect {
        let width = peekBadgeTrailingInset + peekBadgeSize + peekBadgeLeadingGap / 2
        return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    /// The gap between the divider and each pane's nearest element: the
    /// right pane's favicon, the left pane's Peek badge (or close button).
    private static let splitDividerGap: CGFloat = 14

    /// Where the pointer counts as over a split's left-pane Peek badge: the
    /// badge, half the gap to its close button, and the gap to the divider,
    /// stopping at the row's middle (the halves' boundary); full height.
    static func leftPanePeekBadgeHoverRect(in bounds: NSRect) -> NSRect {
        let width = peekBadgeLeadingGap / 2 + peekBadgeSize + splitDividerGap
        return NSRect(x: bounds.midX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    private func isOverPeekBadge(at point: NSPoint) -> Bool {
        (hasPeek && Self.peekBadgeHoverRect(in: bounds).contains(point))
            || (hasSplit && hasLeftPanePeek && Self.leftPanePeekBadgeHoverRect(in: bounds).contains(point))
    }

    /// A split row's left pane's Peek badge; nil for none. Shown only while
    /// the row is a split.
    func updateLeftPanePeekFavicon(_ image: NSImage?) {
        let hadPeek = hasLeftPanePeek
        hasLeftPanePeek = image != nil
        leftPanePeekFaviconImageView.image = image
        updateLayoutState()
        if hasLeftPanePeek != hadPeek, isHovered { recheckHover() }
    }

    func updatePeekFavicon(_ image: NSImage?) {
        let hadPeek = hasPeek
        hasPeek = image != nil
        peekFaviconImageView.image = image
        peekFaviconImageView.isHidden = !hasPeek
        updateLayoutState()
        // A badge appearing under the pointer, or going from under it, moves
        // the hover card between the row and the Peek.
        if hasPeek != hadPeek, isHovered { recheckHover() }
    }

    /// Configures the right-pane segment of a split row (favicon + title after
    /// the centered divider); the left segment is the regular favicon + title.
    /// `emphasized` marks the focused pane's title. Pass nil to clear split
    /// rendering when the cell is reused for a single/pinned tab.
    /// `animatedReveal` animates the single↔split transition in place (the row
    /// continues the drop target's / surviving member's row): revealing, the
    /// left title retracts to its half while the right segment slides in from
    /// the divider; collapsing, the right segment fades and slides back toward
    /// the divider while the left title expands to full width. It only takes
    /// effect on those transitions — reconfigures that stay split apply
    /// instantly. `departingFavicon`/`departingTitle` name the member that
    /// actually left the group: the right segment holds the old RIGHT pane's
    /// content, which is the survivor (not the departed member) when the left
    /// pane departed — the collapse swaps the ghost to the departed content.
    func updateSplitPane(favicon: NSImage?, title: String?, emphasized: Bool = false,
                         animatedReveal: Bool = false,
                         departingFavicon: NSImage? = nil, departingTitle: String? = nil) {
        // A clear arriving mid-collapse (progress ticks on the surviving tab,
        // the drop's selection-restore re-reconfigure) converges to the
        // collapse's own end state — let the animation finish, don't snap it.
        if isCollapsingSplitSegment, favicon == nil, title == nil { return }
        let wasSplit = hasSplit
        hasSplit = favicon != nil || title != nil
        // The left pane's Peek badge belongs to the split: a row that stops
        // being one drops it, so a later split never inherits a stale badge.
        if !hasSplit {
            hasLeftPanePeek = false
            leftPanePeekFaviconImageView.image = nil
        }
        let canAnimate = animatedReveal && window != nil && bounds.width > 0
        let animateCollapse = canAnimate && wasSplit && !hasSplit
        // A collapse must keep the outgoing favicon/title visible while it
        // fades, so leave the segment content and visibility untouched here and
        // let the completion handler clear it.
        if !animateCollapse {
            splitFaviconImageView.image = favicon
            splitTitleLabel.stringValue = title ?? ""
            splitTitleLabel.textColor = emphasized ? .labelColor : .secondaryLabelColor
            splitFaviconImageView.isHidden = !hasSplit
            splitTitleLabel.isHidden = !hasSplit
            splitDivider.isHidden = !hasSplit
        }
        if canAnimate, hasSplit, !wasSplit {
            revealSplitSegment()
        } else if animateCollapse {
            if departingFavicon != nil || departingTitle != nil {
                splitFaviconImageView.image = departingFavicon
                splitTitleLabel.stringValue = departingTitle ?? ""
                splitTitleLabel.textColor = .secondaryLabelColor
            }
            collapseSplitSegment()
        } else {
            resetSplitRevealState()
        }
        // hasSplit changes what hover means (per-half vs full-row) — re-derive
        // from the actual mouse position rather than patching flags here.
        recheckHover()
        updateLayoutState()
    }

    /// True only for the duration of a collapse animation, so `updateLayoutState`
    /// keeps the right segment at full width while it fades instead of snapping
    /// it to zero.
    private var isCollapsingSplitSegment = false
    /// Ties each collapse completion to the collapse that scheduled it: a newer
    /// collapse re-arms `isCollapsingSplitSegment`, so the flag alone can't tell
    /// a stale completion from the live one.
    private var splitCollapseGeneration = 0

    /// Animates a single→split reconfigure: the right segment's views fade and
    /// slide in from beyond the divider while the left title's trailing edge
    /// animates from its pre-split position to the half-row layout.
    private func revealSplitSegment() {
        // Cancel any collapse still in flight — its pending completion would
        // otherwise fire mid-reveal and blank the freshly shown segment.
        resetSplitRevealState()

        let oldTitleMaxX = titleLabel.frame.maxX

        // Land the whole split layout without animation first, so the right
        // segment's views get real frames to animate from (a reused cell can
        // carry stale zero frames, which would fly in from the corner).
        // The left pane's Peek badge arrives with the split, so it fades in too.
        for view in [splitFaviconImageView, splitTitleLabel, splitDivider, leftPanePeekFaviconImageView] {
            view.alphaValue = 0
        }
        updateLayoutState()
        layoutSubtreeIfNeeded()

        // Hold the title at its pre-split width via a temporary trailing
        // overshoot, then animate the constant back to its resting value.
        let overshoot = oldTitleMaxX - titleLabel.frame.maxX
        if overshoot > 0 {
            titleSplitTrailingConstraint.constant = Self.splitTitleTrailingGap + overshoot
            layoutSubtreeIfNeeded()
        }

        addSplitSegmentSlide(from: 24, to: 0)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.splitRevealDuration
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleSplitTrailingConstraint.animator().constant = Self.splitTitleTrailingGap
            splitFaviconImageView.animator().alphaValue = 1
            splitTitleLabel.animator().alphaValue = 1
            splitDivider.animator().alphaValue = 1
            leftPanePeekFaviconImageView.animator().alphaValue = 1
        }
    }

    /// The horizontal slide both reveal and collapse run on the right
    /// segment's layers — one builder so the two directions can't drift.
    private func addSplitSegmentSlide(from: CGFloat, to: CGFloat) {
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = from
        slide.toValue = to
        slide.duration = Self.splitRevealDuration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        splitFaviconImageView.layer?.add(slide, forKey: Self.splitRevealAnimationKey)
        splitTitleLabel.layer?.add(slide, forKey: Self.splitRevealAnimationKey)
    }

    /// Time-mirror of `revealSplitSegment` for a split→single reconfigure: the
    /// right segment's views fade and slide back toward the divider while the
    /// left title's trailing edge animates from its half-row position out to
    /// full width. The row continues the surviving member.
    private func collapseSplitSegment() {
        // Cancel any reveal still in flight so the two animations don't fight.
        resetSplitRevealState()
        isCollapsingSplitSegment = true
        splitCollapseGeneration += 1
        let generation = splitCollapseGeneration

        let oldTitleMaxX = titleLabel.frame.maxX

        // Land the single layout first (activating titleSingleTrailingConstraint)
        // so the title's full-width frame is known, then measure how far it grew.
        updateLayoutState()
        layoutSubtreeIfNeeded()
        let expansion = titleLabel.frame.maxX - oldTitleMaxX
        if expansion > 0 {
            // Hold the title at its pre-collapse (split) width, then animate the
            // constant out to its resting value.
            titleSingleTrailingConstraint.constant = Self.splitTitleTrailingGap - expansion
            layoutSubtreeIfNeeded()
        }

        addSplitSegmentSlide(from: 0, to: -24)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.splitRevealDuration
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleSingleTrailingConstraint.animator().constant = Self.splitTitleTrailingGap
            splitFaviconImageView.animator().alphaValue = 0
            splitTitleLabel.animator().alphaValue = 0
            splitDivider.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The generation check kills completions from superseded collapses
            // (a newer collapse re-armed the flag, so the flag alone lies).
            guard let self, self.isCollapsingSplitSegment,
                  generation == self.splitCollapseGeneration else { return }
            self.splitFaviconImageView.image = nil
            self.splitTitleLabel.stringValue = ""
            self.splitFaviconImageView.isHidden = true
            self.splitTitleLabel.isHidden = true
            self.splitDivider.isHidden = true
            self.resetSplitRevealState()
            self.updateLayoutState()
        })
    }

    /// Restores the resting state a reveal/collapse animates through, so a cell
    /// reused (or reconfigured) mid-animation doesn't keep ghost alphas or a
    /// stale trailing overshoot. Clearing `isCollapsingSplitSegment` also makes
    /// any pending collapse completion a no-op via its flag guard.
    private func resetSplitRevealState() {
        for view in [splitFaviconImageView, splitTitleLabel, splitDivider, leftPanePeekFaviconImageView] {
            view.layer?.removeAnimation(forKey: Self.splitRevealAnimationKey)
            view.alphaValue = 1
        }
        titleSplitTrailingConstraint.constant = Self.splitTitleTrailingGap
        titleSingleTrailingConstraint.constant = Self.splitTitleTrailingGap
        isCollapsingSplitSegment = false
    }

    private static let splitRevealDuration: TimeInterval = 0.2
    private static let splitRevealAnimationKey = "splitReveal"
    /// Resting constant of `titleSplitTrailingConstraint` (mirrors the single
    /// layout's -4 title-to-close-button gap).
    private static let splitTitleTrailingGap: CGFloat = -4

    /// CGColor doesn't track appearance changes — re-resolve on theme switches.
    private func updateSplitDividerColor() {
        splitDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateSplitDividerColor()
        }
    }

    // MARK: - Dev mode (TASK-186.1)

    private static let hostLineFontSize: CGFloat = 10
    /// Labels carry internal leading, so the two lines sit tight with a small
    /// negative gap.
    private static let hostLineSpacing: CGFloat = -2

    /// Marks the row as a dev-mode page: the host under the title for a single
    /// tab and, while the row is selected (`isRowSelected`), a hazard border
    /// around the row; for a split row, a border around each local pane's
    /// half while selected, never a host line. `.none` clears it. The two
    /// lines fit the row's existing height — the title moves up by half the
    /// host line's height — so the list's row layout is unchanged.
    func updateDevMode(_ marking: DevModeRowMarking) {
        guard marking != devModeMarking else { return }
        devModeMarking = marking
        // Selection never changes the host line (`DevModeRowDisplay`), so
        // it is set here only, and a selection change touches the borders alone.
        if let hostLabel = marking.display(isSelected: isRowSelected).hostLabel {
            hostLineLabel.stringValue = hostLabel
            hostLineLabel.isHidden = false
            titleCenterYConstraint.constant = -ceil(hostLineLabel.intrinsicContentSize.height + Self.hostLineSpacing) / 2
        } else {
            hostLineLabel.stringValue = ""
            hostLineLabel.isHidden = true
            titleCenterYConstraint.constant = 0
        }
        applyDevModeBorders()
    }

    /// Shows the borders the marking and selection call for, making each on
    /// first use; hiding is just `isHidden`, so a selection change is cheap.
    private func applyDevModeBorders() {
        let display = devModeMarking.display(isSelected: isRowSelected)
        let showsMain = display.showsMainBorder
        let showsRight = display.showsRightBorder
        if showsMain, devModeBorder == nil { devModeBorder = makeDevModeBorder() }
        if showsRight, devModeSplitBorder == nil { devModeSplitBorder = makeDevModeBorder() }
        devModeBorder?.isHidden = !showsMain
        devModeSplitBorder?.isHidden = !showsRight
        layoutDevModeBorders()
    }

    private func makeDevModeBorder() -> HazardBorderView {
        let border = HazardBorderView()
        border.isHidden = true
        // Over the progress bar and hover background, under the row's content.
        addSubview(border, positioned: .above, relativeTo: progressView)
        return border
    }

    private func layoutDevModeBorders() {
        switch devModeMarking {
        case .none:
            break
        case .tab:
            devModeBorder?.frame = rowHighlightRect(splitSide: nil)
        case .split:
            devModeBorder?.frame = rowHighlightRect(splitSide: 0)
            devModeSplitBorder?.frame = rowHighlightRect(splitSide: 1)
        }
    }

    /// Frames of the hazard borders showing, for `DevModeTests`.
    var devModeBorderFrames: [NSRect] {
        [devModeBorder, devModeSplitBorder].compactMap { border in
            guard let border, !border.isHidden else { return nil }
            return border.frame
        }
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
            // Normal tab: use xmark. Also reset the left-pane button (a reused
            // cell may have shown a pinned split's minus glyph).
            let boldConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(boldConfig)
            splitCloseButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Left Pane")?.withSymbolConfiguration(boldConfig)
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

    /// Per-half close glyphs for a pinned split row: minus = live (close makes
    /// the entry dormant), xmark = dormant (close deletes the entry).
    func updateSplitPinnedMode(left: PinnedEntry, right: PinnedEntry) {
        let boldConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        splitCloseButton.image = NSImage(
            systemSymbolName: left.isLive ? "minus" : "xmark",
            accessibilityDescription: left.isLive ? "Close Left Pane" : "Remove Pin"
        )?.withSymbolConfiguration(boldConfig)
        closeButton.image = NSImage(
            systemSymbolName: right.isLive ? "minus" : "xmark",
            accessibilityDescription: right.isLive ? "Close Right Pane" : "Remove Pin"
        )?.withSymbolConfiguration(boldConfig)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func closeLeftTapped() {
        onCloseLeft?()
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        }
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

    /// Escape cancels, Return and Tab commit; either way the keyboard goes
    /// back to the page — the list does not take it (TASK-174). Left alone,
    /// Return keeps it on the label and Tab leaves it with nothing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Before the commit, which can reload this row out of the list.
        let list = enclosingScrollView?.documentView as? DraggableTableView
        switch commandSelector {
        case #selector(cancelOperation(_:)): endEditing(commit: false)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)), #selector(insertBacktab(_:)): endEditing(commit: true)
        default: return false
        }
        list?.releaseKeyboardFocus()
        return true
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
        let isDark = effectiveAppearance.isDark
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        }
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
            effectiveAppearance.performAsCurrentDrawingAppearance {
                hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
            }
            hoverBackground.isHidden = false
        } else {
            hoverBackground.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
