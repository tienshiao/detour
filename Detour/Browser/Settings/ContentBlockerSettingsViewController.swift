import AppKit

class ContentBlockerSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var updateButton: NSButton!
    private var statusLabel: NSTextField!
    private var totalRulesLabel: NSTextField!
    /// The tracking-parameter list's switch and status line (TASK-337).
    private(set) var trackingListSwitch: NSSwitch!
    private(set) var trackingListStatusLabel: NSTextField!
    /// The table is exactly as tall as its header and rows: no empty striped
    /// rows below the four lists (TASK-189 defect 16).
    private var tableHeight: NSLayoutConstraint!

    private let manager = ContentBlockerManager.shared
    private let filterLists = ContentBlockerManager.filterLists

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let ruleCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override var paneDescription: String? {
        "Filter lists are downloaded and compiled into WebKit content rules. Lists update automatically every 24 hours."
    }

    override var guidePage: GuidePage? { .contentBlocker }

    override func makeBody() -> NSView {
        let container = NSView()
        let spacing = SettingsMetrics.rowGap

        // Table view
        // Sized to its rows, so it never scrolls itself; a scroll over it
        // reaches the pane's scroll view.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 28
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Filter List"
        nameCol.width = 160
        nameCol.minWidth = 100
        tableView.addTableColumn(nameCol)

        let parsedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("parsed"))
        parsedCol.title = "In List"
        parsedCol.width = 70
        parsedCol.minWidth = 50
        tableView.addTableColumn(parsedCol)

        let compiledCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("compiled"))
        compiledCol.title = "Active"
        compiledCol.width = 70
        compiledCol.minWidth = 50
        tableView.addTableColumn(compiledCol)

        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.width = 80
        statusCol.minWidth = 60
        tableView.addTableColumn(statusCol)

        let updatedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("updated"))
        updatedCol.title = "Last Updated"
        updatedCol.width = 110
        updatedCol.minWidth = 80
        tableView.addTableColumn(updatedCol)

        scrollView.documentView = tableView
        container.addSubview(scrollView)
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: 160)

        // Bottom bar
        updateButton = NSButton(title: "Update All Now", target: self, action: #selector(updateAllClicked))
        updateButton.bezelStyle = .rounded
        updateButton.setAccessibilityIdentifier("contentBlockerUpdateAll")
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(updateButton)

        let clearButton = NSButton(title: "Clear Cache & Redownload", target: self, action: #selector(clearCacheClicked))
        clearButton.bezelStyle = .rounded
        clearButton.setAccessibilityIdentifier("contentBlockerClearCache")
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        totalRulesLabel = NSTextField(labelWithString: "")
        totalRulesLabel.font = .systemFont(ofSize: 11)
        totalRulesLabel.textColor = .secondaryLabelColor
        totalRulesLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(totalRulesLabel)

        let trackingSection = makeTrackingListSection()
        container.addSubview(trackingSection)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableHeight,

            updateButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: spacing),
            updateButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            trackingSection.topAnchor.constraint(equalTo: updateButton.bottomAnchor, constant: SettingsMetrics.sectionGap),
            trackingSection.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trackingSection.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            trackingSection.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            bottomHug(trackingSection.bottomAnchor, container.bottomAnchor),

            clearButton.trailingAnchor.constraint(equalTo: updateButton.leadingAnchor, constant: -SettingsMetrics.labelToControl),
            clearButton.firstBaselineAnchor.constraint(equalTo: updateButton.firstBaselineAnchor),

            totalRulesLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            totalRulesLabel.firstBaselineAnchor.constraint(equalTo: updateButton.firstBaselineAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: totalRulesLabel.trailingAnchor, constant: 12),
            statusLabel.firstBaselineAnchor.constraint(equalTo: updateButton.firstBaselineAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -12),
        ])
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return container
    }

    /// The AdGuard URL Tracking list (TASK-337): app-wide, used only for the
    /// links Copy URL, Copy Link and Share… hand out, so it is a section of
    /// its own under the blocking lists rather than a row of their table.
    private func makeTrackingListSection() -> NSView {
        let title = NSTextField.settingsSectionTitle("Copied Links")
        trackingListSwitch = NSSwitch()
        trackingListSwitch.target = self
        trackingListSwitch.action = #selector(trackingListToggled)
        trackingListSwitch.setAccessibilityIdentifier("trackingParameterListEnabled")
        let row = SettingsSwitchRow.make(trackingListSwitch, title: Self.trackingListTitle)
        let help = SettingsWrappingLabel(
            wrapping: "Copy URL, Copy Link and Share… always leave out common tracking parameters such as "
                + "utm_source and fbclid. This list adds the ones particular sites use. It changes only the links "
                + "you copy or share and blocks nothing; it updates with the lists above.",
            estimatedWidth: SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin)
        trackingListStatusLabel = NSTextField(labelWithString: "")
        trackingListStatusLabel.font = .systemFont(ofSize: 11)
        trackingListStatusLabel.textColor = .secondaryLabelColor
        trackingListStatusLabel.setAccessibilityIdentifier("trackingParameterListStatus")

        let section = NSStackView(views: [title, row, help, trackingListStatusLabel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = SettingsMetrics.controlToHelp
        section.setCustomSpacing(SettingsMetrics.sectionTitleToRows, after: title)
        section.translatesAutoresizingMaskIntoConstraints = false
        help.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    static let trackingListTitle = "Remove tracking parameters with the AdGuard URL Tracking filter"

    /// The status line under the tracking list's switch: what Copy URL uses.
    static func trackingListStatus(isEnabled: Bool, ruleCount: Int?, lastFetch: Date?, now: Date) -> String {
        guard isEnabled else { return "Off: not downloaded or used" }
        guard let ruleCount else { return "Not downloaded yet" }
        let rules = "\(ruleCountFormatter.string(from: NSNumber(value: ruleCount)) ?? "\(ruleCount)") rules"
        guard let lastFetch else { return rules }
        // At least a second ago: the formatter reads no difference, or a fetch
        // recorded a moment after `now`, as "in 0s".
        let updated = relativeDateFormatter.localizedString(
            fromTimeInterval: min(lastFetch.timeIntervalSince(now), -1))
        return "\(rules), updated \(updated)"
    }

    private func updateTrackingListRow() {
        let list = manager.trackingParameterList
        trackingListSwitch.state = list.isEnabled ? .on : .off
        // The rules in use, or, while the cached text is still being read
        // (at launch, just turned on), the count recorded when it was.
        let ruleCount = list.counts?.supported ?? manager.parsedRuleCount(for: TrackingParameterList.identifier)
        trackingListStatusLabel.stringValue = Self.trackingListStatus(
            isEnabled: list.isEnabled, ruleCount: ruleCount,
            lastFetch: manager.lastFetchDate(for: TrackingParameterList.identifier), now: Date())
    }

    @objc private func trackingListToggled() {
        manager.setTrackingParameterListEnabled(trackingListSwitch.state == .on)
        updateTrackingListRow()
    }

    /// Header plus every row plus the bezel's two border points.
    private func updateTableHeight() {
        tableView.tile()
        let header = tableView.headerView?.frame.height ?? 0
        let rows = tableView.allRowsHeight
        let height = ceil(header + rows + 2)
        if tableHeight.constant != height {
            tableHeight.constant = height
            contentHeightDidChange()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        tableView.reloadData()
        updateTableHeight()
        updateTotalRules()
        updateStatusLabel()
        updateTrackingListRow()

        NotificationCenter.default.addObserver(self, selector: #selector(statusDidChange),
                                               name: .contentBlockerStatusDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(statusDidChange),
                                               name: .contentBlockerRulesDidChange, object: nil)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self, name: .contentBlockerStatusDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .contentBlockerRulesDidChange, object: nil)
    }

    // MARK: - Actions

    @objc private func updateAllClicked() {
        updateButton.isEnabled = false
        statusLabel.stringValue = "Updating..."
        manager.forceRefreshAll()
    }

    @objc private func clearCacheClicked() {
        updateButton.isEnabled = false
        statusLabel.stringValue = "Clearing cache..."
        manager.clearCacheAndRedownload()
        tableView.reloadData()
        updateTotalRules()
    }

    @objc private func statusDidChange() {
        tableView.reloadData()
        updateTotalRules()
        updateStatusLabel()
        updateTrackingListRow()

        if manager.refreshingIdentifiers.isEmpty {
            updateButton.isEnabled = true
            statusLabel.stringValue = ""
        }
    }

    private func updateTotalRules() {
        var total = 0
        for list in filterLists {
            if let count = manager.compiledRuleCount(for: list.identifier) {
                total += count
            }
        }
        if total > 0 {
            let formatted = Self.ruleCountFormatter.string(from: NSNumber(value: total)) ?? "\(total)"
            totalRulesLabel.stringValue = "\(formatted) active rules"
        } else {
            totalRulesLabel.stringValue = "No active rules"
        }
    }

    private func updateStatusLabel() {
        let refreshing = manager.refreshingIdentifiers.count
        if refreshing > 0 {
            statusLabel.stringValue = "Updating \(refreshing) list\(refreshing == 1 ? "" : "s")..."
            updateButton.isEnabled = false
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filterLists.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let list = filterLists[row]
        let colID = tableColumn?.identifier.rawValue ?? ""
        let cellID = NSUserInterfaceItemIdentifier("CB_\(colID)")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let label = cell.textField!

        switch colID {
        case "name":
            label.stringValue = list.name
        case "parsed":
            if let count = manager.parsedRuleCount(for: list.identifier) {
                label.stringValue = Self.ruleCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
            } else {
                label.stringValue = "—"
            }
            label.textColor = .secondaryLabelColor
        case "compiled":
            if let count = manager.compiledRuleCount(for: list.identifier) {
                label.stringValue = Self.ruleCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
            } else {
                label.stringValue = "—"
            }
            label.textColor = .labelColor
        case "status":
            if manager.refreshingIdentifiers.contains(list.identifier) {
                label.stringValue = "Updating..."
                label.textColor = .secondaryLabelColor
            } else if manager.isCompiled(identifier: list.identifier) {
                label.stringValue = "Active"
                label.textColor = .systemGreen
            } else {
                label.stringValue = "Not loaded"
                label.textColor = .secondaryLabelColor
            }
        case "updated":
            if let date = manager.lastFetchDate(for: list.identifier) {
                label.stringValue = Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
            } else {
                label.stringValue = "Never"
            }
            label.textColor = .secondaryLabelColor
        default:
            break
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}
