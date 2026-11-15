import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-338 phase 2: General, Spaces (its detail column) and Links (its
/// Default) are grouped forms; Search's and Shortcuts' lists, Links' routes
/// and the master lists are drawn as groups. Each control ends on its form's
/// right edge, the Automation sections keep the identifier the automation
/// endpoint refuses (TASK-228.7), and grids are named once.
nonisolated final class SettingsPanesFormTests: XCTestCase {

    // MARK: - Helpers

    @MainActor private func laidOut<Pane: SettingsPaneViewController>(_ pane: Pane, height: CGFloat = 900) -> Pane {
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: height))
        pane.view.layoutSubtreeIfNeeded()
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    @MainActor private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor private func placed(_ view: NSView, in pane: SettingsPaneViewController) -> NSRect {
        guard let superview = view.superview else { return .zero }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: pane.view)
    }

    @MainActor private func enclosing<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
        var current = view.superview
        while let candidate = current, !(candidate is T) { current = candidate.superview }
        return current as? T
    }

    // MARK: - General

    /// Every control of General ends on the form's right edge; the names
    /// start on its text edge.
    @MainActor func testGeneralsControlsShareTheFormsEdges() throws {
        let pane = laidOut(GeneralSettingsViewController())
        pane.viewWillAppear()
        pane.view.layoutSubtreeIfNeeded()
        let right = pane.view.bounds.width - SettingsMetrics.paneMargin - SettingsMetrics.formRowInsetX
        let left = SettingsMetrics.paneMargin + SettingsMetrics.formRowInsetX
        let rows = descendants(of: pane.view).compactMap { $0 as? SettingsFormRow }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.titleLabel != nil }
        XCTAssertGreaterThanOrEqual(rows.count, 4, "default browser, Peek, automation and Private")
        for row in rows {
            let name = row.titleLabel?.stringValue ?? ""
            XCTAssertEqual(placed(try XCTUnwrap(row.titleLabel), in: pane).minX, left, accuracy: 0.5, name)
            if let accessory = row.accessoryView, !accessory.isHidden {
                XCTAssertEqual(placed(accessory, in: pane).maxX, right, accuracy: 0.5, name)
            }
        }
    }

    /// The Automation section and the allowed clients carry the identifier
    /// the endpoint's input tools refuse; Peek's switch does not.
    @MainActor func testTheAutomationSectionsCarryTheEndpointsIdentifier() throws {
        let pane = laidOut(GeneralSettingsViewController())
        pane.viewWillAppear()
        let views = descendants(of: pane.view)
        let inAutomation = ["automationEnabled", "automationAllowPrivate"]
        for identifier in inAutomation {
            let control = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == identifier }, identifier)
            XCTAssertTrue(AutomationWindows.isInAutomationSettings(control), identifier)
        }
        for button in views.compactMap({ $0 as? NSButton }) where button.title.hasPrefix("Copy ") {
            XCTAssertTrue(AutomationWindows.isInAutomationSettings(button), button.title)
        }
        let peek = try XCTUnwrap(views.first { $0.accessibilityIdentifier() == "peekEnabled" })
        XCTAssertFalse(AutomationWindows.isInAutomationSettings(peek))
        let sections = views.compactMap { $0 as? SettingsFormSection }
            .filter { $0.identifier == AutomationWindows.automationSettingsIdentifier }
        XCTAssertEqual(sections.compactMap(\.titleLabel?.stringValue), ["Automation", "Allowed Clients"])
    }

    /// Buttons under a group hide with the room they take.
    @MainActor func testButtonsUnderAGroupHideWithTheirRoom() throws {
        let button = NSButton(title: "Copy", target: nil, action: nil)
        let section = SettingsFormSection(title: "Automation", rows: [SettingsFormRow(title: "One")], buttons: [button])
        let width = section.widthAnchor.constraint(equalToConstant: SettingsMetrics.formWidth)
        width.isActive = true
        let shown = section.fittingSize.height
        section.isButtonRowHidden = true
        XCTAssertEqual(section.fittingSize.height,
                       shown - SettingsMetrics.formGroupToButtons - button.fittingSize.height, accuracy: 0.5)
        section.isButtonRowHidden = false
        XCTAssertEqual(section.fittingSize.height, shown, accuracy: 0.5)
    }

    // MARK: - Spaces

    /// The selected space's Name, Emoji, Profile and Color are rows of one
    /// group in the detail column, their controls on its right edge; the
    /// emoji and colour grids take their row's name and the names leave the
    /// tree, so each is read once.
    @MainActor func testSpacesDetailIsAFormNamedOnce() throws {
        let pane = laidOut(SpacesSettingsViewController())
        pane.viewWillAppear()
        pane.view.layoutSubtreeIfNeeded()
        let rows = descendants(of: pane.view).compactMap { $0 as? SettingsFormRow }
        XCTAssertEqual(rows.compactMap(\.titleLabel?.stringValue), ["Name", "Emoji", "Profile", "Color"])
        let group = try XCTUnwrap(enclosing(SettingsFormGroupView.self, of: try XCTUnwrap(rows.first)))
        let right = placed(group, in: pane).maxX - SettingsMetrics.formRowInsetX
        for row in rows {
            XCTAssertEqual(placed(try XCTUnwrap(row.accessoryView), in: pane).maxX, right, accuracy: 0.5,
                           row.titleLabel?.stringValue ?? "")
            XCTAssertEqual(row.titleLabel?.cell?.isAccessibilityElement(), false, "\(row.titleLabel?.stringValue ?? ""): read once")
        }
        let grids = descendants(of: pane.view).compactMap { $0 as? SpaceChoiceGridView }
        XCTAssertEqual(Set(grids.compactMap { $0.accessibilityLabel() }), ["Emoji", "Color"])
        // The detail column starts level with the list.
        let list = try XCTUnwrap(descendants(of: pane.view).first { $0 is SettingsListContainerView })
        XCTAssertEqual(placed(group, in: pane).maxY, placed(list, in: pane).maxY, accuracy: 0.5)
    }

    // MARK: - Links

    /// The Default is a form section at the pane's bottom: the pop-up's row
    /// named by its title and the caption with the Quarantine guide as the
    /// group's footnote.
    @MainActor func testLinksDefaultIsAFormSection() throws {
        let pane = LinksSettingsViewController(
            linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue())))
        _ = laidOut(pane, height: SettingsMetrics.listPaneMinimumHeight)
        let sections = descendants(of: pane.view).compactMap { $0 as? SettingsFormSection }
        let section = try XCTUnwrap(sections.first { $0.titleLabel?.stringValue == "Default" })
        let row = try XCTUnwrap(section.rows.first)
        let popUp = try XCTUnwrap(row.accessoryView as? NSPopUpButton)
        XCTAssertEqual(popUp.accessibilityLabel(), "Open other links in")
        XCTAssertEqual(row.titleLabel?.cell?.isAccessibilityElement(), false)
        let footnote = try XCTUnwrap(section.rows.last)
        XCTAssertNil(footnote.titleLabel)
        XCTAssertTrue(descendants(of: footnote).contains { ($0 as? SettingsGuideLink)?.page == .quarantine })
        // At the pane's bottom, a margin above the window's edge.
        XCTAssertEqual(placed(section, in: pane).minY, SettingsMetrics.paneMargin, accuracy: 0.5)
        XCTAssertEqual(placed(popUp, in: pane).maxX,
                       pane.view.bounds.width - SettingsMetrics.paneMargin - SettingsMetrics.formRowInsetX, accuracy: 0.5)
    }

    /// A highlighted row is tinted (Links' Default after a blocked space deletion).
    @MainActor func testAHighlightedRowIsTinted() throws {
        let row = SettingsFormRow(title: "Open other links in")
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 36)
        func centre() throws -> NSColor {
            let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh / 2))
        }
        XCTAssertEqual(try centre().alphaComponent, 0, accuracy: 0.01)
        row.isHighlighted = true
        XCTAssertGreaterThan(try centre().alphaComponent, 0.1)
    }

    // MARK: - Lists drawn as groups

    /// Every list pane's list sits in a container drawn as a form group, and
    /// a list's title sits on the rows' text edge like a section header.
    @MainActor func testListsAreDrawnAsGroupsWithTheirTitlesOnTheTextEdge() throws {
        let search = laidOut(SearchSettingsViewController(
            siteSearches: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))))
        let links = laidOut(LinksSettingsViewController(
            linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue()))))
        for (pane, title) in [(search as SettingsPaneViewController, "Site Search"), (links, "Routes")] {
            let label = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == title })
            let list = try XCTUnwrap(descendants(of: pane.view).first { $0 is SettingsListContainerView })
            XCTAssertEqual(placed(label, in: pane).minX - placed(list, in: pane).minX, SettingsMetrics.formRowInsetX,
                           accuracy: 0.5, title)
            XCTAssertEqual(label.font?.pointSize, SettingsMetrics.formTitleFontSize)
            list.updateLayer()
            XCTAssertEqual(list.layer?.cornerRadius, SettingsMetrics.formGroupCornerRadius)
        }
    }

    /// No pane draws a material of its own, so Reduce Transparency has
    /// nothing to change in them: the groups are tints on the opaque window.
    /// The only visual effect views are AppKit's, inside a table's scroll
    /// view (Search's column header on macOS 26), which follow the setting
    /// themselves (its header's scroll pocket: an NSVisualEffectView under
    /// the clip view, whose `enclosingScrollView` is nil).
    @MainActor func testNoPaneUsesAMaterial() throws {
        let panes: [SettingsPaneViewController] = [
            GeneralSettingsViewController(), SpacesSettingsViewController(),
            LinksSettingsViewController(linkRoutes: LinkRouteStore(database: try AppDatabase(dbQueue: DatabaseQueue()))),
            QuickDetourSettingsViewController(), ProfilesSettingsViewController(),
            SearchSettingsViewController(siteSearches: SiteSearchStore(database: try AppDatabase(dbQueue: DatabaseQueue()))),
            ExtensionsSettingsViewController(), ContentBlockerSettingsViewController(),
        ]
        for pane in panes {
            _ = laidOut(pane)
            let materials = descendants(of: pane.view).filter { $0 is NSVisualEffectView }
            // A table header's scroll pocket: NSScrollView's own chrome.
            XCTAssertTrue(materials.allSatisfy { enclosing(NSScrollView.self, of: $0) != nil }, "\(type(of: pane))")
        }
    }
}
