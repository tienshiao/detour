import AppKit

/// The base of every Settings pane (TASK-189): a fixed description at the top
/// and the pane's body in a scroll view below it.
///
/// The body is the scroll view's document, pinned to its width, so content can
/// never widen the window; its height is the body's fitting height, stretched
/// to fill the visible area when the window is taller than that (list panes
/// below their minimum). The window controller sizes the window from
/// `naturalContentHeight` and `minimumContentHeight` through `SettingsPaneHeight`.
///
/// Subclasses build their body in `makeBody()` with no outer margins (the
/// container adds them) and call `contentHeightDidChange()` whenever rows
/// appear, disappear or a list's length changes.
class SettingsPaneViewController: NSViewController {
    /// Called when the pane's natural height may have changed.
    var onContentHeightChange: (() -> Void)?

    /// The text shown above the scroll area, or nil for none.
    var paneDescription: String? { nil }

    /// The pane's smallest content height: `SettingsMetrics.listPaneMinimumHeight`
    /// for panes with a master list, nil to use the natural height (the pane
    /// cannot be shortened).
    var minimumContentHeight: CGFloat? { nil }

    /// Builds the pane's content. Called once from `loadView`.
    func makeBody() -> NSView { NSView() }

    /// The body's height when nothing in it is clipped. The default is the
    /// body's fitting height; list panes add the height that shows every row.
    func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat { fittingHeight }

    private(set) var scrollView: NSScrollView!
    private var body: NSView!
    private var descriptionLabel: NSTextField?
    private var bodyTopInset: CGFloat = 0
    /// The constraints that stretch the document to the visible height; off
    /// while the body is measured, so the window's current height never
    /// feeds back into the natural height.
    private var stretchConstraints: [NSLayoutConstraint] = []

    final override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.windowWidth, height: 300))
        let margin = SettingsMetrics.paneMargin

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        root.addSubview(scroll)
        scrollView = scroll

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let body = makeBody()
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        self.body = body

        // Required, so nothing in a pane can widen the window: content that
        // does not fit truncates or wraps instead (TASK-189 defects 1 and 2).
        var constraints: [NSLayoutConstraint] = [
            root.widthAnchor.constraint(equalToConstant: SettingsMetrics.windowWidth),
        ]
        let scrollTop: NSLayoutConstraint
        let bodyTopInset: CGFloat
        if let text = paneDescription {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            label.preferredMaxLayoutWidth = SettingsMetrics.windowWidth - 2 * margin
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            root.addSubview(label)
            descriptionLabel = label
            constraints += [
                label.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            ]
            scrollTop = scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: SettingsMetrics.descriptionToBody)
            bodyTopInset = 0
        } else {
            scrollTop = scroll.topAnchor.constraint(equalTo: root.topAnchor)
            bodyTopInset = margin
        }

        // The document fills the clip view's width (never wider), and is at
        // least as tall as the visible area so a list column can stretch.
        let fillHeight = document.heightAnchor.constraint(equalTo: clip.heightAnchor)
        fillHeight.priority = NSLayoutConstraint.Priority(49)  // below fitting-size compression
        stretchConstraints = [document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor), fillHeight]
        constraints += stretchConstraints
        constraints += [
            scrollTop,
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),

            body.topAnchor.constraint(equalTo: document.topAnchor, constant: bodyTopInset),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -margin),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -margin),
        ]
        NSLayoutConstraint.activate(constraints)
        self.bodyTopInset = bodyTopInset
        view = root
    }

    /// The content height at which nothing in the pane is clipped or stretched.
    var naturalContentHeight: CGFloat {
        _ = view
        let margin = SettingsMetrics.paneMargin
        var top: CGFloat = bodyTopInset
        if let label = descriptionLabel {
            top += margin + label.fittingSize.height + SettingsMetrics.descriptionToBody
        }
        // Measured at the width the body has in the window: the clip view's
        // width when laid out (narrower with legacy scrollers), else the window's.
        let clipWidth = scrollView.contentView.bounds.width
        let bodyWidth = (clipWidth > 0 ? clipWidth : SettingsMetrics.windowWidth) - 2 * margin
        let width = body.widthAnchor.constraint(equalToConstant: bodyWidth)
        NSLayoutConstraint.deactivate(stretchConstraints)
        width.isActive = true
        let fitting = body.fittingSize.height
        width.isActive = false
        NSLayoutConstraint.activate(stretchConstraints)
        return ceil(top + idealBodyHeight(fittingHeight: fitting) + margin)
    }

    /// Ties the bottom of a body's content to the body's bottom for the
    /// natural height, weakly. Pair it with a required `<=`: a required
    /// equality would cap the scroll area's height, and AppKit would then
    /// snap the window to it as soon as the pane is swapped in, with no animation.
    func bottomHug(_ content: NSLayoutYAxisAnchor, _ bodyBottom: NSLayoutYAxisAnchor) -> NSLayoutConstraint {
        let c = content.constraint(equalTo: bodyBottom)
        c.priority = .defaultLow
        return c
    }

    /// Called after the window has been sized to the pane (shown, switched
    /// to, or refitted). Subclasses can scroll a selection into view here.
    func paneDidFit() {}

    /// Subclasses call this when rows appear or disappear or a list's length changes.
    /// Several changes in one turn of the run loop (a selection that shows
    /// and hides rows) are coalesced into one refit after they settle.
    func contentHeightDidChange() {
        guard isViewLoaded, !heightChangePending else { return }
        heightChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightChangePending = false
            self.onContentHeightChange?()
        }
    }

    private var heightChangePending = false
}

extension NSTableView {
    /// The height of all the table's rows, top of the first to bottom of the
    /// last: what a list needs to show every row without scrolling.
    var allRowsHeight: CGFloat {
        numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
    }
}

/// The bordered box around a master list (Spaces, Profiles, Extensions). The
/// border is drawn in `updateLayer`, so it is resolved again whenever the
/// appearance changes (a `CGColor` set once keeps the appearance it was
/// created in and disappeared in dark mode, TASK-189 defect 9).
final class SettingsListContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.borderWidth = 1
        layer.cornerRadius = SettingsMetrics.listCornerRadius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
