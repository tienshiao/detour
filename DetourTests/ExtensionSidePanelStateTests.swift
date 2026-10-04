import XCTest
@testable import Detour

/// TASK-132.8: the pure rules behind `chrome.sidePanel` — options, what may
/// open, what is open, which panel a window shows, and where it sits.
final class ExtensionSidePanelStateTests: XCTestCase {

    private typealias State = ExtensionSidePanelState<Int, String>
    private typealias Scope = ExtensionSidePanelScope<Int, String>

    // MARK: Options

    func testWithNothingSetTheManifestPathIsTheDefaultPanel() {
        let state = State(manifestDefaultPath: "panel.html")
        XCTAssertEqual(state.resolvedOptions(for: nil), .init(path: "panel.html", enabled: true))
        XCTAssertEqual(state.resolvedOptions(for: 7), .init(path: "panel.html", enabled: true))
        XCTAssertTrue(state.resolvedOptions(for: nil).isOpenable)
        XCTAssertFalse(state.hasOptions(for: 7))
    }

    func testWithNoManifestPathAndNothingSetThereIsNoPanel() {
        let state = State()
        XCTAssertEqual(state.resolvedOptions(for: nil), .init(path: nil, enabled: true))
        XCTAssertFalse(state.resolvedOptions(for: nil).isOpenable)
        XCTAssertNil(State(manifestDefaultPath: "").manifestDefaultPath, "an empty manifest path is no path")
    }

