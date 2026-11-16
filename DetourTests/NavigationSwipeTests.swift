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
    private var server: LoopbackHTTPServer?
    /// Regular windows on a fresh space of the shared store, for the
    /// cross-window case; the store's last active space is put back after.
    private var extraControllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceIDs: (UUID?, UUID?)?

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        for wc in extraControllers { wc.window?.close() }
        extraControllers.removeAll()
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        if let (store, extensions) = previousLastActiveSpaceIDs {
            TabStore.shared.lastActiveSpaceID = store
            ExtensionManager.shared.lastActiveSpaceID = extensions
        }
        server?.stop()
        server = nil
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
        var cache = SwipePictureCache<Int>()
        let ids = (0..<6).map { _ in UUID() }
        for (index, id) in ids.enumerated() { cache.store(index, for: id) }
        XCTAssertEqual(cache.ids, Array(ids.suffix(SwipePictureCache<Int>.capacity)))
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

    @MainActor func testRevisingAPictureKeepsItsPlaceOrDropsIt() {
        var cache = SwipePictureCache<Int>()
        let a = UUID(), b = UUID()
        cache.store(1, for: a)
        cache.store(2, for: b)
        cache.revise(a) { value in value = 10; return true }
        XCTAssertEqual(cache.ids, [a, b], "kept in its place")
        XCTAssertEqual(cache.value(for: a), 10)
        cache.revise(b) { _ in false }
        XCTAssertEqual(cache.ids, [a])
        cache.revise(UUID()) { _ in XCTFail("no value to revise"); return true }
    }

    // MARK: - Pictures of pages left going back (TASK-355)

    /// Stands in for a `WKBackForwardListItem`: only identity matters.
    private final class Item {}

    @MainActor private func makePicture(of item: Item, size: CGSize = CGSize(width: 800, height: 600)) -> ForwardPagePicture<Item> {
        ForwardPagePicture(item: item, image: NSImage(size: NSSize(width: 8, height: 6)), size: size)
    }

    @MainActor func testOnlyABackToAChildsFirstPagePicturesThePageItLeaves() {
        var onPage2 = Self.child
        onPage2.canGoBack = true
        XCTAssertTrue(NavigationSwipeRules.picturesPageLeftGoingBack(onPage2, backListCount: 1),
                      "back lands on the first page, where the own swipe runs forward")
        XCTAssertFalse(NavigationSwipeRules.picturesPageLeftGoingBack(onPage2, backListCount: 2),
                       "back lands on page 2, where WebKit's swipe shows its own picture")
        XCTAssertFalse(NavigationSwipeRules.picturesPageLeftGoingBack(onPage2, backListCount: 0), "no back")
        var noOpener = onPage2
        noOpener.hasOpener = false
        XCTAssertFalse(NavigationSwipeRules.picturesPageLeftGoingBack(noOpener, backListCount: 1),
                       "no opener: WebKit's gesture on the first page too")
        var pinned = onPage2
        pinned.isNormalTab = false
        XCTAssertFalse(NavigationSwipeRules.picturesPageLeftGoingBack(pinned, backListCount: 1))
    }

    /// Kept while the back navigation is in flight (its page still current),
    /// then while it is the forward item; spent once the forward swipe returns.
    @MainActor func testAPictureLastsFromLeavingItsPageUntilReturningToIt() {
        let page1 = Item(), page2 = Item()
        var picture = makePicture(of: page2)
        XCTAssertTrue(picture.stillApplies(currentItem: page2, forwardItem: nil), "the back has not committed yet")
        XCTAssertFalse(picture.shows(forwardItem: nil, webViewSize: picture.size))
        XCTAssertTrue(picture.stillApplies(currentItem: page1, forwardItem: page2), "back on the first page")
        XCTAssertTrue(picture.shows(forwardItem: page2, webViewSize: picture.size))
        XCTAssertTrue(picture.stillApplies(currentItem: page1, forwardItem: page2))
        XCTAssertFalse(picture.stillApplies(currentItem: page2, forwardItem: nil), "returned to it: spent")
    }

    @MainActor func testANewForwardListOrAJumpDropsThePicture() {
        let page1 = Item(), page2 = Item(), page3 = Item()
        var replaced = makePicture(of: page2)
        XCTAssertTrue(replaced.stillApplies(currentItem: page1, forwardItem: page2))
        XCTAssertFalse(replaced.stillApplies(currentItem: page3, forwardItem: nil),
                       "a link followed from the first page replaced the forward list")
        var jumped = makePicture(of: page2)
        XCTAssertFalse(jumped.stillApplies(currentItem: page1, forwardItem: page3),
                       "a history jump left a different forward item")
        XCTAssertFalse(jumped.shows(forwardItem: page3, webViewSize: jumped.size))
    }

    /// TASK-376: a picture in flight follows the history as a kept one does,
    /// and makes a picture only if it comes back while its page is still the
    /// current one and was never left meanwhile.
    @MainActor func testAPictureInFlightCountsOnlyIfItsPageIsStillCurrent() {
        let page1 = Item(), page2 = Item()
        let image = NSImage(size: NSSize(width: 8, height: 6))
        let size = CGSize(width: 800, height: 600)

        let request = ForwardPictureRequest(token: 1, item: page2)
        let picture = request.picture(image: image, size: size, currentItem: page2)
        XCTAssertTrue(picture?.item === page2, "back before the back goes ahead: the page being left")
        XCTAssertEqual(picture?.hasBeenLeft, false)
        XCTAssertNil(request.picture(image: image, size: size, currentItem: page1),
                     "back after the page was left: it may show the page after it")

        var returned = ForwardPictureRequest(token: 2, item: page2)
        XCTAssertTrue(returned.stillApplies(currentItem: page1, forwardItem: page2), "the back committed")
        XCTAssertFalse(returned.stillApplies(currentItem: page2, forwardItem: nil), "and forward again: spent")
        XCTAssertNil(returned.picture(image: image, size: size, currentItem: page2),
                     "a page left and returned to before its picture came back")

        var replaced = ForwardPictureRequest(token: 3, item: page2)
        XCTAssertFalse(replaced.stillApplies(currentItem: Item(), forwardItem: nil), "a new forward list")
    }

    @MainActor func testAResizedPaneGetsThePlainCard() {
        let page2 = Item()
        let picture = makePicture(of: page2, size: CGSize(width: 800, height: 600))
        XCTAssertTrue(picture.shows(forwardItem: page2, webViewSize: CGSize(width: 800.5, height: 600)))
        XCTAssertFalse(picture.shows(forwardItem: page2, webViewSize: CGSize(width: 640, height: 600)),
                       "it would stretch")
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

    // MARK: - The forward picture in a window (TASK-355)

    /// Three pages of solid, different colours from a loopback server: real
    /// back/forward items (`loadHTMLString` documents get none).
    @MainActor private func servePages() async throws -> (URL, URL, URL) {
        func page(_ title: String, _ color: String) -> String {
            "<!doctype html><html><head><title>\(title)</title></head><body style=\"margin:0;background:\(color)\"></body></html>"
        }
        let server = try LoopbackHTTPServer(routes: [
            "/one": page("One", "#ff0000"), "/two": page("Two", "#00ff00"), "/three": page("Three", "#0000ff"),
        ])
        self.server = server
        let port = try await server.start()
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/"))
        return (base.appendingPathComponent("one"), base.appendingPathComponent("two"),
                base.appendingPathComponent("three"))
    }

    @MainActor private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                                      _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private func load(_ url: URL, in tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        webView.load(URLRequest(url: url))
        try await waitUntil("\(url.lastPathComponent) loads") {
            webView.url == url && !webView.isLoading && webView.backForwardList.currentItem?.url == url
        }
    }

    /// A child on its second page, its first page one back.
    @MainActor private func childOnPage2() async throws
        -> (BrowserWindowController, Space, BrowserTab, BrowserWebView, URL, URL, URL) {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        let (one, two, three) = try await servePages()
        try await load(one, in: child)
        try await load(two, in: child)
        try await waitUntil("the child can go back") { child.canGoBack }
        XCTAssertEqual(webView.backForwardList.backList.count, 1)
        return (wc, space, child, webView, one, two, three)
    }

    /// The colour at the middle of `image`, in sRGB.
    @MainActor private func middleColour(of image: NSImage) throws -> NSColor {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let colour = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(colour.usingColorSpace(.sRGB))
    }

    /// Back (the button's core, as Cmd+[ and the mouse's back button) from a
    /// child's page 2 to its first page pictures page 2, and the forward
    /// swipe's card carries that picture, not a blank card. Going forward
    /// spends it.
    @MainActor func testAForwardSwipeAfterBackShowsThePageItReturnsTo() async throws {
        let (wc, _, child, webView, one, two, _) = try await childOnPage2()

        wc.goBack(nil)
        try await waitUntil("back on the first page, page 2 pictured") {
            webView.url == one && !webView.isLoading
                && (wc.navigationSwipePaneStates().first { $0.tabID == child.id }?.hasForwardPicture ?? false)
        }
        try await waitUntil("the own swipe with forward") {
            webView.navigationSwipe.mode == .ownSwipe(canGoForward: true)
        }

        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .forward, tracker: tracker))
        tracker.step(-0.5, phase: .began)
        let card = try XCTUnwrap(wc.navigationSwipe.session?.overlay.forwardPage, "the card carries a picture")
        let colour = try middleColour(of: card.image)
        XCTAssertGreaterThan(colour.greenComponent, 0.8, "page 2 (green) as it was left, not page 1: \(colour)")
        XCTAssertLessThan(colour.redComponent, 0.2, "\(colour)")
        XCTAssertEqual(card.frame, webView.convert(webView.bounds, to: wc.contentContainerView)
            .offsetBy(dx: -(wc.navigationSwipe.session?.overlay.frame.minX ?? 0),
                      dy: -(wc.navigationSwipe.session?.overlay.frame.minY ?? 0)), "at the web view's frame")

        tracker.complete(direction: .forward)
        try await waitUntil("forward on page 2") { webView.url == two && !webView.isLoading && child.canGoBack }
        try await waitUntil("the picture is spent") { wc.navigationSwipe.forwardPictures.value(for: child.id) == nil }
    }

    /// The page's own `history.back()` asks the navigation delegate too, so
    /// it pictures page 2 as a back the window starts does (TASK-376; before
    /// it, the plain card). WebKit's swipe and a `go(to:)` take the same path.
    @MainActor func testABackThePageStartsPicturesThePageItLeavesToo() async throws {
        let (wc, _, child, webView, one, _, _) = try await childOnPage2()

        _ = try await webView.evaluateJavaScript("history.back()")
        try await waitUntil("back on the first page, page 2 pictured, the own swipe with forward") {
            webView.url == one && !webView.isLoading
                && webView.navigationSwipe.mode == .ownSwipe(canGoForward: true)
                && (wc.navigationSwipePaneStates().first { $0.tabID == child.id }?.hasForwardPicture ?? false)
        }
        let picture = try XCTUnwrap(wc.navigationSwipe.forwardPictures.value(for: child.id))
        XCTAssertGreaterThan(try middleColour(of: picture.image).greenComponent, 0.8, "page 2, not page 1")
    }

    /// WebKit's own swipe pictures nothing at its begin: only a swipe that
    /// completes goes back, and WebKit asks the delegate then (TASK-376). A
    /// swipe begun and cancelled leaves nothing in the cache.
    @MainActor func testAWebKitSwipeThatDoesNotGoBackPicturesNothing() async throws {
        let (wc, _, child, webView, _, _, _) = try await childOnPage2()
        var asked = 0
        wc.navigationSwipe.takeForwardPictureSnapshot = { _, _, _ in asked += 1 }

        wc.webViewDidBeginNavigationGesture(webView)
        spinRunLoop()
        wc.webViewDidRemoveNavigationGestureSnapshot(webView)
        XCTAssertEqual(asked, 0)
        XCTAssertNil(wc.navigationSwipe.forwardPictures.value(for: child.id))
        XCTAssertNil(wc.navigationSwipe.forwardPictureRequests[child.id])
    }

    /// Only a back to the first page asks: a forward move from page 2 or a
    /// back that does not land on the first page takes nothing.
    @MainActor func testOnlyABackToTheFirstPageIsPictured() async throws {
        let (wc, _, child, webView, _, _, three) = try await childOnPage2()
        try await load(three, in: child)
        try await waitUntil("on page 3, two back") { webView.backForwardList.backList.count == 2 }
        var asked = 0
        wc.navigationSwipe.takeForwardPictureSnapshot = { _, _, _ in asked += 1 }

        wc.goBack(nil)
        try await waitUntil("back on page 2") { webView.backForwardList.backList.count == 1 && !webView.isLoading }
        XCTAssertEqual(asked, 0, "the back landed on page 2, where WebKit's swipe shows its own picture")
        wc.goForward(nil)
        try await waitUntil("forward on page 3") { webView.url == three && !webView.isLoading }
        XCTAssertEqual(asked, 0, "forward")
        XCTAssertNil(wc.navigationSwipe.forwardPictures.value(for: child.id))
    }

    /// The race TASK-355's review left: the picture asked for on leaving page
    /// 2 comes back only after the user went back and forward again. It is of
    /// a page now current again, spent: kept, a later back the window could
    /// not picture (here held) would have shown it.
    @MainActor func testAPictureThatComesBackAfterThePageWasReturnedToIsDropped() async throws {
        let (wc, _, child, webView, one, two, _) = try await childOnPage2()
        var held: [@MainActor (NSImage?) -> Void] = []
        wc.navigationSwipe.takeForwardPictureSnapshot = { _, _, completion in held.append(completion) }

        wc.goBack(nil)
        try await waitUntil("back on the first page") { webView.url == one && !webView.isLoading && child.canGoForward }
        spinRunLoop()
        wc.goForward(nil)
        try await waitUntil("forward on page 2") { webView.url == two && !webView.isLoading && child.canGoBack }
        spinRunLoop()
        XCTAssertEqual(held.count, 1)
        held[0](NSImage(size: NSSize(width: 8, height: 6)))
        XCTAssertNil(wc.navigationSwipe.forwardPictures.value(for: child.id), "spent before it came back")
        XCTAssertNil(wc.navigationSwipe.forwardPictureRequests[child.id])

        webView.goBack()
        try await waitUntil("back on the first page again") {
            webView.url == one && !webView.isLoading && webView.navigationSwipe.mode == .ownSwipe(canGoForward: true)
        }
        XCTAssertEqual(try pane(child, in: wc).hasForwardPicture, false, "the old picture does not come back")
    }

    /// Only a tab's latest request counts: an older picture coming back after
    /// a newer one does not replace it (TASK-376's request token).
    @MainActor func testAnOlderPictureComingBackLateDoesNotReplaceANewerOne() async throws {
        let (wc, _, child, webView, _, _, _) = try await childOnPage2()
        var held: [@MainActor (NSImage?) -> Void] = []
        wc.navigationSwipe.takeForwardPictureSnapshot = { _, _, completion in held.append(completion) }
        let backItem = try XCTUnwrap(webView.backForwardList.backItem)

        // WebKit asking twice from page 2 (a back refused, then another).
        wc.pictureLeavingPageIfNeeded(in: webView, goingTo: backItem)
        wc.pictureLeavingPageIfNeeded(in: webView, goingTo: backItem)
        XCTAssertEqual(held.count, 2)
        let newer = NSImage(size: NSSize(width: 8, height: 6))
        held[1](newer)
        held[0](NSImage(size: NSSize(width: 4, height: 3)))
        XCTAssertTrue(wc.navigationSwipe.forwardPictures.value(for: child.id)?.image === newer)
    }

    /// A same-document back (a page 2 made by `pushState`): the web process
    /// runs it before it gets to the snapshot, so a picture coming back with
    /// the page already left could be of the first page. It is dropped: the
    /// forward card is never a picture of the wrong page.
    @MainActor func testASameDocumentBackNeverPicturesTheWrongPage() async throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        let (one, _, _) = try await servePages()
        try await load(one, in: child)
        _ = try await webView.evaluateJavaScript("""
            addEventListener('popstate', () => { document.body.style.background = '#ff0000' });
            history.pushState({}, '', 'one-pushed'); document.body.style.background = '#00ff00'; 1
            """)
        try await waitUntil("the pushed page 2") { child.canGoBack && webView.backForwardList.backList.count == 1 }

        var asked = 0
        let take = wc.navigationSwipe.takeForwardPictureSnapshot
        wc.navigationSwipe.takeForwardPictureSnapshot = { webView, configuration, completion in
            asked += 1
            take(webView, configuration, completion)
        }
        wc.goBack(nil)
        try await waitUntil("back on the first page, the snapshot back") {
            webView.url == one && child.canGoForward && asked == 1
                && wc.navigationSwipe.forwardPictureRequests[child.id] == nil
        }
        // Measured on macOS 26.7: the snapshot comes back with the first page
        // already current, so there is no picture (the plain card).
        if let picture = wc.navigationSwipe.forwardPictures.value(for: child.id) {
            let colour = try middleColour(of: picture.image)
            XCTAssertGreaterThan(colour.greenComponent, 0.8, "page 2 as it was left, never page 1: \(colour)")
            XCTAssertLessThan(colour.redComponent, 0.2, "\(colour)")
        }
    }

    /// A pane resized since the picture was taken gets the plain card: the
    /// window fallback, now that every back is pictured.
    @MainActor func testAfterAResizeTheForwardCardIsPlain() async throws {
        let (wc, _, child, webView, one, _, _) = try await childOnPage2()

        wc.goBack(nil)
        try await waitUntil("back on the first page, page 2 pictured") {
            webView.url == one && !webView.isLoading && webView.navigationSwipe.mode == .ownSwipe(canGoForward: true)
                && wc.navigationSwipe.forwardPictures.value(for: child.id) != nil
        }
        let window = try XCTUnwrap(wc.window)
        var frame = window.frame
        frame.size.width -= 120
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(try pane(child, in: wc).hasForwardPicture, false)

        let tracker = ScriptedNavigationSwipeTracker()
        XCTAssertTrue(wc.beginNavigationSwipe(on: webView, direction: .forward, tracker: tracker))
        tracker.step(-0.5, phase: .began)
        XCTAssertNotNil(wc.navigationSwipe.session)
        XCTAssertNil(wc.navigationSwipe.session?.overlay.forwardPage, "the blank card")
        tracker.cancel()
    }

    /// Another window taking the tab's web view over (the user switched to
    /// it) takes the tab's forward picture with it: a forward swipe there
    /// shows it, and none stays behind in the first window's cache (TASK-376).
    @MainActor func testAPictureGoesWithTheWebViewToAnotherWindow() async throws {
        let store = TabStore.shared
        previousLastActiveSpaceIDs = (store.lastActiveSpaceID, ExtensionManager.shared.lastActiveSpaceID)
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Swipe handoff", emoji: "S", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let opener = store.addTab(in: space)
        let child = store.addTab(in: space, parentID: opener.id)
        func window(selecting tab: BrowserTab) -> BrowserWindowController {
            let wc = BrowserWindowController(incognito: false)
            extraControllers.append(wc)
            wc.sidebarSplitView.autosaveName = nil
            wc.setActiveSpace(id: space.id)
            wc.selectTab(id: tab.id)
            wc.showWindow(nil)
            return wc
        }
        func becomeKey(_ wc: BrowserWindowController) {
            wc.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: wc.window))
        }
        let first = window(selecting: child)
        becomeKey(first)
        let second = window(selecting: child)
        becomeKey(first)
        let webView = try XCTUnwrap(child.webView as? BrowserWebView)
        XCTAssertTrue(webView.window === first.window)
        let (one, two, _) = try await servePages()
        try await load(one, in: child)
        try await load(two, in: child)
        try await waitUntil("the child can go back") { child.canGoBack }
        first.goBack(nil)
        try await waitUntil("back on the first page, pictured in the first window") {
            webView.url == one && !webView.isLoading && first.navigationSwipe.forwardPictures.value(for: child.id) != nil
        }

        becomeKey(second)
        XCTAssertTrue(webView.window === second.window, "the second window took the web view over")
        XCTAssertNil(first.navigationSwipe.forwardPictures.value(for: child.id), "none left behind")
        let picture = try XCTUnwrap(second.navigationSwipe.forwardPictures.value(for: child.id), "it went along")
        XCTAssertTrue(picture.item === webView.backForwardList.forwardItem)
    }

    /// Following a link from the first page replaces the forward list: the
    /// picture of the old forward page goes.
    @MainActor func testANavigationFromTheFirstPageDropsThePicture() async throws {
        let (wc, _, child, webView, one, _, three) = try await childOnPage2()

        wc.goBack(nil)
        try await waitUntil("page 2 pictured") {
            webView.url == one && !webView.isLoading && wc.navigationSwipe.forwardPictures.value(for: child.id) != nil
        }
        try await load(three, in: child)
        try await waitUntil("the picture is dropped") { wc.navigationSwipe.forwardPictures.value(for: child.id) == nil }
    }

    /// A tab with no opener keeps WebKit's swipe, which shows its own
    /// picture: Back pictures nothing there.
    @MainActor func testBackOnATabWithNoOpenerPicturesNothing() async throws {
        let (wc, space) = try makeWindow()
        let tab = wc.store.addTab(in: space)
        wc.selectTab(id: tab.id)
        let webView = try XCTUnwrap(tab.webView)
        let (one, two, _) = try await servePages()
        try await load(one, in: tab)
        try await load(two, in: tab)
        try await waitUntil("the tab can go back") { tab.canGoBack }
        wc.goBack(nil)
        try await waitUntil("back on the first page") { webView.url == one && !webView.isLoading }
        spinRunLoop()
        XCTAssertNil(wc.navigationSwipe.forwardPictures.value(for: tab.id))
    }
}
