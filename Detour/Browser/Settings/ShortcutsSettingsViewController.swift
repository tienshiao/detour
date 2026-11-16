import AppKit

// MARK: - The list (pure)

/// What Settings > Shortcuts lists (TASK-327): the registry's commands that
/// have one menu item, under their menu's title, in menu order, filtered by
/// the search field. Pure, so it is tested without the pane.
enum ShortcutList {
    enum Item: Equatable {
        /// A menu's heading.
        case menu(String)
        case command(CommandID)
    }

    /// The items for `query`: each typed word starts a word of the command's
    /// title, one of its aliases or its menu's title ("file new" lists File's
    /// New commands). A menu with no command left has no heading.
    static func items(in menus: [CommandMenu], query: String,
                      includes: (BrowserCommand) -> Bool) -> [Item] {
        let typed = PaletteCommands.words(query)
        var items: [Item] = []
        for menu in menus {
            let commands = menu.commands.filter {
                includes($0) && $0.bindability != .notListed && matches($0, menu: menu.title, typed: typed)
            }
            guard !commands.isEmpty else { continue }
            items.append(.menu(menu.title))
            items += commands.map { .command($0.id) }
        }
        return items
    }

    static func matches(_ command: BrowserCommand, menu: String, typed: [String]) -> Bool {
        guard !typed.isEmpty else { return true }
        let words = PaletteCommands.words(([command.title, menu] + command.aliases).joined(separator: " "))
        return typed.allSatisfy { word in words.contains { $0.hasPrefix(word) } }
    }
}

/// One command's row as the pane shows it. Pure.
struct ShortcutRowState: Equatable {
    enum Kind: Equatable {
        /// The user can record, clear and reset it; whether it differs from
        /// the built-in shortcut.
        case editable(overridden: Bool)
        /// A System Settings App Shortcut names its item: macOS's wins, and
        /// the row says so instead of offering a recorder.
        case systemSettings
        /// The Quick Detour hotkey, set on its own pane.
        case quickDetour
        /// Not changeable here; the reason.
        case fixed(String)
    }

    let title: String
    /// "⇧⌘T"; nil for none.
    let shortcut: String?
    let kind: Kind
    /// An editable row's shortcut is an enabled macOS shortcut (System
    /// Settings > Keyboard > Keyboard Shortcuts), which takes the key before
    /// Detour sees it: ⌃1–⌃9 when Mission Control's "Switch to Desktop N" is
    /// on (TASK-295). The row says so; the recorder stays enabled.
    var isTakenByMacOS = false
    /// Another command's shortcut fires on the same keystroke through a
    /// shifted character on this keyboard layout (TASK-343): a binding
    /// saved before the recorder refused such pairs, or one the layout
    /// chosen since makes collide. Both rows say so; neither is dropped.
    /// Or a shortcut held outside the commands (TASK-350: a menu item that
    /// is none of them, the Quick Detour hotkey) does, on the same keystroke
    /// or the very same shortcut; only this row says so.
    var sameKeystroke: SameKeystroke?

    struct SameKeystroke: Equatable {
        /// The other's title and shortcut ("Zoom In", "⌘+").
        let otherTitle: String
        let otherShortcut: String
        /// What the keystroke runs: the one holding Shift, whose key
        /// equivalent matches the press exactly (TASK-335's measurement).
        /// Nil when both are the very same shortcut (only with a holder
        /// outside the commands): which one fires was not measured.
        let runner: String?
        /// The holder when it is no command of the list (TASK-350).
        var outside: KeystrokeHolder?
    }

