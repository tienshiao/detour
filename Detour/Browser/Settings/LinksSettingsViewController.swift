import AppKit
import UniformTypeIdentifiers

/// Settings > Links: Air Traffic Control's routes and the Default (TASK-191.3),
/// after Arc's sheet (docs/air-traffic-control/). Each route is one row of
/// three lines: `URL [kind] [pattern] ⊖`, `From app [app]`, `Open in [target]`,
/// and, when the route is incomplete, refused or broken, a fourth: the whole
/// warning, wrapped, with the row as tall as it needs. Rows drag
/// to reorder. The rules (target menus, drag destinations, warnings, drafts)
/// live in `LinkRouteEditor.swift`; the store validates and saves, and is
/// read by the resolver for every link, so a change applies to the next one.
final class LinksSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate,
                                         NSTextFieldDelegate, NSMenuDelegate, TabStoreObserver {
    private let editor = LinkRouteEditor(store: TabStore.shared.linkRoutes)
    private var store: LinkRouteStore { editor.store }
    /// The rows the table shows, as of the last refresh.
    private var rows: [LinkRouteEditor.Row] = []

    private var tableView: NSTableView!
    private var tableScroll: NSScrollView!
    private var listHeight: NSLayoutConstraint!
    private var emptyLabel: NSTextField!
    private var defaultRow: LinkRouteHighlightView!
    private var defaultPopUp: NSPopUpButton!
    private var defaultWarningIcon: NSImageView!
    private var defaultWarningLabel: NSTextField!
    /// The Default row ends below its pop-up, or below its warning.
    private var defaultBottomAtPopUp: NSLayoutConstraint!
    private var defaultBottomAtWarning: NSLayoutConstraint!
    /// A row's height without a warning line (measured from a laid-out cell).
    private var routeRowHeight: CGFloat = 100
    /// The width the row heights were last worked out for.
    private var measuredRowWidth: CGFloat = 0
    /// The warning a row shows while its pattern is being typed, when it has
    /// one (`controlTextDidChange`); cleared at the next refresh.
    private var previewMessages: [UUID: String] = [:]

    /// The space whose routes are highlighted (from the blocked-deletion
    /// alert); cleared when the pane is left.
    private var highlightedSpaceID: UUID?
    private var scrollsToHighlightOnFit = false
    private var storeObserver: NSObjectProtocol?

    private static let dragType = NSPasteboard.PasteboardType("com.detour.link-route")
    /// The list's height with no routes: one line of text.
    private static let emptyListHeight: CGFloat = 56

    override var paneDescription: String? {
        "Air Traffic Control opens links in the space you choose: links from other apps, addresses typed in a new tab, and links clicked to another site. Routes are tried from the top, and the first that matches decides. Drag routes to change their order."
    }

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }

    // MARK: - Building

    override func makeBody() -> NSView {
        let container = NSView()

        let routesTitle = NSTextField.settingsSectionTitle("Routes")
        let newRouteButton = NSButton(title: "New Route", target: self, action: #selector(newRouteClicked))
        newRouteButton.bezelStyle = .push
        newRouteButton.setAccessibilityIdentifier("newRoute")
        newRouteButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(routesTitle)
        container.addSubview(newRouteButton)

        let box = SettingsListContainerView()
        container.addSubview(box)

        tableScroll = LinkRouteListScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = false
        tableScroll.hasHorizontalScroller = false
        tableScroll.verticalScrollElasticity = .none
        tableScroll.horizontalScrollElasticity = .none
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = false

        tableView = LinkRouteTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("route"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableScroll.documentView = tableView
        box.addSubview(tableScroll)

        emptyLabel = NSTextField(labelWithString: "No routes. Click New Route to send links to a space by their address or by the app they come from.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(emptyLabel)

        let defaultTitle = NSTextField.settingsSectionTitle("Default")
        container.addSubview(defaultTitle)

        defaultRow = LinkRouteHighlightView()
        container.addSubview(defaultRow)
        let defaultLabel = NSTextField(labelWithString: "Open other links in")
        defaultLabel.font = .systemFont(ofSize: 13)
        defaultLabel.translatesAutoresizingMaskIntoConstraints = false
        defaultPopUp = NSPopUpButton()
        defaultPopUp.translatesAutoresizingMaskIntoConstraints = false
        defaultPopUp.target = self
        defaultPopUp.action = #selector(defaultTargetChanged)
        defaultPopUp.setAccessibilityLabel("Open other links in")
        defaultPopUp.widthAnchor.constraint(equalToConstant: 220).isActive = true
        defaultPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        defaultWarningIcon = LinkRouteCellView.makeWarning().icon
        // Below the pop-up and wrapping, like a route's warning: the space
        // beside the pop-up is too narrow for the longer messages.
        defaultWarningLabel = SettingsWrappingLabel(wrapping: "", estimatedWidth: SettingsMetrics.windowWidth
            - 2 * SettingsMetrics.paneMargin - 2 * LinkRouteHighlightView.insetX - 300)
        defaultWarningLabel.isHidden = true
        for view in [defaultLabel, defaultPopUp!, defaultWarningIcon!, defaultWarningLabel!] { defaultRow.addSubview(view) }

        let caption = SettingsWrappingLabel(
            wrapping: "For every link no route matches: links from other apps, addresses typed in a new tab, and links clicked to another site. Most Recent Space opens a link from another app in the space in front and leaves a typed or clicked link where it is.",
            estimatedWidth: SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin)
        container.addSubview(caption)

        listHeight = box.heightAnchor.constraint(equalToConstant: Self.emptyListHeight)
        defaultBottomAtPopUp = defaultPopUp.bottomAnchor.constraint(equalTo: defaultRow.bottomAnchor,
                                                                    constant: -LinkRouteHighlightView.insetY)
        defaultBottomAtWarning = defaultWarningLabel.bottomAnchor.constraint(equalTo: defaultRow.bottomAnchor,
                                                                             constant: -LinkRouteHighlightView.insetY)
        let inset: CGFloat = 1  // inside the box's border
        NSLayoutConstraint.activate([
            // Nothing above the list stretches: in a window taller than the
            // pane (the 400 pt minimum) the space goes below the caption.
            newRouteButton.topAnchor.constraint(equalTo: container.topAnchor),
            newRouteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            routesTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            routesTitle.centerYAnchor.constraint(equalTo: newRouteButton.centerYAnchor),

            box.topAnchor.constraint(equalTo: newRouteButton.bottomAnchor, constant: SettingsMetrics.sectionTitleToRows),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listHeight,

            tableScroll.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            tableScroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            tableScroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            tableScroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),

            emptyLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),

            defaultTitle.topAnchor.constraint(equalTo: box.bottomAnchor, constant: SettingsMetrics.sectionGap),
            defaultTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            defaultRow.topAnchor.constraint(equalTo: defaultTitle.bottomAnchor, constant: SettingsMetrics.sectionTitleToRows),
            defaultRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            defaultRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            defaultPopUp.topAnchor.constraint(equalTo: defaultRow.topAnchor, constant: LinkRouteHighlightView.insetY),
            defaultBottomAtPopUp,
            defaultLabel.leadingAnchor.constraint(equalTo: defaultRow.leadingAnchor, constant: LinkRouteHighlightView.insetX),
            defaultLabel.firstBaselineAnchor.constraint(equalTo: defaultPopUp.firstBaselineAnchor),
            defaultPopUp.leadingAnchor.constraint(equalTo: defaultLabel.trailingAnchor, constant: SettingsMetrics.labelToControl),
            defaultWarningIcon.leadingAnchor.constraint(equalTo: defaultPopUp.leadingAnchor),
            defaultWarningIcon.centerYAnchor.constraint(equalTo: defaultWarningLabel.topAnchor,
                                                        constant: LinkRouteCellView.warningFirstLineCenter),
            defaultWarningLabel.leadingAnchor.constraint(equalTo: defaultWarningIcon.trailingAnchor,
                                                         constant: LinkRouteCellView.warningIconGap),
            defaultWarningLabel.topAnchor.constraint(equalTo: defaultPopUp.bottomAnchor, constant: LinkRouteCellView.lineGap),
            defaultWarningLabel.trailingAnchor.constraint(equalTo: defaultRow.trailingAnchor,
                                                          constant: -LinkRouteHighlightView.insetX),

            caption.topAnchor.constraint(equalTo: defaultRow.bottomAnchor, constant: SettingsMetrics.controlToHelp),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: LinkRouteHighlightView.insetX),
            caption.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            bottomHug(caption.bottomAnchor, container.bottomAnchor),
        ])
        return container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        routeRowHeight = LinkRouteCellView.measuredHeight(width: Self.estimatedRowWidth)
        tableView.rowHeight = routeRowHeight
        TabStore.shared.addObserver(self)
        storeObserver = NotificationCenter.default.addObserver(
            forName: LinkRouteStore.didChangeNotification, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    /// A warning's line count depends on the row's width, which is the
    /// window's less the pane's scroll bar ("always show scroll bars"):
    /// re-measure when it changes.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard tableView.bounds.width > 0, abs(tableView.bounds.width - measuredRowWidth) > 0.5 else { return }
        updateRowHeights()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard highlightedSpaceID != nil else { return }
        highlightedSpaceID = nil
        refresh()
    }

    override func paneDidFit() {
        super.paneDidFit()
        guard scrollsToHighlightOnFit else { return }
        scrollsToHighlightOnFit = false
        scrollToFirstHighlight()
    }

    // MARK: - Highlighting (the blocked-deletion alert)

    /// Highlights the routes, and the Default, that target `spaceID` (nil:
    /// none), and scrolls the first into view once the window has its height.
    /// A row stops being highlighted once its target changes.
    func highlightRoutes(targetingSpaceID spaceID: UUID?) {
        highlightedSpaceID = spaceID
        scrollsToHighlightOnFit = spaceID != nil
        if isViewLoaded { refresh() }
    }

    private func isHighlighted(_ target: LinkRouteTarget) -> Bool {
        guard let highlightedSpaceID else { return false }
        return target == .space(highlightedSpaceID)
    }

    /// By the saved route's target: that is what blocks the deletion. A draft,
    /// or an edit the store refused, does not.
    private func isHighlighted(_ row: LinkRouteEditor.Row) -> Bool {
        guard highlightedSpaceID != nil, row.isSaved,
              let saved = store.routes.first(where: { $0.id == row.route.id }) else { return false }
        return isHighlighted(saved.target)
    }

    private func scrollToFirstHighlight() {
        guard let document = scrollView.documentView else { return }
        let rect: NSRect
        if let index = rows.firstIndex(where: { isHighlighted($0) }) {
            rect = tableView.convert(tableView.rect(ofRow: index), to: document)
        } else if isHighlighted(store.defaultTarget) {
            rect = defaultRow.convert(defaultRow.bounds, to: document)
        } else {
            return
        }
        document.scrollToVisible(rect.insetBy(dx: 0, dy: -8))
    }

    // MARK: - Refreshing

    /// Brings the rows, the list's height and the Default up to date with the
    /// store, the drafts and the spaces. Rows whose order did not change are
    /// updated in place, so a field being edited keeps its editor.
    private func refresh() {
        guard isViewLoaded else { return }
        previewMessages = [:]
        let newRows = editor.rows
        let sameRows = newRows.map(\.route.id) == rows.map(\.route.id)
        rows = newRows
        if sameRows {
            for index in rows.indices {
                if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? LinkRouteCellView {
                    configure(cell, with: rows[index])
                }
                if let rowView = tableView.rowView(atRow: index, makeIfNecessary: false) as? LinkRouteRowView {
                    rowView.isTargetHighlighted = isHighlighted(rows[index])
                }
            }
        } else {
            tableView.reloadData()
        }
        tableScroll.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        updateRowHeights()
        updateDefault()
    }

    // MARK: - Row heights

    /// The row width before the table is laid out: the pane's body less the
    /// list's border.
    private static let estimatedRowWidth = SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin - 2

    private var rowWidth: CGFloat { tableView.bounds.width > 0 ? tableView.bounds.width : Self.estimatedRowWidth }

    /// The warning a row shows: the one being typed, else the saved state's.
    private func warningMessage(for row: LinkRouteEditor.Row) -> String? {
        previewMessages[row.route.id] ?? linkRouteProblemMessage(row.problems, kind: row.route.match?.kind,
                                                                 isSaved: row.isSaved,
                                                                 hasUnsavedChanges: row.hasUnsavedChanges)
    }

    private func height(of row: LinkRouteEditor.Row) -> CGFloat {
        routeRowHeight + LinkRouteCellView.warningLineHeight(warningMessage(for: row), rowWidth: rowWidth)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < rows.count ? height(of: rows[row]) : routeRowHeight
    }

    /// Tells the table every row's height may have changed (at once, not
    /// animated) and sizes the list to them; the pane refits if that changed
    /// its height.
    private func updateRowHeights() {
        measuredRowWidth = tableView.bounds.width
        if !rows.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
        }
        let height = rows.isEmpty ? Self.emptyListHeight : rows.reduce(0) { $0 + self.height(of: $1) } + 2
        if listHeight.constant != height {
            listHeight.constant = height
            contentHeightDidChange()
        }
    }

    private func updateDefault() {
        let problem = store.defaultTargetProblem
        fillTargetPopUp(defaultPopUp, current: store.defaultTarget, problem: problem)
        let message = problem.flatMap {
            linkRouteProblemMessage([$0], kind: nil, isSaved: true, hasUnsavedChanges: false)
        }
        LinkRouteCellView.setWarning(message, icon: defaultWarningIcon, label: defaultWarningLabel)
        if defaultBottomAtWarning.isActive != (message != nil) {
            defaultBottomAtPopUp.isActive = message == nil
            defaultBottomAtWarning.isActive = message != nil
            contentHeightDidChange()
        }
        defaultRow.isHighlighted = isHighlighted(store.defaultTarget)
    }

    private var spaceOptions: [LinkRouteSpaceOption] {
        TabStore.shared.nonIncognitoSpaces.map { LinkRouteSpaceOption(id: $0.id, name: $0.name, emoji: $0.emoji) }
    }

    // MARK: - TabStoreObserver

    /// A space added, renamed, given a new emoji, reordered or deleted: the
    /// pop-ups list them, and a route's target may have come or gone.
    func tabStoreDidUpdateSpaces() {
        refresh()
    }

    // MARK: - Rows

    private func configure(_ cell: LinkRouteCellView, with row: LinkRouteEditor.Row) {
        let route = row.route
        cell.handle.isHidden = !row.isSaved
        cell.matchPopUp.selectItem(withTag: LinkRouteCellView.tag(for: route.match?.kind))
        cell.patternField.isHidden = route.match == nil
        cell.patternField.placeholderString = LinkRouteCellView.placeholder(for: route.match?.kind)
        if cell.patternField.currentEditor() == nil {
            cell.patternField.stringValue = route.match?.pattern ?? ""
        }
        // The full list is rebuilt as the menu opens (`menuNeedsUpdate`); here
        // only when it lacks the route's app.
        if let menu = cell.appPopUp.menu, menu.items.isEmpty || !selectApp(route.normalizedSourceApp, in: cell.appPopUp) {
            populateAppMenu(menu, current: route.normalizedSourceApp)
            selectApp(route.normalizedSourceApp, in: cell.appPopUp)
        }
        let targetProblem = row.problems.first { $0 == .missingSpace || $0 == .privateSpace }
        fillTargetPopUp(cell.targetPopUp, current: route.target, problem: targetProblem)
        showWarning(for: row, problems: row.problems, in: cell)
    }

    private func showWarning(for row: LinkRouteEditor.Row, problems: [LinkRouteProblem], in cell: LinkRouteCellView) {
        let message = linkRouteProblemMessage(problems, kind: row.route.match?.kind, isSaved: row.isSaved,
                                              hasUnsavedChanges: row.hasUnsavedChanges)
        LinkRouteCellView.setWarning(message, icon: cell.warningIcon, label: cell.warningLabel)
    }

    private func routeID(for view: NSView) -> UUID? {
        let index = tableView.row(for: view)
        guard index >= 0, index < rows.count else { return nil }
        return rows[index].route.id
    }

    private func cell(forRoute id: UUID) -> LinkRouteCellView? {
        guard let index = rows.firstIndex(where: { $0.route.id == id }) else { return nil }
        return tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? LinkRouteCellView
    }

    // MARK: - Target pop-ups

    private func fillTargetPopUp(_ popUp: NSPopUpButton, current: LinkRouteTarget, problem: LinkRouteProblem?) {
        let menu = NSMenu()
        for item in linkRouteTargetMenu(spaces: spaceOptions, current: current) {
            guard let target = item.target else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: Self.title(for: item, problem: problem), action: nil, keyEquivalent: "")
            menuItem.representedObject = LinkRouteTargetBox(target)
            if case .unavailableSpace = item {
                menuItem.image = LinkRouteCellView.warningImage()
            }
            menu.addItem(menuItem)
        }
        popUp.menu = menu
        if let index = menu.items.firstIndex(where: { ($0.representedObject as? LinkRouteTargetBox)?.target == current }) {
            popUp.selectItem(at: index)
        }
    }

    private static func title(for item: LinkRouteTargetMenuItem, problem: LinkRouteProblem?) -> String {
        switch item {
        case .space(let option): return option.title
        case .unavailableSpace: return problem == .privateSpace ? "Private space" : "Space deleted"
        case .mostRecentSpace: return "Most Recent Space"
        case .privateWindow: return "Private Window"
        case .quarantine: return "Quarantine"
        case .quickDetour: return "Quick Detour"
        case .separator: return ""
        }
    }

    // MARK: - App pop-ups

    private static let anyAppTag = 0
    private static let appTag = 1
    private static let chooseAppTag = 2

    private struct AppChoice {
        var bundleID: String
        var name: String
        var icon: NSImage?
    }

    /// The regular apps running now, by name; Detour itself left out.
    private func runningApps() -> [AppChoice] {
        var seen: Set<String> = []
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppChoice? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id.lowercased()).inserted else { return nil }
                return AppChoice(bundleID: id, name: app.localizedName ?? id, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app by bundle ID, whether or not it is running: its name and icon
    /// from where it is installed, else the bundle ID itself.
    private func appChoice(bundleID: String) -> AppChoice {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            return AppChoice(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return AppChoice(bundleID: bundleID, name: SpaceDeletionBlockedAlert.installedAppName(bundleID: bundleID) ?? bundleID,
                             icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        return AppChoice(bundleID: bundleID, name: bundleID,
                         icon: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil))
    }

    /// Any App, the route's own app (if it is not running), the running apps,
    /// then Choose….
    private func populateAppMenu(_ menu: NSMenu, current: String?) {
        menu.removeAllItems()
        let any = NSMenuItem(title: "Any App", action: nil, keyEquivalent: "")
        any.tag = Self.anyAppTag
        menu.addItem(any)
        menu.addItem(.separator())
        var apps = runningApps()
        if let current, !apps.contains(where: { $0.bundleID.caseInsensitiveCompare(current) == .orderedSame }) {
            apps.insert(appChoice(bundleID: current), at: 0)
        }
        for app in apps {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            item.tag = Self.appTag
            item.representedObject = app.bundleID
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            item.toolTip = app.bundleID
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Choose…", action: nil, keyEquivalent: "")
        choose.tag = Self.chooseAppTag
        menu.addItem(choose)
    }

    /// False when the menu has no item for `bundleID`.
    @discardableResult
    private func selectApp(_ bundleID: String?, in popUp: NSPopUpButton) -> Bool {
        guard let bundleID else { return popUp.selectItem(withTag: Self.anyAppTag) }
        guard let item = popUp.menu?.items.first(where: {
            ($0.representedObject as? String)?.caseInsensitiveCompare(bundleID) == .orderedSame
        }) else { return false }
        popUp.select(item)
        return true
    }

    /// Rebuilt as it opens, so apps launched since the pane was shown are listed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for index in rows.indices {
            guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? LinkRouteCellView,
                  cell.appPopUp.menu === menu else { continue }
            let current = rows[index].route.normalizedSourceApp
            populateAppMenu(menu, current: current)
            selectApp(current, in: cell.appPopUp)
        }
    }

    private func chooseApp(forRoute id: UUID) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app whose links this route sends."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.refresh() }  // restores the pop-up on Cancel
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                NSSound.beep()
                return
            }
            self.editor.edit(id) { $0.sourceApp = bundleID }
        }
    }

    // MARK: - Actions

    /// Ends editing in a pattern field, committing what was typed. A click on
    /// a button or pop-up does not end it, and the change that follows can
    /// reload the table out from under the field (losing the text).
    private func commitPendingEdit() {
        guard let window = view.window, let text = window.firstResponder as? NSTextView, text.isFieldEditor else { return }
        window.makeFirstResponder(nil)
    }

    @objc private func newRouteClicked() {
        commitPendingEdit()
        let id = editor.addDraft()
        refresh()
        guard let index = rows.firstIndex(where: { $0.route.id == id }) else { return }
        // The list has grown (the window follows a moment later): lay it out
        // so the new row exists, show it, and put the cursor in its pattern.
        view.layoutSubtreeIfNeeded()
        let rect = tableView.convert(tableView.rect(ofRow: index), to: scrollView.documentView)
        scrollView.documentView?.scrollToVisible(rect)
        if let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? LinkRouteCellView {
            view.window?.makeFirstResponder(cell.patternField)
        }
    }

    @objc func matchKindChanged(_ sender: NSPopUpButton) {
        guard let id = routeID(for: sender) else { return }
        let kind = LinkRouteCellView.kind(forTag: sender.selectedTag())
        commitPendingEdit()
        editor.edit(id) { route in
            if let kind {
                // The pattern carries over from one kind to another.
                route.match = LinkRouteMatch(kind: kind, pattern: route.match?.pattern ?? "")
            } else {
                route.match = nil
            }
        }
        refresh()
        if kind != nil, let cell = cell(forRoute: id), cell.patternField.stringValue.isEmpty {
            view.window?.makeFirstResponder(cell.patternField)
        }
    }

    @objc func patternCommitted(_ sender: NSTextField) {
        guard let id = routeID(for: sender),
              let row = rows.first(where: { $0.route.id == id }), row.route.match != nil else { return }
        let pattern = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern != row.route.match?.pattern else { return refresh() }
        editor.edit(id) { $0.match?.pattern = pattern }
        refresh()
    }

    /// While typing, the row's warning follows the text; nothing is saved
    /// until the field is committed (Return, Tab or a click elsewhere).
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let id = routeID(for: field),
              let row = rows.first(where: { $0.route.id == id }),
              let cell = cell(forRoute: id) else { return }
        let text = field.stringValue
        let problems = editor.problems(previewing: id) { $0.match?.pattern = text }
        showWarning(for: row, problems: problems, in: cell)
        // A warning that appears while typing gets its line now; one that
        // goes keeps its (empty) line until the field is committed, so the
        // window does not resize with every keystroke.
        let preview = linkRouteProblemMessage(problems, kind: row.route.match?.kind, isSaved: row.isSaved,
                                              hasUnsavedChanges: row.hasUnsavedChanges)
        if let preview, preview != warningMessage(for: row) {
            previewMessages[id] = preview
            updateRowHeights()
        }
    }

    @objc func appChanged(_ sender: NSPopUpButton) {
        guard let id = routeID(for: sender) else { return }
        let tag = sender.selectedTag()
        let bundleID = sender.selectedItem?.representedObject as? String
        commitPendingEdit()
        switch tag {
        case Self.chooseAppTag:
            chooseApp(forRoute: id)
        case Self.appTag:
            editor.edit(id) { $0.sourceApp = bundleID }
            refresh()
        default:
            editor.edit(id) { $0.sourceApp = nil }
            refresh()
        }
    }

    @objc func targetChanged(_ sender: NSPopUpButton) {
        guard let id = routeID(for: sender),
              let target = (sender.selectedItem?.representedObject as? LinkRouteTargetBox)?.target else { return }
        commitPendingEdit()
        editor.edit(id) { $0.target = target }
        refresh()
    }

    @objc func removeClicked(_ sender: NSButton) {
        guard let id = routeID(for: sender) else { return }
        commitPendingEdit()
        editor.remove(id)
        refresh()
    }

    @objc private func defaultTargetChanged() {
        guard let target = (defaultPopUp.selectedItem?.representedObject as? LinkRouteTargetBox)?.target else { return }
        if target != store.defaultTarget, !store.setDefaultTarget(target) { NSSound.beep() }
        refresh()
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: LinkRouteCellView.identifier, owner: nil) as? LinkRouteCellView
            ?? makeCell()
        configure(cell, with: rows[row])
        return cell
    }

    private func makeCell() -> LinkRouteCellView {
        let cell = LinkRouteCellView()
        cell.matchPopUp.target = self
        cell.matchPopUp.action = #selector(matchKindChanged)
        cell.patternField.target = self
        cell.patternField.action = #selector(patternCommitted)
        cell.patternField.delegate = self
        cell.appPopUp.target = self
        cell.appPopUp.action = #selector(appChanged)
        cell.appPopUp.menu?.delegate = self
        cell.targetPopUp.target = self
        cell.targetPopUp.action = #selector(targetChanged)
        cell.removeButton.target = self
        cell.removeButton.action = #selector(removeClicked)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = LinkRouteRowView()
        rowView.showsTopSeparator = row > 0
        rowView.isTargetHighlighted = row < rows.count && isHighlighted(rows[row])
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < rows.count, rows[row].isSaved else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].route.id.uuidString, forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.dragType) != nil else { return [] }
        // Saved routes only move among themselves: never below a draft.
        let savedCount = rows.filter(\.isSaved).count
        if dropOperation != .above || row > savedCount {
            tableView.setDropRow(min(row, savedCount), dropOperation: .above)
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: text),
              rows.contains(where: { $0.route.id == id }) else { return false }
        commitPendingEdit()
        // After the commit, which may have saved a draft and so moved rows.
        guard let from = rows.firstIndex(where: { $0.route.id == id }) else { return false }
        let moved = editor.move(from: from, dropRow: row)
        refresh()
        return moved
    }
}