    func testDefaultOptionsOverrideTheManifestAndOnlyGivenFieldsChange() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: nil, path: "other.html", enabled: nil)
        XCTAssertEqual(state.resolvedOptions(for: nil), .init(path: "other.html", enabled: true))

        state.setOptions(tab: nil, path: nil, enabled: false)
        XCTAssertEqual(state.resolvedOptions(for: nil), .init(path: "other.html", enabled: false),
                       "disabling must not forget the path")
        XCTAssertFalse(state.resolvedOptions(for: nil).isOpenable)

        state.setOptions(tab: nil, path: nil, enabled: true)
        XCTAssertTrue(state.resolvedOptions(for: nil).isOpenable)
    }

    func testTabOptionsAreTheTabsOwnAndFallBackFieldByField() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "tab.html?tabId=1", enabled: true)
        XCTAssertTrue(state.hasOptions(for: 1))
        XCTAssertEqual(state.resolvedOptions(for: 1), .init(path: "tab.html?tabId=1", enabled: true))
        XCTAssertEqual(state.resolvedOptions(for: 2), .init(path: "panel.html", enabled: true),
                       "another tab still has the default panel")
        XCTAssertEqual(state.resolvedOptions(for: nil), .init(path: "panel.html", enabled: true))

        // A tab that only disables its panel keeps the default path.
        state.setOptions(tab: 3, path: nil, enabled: false)
        XCTAssertEqual(state.resolvedOptions(for: 3), .init(path: "panel.html", enabled: false))

        // A tab that only names a path follows the default's enabled flag.
        state.setOptions(tab: 4, path: "four.html", enabled: nil)
        state.setOptions(tab: nil, path: nil, enabled: false)
        XCTAssertEqual(state.resolvedOptions(for: 4), .init(path: "four.html", enabled: false))
        XCTAssertEqual(state.resolvedOptions(for: 1), .init(path: "tab.html?tabId=1", enabled: true),
                       "a tab that said enabled keeps it")
    }

    // MARK: Opening

    func testOpenNeedsATarget() {
        var state = State(manifestDefaultPath: "panel.html")
        XCTAssertEqual(state.open(tab: nil, window: nil), .failure(.missingTarget))
        XCTAssertTrue(state.openScopes.isEmpty)
    }

    func testATabWithItsOwnOptionsOpensATabPanel() {
        var state = State()
        state.setOptions(tab: 1, path: "tab.html", enabled: true)
        XCTAssertEqual(state.open(tab: 1, window: "w"), .success(.tab(1)))
        XCTAssertTrue(state.isOpen(.tab(1)))
        XCTAssertFalse(state.isOpen(.window("w")), "a tab panel is not the window's panel")
    }

    func testATabWithoutOptionsOpensTheDefaultPanelInItsWindow() {
        var state = State(manifestDefaultPath: "panel.html")
        XCTAssertEqual(state.open(tab: 2, window: "w"), .success(.window("w")))
        XCTAssertEqual(state.open(tab: 2, window: nil), .failure(.noWindowForTab))
    }

    func testOpenIsRefusedWhenThePanelIsDisabledOrHasNoPath() {
        var state = State()
        XCTAssertEqual(state.open(tab: 1, window: "w"), .failure(.noActivePanelForTab))
        XCTAssertEqual(state.open(tab: nil, window: "w"), .failure(.noActivePanelForWindow))

        state.setOptions(tab: 1, path: "tab.html", enabled: false)
        XCTAssertEqual(state.open(tab: 1, window: "w"), .failure(.noActivePanelForTab))
        XCTAssertTrue(state.openScopes.isEmpty)

        state.setOptions(tab: 1, path: nil, enabled: true)
        XCTAssertEqual(state.open(tab: 1, window: "w"), .success(.tab(1)))
    }

    func testOpeningAnOpenPanelKeepsOneEntryAndMakesItTheMostRecent() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        _ = state.open(tab: nil, window: "w")
        _ = state.open(tab: 1, window: "w")
        XCTAssertEqual(state.openScopes, [.window("w"), .tab(1)])
    }

    // MARK: Closing

    func testCloseClosesTheTabPanelElseTheWindowPanel() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        _ = state.open(tab: nil, window: "w")

        XCTAssertEqual(state.close(tab: 1, window: "w"), [.tab(1)], "the tab's own panel first")
        XCTAssertEqual(state.openScopes, [.window("w")])
        XCTAssertEqual(state.close(tab: 1, window: "w"), [.window("w")],
                       "with no tab panel open, the panel showing beside the tab is the window's")
        XCTAssertEqual(state.close(tab: 1, window: "w"), [], "closing a closed panel is not an error")
        XCTAssertEqual(state.close(tab: nil, window: nil), [])
    }

    func testDisablingOrLosingThePathClosesOpenPanels() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        _ = state.open(tab: nil, window: "w")
        XCTAssertEqual(state.closeScopesNoLongerOpenable(), [], "nothing changed")

        state.setOptions(tab: 1, path: nil, enabled: false)
        XCTAssertEqual(state.closeScopesNoLongerOpenable(), [.tab(1)])
        XCTAssertEqual(state.openScopes, [.window("w")])

        state.setOptions(tab: nil, path: nil, enabled: false)
        XCTAssertEqual(state.closeScopesNoLongerOpenable(), [.window("w")])
        XCTAssertTrue(state.openScopes.isEmpty)
    }

    func testForgettingATabDropsItsOptionsAndItsPanel() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        XCTAssertEqual(state.forget(tab: 1), .tab(1))
        XCTAssertFalse(state.hasOptions(for: 1))
        XCTAssertTrue(state.openScopes.isEmpty)
        XCTAssertNil(state.forget(tab: 1))
        XCTAssertEqual(state.resolvedOptions(for: 1).path, "panel.html", "a later tab with that key starts over")
    }

    func testForgettingAWindowClosesItsPanelOnly() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        _ = state.open(tab: nil, window: "w")
        _ = state.open(tab: nil, window: "v")
        XCTAssertEqual(state.forget(window: "w"), .window("w"))
        XCTAssertEqual(state.openScopes, [.tab(1), .window("v")], "the tab panel belongs to its tab, not to the window")
        XCTAssertNil(state.forget(window: "w"))
    }

    func testCloseAllAndDidClose() {
        var state = State(manifestDefaultPath: "panel.html")
        state.setOptions(tab: 1, path: "a.html", enabled: true)
        _ = state.open(tab: 1, window: "w")
        _ = state.open(tab: nil, window: "w")
        state.didClose(.tab(1))
        XCTAssertEqual(state.openScopes, [.window("w")])
        XCTAssertEqual(state.closeAll(), [.window("w")])
        XCTAssertTrue(state.openScopes.isEmpty)
        XCTAssertTrue(state.hasOptions(for: 1), "closing panels does not forget options")
    }

    func testPanelBehaviourDefaultsToOff() {
        var state = State()
        XCTAssertFalse(state.openPanelOnActionClick)
        state.openPanelOnActionClick = true
        XCTAssertTrue(state.openPanelOnActionClick)
    }

    // MARK: Which panel a window shows

    private typealias Candidate = ExtensionSidePanelCandidate<Int, String, String>

    func testATabPanelShowsOnlyWhileItsTabIsDisplayed() {
        let candidates = [Candidate(id: "tab1", scope: .tab(1), recency: 1)]
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1], candidates: candidates), "tab1")
        XCTAssertNil(sidePanelToDisplay(window: "w", displayedTabs: [2], candidates: candidates))
        XCTAssertNil(sidePanelToDisplay(window: "w", displayedTabs: [], candidates: candidates),
                     "a window showing a snapshot of the tab does not show its panel")
    }

    func testTheWindowPanelShowsForEveryTabWithoutAnOpenTabPanel() {
        let candidates = [
            Candidate(id: "tab1", scope: .tab(1), recency: 1),
            Candidate(id: "window", scope: .window("w"), recency: 2),
        ]
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1], candidates: candidates), "tab1",
                       "the tab's own panel wins, however recent the window's")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [2], candidates: candidates), "window")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [], candidates: candidates), "window")
        XCTAssertNil(sidePanelToDisplay(window: "v", displayedTabs: [2], candidates: candidates),
                     "another window's panel is not this window's")
    }

    func testTheWindowPanelHidesBesideATabItIsDisabledFor() {
        let candidates = [
            Candidate(id: "wa", scope: .window("w"), recency: 1),
            Candidate(id: "wb", scope: .window("w"), recency: 2),
        ]
        // Extension b disabled its panel for tab 2 (`setOptions({tabId: 2, enabled: false})`).
        let disabled: (String, Int) -> Bool = { id, tab in id == "wb" && tab == 2 }
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1], candidates: candidates,
                                          isDisabledForTab: disabled), "wb")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [2], candidates: candidates,
                                          isDisabledForTab: disabled), "wa",
                       "the panel is hidden beside the tab it is disabled for; another extension's still shows")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1, 2], candidates: candidates,
                                          isDisabledForTab: disabled), "wb",
                       "only the focused pane's options count")
        XCTAssertNil(sidePanelToDisplay(window: "w", displayedTabs: [2], candidates: [candidates[1]],
                                        isDisabledForTab: disabled))
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [], candidates: [candidates[1]],
                                          isDisabledForTab: disabled), "wb",
                       "with no live tab there is nothing to be disabled for")
    }

    func testInASplitTheFocusedPanesPanelWinsThenTheOtherPanes() {
        let candidates = [
            Candidate(id: "left", scope: .tab(1), recency: 5),
            Candidate(id: "right", scope: .tab(2), recency: 1),
        ]
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [2, 1], candidates: candidates), "right")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1, 2], candidates: candidates), "left")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [3, 2],
                                          candidates: candidates), "right",
                       "a focused pane without a panel leaves the other pane's showing")
    }

    func testTwoExtensionsInOnePlaceTheMostRecentShows() {
        let candidates = [
            Candidate(id: "a", scope: .tab(1), recency: 3),
            Candidate(id: "b", scope: .tab(1), recency: 4),
            Candidate(id: "wa", scope: .window("w"), recency: 9),
            Candidate(id: "wb", scope: .window("w"), recency: 8),
        ]
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [1], candidates: candidates), "b")
        XCTAssertEqual(sidePanelToDisplay(window: "w", displayedTabs: [], candidates: candidates), "wa")
    }

    // MARK: Layout

    func testWithNoPanelTheContentFillsTheArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = SidePanelLayout.frames(in: bounds, wantedPanelWidth: nil)
        XCTAssertEqual(frames.content, bounds)
        XCTAssertEqual(frames.panel, .zero)
        XCTAssertEqual(frames.divider, .zero)
    }

    func testThePanelSitsAtTheTrailingEdgeAtItsWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = SidePanelLayout.frames(in: bounds, wantedPanelWidth: 400)
        XCTAssertEqual(frames.content, CGRect(x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(frames.panel, CGRect(x: 600, y: 0, width: 400, height: 600))
        XCTAssertEqual(frames.divider.midX, 600, "the drag strip is centred on the boundary")
        XCTAssertEqual(frames.divider.width, SidePanelLayout.dividerHitWidth)
        XCTAssertEqual(frames.content.maxX, frames.panel.minX, "no gap and no overlap")
    }

    func testThePanelHasAMinimumWidthAndLeavesTheContentItsMinimum() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertEqual(SidePanelLayout.frames(in: bounds, wantedPanelWidth: 50).panel.width,
                       SidePanelLayout.minimumPanelWidth)
        XCTAssertEqual(SidePanelLayout.frames(in: bounds, wantedPanelWidth: 5000).content.width,
                       SidePanelLayout.minimumContentWidth)
    }

    func testInANarrowAreaThePanelKeepsItsMinimumBeforeTheContentDoes() {
        // Too narrow for both minimums: the panel keeps its own.
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 600)
        let frames = SidePanelLayout.frames(in: narrow, wantedPanelWidth: 380)
        XCTAssertEqual(frames.panel.width, SidePanelLayout.minimumPanelWidth)
        XCTAssertEqual(frames.content.width, 400 - SidePanelLayout.minimumPanelWidth)

        // Narrower than the panel's minimum: it takes everything, never more.
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 600)
        let tinyFrames = SidePanelLayout.frames(in: tiny, wantedPanelWidth: 380)
        XCTAssertEqual(tinyFrames.panel, CGRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertEqual(tinyFrames.content.width, 0)
    }

    func testTheWantedWidthSurvivesANarrowWindow() {
        // The wanted width is not what is clamped away: widening the window
        // again gives the panel its width back.
        let wanted: CGFloat = 500
        XCTAssertEqual(SidePanelLayout.frames(in: CGRect(x: 0, y: 0, width: 600, height: 400),
                                              wantedPanelWidth: wanted).panel.width, 360)
        XCTAssertEqual(SidePanelLayout.frames(in: CGRect(x: 0, y: 0, width: 1200, height: 400),
                                              wantedPanelWidth: wanted).panel.width, 500)
    }

    func testDraggingTheDividerGivesAClampedWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertEqual(SidePanelLayout.panelWidth(forBoundaryAt: 700, in: bounds), 300)
        XCTAssertEqual(SidePanelLayout.panelWidth(forBoundaryAt: 990, in: bounds), SidePanelLayout.minimumPanelWidth)
        XCTAssertEqual(SidePanelLayout.panelWidth(forBoundaryAt: 10, in: bounds),
                       1000 - SidePanelLayout.minimumContentWidth)
    }

    func testFramesFollowAnOffsetOrigin() {
        let bounds = CGRect(x: 20, y: 10, width: 1000, height: 600)
        let frames = SidePanelLayout.frames(in: bounds, wantedPanelWidth: 400)
        XCTAssertEqual(frames.content, CGRect(x: 20, y: 10, width: 600, height: 600))
        XCTAssertEqual(frames.panel, CGRect(x: 620, y: 10, width: 400, height: 600))
    }
}
