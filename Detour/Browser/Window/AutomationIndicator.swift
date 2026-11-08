import AppKit

// TASK-132.13 AC #5: the user can see that a tab is being driven by an
// extension, and can stop it.
//
// Two places show it, both driven by `BrowserTab.automationOwners`:
//   - the tab's sidebar row: a small indicator beside the favicon, with a
//     tooltip naming the extension (`TabCellView.updateAutomation(tooltip:)`);
//   - the pane showing the tab: a floating capsule at the top centre of the
//     page, with a Stop button (`AutomationBannerView`, hosted by the tab's
//     `WebViewContainerView` and kept current by the window,
//     `BrowserWindowController+AutomationBanner.swift`).
//
// The capsule is an overlay: it is a sibling laid over the web view, never
// changes the web view's frame (a parked tab is laid out at the content area's
// size; showing it must not resize the page an extension is driving), never
// takes first responder, and only the capsule itself answers hit tests.

/// What the user is told about a tab an extension is driving.
struct TabAutomationPresentation: Equatable {
    /// The sidebar indicator's tooltip: `Controlled by “Claude”`, or
    /// `Controlled by 2 extensions`.
    let tooltip: String
    /// The in-window capsule's text: `“Claude” is controlling this tab`, or
    /// `2 extensions are controlling this tab`.
    let bannerTitle: String
    /// Whether the capsule offers Stop: some owner's attachment is one the
    /// user can end (`TabAutomationStop.isStoppable`).
    let canStop: Bool

    /// Nil when nobody is driving the tab. Owners are counted by extension:
    /// one extension holding several attachments (a debugger session and a
    /// command in flight) is still one extension.
    init?(owners: Set<TabAutomationOwner>,
          displayName: (String) -> String = { ExtensionManager.shared.displayName(for: $0) },
          isStoppable: (TabAutomationOwner) -> Bool = { TabAutomationStop.isStoppable($0) }) {
        guard !owners.isEmpty else { return nil }
        let extensionIDs = Set(owners.map(\.extensionID))
        if extensionIDs.count == 1, let id = extensionIDs.first {
            let name = displayName(id)
            tooltip = "Controlled by “\(name)”"
            bannerTitle = "“\(name)” is controlling this tab"
        } else {
            tooltip = "Controlled by \(extensionIDs.count) extensions"
            bannerTitle = "\(extensionIDs.count) extensions are controlling this tab"
        }
        canStop = owners.contains(where: isStoppable)
    }

    /// The presentation for a row standing for `tabs` — one tab, or both
    /// members of a split: driven when either is.
    static func forRow(_ tabs: [BrowserTab]) -> TabAutomationPresentation? {
        TabAutomationPresentation(owners: tabs.reduce(into: Set()) { $0.formUnion($1.automationOwners) })
    }
}

/// Where the capsule sits over a pane: centred on the web view (not the
/// container: a Web Inspector docked at the side takes part of it), just below
/// the web view's top edge (so below a dev toolbar), no wider than the web view
/// allows.
enum AutomationBannerLayout {
    static let topInset: CGFloat = 10
    static let sideInset: CGFloat = 12

    static func frame(fittingSize: NSSize, webViewFrame: NSRect, flipped: Bool) -> NSRect {
        let width = min(fittingSize.width, max(0, webViewFrame.width - 2 * sideInset))
        let height = fittingSize.height
        let y = flipped ? webViewFrame.minY + topInset : webViewFrame.maxY - topInset - height
        return NSRect(x: (webViewFrame.midX - width / 2).rounded(), y: y.rounded(),
                      width: width.rounded(.down), height: height.rounded(.up))
    }
}

/// The capsule over a driven tab's page: icon, `“Claude” is controlling this
/// tab`, and Stop when the user can end the attachment.
///
/// Conforms to `WindowDragPassThrough`: the window's drag strip covers the top
/// 38 pt of the content area, and the capsule sits under it.
final class AutomationBannerView: NSView, WindowDragPassThrough {
    private let glass = GlassContainerView(cornerRadius: .infinity)
    private let iconView = NSImageView()
    /// Exposed (internal) for tests.
    let titleLabel = NSTextField(labelWithString: "")
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var stopButtonTrailing: NSLayoutConstraint!
    private var titleTrailing: NSLayoutConstraint!

    /// What Stop does — set by the window that hosts the pane.
    var onStop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Framed by the container (`layoutAutomationBanner`), never by
        // constraints in it: Auto Layout in the container breaks the docked
        // Web Inspector.
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []

