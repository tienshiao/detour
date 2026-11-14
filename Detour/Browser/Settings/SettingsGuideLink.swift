import AppKit

/// A Learn more link from Settings to a feature's guide page on the website
/// (TASK-292.11). It opens the page the way the Help menu does: a new
/// selected tab in the frontmost normal browser window's active space, or a
/// new window when there is none (`AppDelegate.openHelpPage`), never the
/// user's default browser.
///
/// A borderless button in the link colour rather than a `.link` attribute in
/// a text field: a text field's link opens through NSWorkspace.
final class SettingsGuideLink: NSButton {
    let page: GuidePage

    /// Opens a guide page's URL. Tests replace it to record the URL instead
    /// of loading the website in the test host.
    static var open: (URL) -> Void = { url in
        (NSApp.delegate as? AppDelegate)?.openHelpPage(url)
    }

    /// - Parameters:
    ///   - title: the link's text; "Learn more about <page name>" by default.
    ///     A link beside a section title can say just "Learn more": the
    ///     title names the feature. Its accessibility label always names the page.
    ///   - fontSize: the size of the text it follows (12 for a pane's
    ///     description, 11 for help text).
    init(_ page: GuidePage, title: String? = nil, fontSize: CGFloat = 11) {
        self.page = page
        super.init(frame: .zero)
        let text = title ?? "Learn more about \(page.name)"
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.linkColor,
        ])
        // A momentary-change button draws its alternate title while pressed;
        // left empty, the link's text would vanish for the length of a click.
        attributedAlternateTitle = attributedTitle
        target = self
        action = #selector(openPage)
        toolTip = page.url.absoluteString
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        // Never takes spare height: in a list pane held taller than its
        // content (Links at its 400 pt minimum) a button with the default
        // hugging competed with the list for the room and stretched,
        // pushing the list down with the link centred in a gap.
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityRole(.link)
        setAccessibilityLabel("Learn more about \(page.name)")
        setAccessibilityIdentifier("learnMore.\(page.rawValue)")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A borderless button draws its title 2 pt further in than a label
    /// draws its text (measured on screen). Leaving those 2 pt out of the
    /// alignment rect lines the link's text up with the description or help
    /// text above it when both are pinned to the same edge.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func openPage() {
        Self.open(page.url)
    }
}
