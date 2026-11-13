import AppKit

/// The one-time launch offer to import from Arc (TASK-293.5), as a sheet on
/// the first browser window. For many people it is one of the first things
/// Detour shows, so it shows their own Arc setup: their spaces as chips in
/// Arc's colours, and what would come over. Import Everything imports every
/// Arc profile with everything selected, right here, and the sheet turns into
/// the result; Choose… hands over to the Import from Arc window.
/// The words and the chip packing are pure (`ArcImportText`,
/// `ArcImportOfferChipLayout`); this is view code.
final class ArcImportOfferSheetController: NSWindowController {
    private enum Metrics {
        static let width: CGFloat = 460
        static let inset: CGFloat = 28
        static let contentWidth = width - 2 * inset
        static let cardPadding: CGFloat = 14
        static let chipSpacing: CGFloat = 6
        static let chipRows = 2
        static let iconSize: CGFloat = 64
    }

    /// The sheet on screen, kept alive while it is up.
    private static var presented: ArcImportOfferSheetController?

    private let snapshot: ArcImportSnapshot
    private let store: TabStore
    private weak var browserWindowController: BrowserWindowController?
    private var isImportingHistory = false

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: ArcImportText.offerImportButton, target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    /// Shows the offer as a sheet on `windowController`'s window. False when
    /// that window is gone or an offer is already up, so nothing was shown.
    @discardableResult
    static func present(_ snapshot: ArcImportSnapshot, over windowController: BrowserWindowController,
                        store: TabStore = .shared) -> Bool {
        guard presented == nil, let parent = windowController.window, parent.isVisible,
              !windowController.hasClosed else { return false }
        let controller = ArcImportOfferSheetController(snapshot: snapshot, store: store,
                                                       browserWindowController: windowController)
        guard let sheet = controller.window else { return false }
        presented = controller
        parent.beginSheet(sheet) { _ in presented = nil }
        return true
    }

