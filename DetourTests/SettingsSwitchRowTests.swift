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

    @MainActor func testTheConvertedSettingsAreSwitchesNamedByTheirLabels() throws {
        let cases: [(SettingsPaneViewController, [(String, String)])] = [
            (GeneralSettingsViewController(), Self.generalSwitches),
            (QuickDetourSettingsViewController(), Self.quickDetourSwitches),
        ]
        for (pane, switches) in cases {
            _ = laidOut(pane)
            for (identifier, title) in switches {
                let toggle = try XCTUnwrap(control(identifier, in: pane) as? NSSwitch, "\(identifier) is a switch")
                XCTAssertEqual(toggle.accessibilityLabel(), title, identifier)
                XCTAssertEqual(toggle.controlSize, .regular, identifier)
            }
        }
    }

    /// The label first, the switch 8 pt after it and centred on it, the
    /// label at the body's leading edge, as the Extensions pane's Enabled row.
    @MainActor func testEachSwitchSitsAfterItsLabelAtTheBodysLeadingEdge() throws {
        let cases: [(SettingsPaneViewController, [(String, String)])] = [
            (laidOut(GeneralSettingsViewController()), Self.generalSwitches),
            (laidOut(QuickDetourSettingsViewController()), Self.quickDetourSwitches),
        ]
        for (pane, switches) in cases {
            // The body's leading edge: the pane margin.
            let leading = pane.view.bounds.minX + SettingsMetrics.paneMargin
            for (identifier, title) in switches {
                let toggle = try XCTUnwrap(control(identifier, in: pane) as? NSSwitch)
                let row = try XCTUnwrap(toggle.superview as? NSStackView, identifier)
                let label = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField, identifier)
                XCTAssertEqual(label.stringValue, title)
                let labelFrame = placed(label, in: pane)
                let switchFrame = placed(toggle, in: pane)
                XCTAssertEqual(labelFrame.minX, leading, accuracy: 0.5, "\(identifier): the label starts the row")
                XCTAssertEqual(switchFrame.minX - labelFrame.maxX, SettingsMetrics.labelToControl, accuracy: 0.5,
                               "\(identifier): the switch follows its label")
                XCTAssertEqual(switchFrame.midY, labelFrame.midY, accuracy: 0.5, "\(identifier): centred on the label")
                XCTAssertGreaterThan(labelFrame.width, 0, "\(identifier): the label is not squeezed to nothing")
            }
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
                let label = try XCTUnwrap((toggle.superview as? NSStackView)?.arrangedSubviews.first as? NSTextField)
                XCTAssertFalse(label.isEditable, identifier)
                XCTAssertFalse(label.isSelectable, identifier)
                XCTAssertNil(label.action, identifier)
            }
        }
    }

    /// The hotkey's recorder is a row of its own under the switch, labelled
    /// "Shortcut" on its baseline; it stays usable with the hotkey off (it is
    /// also the menu item's shortcut).
    @MainActor func testTheShortcutRecorderIsARowBelowTheHotKeySwitch() throws {
        let pane = laidOut(QuickDetourSettingsViewController())
        let toggle = try XCTUnwrap(control("quickDetourHotKeyEnabled", in: pane) as? NSSwitch)
        let recorder = try XCTUnwrap(control("quickDetourHotKeyShortcut", in: pane) as? ShortcutRecorderView)
        let row = try XCTUnwrap(toggle.superview)
        let rowFrame = placed(row, in: pane)
        let recorderFrame = placed(recorder, in: pane)
        // The pane's view is not flipped: below means a smaller y.
        XCTAssertEqual(rowFrame.minY - recorderFrame.maxY, SettingsMetrics.rowGap, accuracy: 0.5)
        let label = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Shortcut" })
        let labelFrame = placed(label, in: pane)
        XCTAssertEqual(labelFrame.minX, rowFrame.minX, accuracy: 0.5)
        XCTAssertEqual(recorderFrame.minX - labelFrame.maxX, SettingsMetrics.labelToControl, accuracy: 0.5)
        XCTAssertTrue(recorder.frame.width > 0)
    }

    // MARK: - Accessibility (TASK-336)

    /// The text beside a switch that names it on screen: the label in its
    /// row (a switch row, a group's row) or in its grid row's label column
    /// (Profiles).
    @MainActor private func visibleLabel(of toggle: NSSwitch) -> NSTextField? {
        if let row = toggle.superview as? NSStackView {
            return row.arrangedSubviews.compactMap { $0 as? NSTextField }.first
        }
        var view: NSView? = toggle
        while let current = view, !(current.superview is NSGridView) { view = current.superview }
        guard let cellView = view, let grid = cellView.superview as? NSGridView else {
            // A row laid out by hand (the sidebar popover): its one label.
            return toggle.superview?.subviews.compactMap { $0 as? NSTextField }.first
        }
        for index in 0..<grid.numberOfRows where grid.cell(atColumnIndex: 1, rowIndex: index).contentView === cellView {
            return grid.cell(atColumnIndex: 0, rowIndex: index).contentView as? NSTextField
        }
        return nil
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
        // General's 3, Quick Detour's 2, Profiles' 3 in its grid and 4 filter lists.
        XCTAssertGreaterThanOrEqual(checked, 12)
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

    /// The bordered group's row (Profiles' filter lists and extension
    /// switches, an extension's permissions) and the switch row helper.
    @MainActor func testTheRowHelpersNameTheSwitchAndHideTheLabel() {
        let grouped = NSSwitch()
        let (row, label) = SettingsGroupBoxView.switchRow(grouped, title: "Store data locally")
        XCTAssertEqual(grouped.accessibilityLabel(), "Store data locally")
        // A text field is read through its cell.
        XCTAssertEqual(label.cell?.isAccessibilityElement(), false)
        XCTAssertFalse(staticTexts(under: row).contains("Store data locally"))

        let plain = NSSwitch()
        let switchRow = SettingsSwitchRow.make(plain, title: "Enabled")
        XCTAssertEqual(plain.accessibilityLabel(), "Enabled")
        XCTAssertEqual(staticTexts(under: switchRow), [])
        XCTAssertTrue(accessibilityElements(under: switchRow).contains { $0 === plain })
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