/// The route list never takes keyboard focus: its rows are not selectable,
/// so Tab from a pattern field goes to the next field rather than to the list.
private final class LinkRouteTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// A target in a pop-up item's `representedObject`.
private final class LinkRouteTargetBox: NSObject {
    let target: LinkRouteTarget
    init(_ target: LinkRouteTarget) { self.target = target }
}

/// The route list's own scroll view never scrolls (it is as tall as its
/// rows); scrolling over it scrolls the pane.
private final class LinkRouteListScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// A route row: a separator above every row but the first, and the accent
/// tint when it targets the space the blocked-deletion alert named.
private final class LinkRouteRowView: NSTableRowView {
    var isTargetHighlighted = false { didSet { if isTargetHighlighted != oldValue { needsDisplay = true } } }
    var showsTopSeparator = false { didSet { if showsTopSeparator != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isTargetHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            bounds.fill()
        }
        if showsTopSeparator {
            NSColor.separatorColor.setFill()
            let y = isFlipped ? bounds.minY : bounds.maxY - 1
            NSRect(x: bounds.minX + 10, y: y, width: bounds.width - 20, height: 1).fill()
        }
    }
}

/// The Default's row: tinted like a highlighted route row.
final class LinkRouteHighlightView: NSView {
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 4

    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: SettingsMetrics.listCornerRadius,
                     yRadius: SettingsMetrics.listCornerRadius).fill()
    }
}

