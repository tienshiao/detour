import XCTest
import WebKit
@testable import Detour

/// TASK-186.4: the dev toolbar's Web Inspector buttons. The decision a Console
/// or Network press makes is the pure `InspectorToggle.action`; which buttons
/// a WebKit gets is `WebInspectorControl.capabilities`, from the selectors it
/// answers. The private calls themselves are checked at runtime
/// (docs/harness/task186-4-harness.patch), not here.
@MainActor
final class WebInspectorControlTests: XCTestCase {

    // MARK: - The toggle rule

    func testAClosedInspectorOpensOnTheRequestedTab() {
        XCTAssertEqual(InspectorToggle.action(isVisible: false, currentTab: nil, requested: .console), .show(.console))
        XCTAssertEqual(InspectorToggle.action(isVisible: false, currentTab: nil, requested: .network), .show(.network))
    }

    func testAClosedInspectorIgnoresTheTabItLastShowed() {
        XCTAssertEqual(InspectorToggle.action(isVisible: false, currentTab: .console, requested: .console), .show(.console))
        XCTAssertEqual(InspectorToggle.action(isVisible: false, currentTab: .network, requested: .network), .show(.network))
    }

    func testPressingTheTabItShowsClosesIt() {
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: .console, requested: .console), .close)
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: .network, requested: .network), .close)
    }

    func testPressingAnotherTabSwitchesToIt() {
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: .network, requested: .console), .switchTo(.console))
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: .console, requested: .network), .switchTo(.network))
    }

    func testAnOtherOrUnknownTabSwitchesRatherThanCloses() {
        // Elements, Sources… or a frontend that did not answer.
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: nil, requested: .console), .switchTo(.console))
        XCTAssertEqual(InspectorToggle.action(isVisible: true, currentTab: nil, requested: .network), .switchTo(.network))
    }

    // MARK: - The frontend's tab types

    func testTheFrontendsTabTypesMapToTabs() {
        XCTAssertEqual(WebInspectorTab(frontendType: "console"), .console)
        XCTAssertEqual(WebInspectorTab(frontendType: "network"), .network)
    }

    func testAnyOtherTabTypeIsNoTab() {
        for type in ["elements", "sources", "timeline", "", "Console", "network "] {
            XCTAssertNil(WebInspectorTab(frontendType: type), type)
        }
        XCTAssertNil(WebInspectorTab(frontendType: nil))
    }

    func testTheShowScriptsCallTheFrontendsOwnFunctions() {
        XCTAssertTrue(WebInspectorControl.showTabScript(.console).contains("WI.showConsoleTab()"))
        XCTAssertTrue(WebInspectorControl.showTabScript(.network).contains("WI.showNetworkTab()"))
    }

    // MARK: - Capabilities

    private typealias S = WebInspectorControl.Selectors

    private func capabilities(webViewLacks: Set<Selector> = [], inspectorLacks: Set<Selector> = []) -> WebInspectorControl.Capabilities {
        WebInspectorControl.capabilities(webViewResponds: { !webViewLacks.contains($0) },
                                         inspectorResponds: { !inspectorLacks.contains($0) })
    }

    func testAWebKitWithEverySelectorGetsEveryButton() {
        XCTAssertEqual(capabilities(), [.console, .network, .elementPicker])
    }

    func testNoInspectorOnTheWebViewMeansNoButtons() {
        XCTAssertEqual(capabilities(webViewLacks: [S.inspector]), [])
    }

    func testWithoutTheFrontendWebViewConsoleAndNetworkCannotReadTheTab() {
        XCTAssertEqual(capabilities(inspectorLacks: [S.inspectorWebView]), [.elementPicker])
    }

    func testEachButtonNeedsItsOwnCalls() {
        XCTAssertEqual(capabilities(inspectorLacks: [S.isVisible]), [.elementPicker], "no way to tell open from closed")
        XCTAssertEqual(capabilities(inspectorLacks: [S.close]), [.elementPicker], "no way to close")
        XCTAssertEqual(capabilities(inspectorLacks: [S.show]), [.console, .elementPicker], "Console opens with showConsole")
        XCTAssertEqual(capabilities(inspectorLacks: [S.showConsole]), [.network, .elementPicker])
        XCTAssertEqual(capabilities(inspectorLacks: [S.toggleElementSelection]), [.console, .network])
        XCTAssertEqual(capabilities(inspectorLacks: [S.isElementSelectionActive]), [.console, .network])
    }

    /// A canary: this Mac's WebKit answers every selector the buttons use.
    /// If a macOS update fails this, the buttons hide; record what changed
    /// in wiki/platform/web-inspector-control.md.
    func testThisWebKitSupportsEveryButton() {
        XCTAssertEqual(WebInspectorControl.capabilities, [.console, .network, .elementPicker])
    }

    // MARK: - The toolbar group

    private func makeToolbar() -> DevToolbarView {
        DevToolbarView(frame: NSRect(x: 0, y: 0, width: 800, height: DevToolbarLayout.height))
    }

    func testTheGroupHasConsoleNetworkAndThePickerAfterTheCopyButton() throws {
        let toolbar = makeToolbar()
        let group = try XCTUnwrap(DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console, .network, .elementPicker]))
        XCTAssertEqual(group.buttons.map { $0.accessibilityLabel() }, ["Console", "Network", "Select Element"])
        let views = toolbar.trailingStack.arrangedSubviews
        XCTAssertEqual(views.first, toolbar.copyButton)
        XCTAssertTrue(views[1] is NSBox, "a separator before the group")
        XCTAssertEqual(Array(views[2...]), group.buttons)
    }

    func testInstallingTwiceKeepsOneGroup() throws {
        let toolbar = makeToolbar()
        let first = DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console])
        let second = DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console])
        XCTAssertTrue(first === second)
        XCTAssertEqual(toolbar.trailingStack.arrangedSubviews.count, 3, "copy, separator, console")
    }

    func testAButtonThisWebKitCannotDriveIsLeftOut() throws {
        let toolbar = makeToolbar()
        let group = try XCTUnwrap(DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.elementPicker]))
        XCTAssertNil(group.consoleButton)
        XCTAssertNil(group.networkButton)
        XCTAssertEqual(group.buttons.map { $0.accessibilityLabel() }, ["Select Element"])
    }

    func testNoCapabilitiesMeansNoGroupAndNoSeparator() {
        let toolbar = makeToolbar()
        XCTAssertNil(DevToolbarInspectorGroup.install(in: toolbar, capabilities: []))
        XCTAssertEqual(toolbar.trailingStack.arrangedSubviews, [toolbar.copyButton])
    }

    func testTheInspectorGroupStaysAfterACaptureGroupAddedLater() throws {
        let toolbar = makeToolbar()
        let group = try XCTUnwrap(DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console, .network]))
        let capture = NSButton(title: "Capture", target: nil, action: nil)
        toolbar.addTrailingGroup([capture], order: .capture)
        let views = toolbar.trailingStack.arrangedSubviews
        XCTAssertEqual(views.count, 6, "copy | capture | console network")
        XCTAssertEqual(views[0], toolbar.copyButton)
        XCTAssertTrue(views[1] is NSBox)
        XCTAssertEqual(views[2], capture)
        XCTAssertTrue(views[3] is NSBox)
        XCTAssertEqual(Array(views[4...]), group.buttons)
    }

    func testTheButtonsReportWhichTabTheyAskFor() throws {
        let toolbar = makeToolbar()
        let group = try XCTUnwrap(DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.console, .network, .elementPicker]))
        var asked: [WebInspectorTab] = []
        var picks = 0
        group.onToggle = { asked.append($0) }
        group.onPickElement = { picks += 1 }
        group.consoleButton?.performClick(nil)
        group.networkButton?.performClick(nil)
        group.elementPickerButton?.performClick(nil)
        XCTAssertEqual(asked, [.console, .network])
        XCTAssertEqual(picks, 1)
    }

    func testThePickerShowsWhenItIsOn() throws {
        let toolbar = makeToolbar()
        let group = try XCTUnwrap(DevToolbarInspectorGroup.install(in: toolbar, capabilities: [.elementPicker]))
        let button = try XCTUnwrap(group.elementPickerButton)
        XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)
        group.isElementPickerActive = true
        XCTAssertEqual(button.contentTintColor, .controlAccentColor)
        group.isElementPickerActive = false
        XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)
    }

    // MARK: - In a window

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    private final class RecordingToggler: WebInspectorToggling {
        var toggles: [(WebInspectorTab, WKWebView)] = []
        var picks: [WKWebView] = []
        func toggle(_ tab: WebInspectorTab, for webView: WKWebView) { toggles.append((tab, webView)) }
        func toggleElementSelection(for webView: WKWebView) { picks.append(webView) }
        func isElementSelectionActive(for webView: WKWebView) -> Bool { false }
    }

    /// A Private window (nothing persisted) with a recording toggler.
    private func makeController() throws -> (BrowserWindowController, Space, RecordingToggler) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        let toggler = RecordingToggler()
        wc.webInspectorToggler = toggler
        return (wc, try XCTUnwrap(wc.activeSpace), toggler)
    }

    private func addTab(_ url: URL, to wc: BrowserWindowController, in space: Space) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: url)
        createdTabs.append(tab)
        return tab
    }

    private let localURL = URL(string: "http://app.test:3000/")!
    private let otherLocalURL = URL(string: "http://api.test:4000/")!

    func testADevModeToolbarInAWindowHasTheGroupOnce() throws {
        let (wc, space, _) = try makeController()
        let tab = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: tab.id)
        let other = addTab(otherLocalURL, to: wc, in: space)
        wc.selectTab(id: other.id)
        wc.selectTab(id: tab.id)   // claimed again: wired again
        let toolbar = try XCTUnwrap(tab.webViewContainer?.devToolbar)
        let group = try XCTUnwrap(toolbar.inspectorGroup)
        // One separator before the capture group (TASK-186.3), one before this one.
        XCTAssertEqual(toolbar.trailingStack.arrangedSubviews.filter { $0 is NSBox }.count, 2)
        XCTAssertEqual(group.buttons.count, 3)
        XCTAssertEqual(toolbar.captureGroup?.buttons.count, 2)
        XCTAssertEqual(toolbar.trailingStack.arrangedSubviews.count, 1 + 1 + 2 + 1 + 3)
    }

    func testTheUnfocusedPanesButtonsActOnThatPanesWebView() throws {
        let (wc, space, toggler) = try makeController()
        let left = addTab(localURL, to: wc, in: space)
        let right = addTab(otherLocalURL, to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        wc.selectTab(id: left.id)
        XCTAssertEqual(wc.selectedTabID, left.id)

        let group = try XCTUnwrap(right.webViewContainer?.devToolbar?.inspectorGroup)
        try XCTUnwrap(group.networkButton).performClick(nil)
        try XCTUnwrap(group.elementPickerButton).performClick(nil)

        XCTAssertEqual(toggler.toggles.count, 1)
        XCTAssertEqual(toggler.toggles.first?.0, .network)
        XCTAssertTrue(toggler.toggles.first?.1 === right.webView, "the toolbar's own pane, not the focused one")
        XCTAssertTrue(toggler.picks.first === right.webView)
        XCTAssertEqual(wc.selectedTabID, right.id, "the clicked pane takes focus")
    }
}