    /// - Parameters:
    ///   - systemShortcut: the App Shortcut macOS gives its item, if any.
    ///   - quickDetourShortcut: the Quick Detour hotkey's setting.
    ///   - macOSShortcuts: the enabled macOS shortcuts, as the menu key
    ///     equivalents they take (`SystemHotKey.menuKeyEquivalents`).
    ///   - sameKeystroke: the command sharing this one's keystroke, if any
    ///     (`ShortcutBindingStore.sameKeystrokeConflicts`), and the layout's
    ///     shifted equivalents, to say which of the two the keystroke runs.
    ///   - outsideHolder: else the holder outside the commands sharing it,
    ///     if any (`ShortcutResolution.outsideHolderConflicts`, TASK-350).
    static func make(for command: BrowserCommand, store: ShortcutBindingStore, systemShortcut: KeyEquivalent?,
                     quickDetourShortcut: HotKeyShortcut?, macOSShortcuts: [KeyEquivalent] = [],
                     sameKeystroke: BrowserCommand? = nil, outsideHolder: KeystrokeHolder? = nil,
                     shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent] = { _ in [] }) -> ShortcutRowState {
        switch command.bindability {
        case .quickDetourPane:
            return ShortcutRowState(title: command.title, shortcut: quickDetourShortcut?.displayString,
                                    kind: .quickDetour)
        case _ where systemShortcut != nil:
            return ShortcutRowState(title: command.title, shortcut: systemShortcut?.displayString,
                                    kind: .systemSettings)
        case .fixed(let reason):
            return ShortcutRowState(title: command.title, shortcut: command.keyEquivalent?.displayString,
                                    kind: .fixed(reason))
        case .bindable, .notListed:
            let key = store.keyEquivalent(for: command.id)
            var state = ShortcutRowState(title: command.title, shortcut: key?.displayString,
                                         kind: .editable(overridden: store.isOverridden(command.id)),
                                         isTakenByMacOS: key.map { key in macOSShortcuts.contains { $0.isSameShortcut(as: key) } } ?? false)
            if let key, let other = sameKeystroke, let otherKey = store.keyEquivalent(for: other.id) {
                // The Shift-held one is the exact match for the press.
                let runsThisOne = shiftedEquivalents(key).contains { $0.isSameShortcut(as: otherKey) }
                state.sameKeystroke = SameKeystroke(otherTitle: other.title, otherShortcut: otherKey.displayString ?? "",
                                                    runner: runsThisOne ? command.title : other.title)
            } else if let key, let holder = outsideHolder {
                let runner: String?
                if holder.key.isSameShortcut(as: key) {
                    runner = nil
                } else {
                    runner = shiftedEquivalents(key).contains { $0.isSameShortcut(as: holder.key) }
                        ? command.title : holder.title
                }
                state.sameKeystroke = SameKeystroke(otherTitle: holder.title,
                                                    otherShortcut: holder.key.displayString ?? "",
                                                    runner: runner, outside: holder)
            }
            return state
        }
    }

    /// The App Shortcut AppKit applies to `item`: it applies one by the
    /// item's title (or menu path) when the item enters a menu or is
    /// retitled, and its getters then return it; `userKeyEquivalent` is
    /// non-empty only while one applies (measured, TASK-327).
    static func systemShortcut(of item: NSMenuItem?) -> KeyEquivalent? {
        guard let item, !item.userKeyEquivalent.isEmpty else { return nil }
        return KeyEquivalent(item.keyEquivalent, item.keyEquivalentModifierMask)
    }
}

// MARK: - The pane

/// Settings > Shortcuts (TASK-327): every menu command with its shortcut,
/// grouped by menu and searchable. A click on a shortcut records a new one
/// (`ShortcutRecorderView`: Escape cancels, Delete clears); a shortcut another
/// command, the Quick Detour hotkey, Detour or macOS holds is refused with
/// the holder named on the line under the list. Each changed row has a reset
/// button, and Restore Defaults resets them all. A command a System Settings
/// App Shortcut names shows macOS's shortcut and says so.
final class ShortcutsSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate {
    private let store: ShortcutBindingStore
    private let mainMenu: () -> NSMenu?
    private let includesUpdater: Bool
    private let quickDetourShortcut: () -> HotKeyShortcut?
    private let systemHotKeys: () -> [SystemHotKey]
    private let systemHotKeyCharacter: (UInt16) -> String
    private let systemHotKeyShiftedCharacter: (UInt16) -> String
    private let systemShortcut: (CommandID) -> KeyEquivalent?
    private let shiftedEquivalents: (KeyEquivalent) -> [KeyEquivalent]
    /// Where the keyboard layout change notification is observed: the
    /// distributed center (tests pass their own, not to post system-wide).
    private let layoutChangeCenter: NotificationCenter
    /// The enabled macOS shortcuts as menu key equivalents, read once per
    /// reload (rows are marked with them, TASK-295).
    private var macOSShortcuts: [KeyEquivalent] = []
    /// The commands whose shortcuts share a keystroke on the layout, read
    /// once per reload (TASK-343): each mapped to the other.
    private(set) var sameKeystrokeConflicts: [CommandID: CommandID] = [:]
    /// The commands whose shortcuts share a keystroke with a holder outside
    /// the commands (a menu item that is none of them, the Quick Detour
    /// hotkey), read once per reload (TASK-350).
    private(set) var outsideConflicts: [CommandID: KeystrokeHolder] = [:]
    /// The keyboard layout change observer (a distributed notification).
    private var layoutObserver: NSObjectProtocol?

