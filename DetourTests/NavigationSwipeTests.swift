import AppKit
import WebKit
import XCTest
@testable import Detour

/// TASK-325: the back swipe on a tab opened from another tab, with no back
/// history, closes it and returns to its opener — the Back button's result.
/// The rules are pure (first half); the window tests drive the mode and a
/// swipe's completion through a scripted tracker, since synthetic events
/// cannot drive `NSEvent.trackSwipeEvent` (the real gesture is checked by
/// hand).
nonisolated final class NavigationSwipeTests: XCTestCase {

    private var controller: BrowserWindowController?

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        try await super.tearDown()
    }

    @MainActor private static let child = NavigationSwipeFacts(isNormalTab: true, hasOpener: true, canGoBack: false, canGoForward: false)

    // MARK: - When a tab gets the own swipe

    @MainActor func testATabOpenedFromAnotherWithNoBackItemWantsTheOwnSwipe() {
        XCTAssertTrue(NavigationSwipeRules.wantsOwnSwipe(Self.child))
        var facts = Self.child
        facts.canGoForward = true
        XCTAssertTrue(NavigationSwipeRules.wantsOwnSwipe(facts), "a forward item does not change it")
    }

    @MainActor func testWebKitKeepsTheSwipeOtherwise() {
        var withHistory = Self.child
        withHistory.canGoBack = true
        XCTAssertFalse(NavigationSwipeRules.wantsOwnSwipe(withHistory), "a back item: WebKit walks the history")
        var noOpener = Self.child
        noOpener.hasOpener = false
        XCTAssertFalse(NavigationSwipeRules.wantsOwnSwipe(noOpener), "no opener (none, or closed): nothing, as today")
        var pinned = Self.child
        pinned.isNormalTab = false
        XCTAssertFalse(NavigationSwipeRules.wantsOwnSwipe(pinned), "a pinned tab or favourite is never swiped closed")
    }

    @MainActor func testAMainFrameLoadPutsWebKitsGestureBackAtOnce() {
        let mode = NavigationSwipeRules.mode(for: Self.child, isMainFrameNavigationPending: true,
                                             isWebKitGestureActive: false, current: .ownSwipe(canGoForward: false))
        XCTAssertEqual(mode, .webKit, "before the commit, so WebKit records the page being left")
    }

    @MainActor func testTheOwnSwipeComesOnOnlyAfterWebKitsSwipeHasEnded() {
        XCTAssertEqual(NavigationSwipeRules.mode(for: Self.child, isMainFrameNavigationPending: false,
                                                 isWebKitGestureActive: true, current: .webKit), .webKit)
        XCTAssertEqual(NavigationSwipeRules.mode(for: Self.child, isMainFrameNavigationPending: false,
                                                 isWebKitGestureActive: false, current: .webKit),
                       .ownSwipe(canGoForward: false))
        // Already on: a WebKit swipe cannot be running then, and it stays on.
        XCTAssertEqual(NavigationSwipeRules.mode(for: Self.child, isMainFrameNavigationPending: false,
                                                 isWebKitGestureActive: true, current: .ownSwipe(canGoForward: false)),
                       .ownSwipe(canGoForward: false))
    }

    @MainActor func testTheModeCarriesTheForwardItem() {
        var facts = Self.child
        facts.canGoForward = true
        XCTAssertEqual(NavigationSwipeRules.mode(for: facts, isMainFrameNavigationPending: false,
                                                 isWebKitGestureActive: false, current: .webKit),
                       .ownSwipe(canGoForward: true))
    }

    @MainActor func testTheLeftEdgeStopsRubberBandingAndTheRightOneTooWithAForwardItem() {
        XCTAssertEqual(NavigationSwipeRules.rubberBandEdges(for: .webKit, original: 15), 15)
        XCTAssertEqual(NavigationSwipeRules.rubberBandEdges(for: .ownSwipe(canGoForward: false), original: 15), 14)
        XCTAssertEqual(NavigationSwipeRules.rubberBandEdges(for: .ownSwipe(canGoForward: true), original: 15), 10)
        XCTAssertEqual(NavigationSwipeRules.rubberBandEdges(for: .ownSwipe(canGoForward: false), original: 11), 10,
                       "the view's own setting is kept for the other edges")
    }

    // MARK: - What a completed swipe does

    @MainActor func testBackClosesToTheOpenerOnlyWithoutHistory() {
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .back, for: Self.child, isPeekOpen: false), .closeToOpener)
        var withHistory = Self.child
        withHistory.canGoBack = true
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .back, for: withHistory, isPeekOpen: false), .goBack,
                       "a tab with history goes back; it closes only from its first page")
    }

    @MainActor func testBackDoesNothingWithNoOpenerToReturnTo() {
        var noOpener = Self.child
        noOpener.hasOpener = false
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .back, for: noOpener, isPeekOpen: false), .none)
        var pinned = Self.child
        pinned.isNormalTab = false
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .back, for: pinned, isPeekOpen: false), .none)
    }

    @MainActor func testForwardGoesForwardOnlyWithAForwardItem() {
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .forward, for: Self.child, isPeekOpen: false), .none)
        var facts = Self.child
        facts.canGoForward = true
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .forward, for: facts, isPeekOpen: false), .goForward)
    }

    @MainActor func testNothingHappensUnderAPeek() {
        var facts = Self.child
        facts.canGoForward = true
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .back, for: facts, isPeekOpen: true), .none)
        XCTAssertEqual(NavigationSwipeRules.outcome(of: .forward, for: facts, isPeekOpen: true), .none)
    }

    @MainActor func testProgressIsClampedAndCompletionNeedsTheFarEnd() {
        XCTAssertEqual(NavigationSwipeRules.clampedProgress(1.3, direction: .back), 1)
        XCTAssertEqual(NavigationSwipeRules.clampedProgress(-0.2, direction: .back), 0)
        XCTAssertEqual(NavigationSwipeRules.clampedProgress(0.2, direction: .forward), 0)
        XCTAssertEqual(NavigationSwipeRules.clampedProgress(-1.4, direction: .forward), -1)
        XCTAssertTrue(NavigationSwipeRules.swipeCompleted(finalProgress: 1, sawCancelledPhase: false))
        XCTAssertTrue(NavigationSwipeRules.swipeCompleted(finalProgress: -1, sawCancelledPhase: false))
        XCTAssertFalse(NavigationSwipeRules.swipeCompleted(finalProgress: 0, sawCancelledPhase: false))
        XCTAssertFalse(NavigationSwipeRules.swipeCompleted(finalProgress: 1, sawCancelledPhase: true))
    }

    // MARK: - The pending tracker

    @MainActor private func sample(_ phase: NavigationSwipeScrollSample.Phase, dx: CGFloat = 0, dy: CGFloat = 0, at time: TimeInterval = 10,
                        momentum: NavigationSwipeScrollSample.Phase = .none,
                        precise: Bool = true) -> NavigationSwipeScrollSample {
        NavigationSwipeScrollSample(phase: phase, momentumPhase: momentum, hasPreciseScrollingDeltas: precise,
                                    deltaX: dx, deltaY: dy, timestamp: time)
    }

    @MainActor func testAHorizontalGestureStartsTheSwipeAt15Points() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: 4), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.changed, dx: 6, dy: 1), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertEqual(pending.handle(sample(.changed, dx: 6), armedAt: 5, allowsBack: true, allowsForward: false), .back)
        XCTAssertNil(pending.direction, "it starts once")
    }

    @MainActor func testAGestureThatBeganBeforeTheModeCameOnNeverStartsIt() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: 10, at: 4), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.changed, dx: 30, at: 6), armedAt: 5, allowsBack: true, allowsForward: false),
                     "the rest of WebKit's own swipe cannot close the tab")
        XCTAssertNil(pending.handle(sample(.changed, dx: 30, at: 6), armedAt: 5, allowsBack: true, allowsForward: false))
    }

    @MainActor func testOnlyABeganEventStartsAGesture() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.changed, dx: 30), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.none, dx: 30), armedAt: 5, allowsBack: true, allowsForward: false),
                     "a mouse wheel's phase-less event")
        XCTAssertNil(pending.handle(sample(.changed, dx: 0, momentum: .changed), armedAt: 5, allowsBack: true,
                                    allowsForward: false), "momentum")
        XCTAssertNil(pending.handle(sample(.began, dx: 30, precise: false), armedAt: 5, allowsBack: true,
                                    allowsForward: false), "a line-scrolling wheel")
    }

    @MainActor func testAVerticalGestureIsNoSwipe() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: 4, dy: 3), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.direction)
        XCTAssertNil(pending.handle(sample(.began, dx: 4), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.changed, dx: 4, dy: 10), armedAt: 5, allowsBack: true, allowsForward: false),
                     "turning vertical resets it")
        XCTAssertNil(pending.direction)
        XCTAssertNil(pending.handle(sample(.changed, dx: 20), armedAt: 5, allowsBack: true, allowsForward: false))
    }

    @MainActor func testTheGestureEndingResetsIt() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: 10), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.ended), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.handle(sample(.changed, dx: 10), armedAt: 5, allowsBack: true, allowsForward: false))
    }

    @MainActor func testTravelBackTheOtherWayDoesNotStartIt() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: 5), armedAt: 5, allowsBack: true, allowsForward: true))
        XCTAssertNil(pending.handle(sample(.changed, dx: -30), armedAt: 5, allowsBack: true, allowsForward: true))
    }

    @MainActor func testForwardStartsOnlyWhenTheTabCanGoForward() {
        var pending = PendingNavigationSwipe()
        XCTAssertNil(pending.handle(sample(.began, dx: -20), armedAt: 5, allowsBack: true, allowsForward: false))
        XCTAssertNil(pending.direction)
        XCTAssertEqual(pending.handle(sample(.began, dx: -20), armedAt: 5, allowsBack: true, allowsForward: true), .forward)
    }

    // MARK: - Momentum after a completed swipe

    @MainActor func testTheRestOfTheGestureIsSwallowedAfterACompletedSwipe() {
        var filter = NavigationSwipeMomentumFilter()
        XCTAssertFalse(filter.swallows(sample(.changed, dx: 5), now: 10), "nothing before a swipe")
        filter.arm(at: 10)
        XCTAssertTrue(filter.swallows(sample(.ended), now: 10.1))
        XCTAssertTrue(filter.swallows(sample(.none, dx: 8, momentum: .began), now: 10.2))
        XCTAssertTrue(filter.swallows(sample(.none, dx: 4, momentum: .changed), now: 10.3))
        XCTAssertTrue(filter.swallows(sample(.none, momentum: .ended), now: 10.4))
        XCTAssertFalse(filter.swallows(sample(.none, dx: 4, momentum: .changed), now: 10.5), "disarmed at the momentum's end")
    }

    @MainActor func testTheNextGestureOrAMouseWheelOrTimeDisarmsIt() {
        var filter = NavigationSwipeMomentumFilter()
        filter.arm(at: 10)
        XCTAssertFalse(filter.swallows(sample(.began, dx: 2), now: 10.5))
        XCTAssertNil(filter.armedAt)

        filter.arm(at: 10)
        XCTAssertFalse(filter.swallows(sample(.none, dy: 3), now: 10.5), "a mouse wheel")
        XCTAssertNil(filter.armedAt)

        filter.arm(at: 10)
        XCTAssertFalse(filter.swallows(sample(.none, momentum: .changed), now: 10 + NavigationSwipeMomentumFilter.maximumDuration + 0.1))
        XCTAssertNil(filter.armedAt)
    }

    // MARK: - Opener pictures

    @MainActor func testTheCacheKeepsTheMostRecentFew() {
        var cache = OpenerUnderlayCache<Int>()
        let ids = (0..<6).map { _ in UUID() }
        for (index, id) in ids.enumerated() { cache.store(index, for: id) }
        XCTAssertEqual(cache.ids, Array(ids.suffix(OpenerUnderlayCache<Int>.capacity)))
        cache.store(42, for: ids[2])
        XCTAssertEqual(cache.ids.last, ids[2], "storing again makes it the most recent")
        XCTAssertEqual(cache.value(for: ids[2]), 42)
        cache.remove([ids[2]])
        XCTAssertNil(cache.value(for: ids[2]))
        cache.prune { $0 == ids[5] }
        XCTAssertEqual(cache.ids, [ids[5]])
    }

    @MainActor func testAPictureScalesWithTheContentArea() {
        let capture = OpenerUnderlayCapture(image: NSImage(size: NSSize(width: 10, height: 10)),
                                            frame: CGRect(x: 10, y: 0, width: 490, height: 400),
                                            contentSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(capture.frame(inContentOfSize: CGSize(width: 500, height: 400)),
                       CGRect(x: 5, y: 0, width: 245, height: 200))
    }

    @MainActor func testTheSwitcherPreviewSpansTheWidthFromTheTop() {
        let frame = openerPreviewFrame(imageSize: CGSize(width: 480, height: 300),
                                       in: CGRect(x: 0, y: 0, width: 960, height: 800))
        XCTAssertEqual(frame, CGRect(x: 0, y: 200, width: 960, height: 600))
    }

    // MARK: - In a window

    /// A Private window, so nothing is written; a child tab of `opener`.
    @MainActor private func makeWindow() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    @MainActor private func pane(_ tab: BrowserTab, in wc: BrowserWindowController) throws -> NavigationSwipePaneState {
        try XCTUnwrap(wc.navigationSwipePaneStates().first { $0.tabID == tab.id })
    }

    @MainActor private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor func testASelectedChildTabGetsTheOwnSwipe() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)

        let state = try pane(child, in: wc)
        XCTAssertEqual(state.mode, .ownSwipe(canGoForward: false))
        XCTAssertFalse(state.gesturesEnabled, "WebKit's gesture is off")
        XCTAssertEqual(state.rubberBandEdges, 14, "the left edge does not rubber-band")
        XCTAssertEqual(state.openerID, opener.id)
    }

    @MainActor func testATabWithNoOpenerKeepsWebKitsGesture() throws {
        let (wc, space) = try makeWindow()
        let tab = wc.store.addTab(in: space)
        wc.selectTab(id: tab.id)
        let state = try pane(tab, in: wc)
        XCTAssertEqual(state.mode, .webKit)
        XCTAssertTrue(state.gesturesEnabled)
        XCTAssertEqual(state.rubberBandEdges, 15)
    }

    @MainActor func testClosingTheOpenerGivesTheGestureBackToWebKit() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        XCTAssertTrue(try pane(child, in: wc).mode.isOwnSwipe)

        wc.store.closeTab(id: opener.id, in: space)
        let state = try pane(child, in: wc)
        XCTAssertEqual(state.mode, .webKit, "no opener to return to: the swipe does nothing, as before")
        XCTAssertTrue(state.gesturesEnabled)
        XCTAssertEqual(state.rubberBandEdges, 15, "the view's own edges are back")
    }

    @MainActor func testLeavingTheChildGivesItsWebViewBackToWebKit() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView)
        XCTAssertFalse(webView.allowsBackForwardNavigationGestures)

        wc.selectTab(id: opener.id)
        XCTAssertTrue(webView.allowsBackForwardNavigationGestures, "a hidden page still records WebKit's snapshots")
        XCTAssertEqual(BrowserWindowController.rubberBandEdges(of: webView), 15)
        XCTAssertEqual((webView as? BrowserWebView)?.navigationSwipe.mode, .webKit)

        wc.selectTab(id: child.id)
        XCTAssertFalse(webView.allowsBackForwardNavigationGestures, "and the mode is back once it is shown again")
    }

    @MainActor func testALoadGivesTheGestureBackUntilItCommits() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)

        wc.navigationSwipeMainFrameNavigationDidStart(in: webView)
        XCTAssertTrue(webView.allowsBackForwardNavigationGestures)
        XCTAssertEqual(webView.navigationSwipe.mode, .webKit)

        // A commit that added no back item (a replace, a reload): back on.
        wc.navigationSwipeMainFrameNavigationDidEnd(in: webView)
        XCTAssertEqual(webView.navigationSwipe.mode, .ownSwipe(canGoForward: false))
    }

    @MainActor func testTheModeWaitsForWebKitsOwnSwipeToEnd() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        // Off for a load, during which WebKit's own swipe begins.
        wc.navigationSwipeMainFrameNavigationDidStart(in: webView)
        wc.webViewDidBeginNavigationGesture(webView)
        wc.navigationSwipeMainFrameNavigationDidEnd(in: webView)
        XCTAssertEqual(webView.navigationSwipe.mode, .webKit, "not while WebKit's swipe is still showing")
        // A claim of the same view (a re-selection) must not end the wait.
        wc.selectTab(id: child.id)
        XCTAssertEqual(webView.navigationSwipe.mode, .webKit, "a re-claim does not end WebKit's swipe")

        let before = ProcessInfo.processInfo.systemUptime
        wc.webViewDidRemoveNavigationGestureSnapshot(webView)
        XCTAssertEqual(webView.navigationSwipe.mode, .ownSwipe(canGoForward: false))
        XCTAssertGreaterThanOrEqual(webView.navigationSwipe.armedAt, before,
                                    "armed after WebKit's gesture: none of its events can start the own swipe")
    }

    @MainActor func testACompletedSwipeClosesTheChildAndSelectsItsOpener() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)

        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.4, phase: .began)
        XCTAssertNotNil(wc.navigationSwipe.session)
        XCTAssertTrue(space.tabs.contains { $0 === child }, "nothing happens while the fingers are down")
        tracker.complete(direction: .back)

        XCTAssertFalse(space.tabs.contains { $0 === child }, "the child closed")
        XCTAssertEqual(wc.selectedTabID, opener.id, "its opener is selected")
        XCTAssertNil(wc.navigationSwipe.session)
        XCTAssertNotNil(wc.navigationSwipe.momentumFilter.armedAt, "the gesture's momentum is swallowed")
        XCTAssertTrue(opener.webViewContainer?.isDescendant(of: wc.contentContainerView) == true)
    }

    /// The finished veneer fades over the opener; selecting another tab before
    /// it is gone removes it, so the opener's picture never covers that tab.
    @MainActor func testSelectingAnotherTabRemovesAFinishingVeneer() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let other = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.5, phase: .began)
        tracker.complete(direction: .back)
        let veneer = try XCTUnwrap(wc.navigationSwipe.finishingOverlay, "fading over the opener")
        XCTAssertTrue(veneer.isDescendant(of: wc.contentContainerView))

        wc.selectTab(id: other.id)
        XCTAssertNil(wc.navigationSwipe.finishingOverlay)
        XCTAssertNil(veneer.superview)
    }

    @MainActor func testACancelledSwipeLeavesTheTabOpenAndSelected() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)

        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.3, phase: .began)
        let overlay = try XCTUnwrap(wc.navigationSwipe.session?.overlay)
        XCTAssertTrue(overlay.isDescendant(of: wc.contentContainerView))
        tracker.cancel()

        XCTAssertTrue(space.tabs.contains { $0 === child })
        XCTAssertEqual(wc.selectedTabID, child.id)
        XCTAssertNil(overlay.superview, "the veneer is gone")
        XCTAssertTrue(webView.isDescendant(of: wc.contentContainerView))
    }

    @MainActor func testANavigationDuringTheSwipeCancelsIt() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)

        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.5, phase: .began)
        wc.navigationSwipeMainFrameNavigationDidStart(in: webView)
        XCTAssertNil(wc.navigationSwipe.session)
        XCTAssertFalse(tracker.step(0.9, phase: .ended), "its tracking stops")
        XCTAssertTrue(space.tabs.contains { $0 === child }, "the tab is not closed")
    }

    @MainActor func testNoSwipeStartsWhereItWouldDoNothing() throws {
        let (wc, space) = try makeWindow()
        let lone = wc.store.addTab(in: space)
        wc.selectTab(id: lone.id)
        let webView = try XCTUnwrap(lone.webView as? BrowserWebView)
        XCTAssertFalse(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: ScriptedNavigationSwipeTracker()),
                       "no opener and no history")
        XCTAssertFalse(wc.beginNavigationSwipe(on: webView, direction: .forward, tracker: ScriptedNavigationSwipeTracker()),
                       "no forward item")
        XCTAssertNil(wc.navigationSwipe.session)
    }

    /// The swipe acts on the pane that received it, which need not be the
    /// focused one: an unfocused child pane closes, and its opener is selected.
    @MainActor func testASwipeOnTheUnfocusedPaneClosesThatPane() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let focused = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.store.createSplit(draggedTabID: child.id, targetTabID: focused.id, edge: .right, in: space)
        wc.selectTab(id: focused.id)
        XCTAssertEqual(wc.navigationSwipeHostedPanes.map(\.id), [focused.id, child.id])
        XCTAssertTrue(try pane(child, in: wc).mode.isOwnSwipe)
        XCTAssertEqual(try pane(focused, in: wc).mode, .webKit)

        let tracker = ScriptedNavigationSwipeTracker()
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.5, phase: .began)
        tracker.complete(direction: .back)

        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertTrue(space.tabs.contains { $0 === focused }, "the focused pane stays")
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }

    /// An Option-click child's opener is its own split partner: it closes and
    /// the partner, already selected, goes back to single hosting.
    @MainActor func testASplitChildReturnsToItsPartner() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.store.createSplit(draggedTabID: child.id, targetTabID: opener.id, edge: .right, in: space)
        wc.selectTab(id: opener.id)

        let tracker = ScriptedNavigationSwipeTracker()
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .back, tracker: tracker))
        tracker.step(0.5, phase: .began)
        tracker.complete(direction: .back)

        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertEqual(wc.selectedTabID, opener.id)
        XCTAssertEqual(wc.navigationSwipeHostedPanes.map(\.id), [opener.id])
    }

    /// The Back button keeps its result through the shared core: the child
    /// closes and its opener is selected.
    @MainActor func testTheBackButtonStillClosesTheChild() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let other = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        wc.goBack(nil)
        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertTrue(space.tabs.contains { $0 === other })
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }
}
