import AppKit

/// Settings > Content Blocking: the four filter lists, each a row with its
/// status on the right and its rule counts and last update under its name, a
/// footnote with the total and what is being fetched, the buttons that
/// update or redownload every list, and the Tracking Parameters section (TASK-337).
/// A grouped form (TASK-338); until then the lists were a five-column table.
/// Which lists block content is set per profile, on the Profiles pane.
class ContentBlockerSettingsViewController: SettingsPaneViewController {
    private var updateButton: NSButton!
    /// One row per filter list, in `filterLists` order, and its status value.
    private(set) var listRows: [(row: SettingsFormRow, status: NSTextField)] = []
    /// The total of active rules and what is being fetched.
    private(set) var totalsFootnote: SettingsFormRow!
    /// "Updating…", "Clearing cache…" while a fetch runs, else empty.
    private var activity = ""
    /// The tracking-parameter list's switch and status line (TASK-337).
    private(set) var trackingListSwitch: NSSwitch!
    private(set) var trackingListStatusLabel: NSTextField!

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
        listRows = filterLists.map { list in
            // The widest status it shows, so the row's text column is
            // estimated at the width it will have.
            let status = NSTextField(labelWithString: Self.filterListStatus(isRefreshing: false, isCompiled: false).text)
            status.font = .systemFont(ofSize: SettingsMetrics.formTitleFontSize)
            status.textColor = .secondaryLabelColor
            // One line of details until the first update, so the pane's
            // first measurement already has the rows' height.
            return (SettingsFormRow(title: list.name, help: " ", accessory: .value(status, button: nil)), status)
        }
        totalsFootnote = SettingsFormRow(footnote: " ")