    private(set) var tableView: NSTableView!
    private(set) var searchField: NSSearchField!
    private(set) var restoreDefaultsButton: NSButton!
    private var emptyLabel: NSTextField!
    private var warningIcon: NSImageView!
    private(set) var warningLabel: SettingsWrappingLabel!
    private var listBottomToBody: NSLayoutConstraint!
    private var listBottomToWarning: NSLayoutConstraint!
    /// The warning line on the body's bottom while it shows, so the list
    /// takes the rest (TASK-343: with the line only held above the bottom,
    /// nothing gave the list a height and it collapsed while a refusal showed).
    private var warningToBody: NSLayoutConstraint!

    private(set) var items: [ShortcutList.Item] = []
    /// The command whose recorder records, while one does.
    private(set) var recordingCommand: CommandID?
    /// Why the recorder refused the last shortcut typed, while it records.
    private var refusal: String?
    private var reloadPending = false
    private var observers: [NSObjectProtocol] = []

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("shortcutRow")
    private static let headingIdentifier = NSUserInterfaceItemIdentifier("shortcutHeading")
    static let headingRowHeight: CGFloat = 26

    /// The width of a full-width line of text in the body.
    private static let textWidth = SettingsMetrics.windowWidth - 2 * SettingsMetrics.paneMargin

    /// - Parameters:
    ///   - store: the shortcuts it shows and edits; the shared one in the app.
    ///   - mainMenu: the menu bar conflicts are searched in.
    ///   - includesUpdater: whether Check for Updates… is listed (only a run
    ///     that starts Sparkle has the item).
    ///   - systemHotKeyCharacter: the character a key code types, for
    ///     matching macOS's shortcuts with the commands'; by default the
    ///     current layout's.
    ///   - systemHotKeyShiftedCharacter: the character a key code types
    ///     with Shift, so a macOS shortcut held with Shift also marks the
    ///     command on that character, and the recorder refuses a shifted
    ///     key whose character is an item's (TASK-335); by default the
    ///     current layout's.
    ///   - systemShortcut: the App Shortcut macOS gives a command's item;
    ///     by default read from the live item.
    ///   - shiftedEquivalents: the other key equivalents a shortcut's
    ///     keystroke fires on the layout (TASK-343: a reset, and two saved
    ///     shortcuts on one keystroke); by default the current layout's.
    ///   - layoutChangeCenter: the center posting
    ///     `KeyboardLayout.selectionDidChangeNotification`; by default the
    ///     distributed one.
    init(store: ShortcutBindingStore = .shared,
         mainMenu: @escaping () -> NSMenu? = { NSApp.mainMenu },
         includesUpdater: Bool = AppDelegate.startsUpdater,
         quickDetourShortcut: @escaping () -> HotKeyShortcut? = { QuickDetourHotKey.shared.settings.shortcut },
         systemHotKeys: @escaping () -> [SystemHotKey] = { HotKeyShortcutValidation.currentSystemHotKeys() },
         systemHotKeyCharacter: @escaping (UInt16) -> String = { SystemHotKey.layoutCharacter(forKeyCode: $0) },
         systemHotKeyShiftedCharacter: @escaping (UInt16) -> String = {
             KeyboardLayout.currentShiftedCharacter(forKeyCode: $0)
         },
         systemShortcut: ((CommandID) -> KeyEquivalent?)? = nil,
         shiftedEquivalents: @escaping (KeyEquivalent) -> [KeyEquivalent] = { KeyEquivalent.currentShiftedEquivalents($0) },
         layoutChangeCenter: NotificationCenter = DistributedNotificationCenter.default()) {
        self.store = store
        self.mainMenu = mainMenu
        self.includesUpdater = includesUpdater
        self.quickDetourShortcut = quickDetourShortcut
        self.systemHotKeys = systemHotKeys
        self.systemHotKeyCharacter = systemHotKeyCharacter
        self.systemHotKeyShiftedCharacter = systemHotKeyShiftedCharacter
        self.systemShortcut = systemShortcut ?? { id in
            ShortcutRowState.systemShortcut(of: CommandDispatch.menuItem(for: id, in: mainMenu()))
        }
        self.shiftedEquivalents = shiftedEquivalents
        self.layoutChangeCenter = layoutChangeCenter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Isolated: it tears down main-actor state; the object is released on
    /// the main thread in practice, and the teardown hops there otherwise.
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let layoutObserver { layoutChangeCenter.removeObserver(layoutObserver) }
    }