    private init(snapshot: ArcImportSnapshot, store: TabStore, browserWindowController: BrowserWindowController) {
        self.snapshot = snapshot
        self.store = store
        self.browserWindowController = browserWindowController
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.title = ArcImportText.windowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        show(makeOfferView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - The offer

    private func makeOfferView() -> NSView {
        let content = column(spacing: 0)
        content.addArrangedSubview(iconsRow())
        content.setCustomSpacing(18, after: content.arrangedSubviews.last!)

        let title = label(ArcImportText.offerTitle, font: .systemFont(ofSize: 20, weight: .semibold))
        content.addArrangedSubview(title)
        content.setCustomSpacing(6, after: title)
        let body = label(ArcImportText.offerBody, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        content.addArrangedSubview(body)
        content.setCustomSpacing(18, after: body)

        let cardContent = column(spacing: 10)
        cardContent.addArrangedSubview(chipRows())
        cardContent.addArrangedSubview(label(ArcImportText.offerTotals(snapshot),
                                             font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                             width: Metrics.contentWidth - 2 * Metrics.cardPadding))
        let chipCard = makeCard(around: cardContent)
        content.addArrangedSubview(chipCard)
        content.setCustomSpacing(14, after: chipCard)

        let finePrint = label(ArcImportText.offerFinePrint(now: Date()), font: .systemFont(ofSize: 11),
                              color: .tertiaryLabelColor)
        content.addArrangedSubview(finePrint)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .systemRed
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = Metrics.contentWidth
        statusLabel.isHidden = true
        // Hidden (and so detached) until an import fails.
        content.setCustomSpacing(22, after: finePrint)
        content.addArrangedSubview(statusLabel)
        content.setCustomSpacing(22, after: statusLabel)

        let declineButton = button(ArcImportText.offerDeclineButton, action: #selector(decline(_:)))
        declineButton.keyEquivalent = "\u{1b}"
        let chooseButton = button(ArcImportText.offerChooseButton, action: #selector(choose(_:)))
        importButton.target = self
        importButton.action = #selector(importEverything(_:))
        importButton.keyEquivalent = "\r"
        importButton.controlSize = .large
        let buttons = NSStackView(views: [declineButton, NSView(), chooseButton, importButton])
        buttons.spacing = 8
        content.addArrangedSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true
        return padded(content)
    }

    /// Arc's icon, an arrow, Detour's icon; Detour's alone when Arc's app is gone.
    private func iconsRow() -> NSView {
        var views: [NSView] = []
        if let arcURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "company.thebrowser.Browser") {
            views.append(iconView(NSWorkspace.shared.icon(forFile: arcURL.path), name: "Arc"))
            let arrow = NSImageView()
            arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
            arrow.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
            arrow.contentTintColor = .tertiaryLabelColor
            views.append(arrow)
        }
        views.append(iconView(NSApp.applicationIconImage, name: "Detour"))
        let row = NSStackView(views: views)
        row.spacing = 14
        return row
    }

    private func iconView(_ image: NSImage?, name: String) -> NSView {
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(name)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            view.heightAnchor.constraint(equalToConstant: Metrics.iconSize),
        ])
        return view
    }

    /// The spaces as chips, centred, in at most two rows; the rest as "+N more".
    private func chipRows() -> NSView {
        let chips = snapshot.spaces.map { space in
            SpaceChipView(title: ArcImportText.offerChipTitle(space), tint: space.colorHex.flatMap(NSColor.init(hex:)))
        }
        let moreWidth = { (hidden: Int) -> Double in
            Double(SpaceChipView(title: ArcImportText.offerMoreChipTitle(hidden), tint: nil).fittingSize.width)
        }
        let layout = ArcImportOfferChipLayout.pack(
            widths: chips.map { Double($0.fittingSize.width) }, moreWidth: moreWidth,
            maxWidth: Double(Metrics.contentWidth - 2 * Metrics.cardPadding),
            spacing: Double(Metrics.chipSpacing), maxRows: Metrics.chipRows)
        let rows = column(spacing: Metrics.chipSpacing)
        for (index, indices) in layout.rows.enumerated() {
            var views: [NSView] = indices.map { chips[$0] }
            if index == layout.rows.count - 1, layout.hidden > 0 {
                views.append(SpaceChipView(title: ArcImportText.offerMoreChipTitle(layout.hidden), tint: nil))
            }
            let row = NSStackView(views: views)
            row.spacing = Metrics.chipSpacing
            rows.addArrangedSubview(row)
        }
        return rows
    }

    // MARK: - Actions

    @objc private func decline(_ sender: Any?) {
        end()
    }

    @objc private func choose(_ sender: Any?) {
        end()
        ArcImportWindowController.shared.present()
    }

    @objc private func importEverything(_ sender: Any?) {
        let plan = ArcImportPlanner.plan(snapshot, options: .everything(in: snapshot),
                                         existing: store.arcImportExistingState())
        let outcome: TabStore.SessionSaveOutcome
        do {
            outcome = try store.applyArcImport(plan)
        } catch {
            // Planned against the state of a moment ago, so only something
            // changing in between gets here; the window lets them try again.
            statusLabel.stringValue = ArcImportText.offerFailed
            statusLabel.isHidden = false
            importButton.isEnabled = false
            fitWindowToContent()
            return
        }
        revealImportedSpace(plan)
        show(makeResultView(plan, outcome: outcome))
    }

    /// The window behind the sheet moves to the first space the import made
    /// (else the first it added to), so the setup is there when the sheet goes.
    /// No tab is selected: one would wake a page behind the sheet (and maybe
    /// its sound) before the user chose anything to open.
    private func revealImportedSpace(_ plan: ArcImportPlan) {
        guard let windowController = browserWindowController, !windowController.hasClosed,
              !windowController.isIncognito,
              let spaceID = plan.spaces.first?.id ?? plan.reusedSpaceIDs.first else { return }
        windowController.setActiveSpace(id: spaceID, selectTab: false)
    }

    @objc private func done(_ sender: Any?) {
        guard !isImportingHistory else { return }
        end()
    }

    private func end() {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    // MARK: - The result

    private func makeResultView(_ plan: ArcImportPlan, outcome: TabStore.SessionSaveOutcome) -> NSView {
        let content = column(spacing: 0)
        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        check.contentTintColor = .systemGreen
        content.addArrangedSubview(check)
        content.setCustomSpacing(14, after: check)
        let title = label(ArcImportText.offerDoneTitle, font: .systemFont(ofSize: 20, weight: .semibold))
        content.addArrangedSubview(title)
        content.setCustomSpacing(18, after: title)

        var saveFailure: String?
        if case .failed(let reason) = outcome { saveFailure = reason }
        let names = Dictionary(snapshot.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let lineWidth = Metrics.contentWidth - 2 * Metrics.cardPadding
        let lines = column(spacing: 6, alignment: .leading)
        for line in ArcImportText.summary(of: plan) {
            lines.addArrangedSubview(bullet(line, width: lineWidth))
        }
        let history = column(spacing: 6, alignment: .leading)
        lines.addArrangedSubview(history)
        let resultCard = makeCard(around: lines)
        content.addArrangedSubview(resultCard)
        content.setCustomSpacing(22, after: resultCard)

        // What was left out, apart and quieter than what came over.
        let notes = ArcImportText.resultNotes(of: plan, saveFailure: saveFailure, skipped: snapshot.skipped,
                                              names: names)
        if !notes.isEmpty {
            content.setCustomSpacing(12, after: resultCard)
            let notesLabel = label(notes.joined(separator: "\n"), font: .systemFont(ofSize: 11),
                                   color: .secondaryLabelColor)
            content.addArrangedSubview(notesLabel)
            content.setCustomSpacing(22, after: notesLabel)
        }

        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.controlSize = .large
        let buttons = NSStackView(views: [NSView(), doneButton])
        content.addArrangedSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Metrics.contentWidth).isActive = true

        if !plan.history.isEmpty {
            importHistory(plan.history, names: names, into: history, lineWidth: lineWidth)
        }
        return padded(content)
    }

    /// Writes the history in the background; Done waits for it, as the
    /// window does, so its result is not lost.
    private func importHistory(_ imports: [ArcImportPlan.HistoryImport], names: [ArcProfile.ID: String],
                               into stack: NSStackView, lineWidth: CGFloat) {
        isImportingHistory = true
        doneButton.isEnabled = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let progress = NSStackView(views: [spinner, label("Importing history…", font: .systemFont(ofSize: 13),
                                                          color: .secondaryLabelColor, alignment: .left)])
        progress.spacing = 6
        stack.addArrangedSubview(progress)
        Task {
            let results = await store.importArcHistory(imports)
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for line in ArcImportText.historyLines(results, names: names) {
                stack.addArrangedSubview(bullet(line, width: lineWidth))
            }
            isImportingHistory = false
            doneButton.isEnabled = true
            fitWindowToContent()
        }
    }

    // MARK: - Building blocks

    private func show(_ view: NSView) {
        window?.contentView = view
        fitWindowToContent()
    }

    private func fitWindowToContent() {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Metrics.width, height: view.fittingSize.height))
    }

    private func padded(_ content: NSStackView) -> NSView {
        content.edgeInsets = NSEdgeInsets(top: 28, left: Metrics.inset, bottom: 20, right: Metrics.inset)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        return content
    }

    private func column(spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerX) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor,
                       alignment: NSTextAlignment = .center, width: CGFloat = Metrics.contentWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.preferredMaxLayoutWidth = width
        return label
    }

