import AppKit

class ContentBlockerSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var updateButton: NSButton!
    private var statusLabel: NSTextField!
    private var totalRulesLabel: NSTextField!

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

    override func loadView() {
        preferredContentSize = NSSize(width: 740, height: 300)
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let margin: CGFloat = 20
        let spacing: CGFloat = 12

        let descLabel = NSTextField(wrappingLabelWithString:
            "Filter lists are downloaded and compiled into WebKit content rules. Lists update automatically every 24 hours.")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)

        // Table view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
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

        // Bottom bar
        updateButton = NSButton(title: "Update All Now", target: self, action: #selector(updateAllClicked))
        updateButton.bezelStyle = .rounded
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(updateButton)

        let clearButton = NSButton(title: "Clear Cache & Redownload", target: self, action: #selector(clearCacheClicked))
        clearButton.bezelStyle = .rounded
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

        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            descLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            descLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            scrollView.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: spacing),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scrollView.bottomAnchor.constraint(equalTo: updateButton.topAnchor, constant: -spacing),

            updateButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            updateButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

            clearButton.trailingAnchor.constraint(equalTo: updateButton.leadingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: updateButton.centerYAnchor),

            totalRulesLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            totalRulesLabel.centerYAnchor.constraint(equalTo: updateButton.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: totalRulesLabel.trailingAnchor, constant: spacing),
            statusLabel.centerYAnchor.constraint(equalTo: updateButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -spacing),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        tableView.reloadData()
        updateTotalRules()
        updateStatusLabel()

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
