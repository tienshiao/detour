import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-328: every on/off setting in the Settings window is a switch with a
/// label, laid out like the Extensions pane's switch rows (the label, then
/// the switch 8 pt after it, centred on each other). The switches keep the
/// accessibility identifiers the checkboxes had and take their label's text
/// as their accessible name; the label is plain text, so a click on it does
/// nothing, as on Profiles and Extensions.
nonisolated final class SettingsSwitchRowTests: XCTestCase {

    /// The converted settings: identifier and label.
    @MainActor private static let generalSwitches = [
        ("peekEnabled", "Open links from pinned tabs and favorites in a Peek"),
        ("automationEnabled", "Let AI agents and scripts control Detour (MCP)"),
        ("automationAllowPrivate", "Allow agents to use Private windows"),
        ("automationAgentPointer", "Show where agents click and type"),
    ]
    @MainActor private static let quickDetourSwitches = [
        ("quickDetourHotKeyEnabled", "Open \(QuickDetour.displayName) from any app"),
        ("quickDetourOptionCommandClick", "Open links and sidebar tabs in \(QuickDetour.displayName) with ⌥⌘-click"),
    ]

    private var savedPeek: Bool?
    private var savedOptionCommandClick: Bool?

    @MainActor override func setUp() async throws {
        try await super.setUp()
        savedPeek = PeekSettings.shared.isEnabled
        savedOptionCommandClick = QuickDetourSettings.shared.isOptionCommandClickEnabled
    }

    @MainActor override func tearDown() async throws {
        if let savedPeek { PeekSettings.shared.isEnabled = savedPeek }
        if let savedOptionCommandClick { QuickDetourSettings.shared.isOptionCommandClickEnabled = savedOptionCommandClick }
        try await super.tearDown()
    }

    // MARK: - Helpers

    @MainActor private func laidOut<Pane: SettingsPaneViewController>(_ pane: Pane) -> Pane {
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 900))
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor private func control(_ identifier: String, in pane: SettingsPaneViewController) -> NSView? {
        descendants(of: pane.view).first { $0.accessibilityIdentifier() == identifier }
    }

    /// A view's alignment rectangle (what Auto Layout places: a label's frame
    /// is 2 pt wider on each side) in the pane's coordinates.
    @MainActor private func placed(_ view: NSView, in pane: SettingsPaneViewController) -> NSRect {
        guard let superview = view.superview else { return .zero }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: pane.view)
    }

    /// A button's accessibility role is its cell's (the view reports AXUnknown).
    @MainActor private func role(of button: NSButton) -> NSAccessibility.Role? {
        button.cell?.accessibilityRole()
    }

    @MainActor private func allPanes() throws -> [SettingsPaneViewController] {
        [
            GeneralSettingsViewController(), SpacesSettingsViewController(),
            LinksSettingsViewController(linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue()))),
            QuickDetourSettingsViewController(), ProfilesSettingsViewController(),
            SearchSettingsViewController(
                siteSearches: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))),
            ShortcutsSettingsViewController(store: ShortcutBindingStore(defaults: throwawayDefaults())),
            ExtensionsSettingsViewController(), ContentBlockerSettingsViewController(),
        ]
    }

    /// A defaults suite of its own, gone after the test.
    @MainActor private func throwawayDefaults() -> UserDefaults {
        let suite = "SettingsSwitchRowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - No checkboxes

    @MainActor func testACheckboxIsRecognisedByItsAccessibilityRole() {
        // The guard below relies on this; a switch is not an NSButton at all.
        XCTAssertEqual(role(of: NSButton(checkboxWithTitle: "x", target: nil, action: nil)), .checkBox)
        XCTAssertNotEqual(role(of: NSButton(title: "x", target: nil, action: nil)), .checkBox)
    }

    /// Each pane as it first shows (no selection made): the detail columns
    /// built later for a selection are checked at runtime.
    @MainActor func testNoSettingsPaneUsesACheckbox() throws {
        let panes = try allPanes()
        XCTAssertEqual(panes.count, SettingsWindowController.paneOrder.count, "every pane in the toolbar")
        for pane in panes {
            _ = laidOut(pane)
            let checkboxes = descendants(of: pane.view)
                .compactMap { $0 as? NSButton }
                .filter { role(of: $0) == .checkBox }
            XCTAssertEqual(checkboxes.map(\.title), [], "\(type(of: pane)) has checkboxes")
        }
    }

    // MARK: - The converted rows

    /// General's and Quick Detour's switches are in grouped forms (TASK-338),
    /// mini as System Settings' are.
    @MainActor func testTheConvertedSettingsAreSwitchesNamedByTheirLabels() throws {
        let cases: [(SettingsPaneViewController, [(String, String)], NSControl.ControlSize)] = [
            (GeneralSettingsViewController(), Self.generalSwitches, .mini),
            (QuickDetourSettingsViewController(), Self.quickDetourSwitches, .mini),
        ]
        for (pane, switches, size) in cases {
            _ = laidOut(pane)
            for (identifier, title) in switches {
                let toggle = try XCTUnwrap(control(identifier, in: pane) as? NSSwitch, "\(identifier) is a switch")
                XCTAssertEqual(toggle.accessibilityLabel(), title, identifier)
                XCTAssertEqual(toggle.controlSize, size, identifier)
            }
        }
    }

    /// General's switches (TASK-338: a grouped form) end on the form's right
    /// edge, centred on their names' first line, and the names start on its
    /// text edge. (Quick Detour's: `testQuickDetoursControlsShareTheFormsRightEdge`.)
    @MainActor func testGeneralsSwitchesShareTheFormsRightEdge() throws {
        let pane = laidOut(GeneralSettingsViewController())
        let right = pane.view.bounds.width - SettingsMetrics.paneMargin - SettingsMetrics.formRowInsetX
        let left = SettingsMetrics.paneMargin + SettingsMetrics.formRowInsetX
        for (identifier, title) in Self.generalSwitches {
            let toggle = try XCTUnwrap(control(identifier, in: pane) as? NSSwitch)
            let label = try XCTUnwrap(formRow(of: toggle)?.titleLabel, identifier)
            XCTAssertEqual(label.stringValue, title)
            XCTAssertEqual(placed(toggle, in: pane).maxX, right, accuracy: 0.5, identifier)
            XCTAssertEqual(placed(label, in: pane).minX, left, accuracy: 0.5, identifier)
        }
    }

    /// A click on a label does nothing (as on Profiles and Extensions): it
    /// is plain, unselectable text, not a control with an action.
    @MainActor func testTheLabelsArePlainText() throws {
        for (pane, switches) in [(laidOut(GeneralSettingsViewController()) as SettingsPaneViewController,
                                  Self.generalSwitches),
                                 (laidOut(QuickDetourSettingsViewController()), Self.quickDetourSwitches)] {
            for (identifier, _) in switches {
                let toggle = try XCTUnwrap(control(identifier, in: pane) as? NSSwitch)
                let label = try XCTUnwrap(visibleLabel(of: toggle))
                XCTAssertFalse(label.isEditable, identifier)
                XCTAssertFalse(label.isSelectable, identifier)
                XCTAssertNil(label.action, identifier)
            }
        }
    }

    /// The hotkey's recorder is the row right under the switch's, in the
    /// same group (TASK-338), titled "Shortcut" on its baseline and named
    /// "Quick Detour shortcut" as before; it stays usable with the hotkey
    /// off (it is also the menu item's shortcut).
    @MainActor func testTheShortcutRecorderIsARowBelowTheHotKeySwitch() throws {
        let pane = laidOut(QuickDetourSettingsViewController())
        let toggle = try XCTUnwrap(control("quickDetourHotKeyEnabled", in: pane) as? NSSwitch)
        let recorder = try XCTUnwrap(control("quickDetourHotKeyShortcut", in: pane) as? ShortcutRecorderView)
        let switchRow = try XCTUnwrap(formRow(of: toggle))
        let recorderRow = try XCTUnwrap(formRow(of: recorder))
        XCTAssertEqual(recorderRow.superview, switchRow.superview, "one group")
        XCTAssertEqual(placed(switchRow, in: pane).minY, placed(recorderRow, in: pane).maxY, accuracy: 0.5,
                       "right under it (the pane's view is not flipped)")
        XCTAssertEqual(recorderRow.titleLabel?.stringValue, "Shortcut")
        XCTAssertEqual(recorder.accessibilityLabel(), "\(QuickDetour.displayName) shortcut")
        XCTAssertEqual(placed(try XCTUnwrap(recorderRow.titleLabel), in: pane).minX,
                       placed(try XCTUnwrap(switchRow.titleLabel), in: pane).minX, accuracy: 0.5)
        XCTAssertEqual(placed(recorder, in: pane).maxX, placed(toggle, in: pane).maxX, accuracy: 0.5)
        XCTAssertTrue(recorder.isEnabled, "the pane never turns it off")
        XCTAssertTrue(recorder.frame.width > 0)
    }

    /// Quick Detour's controls (two switches, the recorder, the idle pop-up)
    /// end on one right edge, and their names start on one left edge.
    @MainActor func testQuickDetoursControlsShareTheFormsRightEdge() throws {
        let pane = laidOut(QuickDetourSettingsViewController())
        let controls = try ["quickDetourHotKeyEnabled", "quickDetourHotKeyShortcut", "quickDetourOptionCommandClick",
                            "quickDetourIdleTimeout"].map { try XCTUnwrap(control($0, in: pane), $0) }
        let rights = controls.map { placed($0, in: pane).maxX }
        let lefts = try controls.map { placed(try XCTUnwrap(formRow(of: $0)?.titleLabel), in: pane).minX }
        let body = pane.view.bounds.width - SettingsMetrics.paneMargin
        for right in rights { XCTAssertEqual(right, body - SettingsMetrics.formRowInsetX, accuracy: 0.5) }
        for left in lefts { XCTAssertEqual(left, SettingsMetrics.paneMargin + SettingsMetrics.formRowInsetX, accuracy: 0.5) }
    }

    /// The form row a control sits in.
    @MainActor private func formRow(of view: NSView) -> SettingsFormRow? {
        var current = view.superview
        while let candidate = current, !(candidate is SettingsFormRow) { current = candidate.superview }
        return current as? SettingsFormRow
    }

    // MARK: - Accessibility (TASK-336)

    /// The text beside a switch that names it on screen: the label in its
    /// row (a switch row, a group's row) or in its grid row's label column
    /// (Profiles).
    @MainActor private func visibleLabel(of toggle: NSSwitch) -> NSTextField? {
        // A grouped form's row (TASK-338: every pane): its name.
        if let row = formRow(of: toggle) { return row.titleLabel }
        // A row laid out by hand (the sidebar popover): its one label.
        if let row = toggle.superview as? NSStackView {
            return row.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        }
        return toggle.superview?.subviews.compactMap { $0 as? NSTextField }.first
    }

    /// What an Accessibility client gets from `view` down: the unignored
    /// elements AppKit hands out, as VoiceOver walks them.
    @MainActor private func accessibilityElements(under view: NSView) -> [any NSAccessibilityProtocol] {
        func walk(_ element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
            let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            return children + children.flatMap(walk)
        }
        return walk(view)
    }

    /// The static texts of that tree, by their text.
    @MainActor private func staticTexts(under view: NSView) -> [String] {
        accessibilityElements(under: view)
            .filter { $0.accessibilityRole() == .staticText }
            .compactMap { ($0.accessibilityValue() as? String) ?? ($0 as? NSCell)?.stringValue }
    }

    /// Each pane as it first shows, Profiles with a profile selected (its
    /// grid's switches and filter-list group). Extension switches need an
    /// installed extension and are checked at runtime.
    @MainActor private func panesWithSwitches() throws -> [SettingsPaneViewController] {
        let panes = try allPanes()
        for pane in panes {
            _ = laidOut(pane)
            pane.viewWillAppear()
            pane.view.layoutSubtreeIfNeeded()
        }
        return panes
    }

    /// Every switch has an accessible name, and it is the text shown beside
    /// it: VoiceOver says what the screen says.
    @MainActor func testEverySwitchIsNamedByTheLabelBesideIt() throws {
        var checked = 0
        for pane in try panesWithSwitches() {
            for toggle in descendants(of: pane.view).compactMap({ $0 as? NSSwitch }) {
                let place = "\(type(of: pane)) \(toggle.accessibilityIdentifier())"
                let label = try XCTUnwrap(visibleLabel(of: toggle), "\(place): a label beside it")
                XCTAssertFalse(label.stringValue.isEmpty, place)
                XCTAssertEqual(toggle.accessibilityLabel(), label.stringValue, place)
                checked += 1
            }
        }
        // General's 3, Quick Detour's 2, Profiles' 3 and its 4 filter lists,
        // Content Blocking's tracking list (TASK-337).
        XCTAssertGreaterThanOrEqual(checked, 13)
    }

    /// The setting is one element: the switch, named; its label is not also
    /// read as text of its own. The walk does see other text (a section
    /// title), so an empty result is not a walk that sees nothing.
    @MainActor func testTheAccessibilityTreeHasEachSwitchOnceAndNotItsLabel() throws {
        for pane in try panesWithSwitches() {
            let switches = descendants(of: pane.view).compactMap { $0 as? NSSwitch }
            guard !switches.isEmpty else { continue }
            let elements = accessibilityElements(under: pane.view)
            let texts = staticTexts(under: pane.view)
            XCTAssertFalse(texts.isEmpty, "\(type(of: pane)): the walk reaches the pane's text")
            for toggle in switches where !toggle.isHiddenOrHasHiddenAncestor {
                let name = try XCTUnwrap(toggle.accessibilityLabel(), "\(type(of: pane))")
                XCTAssertTrue(elements.contains { $0 === toggle }, "\(name): the switch is in the tree")
                XCTAssertEqual(toggle.accessibilitySubrole(), .switch, name)
                XCTAssertFalse(texts.contains(name), "\(type(of: pane)): \"\(name)\" is read as text too")
            }
        }
    }

    // MARK: - Every control (TASK-342)

    /// The roles an Accessibility client stops on as controls.
    private static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .popUpButton, .textField, .radioButton, .radioGroup, .image, .link, .comboBox,
        .slider, .menuButton,
    ]

    private static let scrollBarParts: Set<NSAccessibility.Subrole> = [
        .incrementArrow, .decrementArrow, .incrementPage, .decrementPage,
    ]

    /// "Name:" and "Name" are the same label to a sighted user.
    private static func normalized(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasSuffix(":") { text.removeLast() }
        return text
    }

    /// The name an Accessibility client reads for an element: its title, else
    /// its label (axsettings' rule, without the title UI element no row uses).
    /// A control is read through its cell, and the cell answers with the
    /// control's label (what the running app's Accessibility shows), which a
    /// cell asked in process does not forward: so the control's too.
    @MainActor private func accessibleName(_ element: any NSAccessibilityProtocol) -> String? {
        var names = [element.accessibilityTitle(), element.accessibilityLabel()]
        if let control = (element as? NSCell)?.controlView {
            names += [control.accessibilityTitle(), control.accessibilityLabel()]
        }
        return names.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Every control `view` shows an Accessibility client has a name, and no
    /// text of the same tree reads that name again ("Name:" beside a field
    /// named Name); a shortcut recorder says its shortcut once, as its value.
    /// Returns how many controls it checked.
    @MainActor @discardableResult
    private func assertEveryControlIsNamedOnce(in view: NSView, _ place: String,
                                               file: StaticString = #filePath, line: UInt = #line) -> Int {
        let elements = accessibilityElements(under: view)
        let texts = Set(staticTexts(under: view).map(Self.normalized))
        var checked = 0
        for element in elements {
            guard let role = element.accessibilityRole(), Self.controlRoles.contains(role) else { continue }
            // A scroll bar's arrows and page areas are AppKit's own.
            let subrole = element.accessibilitySubrole()
            if let subrole, Self.scrollBarParts.contains(subrole) { continue }
            let what = "\(place): \(role.rawValue) \(subrole?.rawValue ?? "") \(element.accessibilityIdentifier())"
            guard let name = accessibleName(element) else {
                XCTFail("\(what) has no accessible name", file: file, line: line)
                continue
            }
            XCTAssertFalse(texts.contains(Self.normalized(name)), "\(what): \"\(name)\" is also read as text",
                           file: file, line: line)
            checked += 1
        }
        for recorder in ([view] + descendants(of: view)).compactMap({ $0 as? ShortcutRecorderView }) {
            XCTAssertEqual(staticTexts(under: recorder), [], "\(place): the recorder's shortcut is read once",
                           file: file, line: line)
        }
        return checked
    }

    /// Every pane as it first shows, and the states it shows later: a
    /// profile of the user's (its Name field) with a custom user agent,
    /// route rows, the site search sheet, Shortcuts rows of each kind.
    /// Extensions with an extension installed are checked by
    /// SettingsProfilesExtensionsFormTests' header test and at runtime.
    @MainActor func testEveryControlInEveryPaneHasOneAccessibleName() throws {
        var checked = 0
        for pane in try panesWithSwitches() {
            checked += assertEveryControlIsNamedOnce(in: pane.view, "\(type(of: pane))")
        }

        let profile = TabStore.shared.addProfile(name: "AX Test \(UUID().uuidString.prefix(6))")
        addTeardownBlock { @MainActor in
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        profile.userAgentMode = .custom
        profile.customUserAgent = "Test Agent/1.0"
        let profiles = laidOut(ProfilesSettingsViewController())
        profiles.viewWillAppear()
        let table = try XCTUnwrap(descendants(of: profiles.view).compactMap { $0 as? NSTableView }.first)
        let listed = TabStore.shared.profiles.filter { !$0.isIncognito || $0.id == TabStore.incognitoProfileID }
        let index = try XCTUnwrap(listed.firstIndex { $0.id == profile.id })
        table.deselectAll(nil)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        profiles.view.layoutSubtreeIfNeeded()
        let fields = descendants(of: profiles.view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(Set(fields.compactMap { $0.accessibilityLabel() }), ["Name", "Custom string"])
        checked += assertEveryControlIsNamedOnce(in: profiles.view, "Profiles (a custom user agent)")

        // A route row: its line labels (URL, From app, Open in) and their
        // symbols are not read after the controls they label.
        let route = LinkRouteCellView()
        XCTAssertEqual(assertEveryControlIsNamedOnce(in: route, "a route row"), 6,
                       "drag handle, URL condition, Pattern, Remove Route, From app, Open in")
        XCTAssertEqual(staticTexts(under: route), [])

        let form = SiteSearchForm(store: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue())),
                                  editing: nil)
        XCTAssertEqual(assertEveryControlIsNamedOnce(in: form, "the site search sheet"), 3)
        XCTAssertEqual([form.nameField, form.keywordField, form.addressField].map { $0.accessibilityLabel() },
                       ["Name", "Keyword", "Address"])

        for (state, id) in [
            (ShortcutRowState(title: "Zoom In", shortcut: "⌘+", kind: .editable(overridden: true)), BrowserCommands.zoomIn.id),
            (ShortcutRowState(title: "Reload Page", shortcut: nil, kind: .editable(overridden: false)), BrowserCommands.reload.id),
            (ShortcutRowState(title: "Undo", shortcut: "⌘Z", kind: .fixed("Fixed")), BrowserCommands.undo.id),
            (ShortcutRowState(title: "Hide Detour", shortcut: "⌘H", kind: .systemSettings), BrowserCommands.hide.id),
            (ShortcutRowState(title: "New \(QuickDetour.displayName) Window", shortcut: "⌥⌘N", kind: .quickDetour),
             BrowserCommands.newQuickDetourWindow.id),
        ] {
            let row = ShortcutRowView(identifier: NSUserInterfaceItemIdentifier("row"))
            row.show(state, commandID: id)
            assertEveryControlIsNamedOnce(in: row, "the \(state.title) row")
            // The row is read as its recorder ("Zoom In shortcut, ⌘+"), not
            // its title and then the recorder.
            XCTAssertFalse(staticTexts(under: row).contains(state.title), state.title)
            XCTAssertEqual(row.recorder.accessibilityLabel(), "\(state.title) shortcut")
            XCTAssertEqual(row.recorder.accessibilityValue() as? String, state.shortcut ?? "none")
        }
        XCTAssertGreaterThan(checked, 40, "the walk reaches the panes' controls")
    }

    /// The Shortcuts pane's search field is named by its placeholder; the
    /// Quick Detour recorder keeps its more specific name and its
    /// identifier.
    @MainActor func testTheShortcutsSearchFieldAndTheQuickDetourRecorderAreNamed() throws {
        let shortcuts = laidOut(ShortcutsSettingsViewController(store: ShortcutBindingStore(defaults: throwawayDefaults())))
        let search = try XCTUnwrap(control("shortcutsSearch", in: shortcuts) as? NSSearchField)
        XCTAssertEqual(search.accessibilityLabel(), "Search Commands")
        let quickDetour = laidOut(QuickDetourSettingsViewController())
        let recorder = try XCTUnwrap(control("quickDetourHotKeyShortcut", in: quickDetour) as? ShortcutRecorderView)
        XCTAssertEqual(recorder.accessibilityLabel(), "\(QuickDetour.displayName) shortcut")
        XCTAssertEqual(staticTexts(under: recorder), [])
    }

    /// TASK-336's rule on its own (a form row applies it to its control):
    /// the control takes the label's text, or an explicit name, and the
    /// label's cell leaves the tree. (The bordered group's row and the
    /// label-then-switch row went with TASK-338.)
    @MainActor func testTheRowHelpersNameTheSwitchAndHideTheLabel() {
        let toggle = NSSwitch()
        let label = NSTextField(labelWithString: "Enabled")
        let row = NSStackView(views: [label, toggle])
        SettingsSwitchRow.name(toggle, by: label)
        XCTAssertEqual(toggle.accessibilityLabel(), "Enabled")
        // A text field is read through its cell.
        XCTAssertEqual(label.cell?.isAccessibilityElement(), false)
        XCTAssertEqual(staticTexts(under: row), [])
        XCTAssertTrue(accessibilityElements(under: row).contains { $0 === toggle })
        let recorder = NSView()
        SettingsSwitchRow.name(recorder, by: NSTextField(labelWithString: "Shortcut"), as: "Quick Detour shortcut")
        XCTAssertEqual(recorder.accessibilityLabel(), "Quick Detour shortcut")
    }

    /// The sidebar's page settings popover lays its switches out the same
    /// way (label, then switch) and reads them once too.
    @MainActor func testThePagePopoverReadsEachSwitchOnce() throws {
        let popover = SettingsPopoverViewController()
        popover.host = "example.com"
        popover.isDevModeAvailable = true
        let switches = descendants(of: popover.view).compactMap { $0 as? NSSwitch }
        XCTAssertEqual(switches.count, 3, "content blocking, picture in picture, dev mode")
        let texts = staticTexts(under: popover.view)
        XCTAssertFalse(texts.isEmpty)
        for toggle in switches {
            let label = try XCTUnwrap(visibleLabel(of: toggle))
            XCTAssertEqual(toggle.accessibilityLabel(), label.stringValue)
            XCTAssertFalse(texts.contains(label.stringValue), label.stringValue)
        }
    }

    // MARK: - Stored values

    @MainActor func testThePeekSwitchShowsAndWritesItsSetting() throws {
        PeekSettings.shared.isEnabled = false
        let pane = laidOut(GeneralSettingsViewController())
        pane.viewWillAppear()
        let toggle = try XCTUnwrap(control("peekEnabled", in: pane) as? NSSwitch)
        XCTAssertEqual(toggle.state, .off)
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertTrue(PeekSettings.shared.isEnabled)
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertFalse(PeekSettings.shared.isEnabled)
    }

    /// Content Blocking's tracking-parameter list switch (TASK-337). The test
    /// host stores the setting without fetching.
    @MainActor func testTheTrackingListSwitchShowsAndWritesItsSetting() throws {
        let list = ContentBlockerManager.shared.trackingParameterList
        let saved = list.isEnabled
        addTeardownBlock { @MainActor in list.setEnabled(saved) }
        list.setEnabled(true)
        let pane = laidOut(ContentBlockerSettingsViewController())
        pane.viewWillAppear()
        let toggle = try XCTUnwrap(control("trackingParameterListEnabled", in: pane) as? NSSwitch)
        XCTAssertEqual(toggle.state, .on, "on by default")
        XCTAssertEqual(toggle.accessibilityLabel(), ContentBlockerSettingsViewController.trackingListTitle)
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertFalse(list.isEnabled)
        XCTAssertEqual(pane.trackingListStatusLabel.stringValue, "Off: not downloaded or used")
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertTrue(list.isEnabled)
    }

    @MainActor func testTheOptionCommandClickSwitchShowsAndWritesItsSetting() throws {
        QuickDetourSettings.shared.isOptionCommandClickEnabled = false
        let pane = laidOut(QuickDetourSettingsViewController())
        let toggle = try XCTUnwrap(control("quickDetourOptionCommandClick", in: pane) as? NSSwitch)
        XCTAssertEqual(toggle.state, .off, "the pane shows the stored value")
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertTrue(QuickDetourSettings.shared.isOptionCommandClickEnabled)
        // A change from elsewhere reaches the switch.
        QuickDetourSettings.shared.isOptionCommandClickEnabled = false
        XCTAssertEqual(toggle.state, .off)
    }
}