    private func bullet(_ text: String, width: CGFloat) -> NSView {
        let dot = label("•", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .left)
        let line = label(text, font: .systemFont(ofSize: 13), alignment: .left, width: width - 14)
        let row = NSStackView(views: [dot, line])
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .large
        return button
    }

    /// A rounded, softly filled panel the width of the content.
    private func makeCard(around content: NSStackView) -> NSView {
        let card = FilledView()
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Metrics.contentWidth),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.cardPadding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Metrics.cardPadding),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardPadding),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.cardPadding),
        ])
        return card
    }
}

/// The card behind the chips and the result: a fill that follows the
/// appearance, since a layer's colours do not.
private final class FilledView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(effectiveAppearance.isDark ? 0.07 : 0.045).cgColor
        }
    }
}

/// One Arc space as a capsule in the space's colour.
private final class SpaceChipView: NSView {
    private let tint: NSColor?

    init(title: String, tint: NSColor?) {
        self.tint = tint
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(lessThanOrEqualToConstant: 170),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.isDark
            // Arc's colours are its shaded tones: lifted in Dark Mode so the
            // tint still reads on a dark sheet.
            let base = tint.map { dark ? ($0.blended(withFraction: 0.35, of: .white) ?? $0) : $0 }
                ?? .secondaryLabelColor
            layer?.backgroundColor = base.withAlphaComponent(dark ? 0.26 : 0.14).cgColor
            layer?.borderColor = base.withAlphaComponent(dark ? 0.45 : 0.3).cgColor
        }
    }
}