        let clearButton = NSButton(title: "Clear Cache & Redownload", target: self, action: #selector(clearCacheClicked))
        clearButton.bezelStyle = .rounded
        clearButton.setAccessibilityIdentifier("contentBlockerClearCache")
        updateButton = NSButton(title: "Update All Now", target: self, action: #selector(updateAllClicked))
        updateButton.bezelStyle = .rounded
        updateButton.setAccessibilityIdentifier("contentBlockerUpdateAll")

        return formBody(SettingsForm(sections: [
            SettingsFormSection(title: "Filter Lists", rows: listRows.map(\.row), footnote: totalsFootnote,
                                buttons: [clearButton, updateButton]),
            makeTrackingListSection(),
        ]))
    }

    /// The AdGuard URL Tracking list (TASK-337): app-wide, used only for the
    /// links Copy URL, Copy Link and Share… hand out and the addresses
    /// quarantine pages load (TASK-329), so it is a section of its own under
    /// the blocking lists rather than one of their rows.
    private func makeTrackingListSection() -> SettingsFormSection {
        trackingListSwitch = NSSwitch()
        trackingListSwitch.target = self
        trackingListSwitch.action = #selector(trackingListToggled)
        trackingListSwitch.setAccessibilityIdentifier("trackingParameterListEnabled")
        let row = SettingsFormRow(
            title: Self.trackingListTitle,
            help: Self.trackingListHelp,
            accessory: .toggle(trackingListSwitch))
        trackingListStatusLabel = NSTextField(labelWithString: "")
        trackingListStatusLabel.font = .systemFont(ofSize: SettingsMetrics.formHelpFontSize)
        trackingListStatusLabel.textColor = .secondaryLabelColor
        trackingListStatusLabel.lineBreakMode = .byTruncatingTail
        trackingListStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trackingListStatusLabel.setAccessibilityIdentifier("trackingParameterListStatus")
        row.addDetail(trackingListStatusLabel)
        return SettingsFormSection(title: "Tracking Parameters", rows: [row])
    }

    static let trackingListTitle = "Remove tracking parameters with the AdGuard URL Tracking filter"
    static let trackingListHelp = "Copy URL, Copy Link, Share… and Quarantine always leave out common tracking "
        + "parameters such as utm_source and fbclid. This list adds the ones particular sites use. It blocks "
        + "nothing; it updates with the lists above."

    /// The status line under the tracking list's switch: what Copy URL uses.
    static func trackingListStatus(isEnabled: Bool, ruleCount: Int?, lastFetch: Date?, now: Date) -> String {
        guard isEnabled else { return "Off: not downloaded or used" }
        guard let ruleCount else { return "Not downloaded yet" }
        let rules = "\(formatted(ruleCount)) rules"
        guard let lastFetch else { return rules }
        return "\(rules), \(updatedText(lastFetch, now: now))"
    }

    /// "updated 3 hr. ago". At least a second ago: the formatter reads no
    /// difference, or a fetch recorded a moment after `now`, as "in 0s".
    private static func updatedText(_ lastFetch: Date, now: Date) -> String {
        "updated \(relativeDateFormatter.localizedString(fromTimeInterval: min(lastFetch.timeIntervalSince(now), -1)))"
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

    override func viewWillAppear() {
        super.viewWillAppear()
        updateListRows()
        updateActivity()
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
        activity = "Updating…"
        manager.forceRefreshAll()
        updateFootnote()
    }

    @objc private func clearCacheClicked() {
        updateButton.isEnabled = false
        activity = "Clearing cache…"
        manager.clearCacheAndRedownload()
        updateListRows()
    }

    @objc private func statusDidChange() {
        updateListRows()
        updateActivity()
        updateTrackingListRow()
    }

    // MARK: - The lists

    /// Each list's status and details, and the footnote's total.
    private func updateListRows() {
        let now = Date()
        for (list, item) in zip(filterLists, listRows) {
            let status = Self.filterListStatus(isRefreshing: manager.refreshingIdentifiers.contains(list.identifier),
                                               isCompiled: manager.isCompiled(identifier: list.identifier))
            item.status.stringValue = status.text
            item.status.textColor = status.isActive ? .systemGreen : .secondaryLabelColor
            item.row.setHelp(Self.filterListDetail(parsed: manager.parsedRuleCount(for: list.identifier),
                                                   compiled: manager.compiledRuleCount(for: list.identifier),
                                                   lastFetch: manager.lastFetchDate(for: list.identifier), now: now))
        }
        updateFootnote()
    }

    private func updateActivity() {
        let refreshing = manager.refreshingIdentifiers.count
        if refreshing > 0 {
            activity = "Updating \(refreshing) list\(refreshing == 1 ? "" : "s")…"
            updateButton.isEnabled = false
        } else {
            // A fetch that ended while the pane was hidden (its observers
            // are off then) leaves no "Updating…" and no disabled button.
            activity = ""
            updateButton.isEnabled = true
        }
        updateFootnote()
    }

    private func updateFootnote() {
        let total = filterLists.compactMap { manager.compiledRuleCount(for: $0.identifier) }.reduce(0, +)
        totalsFootnote.setHelp(Self.totalsText(activeRules: total, activity: activity))
    }

    /// A list's status, on the right of its row: what the table's Status
    /// column said.
    static func filterListStatus(isRefreshing: Bool, isCompiled: Bool) -> (text: String, isActive: Bool) {
        if isRefreshing { return ("Updating…", false) }
        return isCompiled ? ("Active", true) : ("Not loaded", false)
    }

    /// A list's details, under its name: the rules in the list, the rules
    /// compiled into WebKit's content rules, and when it was last fetched
    /// (the table's In List, Active and Last Updated columns).
    static func filterListDetail(parsed: Int?, compiled: Int?, lastFetch: Date?, now: Date) -> String {
        var parts: [String] = []
        if let parsed { parts.append("\(formatted(parsed)) rules") }
        if let compiled { parts.append("\(formatted(compiled)) active") }
        if let lastFetch {
            parts.append(updatedText(lastFetch, now: now))
        } else {
            parts.append("never updated")
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The footnote under the lists: the active rules in total, and what is
    /// being fetched.
    static func totalsText(activeRules: Int, activity: String) -> String {
        let total = activeRules > 0 ? "\(formatted(activeRules)) active rules" : "No active rules"
        return activity.isEmpty ? total : "\(total). \(activity)"
    }

    private static func formatted(_ count: Int) -> String {
        ruleCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
