import XCTest
import AppKit
@testable import Detour

/// TASK-338: the System Settings–style grouped form. Its rows put the
/// setting's name on the left and the control on the right, every control on
/// one right edge and every name on one left edge, with long names and help
/// text wrapping before the control, at the narrowest width a form gets (a
/// detail column beside a master list, less a legacy scroller) and the widest
/// (a pane's body). Each row names its control, so a setting is read once.
nonisolated final class SettingsFormTests: XCTestCase {

    /// A detail column beside a master list with "always show scroll bars"
    /// (15 pt narrower), and a pane's whole body.
    @MainActor private static let widths: [CGFloat] = [SettingsMetrics.detailColumnWidth - 17, SettingsMetrics.formWidth]

    @MainActor private static let longTitle = ContentBlockerSettingsViewController.trackingListTitle
    @MainActor private static let longHelp = "Copy URL, Copy Link and Share… always leave out common tracking parameters "
        + "such as utm_source and fbclid. This list adds the ones particular sites use. It changes only the links "
        + "you copy or share and blocks nothing; it updates with the lists above."

    // MARK: - Helpers

    /// One row of every kind, with long text where it can wrap.
    @MainActor private func makeRows() -> [SettingsFormRow] {
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: ["Never", "1 hour", "6 hours", "12 hours", "1 day"])
        let value = NSTextField(labelWithString: "American (Voice 4)")
        let custom = NSColorWell()
        let link = SettingsGuideLink(.quickDetour, title: "Learn more")
        let withLink = SettingsFormRow(title: "Links", help: "Help with a link after it.")
        withLink.addLink(link)
        return [
            SettingsFormRow(title: Self.longTitle, help: Self.longHelp, accessory: .toggle(NSSwitch())),
            SettingsFormRow(title: "Short", accessory: .toggle(NSSwitch())),
            SettingsFormRow(title: "Close Quick Detour windows not used for", help: Self.longHelp, accessory: .popUp(popUp)),
            SettingsFormRow(title: "History", accessory: .button(NSButton(title: "Clear History…", target: nil, action: nil))),
            SettingsFormRow(title: "Voice", accessory: .value(value, button: NSButton(title: "Select…", target: nil, action: nil))),
            SettingsFormRow(title: "Shortcut", help: Self.longHelp, accessory: .shortcut(ShortcutRecorderView()),
                            accessibilityName: "Quick Detour shortcut"),
            SettingsFormRow(title: "Colour", accessory: .custom(custom)),
            withLink,
        ]
    }

    /// A form `width` wide, built for that width, laid out in a flipped host.
    @MainActor private func laidOut(_ sections: [SettingsFormSection], width: CGFloat) -> (SettingsForm, NSView) {
        let form = SettingsForm(sections: sections, estimatedWidth: width)
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        host.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: host.topAnchor),
            form.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            form.widthAnchor.constraint(equalToConstant: width),
        ])
        // Twice: a wrapping label re-measures at the width the first pass gave it.
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return (form, host)
    }

    @MainActor private final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
    }

    /// A view's alignment rectangle (what Auto Layout places; a label's frame
    /// is 2 pt wider on each side) in `host`'s coordinates.
    @MainActor private func placed(_ view: NSView, in host: NSView) -> NSRect {
        guard let superview = view.superview else { return .zero }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: host)
    }

    /// What an Accessibility client gets from `view` down.
    @MainActor private func accessibilityElements(under view: NSView) -> [any NSAccessibilityProtocol] {
        func walk(_ element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
            let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            return children + children.flatMap(walk)
        }
        return walk(view)
    }

    @MainActor private func staticTexts(under view: NSView) -> [String] {
        accessibilityElements(under: view)
            .filter { $0.accessibilityRole() == .staticText }
            .compactMap { ($0.accessibilityValue() as? String) ?? ($0 as? NSCell)?.stringValue }
    }

    // MARK: - Geometry

    /// Every control ends on the group's right edge less the row inset, and
    /// every name and the header start on its left edge plus the inset, at
    /// the narrowest and widest form.
    @MainActor func testControlsShareOneRightEdgeAndNamesOneLeftEdge() throws {
        for width in Self.widths {
            let section = SettingsFormSection(title: "Section", rows: makeRows(),
                                              buttons: [NSButton(title: "Reset…", target: nil, action: nil)])
            let (_, host) = laidOut([section], width: width)
            let group = placed(section.group, in: host)
            let right = group.maxX - SettingsMetrics.formRowInsetX
            let left = group.minX + SettingsMetrics.formRowInsetX
            XCTAssertEqual(group.width, width, accuracy: 0.5)
            for row in section.rows {
                let name = row.titleLabel?.stringValue ?? "footnote"
                let title = try XCTUnwrap(row.titleLabel)
                XCTAssertEqual(placed(title, in: host).minX, left, accuracy: 0.5, "\(width): \(name)'s name")
                if let accessory = row.accessoryView {
                    XCTAssertEqual(placed(accessory, in: host).maxX, right, accuracy: 0.5, "\(width): \(name)'s control")
                }
            }
            XCTAssertEqual(placed(try XCTUnwrap(section.titleLabel), in: host).minX, left, accuracy: 0.5, "the header")
            // The buttons under the group end on its edge, as System Settings'.
            let buttons = placed(try XCTUnwrap(section.buttonRow), in: host)
            XCTAssertEqual(buttons.maxX, group.maxX, accuracy: 0.5)
            XCTAssertEqual(buttons.minY - group.maxY, SettingsMetrics.formGroupToButtons, accuracy: 0.5)
        }
    }

    /// Long names and help text wrap in the text column and never reach the
    /// control; rows never overlap; text keeps 10 pt and controls 7 pt from
    /// the row's top and bottom.
    @MainActor func testLongTextWrapsBeforeTheControlWithoutOverlapping() throws {
        for width in Self.widths {
            let section = SettingsFormSection(rows: makeRows())
            let (_, host) = laidOut([section], width: width)
            var previousBottom = placed(section.group, in: host).minY
            for row in section.rows {
                let rowFrame = row.convert(row.bounds, to: host)
                let name = "\(width): \(row.titleLabel?.stringValue.prefix(20) ?? "")"
                XCTAssertEqual(rowFrame.minY, previousBottom, accuracy: 0.5, "\(name): rows follow each other")
                previousBottom = rowFrame.maxY
                let texts = [row.titleLabel, row.helpLabel].compactMap { $0 }.filter { !$0.isHidden }
                for text in texts {
                    let frame = placed(text, in: host)
                    XCTAssertGreaterThanOrEqual(frame.minY, rowFrame.minY + SettingsMetrics.formRowInsetY - 0.5, name)
                    XCTAssertLessThanOrEqual(frame.maxY, rowFrame.maxY - SettingsMetrics.formRowInsetY + 0.5, name)
                    // Wrapped, not clipped: as tall as the text needs at its width.
                    XCTAssertGreaterThanOrEqual(text.frame.height + 0.5, text.intrinsicContentSize.height, name)
                    if let accessory = row.accessoryView {
                        XCTAssertLessThanOrEqual(frame.maxX,
                                                 placed(accessory, in: host).minX - SettingsMetrics.formLabelToControl + 0.5,
                                                 "\(name): text runs into the control")
                    }
                }
                if let accessory = row.accessoryView {
                    let frame = accessory.convert(accessory.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.minY, rowFrame.minY + SettingsMetrics.formControlInsetY - 0.5, name)
                    XCTAssertLessThanOrEqual(frame.maxY, rowFrame.maxY - SettingsMetrics.formControlInsetY + 0.5, name)
                }
            }
            // The long name and help text did wrap.
            let first = try XCTUnwrap(section.rows.first)
            let oneLine = SettingsFormRow.titleLineHeight
            XCTAssertGreaterThan(first.helpLabel.frame.height, oneLine * 1.5, "\(width): the help wraps")
            if width < 500 {
                XCTAssertGreaterThan(try XCTUnwrap(first.titleLabel).frame.height, oneLine * 1.5, "the name wraps")
            }
        }
    }

    /// A switch is mini and centred on the name's first line, a pop-up or a
    /// button sits on the name's baseline.
    @MainActor func testControlsLineUpWithTheNamesFirstLine() throws {
        let rows = makeRows()
        let (_, host) = laidOut([SettingsFormSection(rows: rows)], width: SettingsMetrics.formWidth)
        let toggleRow = rows[0], popUpRow = rows[2]
        let toggle = try XCTUnwrap(toggleRow.accessoryView as? NSSwitch)
        XCTAssertEqual(toggle.controlSize, .mini)
        XCTAssertEqual(toggle.frame.size, SettingsFormRow.switchSize(.mini))
        XCTAssertLessThan(toggle.frame.width, 54, "smaller than a regular switch")
        let title = try XCTUnwrap(toggleRow.titleLabel)
        let titleTop = title.convert(title.bounds, to: host).minY
        XCTAssertEqual(toggle.convert(toggle.bounds, to: host).midY, titleTop + SettingsFormRow.titleLineHeight / 2,
                       accuracy: 0.5)

        let popUp = try XCTUnwrap(popUpRow.accessoryView as? NSPopUpButton)
        let popUpTitle = try XCTUnwrap(popUpRow.titleLabel)
        let baseline = { (view: NSView) in view.convert(view.bounds, to: host).minY + view.firstBaselineOffsetFromTop }
        XCTAssertEqual(baseline(popUp), baseline(popUpTitle), accuracy: 0.5)
    }

    // MARK: - Heights

    /// One-line rows are as tall as System Settings': 36 pt for a switch,
    /// the control plus 7 pt above and below for a taller one (a pop-up: 38
    /// on macOS 26). The section is its header, the gap, its rows and the
    /// buttons under it; the form adds 30 pt between sections.
    @MainActor func testRowSectionAndFormHeights() throws {
        let popUp = NSPopUpButton()
        popUp.addItem(withTitle: "6 hours")
        let switchRow = SettingsFormRow(title: "Short", accessory: .toggle(NSSwitch()))
        let popUpRow = SettingsFormRow(title: "Short", accessory: .popUp(popUp))
        let footnote = SettingsFormRow(footnote: "A footnote.")
        let button = NSButton(title: "Reset…", target: nil, action: nil)
        let first = SettingsFormSection(title: "First", rows: [switchRow, popUpRow], footnote: footnote, buttons: [button])
        let second = SettingsFormSection(title: "Second", rows: [SettingsFormRow(title: "Another")])
        let (form, _) = laidOut([first, second], width: SettingsMetrics.formWidth)

        let textRow = 2 * SettingsMetrics.formRowInsetY + SettingsFormRow.titleLineHeight
        XCTAssertEqual(textRow, 36, "System Settings' one-line row")
        XCTAssertEqual(switchRow.frame.height, textRow, accuracy: 0.5)
        XCTAssertEqual(popUpRow.frame.height, max(textRow, popUp.frame.height + 2 * SettingsMetrics.formControlInsetY),
                       accuracy: 0.5)
        XCTAssertEqual(footnote.frame.height, 2 * SettingsMetrics.formRowInsetY + footnote.helpLabel.frame.height,
                       accuracy: 0.5)

        let header = try XCTUnwrap(first.titleLabel).frame.height
        let rows = switchRow.frame.height + popUpRow.frame.height + footnote.frame.height
        XCTAssertEqual(first.group.frame.height, rows, accuracy: 0.5)
        XCTAssertEqual(first.frame.height, header + SettingsMetrics.formHeaderToGroup + rows
                       + SettingsMetrics.formGroupToButtons + button.frame.height, accuracy: 0.5)
        XCTAssertEqual(form.frame.height, first.frame.height + SettingsMetrics.formSectionGap + second.frame.height,
                       accuracy: 0.5)
    }

    /// A hidden row leaves no gap; a hidden section neither.
    @MainActor func testHiddenRowsAndSectionsTakeNoRoom() throws {
        let rows = [SettingsFormRow(title: "One"), SettingsFormRow(title: "Two"), SettingsFormRow(title: "Three")]
        let section = SettingsFormSection(title: "Rows", rows: rows)
        let other = SettingsFormSection(title: "Other", rows: [SettingsFormRow(title: "Four")])
        let (form, host) = laidOut([section, other], width: SettingsMetrics.formWidth)
        let full = section.group.frame.height
        rows[1].isHidden = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(section.group.frame.height, full - rows[1].frame.height, accuracy: 0.5)
        XCTAssertEqual(rows[2].convert(rows[2].bounds, to: host).minY, rows[0].convert(rows[0].bounds, to: host).maxY,
                       accuracy: 0.5)
        let withBoth = form.frame.height
        other.isHidden = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(form.frame.height, withBoth - SettingsMetrics.formSectionGap - other.frame.height, accuracy: 0.5)
    }

    /// Measured before any layout (as a pane is, before the window shows it)
    /// a form is as tall as it is laid out: its rows wrap at the width they
    /// will get, and a mini switch has its real size outside a window.
    @MainActor func testTheFirstMeasurementIsTheLaidOutHeight() {
        for width in Self.widths {
            let cold = SettingsForm(sections: [SettingsFormSection(title: "Rows", rows: makeRows())], estimatedWidth: width)
            let pin = cold.widthAnchor.constraint(equalToConstant: width)
            pin.isActive = true
            let measured = cold.fittingSize.height
            pin.isActive = false
            let (laid, _) = laidOut([SettingsFormSection(title: "Rows", rows: makeRows())], width: width)
            XCTAssertEqual(measured, laid.frame.height, accuracy: 0.5, "at \(width)")
        }
    }

    // MARK: - Accessibility (TASK-336, built in)

    /// A switch, pop-up, recorder or custom control is named by its row (the
    /// recorder by its explicit name) and the name leaves the tree, so the
    /// setting is read once; a button keeps its title and a value is text of
    /// its own, so their rows keep the name. Help text stays readable.
    @MainActor func testEachRowNamesItsControlAndIsReadOnce() throws {
        let rows = makeRows()
        let (_, host) = laidOut([SettingsFormSection(title: "Rows", rows: rows)], width: SettingsMetrics.formWidth)
        let texts = staticTexts(under: host)
        let elements = accessibilityElements(under: host)
        let named: [(SettingsFormRow, String)] = [
            (rows[0], Self.longTitle), (rows[1], "Short"), (rows[2], "Close Quick Detour windows not used for"),
            (rows[5], "Quick Detour shortcut"), (rows[6], "Colour"),
        ]
        for (row, name) in named {
            let control = try XCTUnwrap(row.accessoryView)
            XCTAssertEqual(control.accessibilityLabel(), name)
            XCTAssertTrue(elements.contains { $0 === control || ($0 as? NSCell)?.controlView === control }, name)
            let title = try XCTUnwrap(row.titleLabel)
            XCTAssertEqual(title.cell?.isAccessibilityElement(), false, name)
            XCTAssertFalse(texts.contains(title.stringValue), "\(name): its name is read twice")
        }
        XCTAssertTrue(texts.contains(Self.longHelp), "help text stays readable")
        // The button row and the value row keep their name as text.
        XCTAssertTrue(texts.contains("History"))
        let button = try XCTUnwrap(rows[3].accessoryView as? NSButton)
        XCTAssertEqual(button.title, "Clear History…")
        XCTAssertNotEqual(button.accessibilityLabel(), "History", "a button keeps its own name")
        XCTAssertTrue(texts.contains("Voice"))
        XCTAssertTrue(texts.contains("American (Voice 4)"))
        XCTAssertTrue(texts.contains("Rows"), "the header is read")
    }

    /// VoiceOver meets the control right after the name: a switch first (it
    /// carries the name), then its help; a value after the name it belongs
    /// to, then the details.
    @MainActor func testTheControlIsReadBeforeTheHelpText() throws {
        let toggle = NSSwitch()
        let toggleRow = SettingsFormRow(title: "Peek", help: "Opens a Peek.", accessory: .toggle(toggle))
        let value = NSTextField(labelWithString: "Active")
        let valueRow = SettingsFormRow(title: "EasyList", help: "74,713 rules", accessory: .value(value, button: nil))
        let (_, host) = laidOut([SettingsFormSection(rows: [toggleRow, valueRow])], width: SettingsMetrics.formWidth)
        let order = accessibilityElements(under: host).compactMap { element -> String? in
            if (element as? NSSwitch) === toggle { return "switch" }
            guard element.accessibilityRole() == .staticText else { return nil }
            return (element.accessibilityValue() as? String) ?? (element as? NSCell)?.stringValue
        }
        XCTAssertEqual(order, ["switch", "Opens a Peek.", "EasyList", "Active", "74,713 rules"])
    }

    /// A custom accessory that is only a container cannot carry the name, so
    /// its row keeps the title as text.
    @MainActor func testACustomContainerKeepsItsTitle() {
        let row = SettingsFormRow(title: "Colours", accessory: .custom(NSView()))
        let (_, host) = laidOut([SettingsFormSection(rows: [row])], width: SettingsMetrics.formWidth)
        XCTAssertTrue(staticTexts(under: host).contains("Colours"))
        XCTAssertNotEqual(row.titleLabel?.cell?.isAccessibilityElement(), false)
    }

    // MARK: - Warning line

    @MainActor func testTheWarningLineComesAndGoes() throws {
        let row = SettingsFormRow(title: "Shortcut", help: "Help.", accessory: .shortcut(ShortcutRecorderView()))
        let (_, host) = laidOut([SettingsFormSection(rows: [row])], width: SettingsMetrics.formWidth)
        let without = row.frame.height
        XCTAssertNil(row.warning)
        row.setWarning("Debug builds don't register the global shortcut.")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.warning, "Debug builds don't register the global shortcut.")
        XCTAssertGreaterThan(row.frame.height, without + 10)
        XCTAssertTrue(staticTexts(under: host).contains("Debug builds don't register the global shortcut."))
        row.setWarning(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(row.warning)
        XCTAssertEqual(row.frame.height, without, accuracy: 0.5)
    }

    // MARK: - The pilot panes (Quick Detour, Content Blocking)

    /// Measured before their first layout, the panes ask for the height they
    /// have once laid out, so the window opens at the right height.
    @MainActor func testThePilotPanesFirstMeasurementIsTheirLaidOutHeight() {
        let panes: [SettingsPaneViewController] = [QuickDetourSettingsViewController(),
                                                   ContentBlockerSettingsViewController()]
        for pane in panes {
            let cold = pane.naturalContentHeight
            pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: cold))
            pane.view.layoutSubtreeIfNeeded()
            pane.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(pane.naturalContentHeight, cold, accuracy: 0.5, "\(type(of: pane))")
        }
    }

    /// The four lists are rows with their status on the right and their
    /// counts and last update under their name; the buttons sit under the
    /// group on its right edge and keep their identifiers; the tracking
    /// list's status line is still its own identified text, in its row.
    @MainActor func testContentBlockingListsAreRowsWithButtonsUnderThem() throws {
        let pane = ContentBlockerSettingsViewController()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 900))
        pane.viewWillAppear()
        defer { pane.viewDidDisappear() }
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(pane.listRows.map { $0.row.titleLabel?.stringValue }, ContentBlockerManager.filterLists.map(\.name))
        for item in pane.listRows {
            XCTAssertTrue(["Active", "Not loaded", "Updating…"].contains(item.status.stringValue), item.status.stringValue)
            XCTAssertFalse(item.row.helpLabel.isHidden)
            XCTAssertTrue(item.row.accessoryView?.subviews.contains(item.status) == true, "the status is on the right")
        }
        func find(_ identifier: String) -> NSView? {
            func walk(_ view: NSView) -> NSView? {
                if view.accessibilityIdentifier() == identifier { return view }
                return view.subviews.lazy.compactMap(walk).first
            }
            return walk(pane.view)
        }
        let section = try XCTUnwrap(pane.listRows.first.flatMap { row -> SettingsFormSection? in
            var view: NSView? = row.row
            while let current = view, !(current is SettingsFormSection) { view = current.superview }
            return view as? SettingsFormSection
        })
        let update = try XCTUnwrap(find("contentBlockerUpdateAll") as? NSButton)
        let clear = try XCTUnwrap(find("contentBlockerClearCache") as? NSButton)
        XCTAssertEqual(section.buttonRow?.arrangedSubviews, [clear, update])
        let status = try XCTUnwrap(find("trackingParameterListStatus") as? NSTextField)
        XCTAssertTrue(status === pane.trackingListStatusLabel)
        var row: NSView? = status
        while let current = row, !(current is SettingsFormRow) { row = current.superview }
        XCTAssertEqual((row as? SettingsFormRow)?.titleLabel?.stringValue, ContentBlockerSettingsViewController.trackingListTitle)
        XCTAssertFalse(status.stringValue.isEmpty)
    }

    /// The text of a list's row: what the table's Status, In List, Active and
    /// Last Updated columns said, and the total under the lists.
    @MainActor func testTheFilterListTexts() {
        typealias Pane = ContentBlockerSettingsViewController
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Pane.filterListStatus(isRefreshing: true, isCompiled: true).text, "Updating…")
        XCTAssertEqual(Pane.filterListStatus(isRefreshing: false, isCompiled: true).text, "Active")
        XCTAssertTrue(Pane.filterListStatus(isRefreshing: false, isCompiled: true).isActive)
        XCTAssertEqual(Pane.filterListStatus(isRefreshing: false, isCompiled: false).text, "Not loaded")
        XCTAssertFalse(Pane.filterListStatus(isRefreshing: false, isCompiled: false).isActive)

        XCTAssertEqual(Pane.filterListDetail(parsed: nil, compiled: nil, lastFetch: nil, now: now), "Never updated")
        let full = Pane.filterListDetail(parsed: 74_713, compiled: 74_700, lastFetch: now.addingTimeInterval(-12), now: now)
        XCTAssertTrue(full.hasPrefix("74,713 rules, 74,700 active, updated "), full)
        XCTAssertTrue(full.contains("12"), full)
        let fetchedOnly = Pane.filterListDetail(parsed: nil, compiled: nil, lastFetch: now.addingTimeInterval(-11), now: now)
        XCTAssertTrue(fetchedOnly.hasPrefix("Updated "), fetchedOnly)
        let ahead = Pane.filterListDetail(parsed: 1, compiled: nil, lastFetch: now.addingTimeInterval(0.5), now: now)
        XCTAssertFalse(ahead.contains("in "), "a fetch a moment ahead of the clock is not in the future: \(ahead)")

        XCTAssertEqual(Pane.totalsText(activeRules: 156_372, activity: ""), "156,372 active rules")
        XCTAssertEqual(Pane.totalsText(activeRules: 0, activity: "Updating 2 lists…"), "No active rules. Updating 2 lists…")
    }

    // MARK: - Phase 2 additions

    /// A header's accessory (a Learn more link) follows the title on its
    /// baseline.
    @MainActor func testAHeaderAccessoryFollowsTheTitle() throws {
        let link = SettingsGuideLink(.tabArchiving, title: "Learn more")
        let section = SettingsFormSection(title: "Tabs", headerAccessory: link, rows: [SettingsFormRow(title: "One")])
        let (_, host) = laidOut([section], width: SettingsMetrics.formWidth)
        let title = try XCTUnwrap(section.titleLabel)
        XCTAssertEqual(placed(link, in: host).minX - placed(title, in: host).maxX, SettingsMetrics.labelToControl,
                       accuracy: 0.5)
        let baseline = { (view: NSView) in view.convert(view.bounds, to: host).minY + view.firstBaselineOffsetFromTop }
        XCTAssertEqual(baseline(link), baseline(title), accuracy: 0.5)
    }

    /// A row turned off disables its control and dims its name.
    @MainActor func testADisabledRowDimsItsNameAndDisablesItsControl() throws {
        let toggle = NSSwitch()
        let row = SettingsFormRow(title: "EasyList", accessory: .toggle(toggle))
        row.isEnabled = false
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(row.titleLabel?.textColor, .tertiaryLabelColor)
        row.isEnabled = true
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(row.titleLabel?.textColor, .labelColor)
    }

    /// A button row is 44 pt, as System Settings' (10 pt above and below a
    /// 24 pt button); a value with a button too.
    @MainActor func testButtonRowsAreSystemSettingsHeight() throws {
        let button = NSButton(title: "Clear…", target: nil, action: nil)
        let row = SettingsFormRow(title: "History", accessory: .button(button))
        let value = SettingsFormRow(title: "Voice", accessory: .value(NSTextField(labelWithString: "American"),
                                                                      button: NSButton(title: "Select…", target: nil,
                                                                                       action: nil)))
        _ = laidOut([SettingsFormSection(rows: [row, value])], width: SettingsMetrics.formWidth)
        XCTAssertEqual(row.frame.height, button.frame.height + 2 * SettingsMetrics.formButtonInsetY, accuracy: 0.5)
        XCTAssertEqual(value.frame.height, row.frame.height, accuracy: 0.5)
    }

    /// Under Increase Contrast a group and a list drawn as one get a border
    /// (the override stands in for the system setting, which a process
    /// cannot turn on for itself).
    @MainActor func testIncreaseContrastBordersTheGroups() throws {
        defer { SettingsGroupStyle.increaseContrastOverride = nil }
        func leftEdge(contrast: Bool) throws -> NSColor {
            SettingsGroupStyle.increaseContrastOverride = contrast
            let group = SettingsFormGroupView(rows: [SettingsFormRow(title: "One")])
            group.frame = NSRect(x: 0, y: 0, width: 200, height: 36)
            group.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(group.bitmapImageRepForCachingDisplay(in: group.bounds))
            group.cacheDisplay(in: group.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: 0, y: rep.pixelsHigh / 2))
        }
        XCTAssertGreaterThan(try leftEdge(contrast: true).alphaComponent, try leftEdge(contrast: false).alphaComponent + 0.03)

        let list = SettingsListContainerView()
        SettingsGroupStyle.increaseContrastOverride = true
        list.updateLayer()
        XCTAssertEqual(list.layer?.borderWidth, 1)
        SettingsGroupStyle.increaseContrastOverride = false
        list.updateLayer()
        XCTAssertEqual(list.layer?.borderWidth, 0)
        XCTAssertEqual(list.layer?.cornerRadius, SettingsMetrics.formGroupCornerRadius)
    }
}