/// One route: three lines (URL, From app, Open in) and a drag handle.
final class LinkRouteCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("LinkRouteCell")

    let handle = NSImageView()
    let matchPopUp = NSPopUpButton()
    let patternField = NSTextField()
    let removeButton = NSButton()
    let appPopUp = NSPopUpButton()
    let targetPopUp = NSPopUpButton()
    let warningIcon: NSImageView
    let warningLabel: NSTextField

    /// Padding inside a row, and between its lines.
    private static let insetX: CGFloat = 10
    private static let insetY: CGFloat = 10
    static let lineGap: CGFloat = 6
    /// Where the right-aligned line labels end.
    private static let labelEdge: CGFloat = 112
    /// The warning line: its font, icon and the gap after the icon.
    static let warningFont = NSFont.systemFont(ofSize: 11)
    static let warningIconWidth: CGFloat = 16
    static let warningIconGap: CGFloat = 4
    /// From the warning text's top to the middle of its first line.
    static var warningFirstLineCenter: CGFloat {
        ceil(warningFont.ascender - warningFont.descender + warningFont.leading) / 2
    }

    /// The width a route's warning wraps at, in a row `rowWidth` wide.
    static func warningWrapWidth(rowWidth: CGFloat) -> CGFloat {
        rowWidth - labelEdge - SettingsMetrics.labelToControl - warningIconWidth - warningIconGap - insetX
    }

    /// What a warning adds to a row: nothing without one, else the gap and
    /// the wrapped text's height.
    static func warningLineHeight(_ message: String?, rowWidth: CGFloat) -> CGFloat {
        guard let message, !message.isEmpty else { return 0 }
        let width = warningWrapWidth(rowWidth: rowWidth)
        let rect = (message as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: warningFont])
        // The label draws inside a text field cell, which adds a little
        // padding; measure with the same cell to be exact.
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = warningFont
        label.preferredMaxLayoutWidth = width
        return lineGap + max(ceil(rect.height), ceil(label.intrinsicContentSize.height))
    }

    override func layout() {
        super.layout()
        // The label wraps at its own width (the row's, less the columns).
        let width = Self.warningWrapWidth(rowWidth: bounds.width)
        if width > 1, abs(warningLabel.preferredMaxLayoutWidth - width) > 0.5 {
            warningLabel.preferredMaxLayoutWidth = width
            warningLabel.invalidateIntrinsicContentSize()
        }
    }
    private static let matchWidth: CGFloat = 120
    private static let popUpWidth: CGFloat = 220

    private static let anyURLTag = 99

    static func tag(for kind: LinkRouteMatchKind?) -> Int {
        switch kind {
        case .domainIs: return 0
        case .contains: return 1
        case .isEqualTo: return 2
        case nil: return anyURLTag
        }
    }

    static func kind(forTag tag: Int) -> LinkRouteMatchKind? {
        switch tag {
        case 0: return .domainIs
        case 1: return .contains
        case 2: return .isEqualTo
        default: return nil
        }
    }

    static func placeholder(for kind: LinkRouteMatchKind?) -> String {
        switch kind {
        case .domainIs, nil: return "example.com"
        case .contains: return "text in the address"
        case .isEqualTo: return "https://example.com/page"
        }
    }

    init() {
        (warningIcon, warningLabel) = Self.makeWarning()
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        identifier = Self.identifier

        handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")
        handle.contentTintColor = .tertiaryLabelColor
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = "Drag to change the order"

        for (title, kind) in [("Domain is", LinkRouteMatchKind.domainIs), ("Contains", .contains), ("Is equal to", .isEqualTo)] {
            matchPopUp.addItem(withTitle: title)
            matchPopUp.lastItem?.tag = Self.tag(for: kind)
        }
        matchPopUp.menu?.addItem(.separator())
        matchPopUp.addItem(withTitle: "Any URL")
        matchPopUp.lastItem?.tag = Self.anyURLTag
        matchPopUp.setAccessibilityLabel("URL condition")

        patternField.font = .systemFont(ofSize: 13)
        patternField.lineBreakMode = .byTruncatingTail
        patternField.usesSingleLineMode = true
        patternField.cell?.sendsActionOnEndEditing = true
        patternField.setAccessibilityLabel("Pattern")
        patternField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        patternField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeButton.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove Route")
        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove this route"
        removeButton.setButtonType(.momentaryChange)

        appPopUp.menu = NSMenu()
        appPopUp.setAccessibilityLabel("From app")
        appPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetPopUp.setAccessibilityLabel("Open in")
        targetPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let urlLabel = Self.lineLabel("URL", symbol: "link")
        let appLabel = Self.lineLabel("From app", symbol: "app.badge")
        let targetLabel = Self.lineLabel("Open in", symbol: "arrow.turn.down.right")

        for view in [handle, matchPopUp, patternField, removeButton, appPopUp, targetPopUp, warningIcon, warningLabel,
                     urlLabel.stack, appLabel.stack, targetLabel.stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        let controlsLeading = Self.labelEdge + SettingsMetrics.labelToControl
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.insetX),
            handle.centerYAnchor.constraint(equalTo: centerYAnchor),

            matchPopUp.topAnchor.constraint(equalTo: topAnchor, constant: Self.insetY),
            matchPopUp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: controlsLeading),
            patternField.leadingAnchor.constraint(equalTo: matchPopUp.trailingAnchor, constant: 8),
            patternField.firstBaselineAnchor.constraint(equalTo: matchPopUp.firstBaselineAnchor),
            patternField.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -8),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insetX),
            removeButton.centerYAnchor.constraint(equalTo: matchPopUp.centerYAnchor),

            appPopUp.topAnchor.constraint(equalTo: matchPopUp.bottomAnchor, constant: Self.lineGap),
            appPopUp.leadingAnchor.constraint(equalTo: matchPopUp.leadingAnchor),
            // Fixed widths, so the pop-ups line up from row to row; a long
            // name truncates.
            matchPopUp.widthAnchor.constraint(equalToConstant: Self.matchWidth),
            appPopUp.widthAnchor.constraint(equalToConstant: Self.popUpWidth),

            targetPopUp.topAnchor.constraint(equalTo: appPopUp.bottomAnchor, constant: Self.lineGap),
            targetPopUp.leadingAnchor.constraint(equalTo: matchPopUp.leadingAnchor),
            targetPopUp.widthAnchor.constraint(equalToConstant: Self.popUpWidth),
            // `<=`: the table sets the row's height (measured from this
            // layout), and a fraction of a point must not conflict.
            targetPopUp.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.insetY),

            // The warning is a line of its own under Open in, as wide as the
            // row allows and wrapping; the table gives the row the height
            // (`warningLineHeight`), so nothing pins the label's bottom.
            warningIcon.leadingAnchor.constraint(equalTo: matchPopUp.leadingAnchor),
            warningIcon.centerYAnchor.constraint(equalTo: warningLabel.topAnchor, constant: Self.warningFirstLineCenter),
            warningLabel.topAnchor.constraint(equalTo: targetPopUp.bottomAnchor, constant: Self.lineGap),
            warningLabel.leadingAnchor.constraint(equalTo: warningIcon.trailingAnchor, constant: Self.warningIconGap),
            warningLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.insetX),
        ])
        for (label, control) in [(urlLabel, matchPopUp), (appLabel, appPopUp), (targetLabel, targetPopUp)] as [((stack: NSStackView, text: NSTextField), NSView)] {
            NSLayoutConstraint.activate([
                label.stack.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelEdge),
                label.text.firstBaselineAnchor.constraint(equalTo: control.firstBaselineAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A line's label: a symbol and a word, right-aligned at `labelEdge`.
    private static func lineLabel(_ text: String, symbol: String) -> (stack: NSStackView, text: NSTextField) {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [image, label])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        return (stack, label)
    }

    static func warningImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        return image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
    }

    static func makeWarning() -> (icon: NSImageView, label: NSTextField) {
        let icon = NSImageView()
        icon.image = warningImage()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: warningIconWidth).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Wraps: the whole message is always shown.
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = warningFont
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.isSelectable = false
        icon.isHidden = true
        label.isHidden = true
        return (icon, label)
    }

    static func setWarning(_ message: String?, icon: NSImageView, label: NSTextField) {
        icon.isHidden = message == nil
        label.isHidden = message == nil
        label.stringValue = message ?? ""
    }

    /// A row's height: a cell laid out at the list's width.
    static func measuredHeight(width: CGFloat) -> CGFloat {
        let cell = LinkRouteCellView()
        cell.matchPopUp.selectItem(at: 0)
        cell.appPopUp.addItem(withTitle: "Any App")
        cell.targetPopUp.addItem(withTitle: "Most Recent Space")
        let fixedWidth = cell.widthAnchor.constraint(equalToConstant: width)
        fixedWidth.isActive = true
        defer { fixedWidth.isActive = false }
        return ceil(cell.fittingSize.height)
    }
}
