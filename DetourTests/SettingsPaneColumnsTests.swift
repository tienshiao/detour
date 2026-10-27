import XCTest
import AppKit
@testable import Detour

/// TASK-211: in a Settings pane with a master list (Spaces, Profiles,
/// Extensions) the list and the detail column are fixed to the top and
/// bottom of the pane below the description, and each scrolls only its own
/// contents. Scrolling the details used to scroll the whole body, list
/// included, because the body was one scroll view (TASK-189). Panes without a
/// master list keep scrolling as one body.
@MainActor
final class SettingsPaneColumnsTests: XCTestCase {

    // MARK: - Fixtures

    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var count = 30
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    /// A list pane like Profiles: a bordered list on the left, a detail
    /// column on the right in a column scroll view.
    private final class ListPane: SettingsPaneViewController {
        let rows = Rows()
        let table = NSTableView()
        var listScroll: NSScrollView!
        var detailScroll: NSScrollView!
        var detailHeight: NSLayoutConstraint!

        override var paneDescription: String? { "A pane with a list and a detail column." }
        override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
        override var scrollsBodyAsWhole: Bool { false }

        override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
            max(fittingHeight, table.allRowsHeight + SettingsMetrics.listBarHeight)
        }

        override func makeBody() -> NSView {
            let container = NSView()
            let listScroll = SettingsColumnScrollView()
            listScroll.translatesAutoresizingMaskIntoConstraints = false
            table.headerView = nil
            table.rowHeight = SettingsMetrics.listRowHeight
            table.addTableColumn(NSTableColumn(identifier: .init("c")))
            table.dataSource = rows
            table.delegate = rows
            listScroll.documentView = table
            container.addSubview(listScroll)
            self.listScroll = listScroll

            let document = NSView()
            document.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(content)
            detailHeight = content.heightAnchor.constraint(equalToConstant: 1000)
            let detailScroll = makeColumnScrollView(document: document,
                                                    estimatedWidth: SettingsMetrics.detailColumnWidth)
            container.addSubview(detailScroll)
            self.detailScroll = detailScroll

            NSLayoutConstraint.activate([
                listScroll.topAnchor.constraint(equalTo: container.topAnchor),
                listScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                listScroll.widthAnchor.constraint(equalToConstant: SettingsMetrics.listWidth),
                listScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -SettingsMetrics.listBarHeight),

                detailScroll.topAnchor.constraint(equalTo: container.topAnchor),
                detailScroll.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: SettingsMetrics.sectionGap),
                detailScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                detailScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                content.topAnchor.constraint(equalTo: document.topAnchor),
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                detailHeight,
            ])
            return container
        }
    }

    /// A pane without a master list, like General: one scrolling body.
    private final class WholePane: SettingsPaneViewController {
        override var paneDescription: String? { "A pane that scrolls as one body." }
        override func makeBody() -> NSView {
            let body = NSView()
            let tall = NSView()
            tall.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(tall)
            NSLayoutConstraint.activate([
                tall.topAnchor.constraint(equalTo: body.topAnchor),
                tall.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                tall.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                tall.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                tall.heightAnchor.constraint(equalToConstant: 900),
            ])
            return body
        }
    }

    /// Extensions' shape: the details scroll above a button that stays put.
    private final class FooterPane: SettingsPaneViewController {
        var detailScroll: NSScrollView!
        let button = NSButton(title: "Uninstall Extension", target: nil, action: nil)
        var detailHeight: NSLayoutConstraint!

        override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
        override var scrollsBodyAsWhole: Bool { false }

        override func makeBody() -> NSView {
            let container = NSView()
            let document = NSView()
            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(content)
            detailHeight = content.heightAnchor.constraint(equalToConstant: 900)
            detailScroll = makeColumnScrollView(document: document, estimatedWidth: SettingsMetrics.detailColumnWidth)
            container.addSubview(detailScroll)
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            NSLayoutConstraint.activate([
                detailScroll.topAnchor.constraint(equalTo: container.topAnchor),
                detailScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                detailScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                detailScroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -SettingsMetrics.sectionGap),
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                content.topAnchor.constraint(equalTo: document.topAnchor),
                content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
                detailHeight,
            ])
            return container
        }
    }

    private func makeListPane(height: CGFloat) -> ListPane {
        let pane = ListPane()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: height))
        pane.table.reloadData()
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    private func frame(of view: NSView, in pane: SettingsPaneViewController) -> NSRect {
        view.convert(view.bounds, to: pane.view)
    }

    private func resize(_ pane: SettingsPaneViewController, height: CGFloat) {
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: height))
        pane.view.layoutSubtreeIfNeeded()
    }

    private func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func offset(_ scrollView: NSScrollView) -> CGFloat { scrollView.contentView.bounds.origin.y }

    private func maxOffset(_ scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        var probe = clip.bounds
        probe.origin.y = 1e7
        return clip.constrainBoundsRect(probe).origin.y
    }

    // MARK: - Fixed columns

    func testListAndDetailsFillThePaneBelowTheDescriptionAtEveryHeight() {
        let pane = makeListPane(height: SettingsMetrics.listPaneMinimumHeight)
        let margin = SettingsMetrics.paneMargin
        // The root view is not flipped: measure the top from the pane's top edge.
        let topGap = pane.view.bounds.height - frame(of: pane.detailScroll, in: pane).maxY
        XCTAssertGreaterThan(topGap, margin + SettingsMetrics.descriptionToBody, "below the description")

        for height: CGFloat in [SettingsMetrics.minimumCappedHeight, 400, 640, 900] {
            resize(pane, height: height)
            let detail = frame(of: pane.detailScroll, in: pane)
            let list = frame(of: pane.listScroll, in: pane)
            XCTAssertEqual(detail.minY, margin, accuracy: 0.5, "details reach the bottom margin at \(height)")
            XCTAssertEqual(height - detail.maxY, topGap, accuracy: 0.5, "details start below the description at \(height)")
            XCTAssertEqual(height - list.maxY, topGap, accuracy: 0.5, "the list starts below the description at \(height)")
            XCTAssertEqual(list.minY, margin + SettingsMetrics.listBarHeight, accuracy: 0.5,
                           "the list reaches its bar at the bottom at \(height)")
        }
    }

    func testScrollingTheDetailsLeavesTheListInPlace() {
        let pane = makeListPane(height: 400)
        let listFrame = frame(of: pane.listScroll, in: pane)
        let detailFrame = frame(of: pane.detailScroll, in: pane)
        scroll(pane.listScroll, to: 40)

        scroll(pane.detailScroll, to: 300)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(offset(pane.detailScroll), 300, accuracy: 0.5, "the details scroll")
        XCTAssertEqual(frame(of: pane.listScroll, in: pane), listFrame, "the list does not move")
        XCTAssertEqual(offset(pane.listScroll), 40, accuracy: 0.5, "the list keeps its own offset")
        XCTAssertEqual(frame(of: pane.detailScroll, in: pane), detailFrame, "the detail area itself stays put")
    }

    func testScrollingTheListLeavesTheDetailsInPlace() {
        let pane = makeListPane(height: 400)
        let detailFrame = frame(of: pane.detailScroll, in: pane)
        scroll(pane.detailScroll, to: 120)

        scroll(pane.listScroll, to: maxOffset(pane.listScroll))
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(offset(pane.listScroll), 0, "30 rows overflow a 400 pt pane")
        XCTAssertEqual(frame(of: pane.detailScroll, in: pane), detailFrame)
        XCTAssertEqual(offset(pane.detailScroll), 120, accuracy: 0.5)
    }

    func testTheDetailDocumentIsAsTallAsItsContentAndAsWideAsTheColumn() {
        let pane = makeListPane(height: 400)
        let document = pane.detailScroll.documentView!
        XCTAssertEqual(document.frame.height, 1000, accuracy: 0.5)
        XCTAssertEqual(document.frame.width, pane.detailScroll.contentView.bounds.width, accuracy: 0.5)
    }

    func testScrollingColumnsToTopLeavesTheList() {
        let pane = makeListPane(height: 400)
        scroll(pane.detailScroll, to: 300)
        scroll(pane.listScroll, to: 50)

        pane.scrollColumnsToTop()

        XCTAssertEqual(offset(pane.detailScroll), 0, accuracy: 0.5, "another selection shows its details from the top")
        XCTAssertEqual(offset(pane.listScroll), 50, accuracy: 0.5, "the list keeps the selection in view")
    }

    // MARK: - Natural height

    func testNaturalHeightShowsTheWholeDetailColumn() {
        let pane = makeListPane(height: 400)
        pane.rows.count = 2
        pane.table.reloadData()
        let tall = pane.naturalContentHeight
        pane.detailHeight.constant = 600
        let shorter = pane.naturalContentHeight
        XCTAssertEqual(tall - shorter, 400, accuracy: 0.5, "the detail content sets the natural height")
    }

    func testNaturalHeightShowsEveryRowWhenTheListIsTaller() {
        let pane = makeListPane(height: 400)
        pane.detailHeight.constant = 100
        pane.rows.count = 40
        pane.table.reloadData()
        let forty = pane.naturalContentHeight
        pane.rows.count = 50
        pane.table.reloadData()
        XCTAssertEqual(pane.naturalContentHeight - forty, 10 * pane.table.rowHeight + 10 * pane.table.intercellSpacing.height,
                       accuracy: 0.5)
    }

    func testNaturalHeightIgnoresTheWindowsCurrentHeight() {
        let pane = makeListPane(height: 400)
        let natural = pane.naturalContentHeight
        resize(pane, height: 900)
        XCTAssertEqual(pane.naturalContentHeight, natural, accuracy: 0.5)
        resize(pane, height: 250)
        XCTAssertEqual(pane.naturalContentHeight, natural, accuracy: 0.5)
    }

    // MARK: - A button below the details

    func testAButtonBelowTheDetailsStaysInViewWhileTheyScroll() {
        let pane = FooterPane()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.listPaneMinimumHeight))
        pane.view.layoutSubtreeIfNeeded()
        let button = frame(of: pane.button, in: pane)
        XCTAssertEqual(button.minY, SettingsMetrics.paneMargin, accuracy: 0.5, "at the bottom of the pane")
        XCTAssertGreaterThan(maxOffset(pane.detailScroll), 0, "900 pt of details overflow a 400 pt pane")

        scroll(pane.detailScroll, to: maxOffset(pane.detailScroll))
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(frame(of: pane.button, in: pane), button, "the button does not scroll with the details")
        XCTAssertGreaterThanOrEqual(frame(of: pane.detailScroll, in: pane).minY, button.maxY, "the details end above it")
    }

    func testNaturalHeightCountsTheButtonBelowTheDetails() {
        let pane = FooterPane()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.listPaneMinimumHeight))
        pane.view.layoutSubtreeIfNeeded()
        let buttonHeight = pane.button.fittingSize.height
        XCTAssertEqual(pane.naturalContentHeight,
                       2 * SettingsMetrics.paneMargin + 900 + SettingsMetrics.sectionGap + buttonHeight, accuracy: 1)
    }

    // MARK: - Whole-body panes

    func testAPaneWithoutAListStillScrollsAsOneBody() {
        let pane = WholePane()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 300))
        pane.view.layoutSubtreeIfNeeded()
        let scrollView = try! XCTUnwrap(pane.scrollView)
        XCTAssertGreaterThanOrEqual(scrollView.documentView!.frame.height, 900, "the body is the scroll view's document")
        scroll(scrollView, to: 200)
        XCTAssertEqual(offset(scrollView), 200, accuracy: 0.5)
    }

    func testAListPaneHasNoBodyScrollView() {
        let pane = makeListPane(height: 400)
        XCTAssertNil(pane.scrollView, "nothing scrolls the list and the details together")
    }

    // MARK: - The real panes

    func testQuickDetourHasAPaneOfItsOwnAfterLinks() {
        XCTAssertEqual(SettingsWindowController.paneOrder.map(\.rawValue),
                       ["general", "spaces", "links", "quickdetour", "profiles", "extensions", "contentblocker"])
    }

    func testPanesWithAListScrollTheirColumnsAndTheOthersScrollAsOneBody() {
        let whole: [SettingsPaneViewController] = [GeneralSettingsViewController(), QuickDetourSettingsViewController(),
                                                   ContentBlockerSettingsViewController()]
        let columns: [SettingsPaneViewController] = [SpacesSettingsViewController(), LinksSettingsViewController(),
                                                     ProfilesSettingsViewController(), ExtensionsSettingsViewController()]
        for pane in whole {
            _ = pane.view
            XCTAssertNotNil(pane.scrollView, "\(type(of: pane)) scrolls as one body")
            XCTAssertNil(pane.minimumContentHeight, "\(type(of: pane)) is fixed at its natural height")
        }
        for pane in columns {
            _ = pane.view
            XCTAssertNil(pane.scrollView, "\(type(of: pane)) keeps its list in place")
            XCTAssertEqual(pane.minimumContentHeight, SettingsMetrics.listPaneMinimumHeight)
        }
    }

    func testTheQuickDetourPaneFitsItsControls() {
        let pane = QuickDetourSettingsViewController()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: 600))
        pane.view.layoutSubtreeIfNeeded()
        let natural = pane.naturalContentHeight
        XCTAssertGreaterThan(natural, 150, "the shortcut, ⌥⌘-click, idle and caption rows")
        XCTAssertLessThan(natural, SettingsMetrics.listPaneMinimumHeight)
    }

    func testTheLinksPaneDoesNotNeedMoreThanTheListMinimum() {
        let pane = LinksSettingsViewController()
        pane.view.setFrameSize(NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.listPaneMinimumHeight))
        pane.view.layoutSubtreeIfNeeded()
        // The Default and its caption, the Routes title and an empty list fit
        // the 400 pt minimum, so it is not raised.
        XCTAssertLessThanOrEqual(pane.naturalContentHeight, SettingsMetrics.listPaneMinimumHeight)
    }

    // MARK: - End anchoring

    func testADetailColumnScrolledToItsEndStaysAtItsEndWhenThePaneShrinks() {
        let pane = makeListPane(height: 640)
        scroll(pane.detailScroll, to: maxOffset(pane.detailScroll))

        resize(pane, height: 420)

        XCTAssertGreaterThan(maxOffset(pane.detailScroll), 0)
        XCTAssertEqual(offset(pane.detailScroll), maxOffset(pane.detailScroll), accuracy: 0.5)
    }

    func testAListScrolledToItsEndStaysAtItsEndWhenThePaneShrinks() {
        let pane = makeListPane(height: 640)
        scroll(pane.listScroll, to: maxOffset(pane.listScroll))

        resize(pane, height: SettingsMetrics.minimumCappedHeight)

        XCTAssertEqual(offset(pane.listScroll), maxOffset(pane.listScroll), accuracy: 0.5)
    }

    func testAListAtItsEndStaysAtItsEndWhenThePaneGrows() {
        let pane = makeListPane(height: 420)
        scroll(pane.listScroll, to: maxOffset(pane.listScroll))

        resize(pane, height: 640)

        XCTAssertEqual(offset(pane.listScroll), maxOffset(pane.listScroll), accuracy: 0.5)
    }

    func testAColumnScrolledElsewhereKeepsItsOffset() {
        let pane = makeListPane(height: 640)
        scroll(pane.detailScroll, to: 150)
        scroll(pane.listScroll, to: 60)

        resize(pane, height: 420)

        XCTAssertEqual(offset(pane.detailScroll), 150, accuracy: 0.5)
        XCTAssertEqual(offset(pane.listScroll), 60, accuracy: 0.5)
    }

    func testAColumnAtItsTopStaysAtItsTop() {
        let pane = makeListPane(height: 640)

        resize(pane, height: 420)

        XCTAssertEqual(offset(pane.detailScroll), 0, accuracy: 0.5)
        XCTAssertEqual(offset(pane.listScroll), 0, accuracy: 0.5)
    }
}