        iconView.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Truncates first when the pane is narrow.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stopButton.controlSize = .small
        stopButton.bezelStyle = .push
        stopButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        // A click on Stop must not take the keyboard from the page.
        stopButton.refusesFirstResponder = true
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setContentHuggingPriority(.required, for: .horizontal)
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stopButton.toolTip = "Stop the extension controlling this tab"

        let content = glass.contentView
        content.addSubview(iconView)
        content.addSubview(titleLabel)
        content.addSubview(stopButton)
        addSubview(glass)

        stopButtonTrailing = stopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                                  constant: -Self.buttonTrailingInset)
        titleTrailing = titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                             constant: -Self.titleTrailingInset)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.leadingInset),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconGap),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stopButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: Self.buttonGap),
            stopButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stopButtonTrailing,
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var showsStopButton: Bool { !stopButton.isHidden }

    /// The capsule's untruncated size, summed from its parts' intrinsic sizes
    /// (the same insets the constraints use). Not `fittingSize`: the glass
    /// view's content is not reliably constrained to its edges, and measured
    /// that way the label came out at zero width.
    var preferredSize: NSSize {
        var width = Self.leadingInset + iconView.intrinsicContentSize.width + Self.iconGap
            + ceil(titleLabel.intrinsicContentSize.width)
        if showsStopButton {
            width += Self.buttonGap + stopButton.intrinsicContentSize.width + Self.buttonTrailingInset
        } else {
            width += Self.titleTrailingInset
        }
        return NSSize(width: ceil(width), height: Self.height)
    }

    private static let height: CGFloat = 32
    private static let leadingInset: CGFloat = 12
    private static let iconGap: CGFloat = 6
    private static let buttonGap: CGFloat = 10
    private static let buttonTrailingInset: CGFloat = 6
    private static let titleTrailingInset: CGFloat = 14

    func apply(_ presentation: TabAutomationPresentation) {
        titleLabel.stringValue = presentation.bannerTitle
        setAccessibilityLabel(presentation.bannerTitle)
        stopButton.isHidden = !presentation.canStop
        // Deactivate before activating so both trailing rules never coexist.
        if presentation.canStop {
            titleTrailing.isActive = false
            stopButtonTrailing.isActive = true
        } else {
            stopButtonTrailing.isActive = false
            titleTrailing.isActive = true
        }
    }

    @objc private func stopTapped() {
        onStop?()
    }

    // The capsule is not part of the page: a press on it (outside Stop) must
    // not fall through to the window's drag strip or the responder chain,
    // and the pointer over it is an arrow, not the page's cursor.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// A scroll over the capsule scrolls the page under it, as it would if
    /// the capsule were not there.
    override func scrollWheel(with event: NSEvent) {
        if let webView = (superview as? WebViewContainerView)?.hostedWebView {
            webView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Hosting in the pane

extension WebViewContainerView {
    /// Whether the capsule is up over this pane.
    var isShowingAutomationBanner: Bool {
        guard let automationBanner else { return false }
        return !automationBanner.isHidden
    }

    /// Shows the capsule for `presentation` over the web view, or hides it
    /// (nil). The web view's frame is not touched.
    func updateAutomationBanner(_ presentation: TabAutomationPresentation?, onStop: @escaping () -> Void) {
        guard let presentation else { return hideAutomationBanner() }
        let banner = automationBanner ?? makeAutomationBanner()
        banner.apply(presentation)
        banner.onStop = onStop
        banner.isHidden = false
        layoutAutomationBanner()
    }

    func hideAutomationBanner() {
        automationBanner?.isHidden = true
        automationBanner?.onStop = nil
    }

    private func makeAutomationBanner() -> AutomationBannerView {
        let banner = AutomationBannerView()
        banner.isHidden = true
        automationBanner = banner
        addSubview(banner, positioned: .above, relativeTo: nil)
        return banner
    }

    /// Frames the capsule over the web view's current frame; run whenever the
    /// container resizes or WebKit re-frames the web view (an inspector
    /// docking, the dev toolbar showing).
    func layoutAutomationBanner() {
        guard let banner = automationBanner, !banner.isHidden, let webView = hostedWebView else { return }
        let frame = AutomationBannerLayout.frame(fittingSize: banner.preferredSize, webViewFrame: webView.frame,
                                                 flipped: isFlipped)
        if banner.frame != frame { banner.frame = frame }
    }

    /// Keeps the capsule above whatever is added after it (a re-wrapped web
    /// view, a docked inspector, the dev toolbar).
    func keepAutomationBannerOnTop(after added: NSView) {
        guard let banner = automationBanner, added !== banner, banner.superview === self,
              subviews.last !== banner else { return }
        addSubview(banner, positioned: .above, relativeTo: nil)
    }
}