    override var paneDescription: String? {
        "Click a shortcut and type a new one; Delete removes it and Escape cancels. A shortcut needs ⌘ or ⌃, unless it is a function key. Shortcuts set in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts take precedence."
    }

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
    override var scrollsBodyAsWhole: Bool { false }

    /// Tall enough to show every row without scrolling the list.
    override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
        let search = searchField.fittingSize.height
        return max(fittingHeight, search + SettingsMetrics.rowGap + tableView.allRowsHeight + 2)
    }

    // MARK: - Building

    override func makeBody() -> NSView {
        let container = NSView()

        searchField = NSSearchField()
        searchField.placeholderString = "Search Commands"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityIdentifier("shortcutsSearch")
        // A search field is not named by its placeholder (TASK-342).
        searchField.setAccessibilityLabel(searchField.placeholderString)
        container.addSubview(searchField)

        restoreDefaultsButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restoreDefaultsButton.translatesAutoresizingMaskIntoConstraints = false
        restoreDefaultsButton.setAccessibilityIdentifier("shortcutsRestoreDefaults")
        restoreDefaultsButton.toolTip = "Give every command its built-in shortcut"
        container.addSubview(restoreDefaultsButton)

        let listContainer = SettingsListContainerView()
        container.addSubview(listContainer)

        let scroll = SettingsColumnScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        tableView = AutomationTableView()
        tableView.style = .plain
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.floatsGroupRows = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Shortcuts")
        scroll.documentView = tableView
        listContainer.addSubview(scroll)

        emptyLabel = NSTextField(labelWithString: "")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        listContainer.addSubview(emptyLabel)

        warningIcon = LinkRouteCellView.makeWarning().icon
        warningLabel = SettingsWrappingLabel(
            wrapping: "", estimatedWidth: Self.textWidth - LinkRouteCellView.warningIconWidth
                - LinkRouteCellView.warningIconGap)
        warningLabel.isHidden = true
        warningLabel.setAccessibilityIdentifier("shortcutsWarning")
        container.addSubview(warningIcon)
        container.addSubview(warningLabel)

        listBottomToBody = listContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        listBottomToWarning = warningLabel.topAnchor.constraint(equalTo: listContainer.bottomAnchor,
                                                                constant: LinkRouteCellView.lineGap)
        warningToBody = warningLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 240),
            restoreDefaultsButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            restoreDefaultsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            restoreDefaultsButton.leadingAnchor.constraint(greaterThanOrEqualTo: searchField.trailingAnchor,
                                                           constant: SettingsMetrics.rowGap),

            listContainer.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: SettingsMetrics.rowGap),
            listContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listBottomToBody,

            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -1),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            warningIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            warningIcon.centerYAnchor.constraint(equalTo: warningLabel.topAnchor,
                                                 constant: LinkRouteCellView.warningFirstLineCenter),
            warningLabel.leadingAnchor.constraint(equalTo: warningIcon.trailingAnchor,
                                                  constant: LinkRouteCellView.warningIconGap),
            warningLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            warningLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        for (name, object) in [(ShortcutBindingStore.didChangeNotification, store as AnyObject?),
                               (QuickDetourHotKeySettings.didChangeNotification, nil)] {
            observers.append(NotificationCenter.default.addMainObserver(forName: name, object: object) { [weak self] _ in
                self?.scheduleReload()
            })
        }
        // Another keyboard layout can make two saved shortcuts one keystroke
        // (TASK-343), or stop doing so: the rows are marked again.
        layoutObserver = layoutChangeCenter.addMainObserver(
            forName: KeyboardLayout.selectionDidChangeNotification, object: nil) { [weak self] _ in
            self?.scheduleReload()
        }
        reload()
        return container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // An App Shortcut changed in System Settings meanwhile.
        reload()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // The Quick Detour hotkey is suspended while a recorder records.
        endRecording()
    }

    // MARK: - State

    private var query: String { searchField?.stringValue ?? "" }

    private func includes(_ command: BrowserCommand) -> Bool {
        command.responder != .updater || includesUpdater
    }

    /// Rebuilds the rows. Deferred while a recorder records: its row must
    /// not be rebuilt under it (it is reloaded when recording ends).
    func reload() {
        guard recordingCommand == nil else {
            reloadPending = true
            return
        }
        reloadPending = false
        listedQuery = query
        items = ShortcutList.items(in: BrowserCommands.menus, query: query, includes: includes)
        macOSShortcuts = systemHotKeys().flatMap {
            $0.menuKeyEquivalents(character: systemHotKeyCharacter, shiftedCharacter: systemHotKeyShiftedCharacter)
        }
        sameKeystrokeConflicts = store.sameKeystrokeConflicts(shiftedEquivalents: shiftedEquivalents)
        outsideConflicts = ShortcutResolution.outsideHolderConflicts(of: store.effectiveKeys, holders: outsideHolders(),
                                                                     shiftedEquivalents: shiftedEquivalents)
        tableView.reloadData()
        emptyLabel.stringValue = items.isEmpty ? "No commands match “\(query)”." : ""
        emptyLabel.isHidden = !items.isEmpty
        restoreDefaultsButton.isEnabled = store.hasOverrides
        updateWarning()
        contentHeightDidChange()
    }

    /// Changes come in bursts (a recorded shortcut, the reset that follows a
    /// refused one): one reload after them.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reloadPending else { return }
            self.reload()
        }
    }

    func rowState(for command: BrowserCommand) -> ShortcutRowState {
        ShortcutRowState.make(for: command, store: store, systemShortcut: systemShortcut(command.id),
                              quickDetourShortcut: quickDetourShortcut(), macOSShortcuts: macOSShortcuts,
                              sameKeystroke: sameKeystrokeConflicts[command.id].flatMap(BrowserCommands.command(withID:)),
                              outsideHolder: outsideConflicts[command.id], shiftedEquivalents: shiftedEquivalents)
    }

    /// The shortcuts held outside the store's commands (TASK-350): the live
    /// menu's other items, and the Quick Detour hotkey named from its
    /// setting rather than by its File item, as the recorder names it.
    private func outsideHolders() -> [KeystrokeHolder] {
        HotKeyShortcutValidation.keystrokeHolders(
            in: mainMenu(),
            isExcluded: { [store] item in
                store.isCommandItem(item) || item.identifier?.rawValue == BrowserCommands.newQuickDetourWindow.id.rawValue
            },
            key: { item in
                // A command's item the store does not write (the fixed Edit
                // commands) holds its registry key, though AppKit may have
                // cleared it on the item: it gives a key equivalent to one
                // item of the bar only, and a binding saved on Copy's ⌘C took
                // it at launch (measured, TASK-350). An App Shortcut on the
                // item wins.
                if let raw = item.identifier?.rawValue,
                   let command = BrowserCommands.command(withID: CommandID(rawValue: raw)),
                   item.userKeyEquivalent.isEmpty {
                    return command.keyEquivalent
                }
                return HotKeyShortcutValidation.liveKeyEquivalent(of: item)
            },
            quickDetourShortcut: quickDetourShortcut())
    }

    /// Why `shortcut` cannot be `id`'s, or nil.
    func problem(for shortcut: HotKeyShortcut, command id: CommandID) -> HotKeyShortcutProblem? {
        HotKeyShortcutValidation.problem(
            for: shortcut, rules: .appShortcut, menu: mainMenu(),
            // Its own item, and the Quick Detour item (named apart, from its setting).
            isOwnItem: { item in
                let raw = item.identifier?.rawValue
                return raw == id.rawValue || raw == BrowserCommands.newQuickDetourWindow.id.rawValue
            },
            quickDetourShortcut: quickDetourShortcut(), systemHotKeys: systemHotKeys(),
            shiftedCharacter: systemHotKeyShiftedCharacter)
    }

    private func updateWarning() {
        let shown = warningLabel.isHidden ? nil : warningLabel.stringValue
        LinkRouteCellView.setWarning(refusal, icon: warningIcon, label: warningLabel)
        // Off first, so the two are never on together.
        if refusal == nil {
            NSLayoutConstraint.deactivate([listBottomToWarning, warningToBody])
            listBottomToBody.isActive = true
        } else {
            listBottomToBody.isActive = false
            NSLayoutConstraint.activate([listBottomToWarning, warningToBody])
        }
        if shown != refusal { contentHeightDidChange() }
    }

    /// The row view of `id`'s command, if it is on screen.
    func rowView(for id: CommandID) -> ShortcutRowView? {
        guard let row = items.firstIndex(of: .command(id)) else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ShortcutRowView
    }

    private func endRecording() {
        guard let id = recordingCommand else { return }
        rowView(for: id)?.recorder.endRecording()
    }

    // MARK: - Actions

    /// The query the rows were last built for: the field's action and its
    /// text-change callback both report one edit.
    private var listedQuery: String?

    @objc private func searchChanged() {
        reloadIfQueryChanged()
    }

    func controlTextDidChange(_ obj: Notification) {
        reloadIfQueryChanged()
    }

    private func reloadIfQueryChanged() {
        guard query != listedQuery else { return }
        reload()
    }

    @objc private func restoreDefaults() {
        endRecording()
        store.resetAll()
    }

    /// Back to the built-in shortcut, unless another command's binding now
    /// holds it: the reset would leave this one with none (an override wins
    /// over a default), so it is refused with the holder named. Also refused
    /// when the built-in shortcut and another command's binding are one
    /// keystroke on this keyboard through a shifted character (TASK-343:
    /// Zoom In's ⌘+ while another command holds ⇧⌘=), as recording it is,
    /// and when a holder outside the commands has it or its keystroke
    /// (TASK-350: the Quick Detour hotkey set to the default, an AppKit item).
    func reset(_ id: CommandID) {
        endRecording()
        if let builtIn = BrowserCommands.command(withID: id)?.keyEquivalent {
            if let holder = store.command(holding: builtIn, except: id) {
                refuseReset("\(builtIn.displayString ?? "") is now \(holder.title)'s shortcut. Change that one first.")
                return
            }
            if let shared = store.command(sharingKeystrokeWith: builtIn, except: id,
                                          shiftedEquivalents: shiftedEquivalents) {
                refuseReset(Self.sameKeystrokeRefusal(builtIn: builtIn, held: shared.key, holder: shared.command.title))
                return
            }
            if let holder = ShortcutResolution.outsideHolderConflicts(
                of: [(id: id, key: builtIn)], holders: outsideHolders(), shiftedEquivalents: shiftedEquivalents)[id] {
                refuseReset(Self.outsideRefusal(builtIn: builtIn, holder: holder))
                return
            }
        }
        refusal = nil
        updateWarning()
        store.reset(id)
    }

    private func refuseReset(_ message: String) {
        NSSound.beep()
        refusal = message
        updateWarning()
    }

    static func sameKeystrokeRefusal(builtIn: KeyEquivalent, held: KeyEquivalent, holder: String) -> String {
        "\(builtIn.displayString ?? "") and \(held.displayString ?? "") are one keystroke on this keyboard, and "
            + "\(held.displayString ?? "") is now \(holder)'s shortcut. Change that one first."
    }

    /// A reset refused for a holder outside the commands (TASK-350): "⌘R is
    /// the Quick Detour shortcut (Settings > Quick Detour). Change that one
    /// first." A menu item that is no command cannot be changed here.
    static func outsideRefusal(builtIn: KeyEquivalent, holder: KeystrokeHolder) -> String {
        let builtInShown = builtIn.displayString ?? ""
        let held = holder.key.displayString ?? ""
        let start = holder.key.isSameShortcut(as: builtIn)
            ? "\(builtInShown) is "
            : "\(builtInShown) and \(held) are one keystroke on this keyboard, and \(held) is "
        switch holder.kind {
        case .menuItem: return start + holder.phrase + ", which cannot be changed here."
        case .quickDetour: return start + holder.phrase + ". Change that one first."
        }
    }

    private func recordingChanged(_ recording: Bool, command id: CommandID) {
        if recording {
            // One recorder at a time: another one's recording ends first.
            if let other = recordingCommand, other != id { rowView(for: other)?.recorder.endRecording() }
            recordingCommand = id
        } else if recordingCommand == id {
            recordingCommand = nil
        }
        // A press of the Quick Detour shortcut reaches the recorder (which
        // refuses it) instead of opening the launcher.
        QuickDetourHotKey.shared.setRecording(recordingCommand != nil)
        refusal = nil
        updateWarning()
        if recordingCommand == nil, reloadPending { reload() }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard items.indices.contains(row), case .menu = items[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        self.tableView(tableView, isGroupRow: row) ? Self.headingRowHeight : SettingsMetrics.listRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        switch items[row] {
        case .menu(let title):
            let cell = (tableView.makeView(withIdentifier: Self.headingIdentifier, owner: nil) as? NSTableCellView)
                ?? Self.makeHeadingCell()
            cell.textField?.stringValue = title
            return cell
        case .command(let id):
            guard let command = BrowserCommands.command(withID: id) else { return nil }
            let cell = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? ShortcutRowView)
                ?? ShortcutRowView(identifier: Self.rowIdentifier)
            configure(cell, for: command)
            return cell
        }
    }

    private static func makeHeadingCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = headingIdentifier
        let label = NSTextField.settingsSectionTitle("")
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure(_ cell: ShortcutRowView, for command: BrowserCommand) {
        let id = command.id
        cell.show(rowState(for: command), commandID: id)
        let recorder = cell.recorder
        recorder.problem = { [weak self] shortcut in self?.problem(for: shortcut, command: id) }
        recorder.onChange = { [weak self] shortcut in
            self?.store.setKeyEquivalent(shortcut?.menuKeyEquivalent, for: id)
        }
        recorder.onRecordingChange = { [weak self] recording in self?.recordingChanged(recording, command: id) }
        recorder.onRefuse = { [weak self] message in
            guard let self, self.recordingCommand == id else { return }
            self.refusal = message
            self.updateWarning()
        }
        cell.onReset = { [weak self] in self?.reset(id) }
        cell.onShowQuickDetourPane = {
            SettingsWindowController.shared.showPane(named: SettingsWindowController.quickDetourPaneName)
        }
    }
}

