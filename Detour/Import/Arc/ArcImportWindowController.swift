import AppKit
import UniformTypeIdentifiers

/// File › Import from Arc… (TASK-293.3): choose a source (Arc on this Mac, or
/// an `Arc Data Export.md`), pick the profiles, their target Detour profiles
/// and spaces, and what to bring; then the same window shows what was added
/// and how the history import went. The rules live in `ArcImportPlanner`
/// and `TabStore.applyArcImport`; this is view code.
final class ArcImportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ArcImportWindowController()

    private enum Source: Equatable {
        case installation
        /// An export file, nil until one is chosen.
        case exportFile(URL?)
    }

    private enum Metrics {
        static let width: CGFloat = 580
        static let listHeight: CGFloat = 250
        static let inset: CGFloat = 20
        static let spaceIndent: CGFloat = 22
    }

    private let store: TabStore
    private var source: Source = .installation
    private var snapshot: ArcImportSnapshot?
    /// Bumped on every load, so a slow read that finishes after the user
    /// switched source is dropped.
    private var loadGeneration = 0
    private var isImporting = false

    private var profileChecks: [ArcProfile.ID: NSButton] = [:]
    private var profilePopups: [ArcProfile.ID: NSPopUpButton] = [:]
    private var spaceChecks: [String: NSButton] = [:]

    // Form
    private let formView = NSStackView()
    private let installationRadio = NSButton(radioButtonWithTitle: "Arc on this Mac", target: nil, action: nil)
    private let exportRadio = NSButton(radioButtonWithTitle: "An Arc export file", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let exportHelp = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let listScroll = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let pinnedCheck = NSButton(checkboxWithTitle: "Pinned tabs and folders", target: nil, action: nil)
    private let favoritesCheck = NSButton(checkboxWithTitle: "Favorites", target: nil, action: nil)
    private let todayCheck = NSButton(checkboxWithTitle: "Unpinned tabs", target: nil, action: nil)
    private let historyCheck = NSButton(checkboxWithTitle: "History (last 90 days)", target: nil, action: nil)
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Result
    private let resultView = NSStackView()
    private let resultLines = NSStackView()
    private let historyLines = NSStackView()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var arcProfileNames: [ArcProfile.ID: String] = [:]

    init(store: TabStore = .shared) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = ArcImportText.windowTitle
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        buildResult()
        // One of the two is the window's content at a time, so neither one's
        // height constrains the other.
        for view in [formView, resultView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: Metrics.width).isActive = true
        }
        resultView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        window.contentView = formView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window on its form, reading Arc's data afresh.
    func present() {
        guard !isImporting else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        window?.contentView = formView
        let arcFound = ArcSidebarReader.isArcDataPresent()
        installationRadio.isEnabled = arcFound
        installationRadio.title = arcFound ? "Arc on this Mac" : "Arc on this Mac (not found)"
        if !arcFound, source == .installation { source = .exportFile(nil) }
        if source == .exportFile(nil) {
            snapshot = nil
            showList(message: arcFound
                     ? "Choose an Arc export file. In Arc: Settings › Advanced › Export Data."
                     : "Arc’s data wasn’t found on this Mac. Choose an Arc export file instead: in Arc, "
                       + "Settings › Advanced › Export Data.")
        } else {
            load()
        }
        syncSourceControls()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Building

    private func buildForm() {
        formView.orientation = .vertical
        formView.alignment = .leading
        formView.spacing = 12
        formView.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset,
                                           right: Metrics.inset)

        for radio in [installationRadio, exportRadio] {
            radio.target = self
            radio.action = #selector(sourceChanged(_:))
        }
        chooseButton.target = self
        chooseButton.action = #selector(chooseExportFile(_:))
        exportHelp.textColor = .secondaryLabelColor
        exportHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let exportRow = NSStackView(views: [exportRadio, chooseButton])
        exportRow.spacing = 8
        let sourceColumn = NSStackView(views: [installationRadio, exportRow, exportHelp])
        sourceColumn.orientation = .vertical
        sourceColumn.alignment = .leading
        sourceColumn.spacing = 6
        let sourceLabel = NSTextField(labelWithString: "Import from:")
        let sourceRow = NSStackView(views: [sourceLabel, sourceColumn])
        sourceRow.alignment = .firstBaseline
        sourceRow.spacing = 8
        formView.addArrangedSubview(sourceRow)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        listScroll.documentView = document
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.drawsBackground = true
        listScroll.backgroundColor = .controlBackgroundColor
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listScroll.heightAnchor.constraint(equalToConstant: Metrics.listHeight),
            listScroll.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.inset),
            document.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
        ])
        formView.addArrangedSubview(listScroll)

        // The label is the grid's first column, so it stays on the first
        // row's baseline whatever height the form takes.
        let bringLabel = NSTextField(labelWithString: "Bring:")
        let bringGrid = NSGridView(views: [[bringLabel, pinnedCheck, favoritesCheck],
                                           [NSGridCell.emptyContentView, todayCheck, historyCheck]])
        bringGrid.rowAlignment = .firstBaseline
        bringGrid.columnSpacing = 8
        bringGrid.rowSpacing = 6
        bringGrid.setContentHuggingPriority(.required, for: .horizontal)
        for check in [pinnedCheck, favoritesCheck, todayCheck, historyCheck] {
            check.state = .on
            check.target = self
            check.action = #selector(selectionChanged(_:))
        }
        bringGrid.column(at: 1).trailingPadding = 10
        formView.addArrangedSubview(bringGrid)

        for label in [statusLabel, notesLabel] {
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Metrics.width - 2 * Metrics.inset
            formView.addArrangedSubview(label)
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        importButton.target = self
        importButton.action = #selector(runImport(_:))
        importButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, importButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        formView.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.inset).isActive = true
    }

    private func buildResult() {
        resultView.orientation = .vertical
        resultView.alignment = .leading
        resultView.spacing = 10
        resultView.edgeInsets = NSEdgeInsets(top: Metrics.inset, left: Metrics.inset, bottom: Metrics.inset,
                                             right: Metrics.inset)
        let title = NSTextField(labelWithString: "Imported from Arc")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        resultView.addArrangedSubview(title)
        for stack in [resultLines, historyLines] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            resultView.addArrangedSubview(stack)
        }
        doneButton.target = self
        doneButton.action = #selector(cancel(_:))
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), doneButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        resultView.addArrangedSubview(NSView())
        resultView.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.inset).isActive = true
    }

    private func syncSourceControls() {
        installationRadio.state = source == .installation ? .on : .off
        exportRadio.state = source == .installation ? .off : .on
        chooseButton.isEnabled = source != .installation || !installationRadio.isEnabled
        if case .exportFile(let url?) = source {
            exportHelp.stringValue = url.lastPathComponent
        } else {
            exportHelp.stringValue = "In Arc: Settings › Advanced › Export Data."
        }
    }

    // MARK: - Loading

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let source = self.source
        snapshot = nil
        showList(message: "Reading…")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ArcImportSnapshot, ArcImportError> in
                do throws(ArcImportError) {
                    switch source {
                    case .installation: return .success(try ArcSidebarReader.read())
                    case .exportFile(let url?): return .success(try ArcExportReader.read(file: url))
                    case .exportFile(nil): throw ArcImportError.arcNotFound
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == loadGeneration else { return }
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                showList(message: nil)
            case .failure(let error):
                showList(message: error.localizedDescription)
            }
        }
    }

    /// Rebuilds the profile and space list from `snapshot`, or shows `message` instead.
    private func showList(message: String?) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        profileChecks = [:]
        profilePopups = [:]
        spaceChecks = [:]
        arcProfileNames = [:]
        guard let snapshot, message == nil else {
            let label = NSTextField(wrappingLabelWithString: message ?? "")
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Metrics.width - 2 * Metrics.inset - 30
            listStack.addArrangedSubview(label)
            updateNotes()
            return
        }
        let existing = store.arcImportExistingState()
        for profile in snapshot.profiles {
            arcProfileNames[profile.id] = profile.name
            let spaces = snapshot.spaces.filter { $0.profileID == profile.id }
            listStack.addArrangedSubview(profileRow(profile, existing: existing))
            for space in spaces {
                listStack.addArrangedSubview(spaceRow(space))
            }
        }
        if snapshot.profiles.isEmpty {
            showList(message: "Nothing to import: no spaces or profiles were found.")
            return
        }
        updateNotes()
    }

    private func profileRow(_ profile: ArcProfile, existing: ArcImportExistingState) -> NSView {
        let check = NSButton(checkboxWithTitle: profile.name, target: self, action: #selector(selectionChanged(_:)))
        check.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        check.state = .on
        profileChecks[profile.id] = check
        let detail = NSTextField(labelWithString: ArcImportText.profileDetail(profile))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let popup = NSPopUpButton()
        let newName = ArcImportPlanner.uniqueProfileName(profile.name, taken: existing.profiles.map(\.name))
        popup.addItem(withTitle: "New profile “\(newName)”")
        popup.menu?.addItem(.separator())
        for detourProfile in existing.profiles {
            popup.addItem(withTitle: detourProfile.name)
            popup.lastItem?.representedObject = detourProfile.id
        }
        // A re-import goes back where it went before (the planner's rule);
        // the popup says so.
        if let linked = existing.links[profile.sourceKey],
           let index = popup.itemArray.firstIndex(where: { $0.representedObject as? UUID == linked }) {
            popup.selectItem(at: index)
        }
        profilePopups[profile.id] = popup

        let into = NSTextField(labelWithString: "into:")
        into.textColor = .secondaryLabelColor
        let name = NSStackView(views: [check, detail])
        name.orientation = .vertical
        name.alignment = .leading
        name.spacing = 1
        let row = NSStackView(views: [name, NSView(), into, popup])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.inset - 40).isActive = true
        return row
    }

    private func spaceRow(_ space: ArcSpace) -> NSView {
        let title = [space.emoji, space.title].compactMap { $0 }.joined(separator: " ")
        let check = NSButton(checkboxWithTitle: title, target: self, action: #selector(selectionChanged(_:)))
        check.state = .on
        spaceChecks[space.sourceKey] = check
        let detail = NSTextField(labelWithString: ArcImportText.spaceDetail(space))
        detail.textColor = .secondaryLabelColor
        let indent = NSView()
        indent.widthAnchor.constraint(equalToConstant: Metrics.spaceIndent).isActive = true
        let row = NSStackView(views: [indent, check, NSView(), detail])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Metrics.width - 2 * Metrics.inset - 40).isActive = true
        return row
    }

    private func updateNotes() {
        var notes = [ArcImportText.notImported]
        if let snapshot {
            if let skipped = ArcImportText.skippedNote(snapshot.skipped) { notes.append(skipped) }
            if case .exportFile = snapshot.source { notes.append(ArcImportText.exportGuess) }
            if case .installation = snapshot.source, historyCheck.state == .on { notes.append(ArcImportText.historyNote) }
        }
        notesLabel.stringValue = notes.joined(separator: "\n\n")
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
        updateEnabledState()
    }

    private func updateEnabledState() {
        // An export carries no history.
        if case .exportFile = snapshot?.source { historyCheck.isEnabled = false } else { historyCheck.isEnabled = true }
        for (id, check) in profileChecks {
            let on = check.state == .on
            profilePopups[id]?.isEnabled = on
            for space in snapshot?.spaces ?? [] where space.profileID == id {
                spaceChecks[space.sourceKey]?.isEnabled = on
            }
        }
        let anyProfile = profileChecks.values.contains { $0.state == .on }
        let anyThing = [pinnedCheck, favoritesCheck, todayCheck, historyCheck]
            .contains { $0.state == .on && $0.isEnabled }
        importButton.isEnabled = snapshot != nil && anyProfile && anyThing && !isImporting
    }

    // MARK: - Actions

    @objc private func sourceChanged(_ sender: NSButton) {
        if sender === installationRadio {
            source = .installation
            load()
        } else if case .exportFile = source {
            // Already on an export: keep it.
        } else {
            source = .exportFile(nil)
            snapshot = nil
            showList(message: "Choose an Arc export file. In Arc: Settings › Advanced › Export Data.")
            chooseExportFile(sender)
        }
        syncSourceControls()
    }

    @objc private func chooseExportFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file Arc’s Export Data saved (“Arc Data Export.md”)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.source = .exportFile(url)
            self.syncSourceControls()
            self.load()
        }
    }

    @objc private func selectionChanged(_ sender: Any?) {
        updateEnabledState()
        if (sender as? NSButton) === historyCheck { updateNotes() }
    }

    @objc private func cancel(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc private func runImport(_ sender: Any?) {
        guard let snapshot, !isImporting else { return }
        let existing = store.arcImportExistingState()
        var options = ArcImportOptions(
            profiles: Set(profileChecks.filter { $0.value.state == .on }.map(\.key)),
            spaces: Set(spaceChecks.filter { $0.value.state == .on }.map(\.key)))
        options.includePinned = pinnedCheck.state == .on
        options.includeFavorites = favoritesCheck.state == .on
        options.includeTodayTabs = todayCheck.state == .on
        options.includeHistory = historyCheck.state == .on && historyCheck.isEnabled
        for (id, popup) in profilePopups where options.profiles.contains(id) {
            if let target = popup.selectedItem?.representedObject as? UUID {
                // A profile deleted since the list was built: refresh the
                // popups (the other choices stay) rather than import
                // somewhere the user did not choose.
                guard existing.profiles.contains(where: { $0.id == target }) else {
                    refreshProfilePopups(existing: existing)
                    showStatus("A profile you chose was deleted. Check where each Arc profile goes, then import again.")
                    return
                }
                options.profileTargets[id] = .existing(target)
            } else {
                options.profileTargets[id] = .newProfile
            }
        }

        let plan = ArcImportPlanner.plan(snapshot, options: options, existing: existing)
        let outcome: TabStore.SessionSaveOutcome
        do {
            outcome = try store.applyArcImport(plan)
        } catch {
            showList(message: nil)
            showStatus("Detour changed while this window was open. Nothing was imported; check your choices and import again.")
            return
        }
        showResult(plan, outcome: outcome)
    }

    /// Re-lists the existing profiles in every "into" popup, keeping each
    /// choice that still exists; a deleted one falls back to a new profile.
    private func refreshProfilePopups(existing: ArcImportExistingState) {
        for popup in profilePopups.values {
            let selected = popup.selectedItem?.representedObject as? UUID
            while popup.numberOfItems > 2 { popup.removeItem(at: 2) }
            for profile in existing.profiles {
                popup.addItem(withTitle: profile.name)
                popup.lastItem?.representedObject = profile.id
            }
            let index = popup.itemArray.firstIndex { $0.representedObject as? UUID == selected } ?? 0
            popup.selectItem(at: index)
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
    }

    private func showResult(_ plan: ArcImportPlan, outcome: TabStore.SessionSaveOutcome) {
        window?.contentView = resultView
        resultLines.arrangedSubviews.forEach { $0.removeFromSuperview() }
        historyLines.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var saveFailure: String?
        if case .failed(let reason) = outcome { saveFailure = reason }
        let lines = ArcImportText.resultLines(of: plan, saveFailure: saveFailure, skipped: snapshot?.skipped ?? [],
                                              names: arcProfileNames)
        for line in lines { resultLines.addArrangedSubview(wrapping("• " + line)) }

        guard !plan.history.isEmpty else { return }
        isImporting = true
        doneButton.isEnabled = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let progress = NSStackView(views: [spinner, NSTextField(labelWithString: "Importing history…")])
        historyLines.addArrangedSubview(progress)
        Task {
            let results = await store.importArcHistory(plan.history)
            historyLines.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for line in ArcImportText.historyLines(results, names: arcProfileNames) {
                historyLines.addArrangedSubview(wrapping("• " + line))
            }
            isImporting = false
            doneButton.isEnabled = true
        }
    }

    private func wrapping(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = Metrics.width - 2 * Metrics.inset
        return label
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The history write runs in the background either way; closing only
        // hides its result, but the window keeps it until it is done.
        !isImporting
    }
}

/// A document view that lays its content out from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