// MARK: - A row

/// A command's row: its title, a note when its shortcut is set elsewhere,
/// the recorder, and the reset button (shown once the shortcut differs from
/// the built-in one).
final class ShortcutRowView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(labelWithString: "")
    let quickDetourLink = NSButton()
    let recorder = ShortcutRecorderView()
    let resetButton: NSButton

    var onReset: (() -> Void)?
    var onShowQuickDetourPane: (() -> Void)?
    private(set) var state: ShortcutRowState?

    init(identifier: NSUserInterfaceItemIdentifier) {
        let image = NSImage(systemSymbolName: "arrow.uturn.backward.circle.fill",
                            accessibilityDescription: "Restore Default")!
        resetButton = NSButton(image: image, target: nil, action: nil)
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)
        textField = titleLabel

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        addSubview(noteLabel)

        quickDetourLink.isBordered = false
        quickDetourLink.setButtonType(.momentaryChange)
        quickDetourLink.attributedTitle = NSAttributedString(
            string: "Change in \(QuickDetour.displayName) Settings",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
        quickDetourLink.attributedAlternateTitle = quickDetourLink.attributedTitle
        quickDetourLink.target = self
        quickDetourLink.action = #selector(showQuickDetourPane)
        quickDetourLink.translatesAutoresizingMaskIntoConstraints = false
        quickDetourLink.setAccessibilityIdentifier("shortcutsQuickDetourLink")
        addSubview(quickDetourLink)

        recorder.placeholder = "None"
        addSubview(recorder)

        resetButton.isBordered = false
        resetButton.bezelStyle = .regularSquare
        resetButton.imageScaling = .scaleProportionallyDown
        resetButton.contentTintColor = .tertiaryLabelColor
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resetButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            noteLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            noteLabel.trailingAnchor.constraint(equalTo: recorder.leadingAnchor, constant: -8),
            noteLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            quickDetourLink.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            quickDetourLink.trailingAnchor.constraint(equalTo: recorder.leadingAnchor, constant: -8),
            quickDetourLink.centerYAnchor.constraint(equalTo: centerYAnchor),
            recorder.centerYAnchor.constraint(equalTo: centerYAnchor),
            recorder.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -6),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            resetButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 16),
            resetButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: ShortcutRowState, commandID id: CommandID) {
        self.state = state
        titleLabel.stringValue = state.title
        recorder.endRecording()
        recorder.shortcutLabel = state.shortcut
        recorder.setAccessibilityIdentifier("shortcut.\(id.rawValue)")
        // The recorder carries the row's name ("Zoom In shortcut", more
        // specific than the title), so the title is not read before it as
        // text of its own (TASK-342).
        SettingsSwitchRow.name(recorder, by: titleLabel, as: "\(state.title) shortcut")
        resetButton.setAccessibilityIdentifier("shortcutReset.\(id.rawValue)")
        resetButton.setAccessibilityLabel("Restore the default shortcut of \(state.title)")
        noteLabel.isHidden = true
        noteLabel.textColor = .secondaryLabelColor
        quickDetourLink.isHidden = true
        resetButton.isHidden = true
        toolTip = nil
        switch state.kind {
        case .editable(let overridden):
            recorder.isEnabled = true
            resetButton.isHidden = !overridden
            if overridden, let builtIn = BrowserCommands.command(withID: id)?.keyEquivalent?.displayString {
                resetButton.toolTip = "Restore \(builtIn)"
            } else {
                resetButton.toolTip = "Restore: no shortcut"
            }
            if state.isTakenByMacOS {
                noteLabel.stringValue = Self.takenByMacOSNote
                noteLabel.textColor = .systemOrange
                noteLabel.isHidden = false
                toolTip = Self.takenByMacOSToolTip(state.shortcut ?? "")
            } else if let same = state.sameKeystroke {
                // macOS's mark first: it takes the key before either command.
                noteLabel.stringValue = Self.sameKeystrokeNote(same)
                noteLabel.textColor = .systemOrange
                noteLabel.isHidden = false
                toolTip = Self.sameKeystrokeToolTip(same, shortcut: state.shortcut ?? "")
            }
        case .systemSettings:
            recorder.isEnabled = false
            noteLabel.stringValue = "Set in System Settings"
            noteLabel.isHidden = false
            toolTip = "System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts gives this command its shortcut."
        case .quickDetour:
            recorder.isEnabled = false
            quickDetourLink.isHidden = false
        case .fixed(let reason):
            recorder.isEnabled = false
            toolTip = reason
        }
    }

    static let takenByMacOSNote = "Used by macOS"

    static func sameKeystrokeNote(_ same: ShortcutRowState.SameKeystroke) -> String {
        "Same key as \(same.otherTitle)"
    }

    static func sameKeystrokeToolTip(_ same: ShortcutRowState.SameKeystroke, shortcut: String) -> String {
        guard let holder = same.outside else {
            return "\(shortcut) and \(same.otherTitle)'s \(same.otherShortcut) are one keystroke on this keyboard, "
                + "which runs \(same.runner ?? same.otherTitle). Record another shortcut for one of them."
        }
        // A holder outside the list: only this row can change (TASK-350).
        guard let runner = same.runner else {
            switch holder.kind {
            case .quickDetour:
                // A Carbon hotkey takes the key before any menu.
                return "\(shortcut) is also \(holder.phrase), which takes the key first while it is on. "
                    + "Record another shortcut for this command."
            case .menuItem:
                // macOS keeps a key equivalent on one menu item only (TASK-350).
                return "\(shortcut) is also \(holder.phrase), and only one of them can have it. "
                    + "Record another shortcut for this command."
            }
        }
        return "\(shortcut) and \(same.otherShortcut), \(holder.phrase), are one keystroke on this keyboard, which "
            + "runs \(runner). Record another shortcut for this command."
    }

    static func takenByMacOSToolTip(_ shortcut: String) -> String {
        "macOS takes \(shortcut) before Detour sees it (System Settings > Keyboard > Keyboard Shortcuts; ⌃1 to ⌃9 are Mission Control's Switch to Desktop when turned on). Turn it off there, or record another shortcut."
    }

    @objc private func resetClicked() { onReset?() }

    @objc private func showQuickDetourPane() { onShowQuickDetourPane?() }
}
