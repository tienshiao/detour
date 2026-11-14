import AppKit
import Combine
import os
import WebKit

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "NavigationSwipe")

/// One swipe of Detour's own being tracked.
final class NavigationSwipeSession {
    /// The tab whose web view received the swipe: in a split, not necessarily
    /// the focused pane.
    let tabID: UUID
    weak var webView: BrowserWebView?
    let direction: NavigationSwipeDirection
    /// What completing it does, decided at its start and checked again at its
    /// end.
    let outcome: NavigationSwipeOutcome
    let factsAtStart: NavigationSwipeFacts
    let overlay: NavigationSwipeOverlayView
    var progress: CGFloat = 0
    var sawCancelledPhase = false

    init(tabID: UUID, webView: BrowserWebView, direction: NavigationSwipeDirection, outcome: NavigationSwipeOutcome,
         factsAtStart: NavigationSwipeFacts, overlay: NavigationSwipeOverlayView) {
        self.tabID = tabID
        self.webView = webView
        self.direction = direction
        self.outcome = outcome
        self.factsAtStart = factsAtStart
        self.overlay = overlay
    }
}

/// A window's state for Detour's own navigation swipe (TASK-325).
final class NavigationSwipeWindowState {
    /// The swipe being tracked.
    var session: NavigationSwipeSession?
    /// The veneer of a completed swipe, kept over the result until it fades.
    var finishingOverlay: NavigationSwipeOverlayView?
    /// The tab the completed swipe left selected: the veneer is the picture
    /// of what shows there, so selecting any other tab removes it.
    var finishingSelectionID: UUID?
    /// The veneer stays until this web view's load commits or fails, or
    /// `coverTimeout` runs: the forward page after a forward swipe, an opener
    /// that was asleep after a close.
    weak var coverWebView: WKWebView?
    var coverTimeout: DispatchWorkItem?
    var momentumFilter = NavigationSwipeMomentumFilter()
    /// Pictures of openers taken as they left this window's screen.
    var underlays = OpenerUnderlayCache<OpenerUnderlayCapture>()
    var underlayRequests: [UUID: Int] = [:]
    /// canGoBack, canGoForward and isLoading of every hosted pane.
    var paneSubscriptions = Set<AnyCancellable>()
    /// The Debug automation tool's tracker, for a swipe it began.
    var scriptedTracker: ScriptedNavigationSwipeTracker?
}

/// A hosted pane's swipe state, for tests and the Debug automation tool.
struct NavigationSwipePaneState {
    let tabID: UUID
    let mode: NavigationSwipeMode
    let gesturesEnabled: Bool
    let rubberBandEdges: UInt?
    let facts: NavigationSwipeFacts
    let openerID: UUID?
    let hasOpenerPicture: Bool
}

/// Detour's own back swipe (TASK-325): on a tab opened from another tab, with
/// no back item, the two-finger back swipe does what the Back button does —
/// closes the tab and selects its opener. WebKit's own swipe cannot (it needs
/// a back item), so while a hosted tab is in that state its web view's gesture
/// is off, the left edge does not rubber-band, and the scrolls the page does
/// not use (`_webView:didNotHandleWheelEvent:`) start `NSEvent.trackSwipeEvent`.
/// The rules are in NavigationSwipe.swift; the WebKit side in
/// wiki/platform/back-swipe-and-unhandled-scrolls.md.
extension BrowserWindowController {

    // MARK: Facts and mode

    func navigationSwipeFacts(for tab: BrowserTab) -> NavigationSwipeFacts {
        NavigationSwipeFacts(isNormalTab: currentTabs.contains { $0 === tab },
                             hasOpener: parentTab(for: tab) != nil,
                             canGoBack: tab.webView?.canGoBack ?? tab.canGoBack,
                             canGoForward: tab.webView?.canGoForward ?? tab.canGoForward)
    }

    /// The panes whose live web views this window shows: the selected tab and
    /// its split partner, when this window hosts them.
    var navigationSwipeHostedPanes: [BrowserTab] {
        guard let tab = selectedTab else { return [] }
        return splitMembers(of: tab).filter { $0.webView?.isDescendant(of: contentContainerView) == true }
    }

    /// The hosted pane (selected tab or its split partner) whose live web view
    /// is `webView`, if this window shows it.
    func hostedPane(showing webView: WKWebView) -> BrowserTab? {
        guard let selected = selectedTab, webView.isDescendant(of: contentContainerView) else { return nil }
        return splitMembers(of: selected).first { $0.webView === webView }
    }

    /// Puts every hosted pane's web view in the mode the rules give it now.
    func refreshNavigationSwipeModes() {
        for pane in navigationSwipeHostedPanes {
            guard let webView = pane.webView as? BrowserWebView else { continue }
            applyNavigationSwipeMode(to: webView, facts: navigationSwipeFacts(for: pane))
        }
    }

    private func applyNavigationSwipeMode(to webView: BrowserWebView, facts: NavigationSwipeFacts) {
        let state = webView.navigationSwipe
        var target = NavigationSwipeRules.mode(for: facts,
                                               isMainFrameNavigationPending: state.isMainFrameNavigationPending,
                                               isWebKitGestureActive: state.isWebKitGestureActive,
                                               current: state.mode)
        // Without the rubber-banding SPI the left edge eats the scrolls the own
        // swipe needs: keep WebKit's gesture.
        if target.isOwnSwipe, !Self.canControlRubberBanding(webView) { target = .webKit }
        guard target != state.mode else { return }
        setNavigationSwipeMode(target, on: webView)
    }

    private func setNavigationSwipeMode(_ mode: NavigationSwipeMode, on webView: BrowserWebView) {
        let previous = webView.navigationSwipe.mode
        switch mode {
        case .ownSwipe:
            let original = webView.navigationSwipe.originalRubberBandEdges
                ?? Self.rubberBandEdges(of: webView) ?? NavigationSwipeRules.allEdges
            webView.navigationSwipe.originalRubberBandEdges = original
            webView.allowsBackForwardNavigationGestures = false
            Self.setRubberBandEdges(NavigationSwipeRules.rubberBandEdges(for: mode, original: original), of: webView)
            if !previous.isOwnSwipe {
                webView.navigationSwipe.armedAt = ProcessInfo.processInfo.systemUptime
                webView.navigationSwipe.pending.reset()
            }
        case .webKit:
            webView.allowsBackForwardNavigationGestures = true
            if let original = webView.navigationSwipe.originalRubberBandEdges {
                Self.setRubberBandEdges(original, of: webView)
            }
            webView.navigationSwipe.originalRubberBandEdges = nil
            webView.navigationSwipe.pending.reset()
        }
        webView.navigationSwipe.mode = mode
        log.info("Swipe mode \(String(describing: mode), privacy: .public) (was \(String(describing: previous), privacy: .public)), gestures \(webView.allowsBackForwardNavigationGestures, privacy: .public), rubber-band edges \(Self.rubberBandEdges(of: webView) ?? 99, privacy: .public)")
    }

    /// WebKit's gesture for a web view this window starts or stops hosting:
    /// the own mode exists only while a window hosts the view, so a page that
    /// navigates while hidden still records WebKit's snapshots.
    func resetNavigationSwipeMode(of webView: WKWebView) {
        guard let webView = webView as? BrowserWebView else {
            webView.allowsBackForwardNavigationGestures = true
            return
        }
        if webView.navigationSwipe.mode.isOwnSwipe {
            setNavigationSwipeMode(.webKit, on: webView)
        } else {
            webView.allowsBackForwardNavigationGestures = true
        }
        // `isWebKitGestureActive` is left alone: every claim, even of the view
        // already hosted here, passes through this reset, and clearing it would
        // let the own mode come on under WebKit's swipe still showing. The flag
        // lives on the view, so whichever window hosts it next hears the
        // snapshot's removal; the watchdog covers a removal never reported.
    }

    // MARK: Rubber-banding SPI

    // `-[WKWebView _rubberBandingEnabled]` / `_setRubberBandingEnabled:` take a
    // `_WKRectEdge` (NSUInteger). Key-value coding throws on the setter, so
    // both go through their implementations, behind `responds(to:)`.
    private static let rubberBandingSelector = NSSelectorFromString("_rubberBandingEnabled")
    private static let setRubberBandingSelector = NSSelectorFromString("_setRubberBandingEnabled:")

    static func canControlRubberBanding(_ webView: WKWebView) -> Bool {
        webView.responds(to: rubberBandingSelector) && webView.responds(to: setRubberBandingSelector)
    }

    static func rubberBandEdges(of webView: WKWebView) -> UInt? {
        guard webView.responds(to: rubberBandingSelector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(webView.method(for: rubberBandingSelector), to: Getter.self)(webView, rubberBandingSelector)
    }

    private static func setRubberBandEdges(_ edges: UInt, of webView: WKWebView) {
        guard webView.responds(to: setRubberBandingSelector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: setRubberBandingSelector), to: Setter.self)(webView, setRubberBandingSelector, edges)
    }

    // MARK: What changes the mode

    /// Re-observes the hosted panes' history and loading state; called after
    /// every claim.
    func bindNavigationSwipePanes() {
        navigationSwipe.paneSubscriptions.removeAll()
        for pane in navigationSwipeHostedPanes {
            pane.$canGoBack.combineLatest(pane.$canGoForward, pane.$isLoading)
                .dropFirst()
                // Published values are sent before they are stored: read the
                // web view's own state a turn later.
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak pane] _ in
                    guard let self, let pane else { return }
                    self.navigationSwipePaneStateDidChange(pane)
                }
                .store(in: &navigationSwipe.paneSubscriptions)
        }
    }

    private func navigationSwipePaneStateDidChange(_ pane: BrowserTab) {
        // The swipe's tab moved in its history mid-gesture: what it was going
        // to do no longer holds.
        if let session = navigationSwipe.session, session.tabID == pane.id {
            let facts = navigationSwipeFacts(for: pane)
            if facts.canGoBack != session.factsAtStart.canGoBack || facts.canGoForward != session.factsAtStart.canGoForward {
                cancelNavigationSwipe(reason: "history changed")
            }
        }
        // A load that ended without a commit or failure callback (it became a
        // download, say) is not pending any more.
        if let webView = pane.webView as? BrowserWebView, !webView.isLoading {
            webView.navigationSwipe.isMainFrameNavigationPending = false
        }
        refreshNavigationSwipeModes()
    }

    /// A main-frame load started in `webView` (its provisional navigation).
    /// WebKit's gesture goes back on before the commit, so WebKit records the
    /// snapshot of the page being left for its own later swipe back to it.
    func navigationSwipeMainFrameNavigationDidStart(in webView: WKWebView) {
        if let session = navigationSwipe.session, session.webView === webView {
            cancelNavigationSwipe(reason: "navigation started")
        }
        guard let webView = webView as? BrowserWebView else { return }
        webView.navigationSwipe.isMainFrameNavigationPending = true
        if webView.navigationSwipe.mode.isOwnSwipe {
            setNavigationSwipeMode(.webKit, on: webView)
        }
    }

    /// The main-frame load committed or failed.
    func navigationSwipeMainFrameNavigationDidEnd(in webView: WKWebView) {
        if navigationSwipe.coverWebView === webView {
            fadeOutFinishingNavigationSwipeOverlay()
        }
        guard let webView = webView as? BrowserWebView, webView.navigationSwipe.isMainFrameNavigationPending else { return }
        webView.navigationSwipe.isMainFrameNavigationPending = false
        refreshNavigationSwipeModes()
    }

    /// The store changed: an opener may have closed or come back, the swipe's
    /// tab may be gone, and an opener may have no child left to picture.
    func navigationSwipeStoreDidChange(removedTabID: UUID? = nil) {
        if let removedTabID, navigationSwipe.session?.tabID == removedTabID {
            cancelNavigationSwipe(reason: "tab closed")
        }
        navigationSwipe.underlays.prune { [store] id in Self.hasOpenChild(id, in: store) }
        // A request whose tab closed, or whose snapshot failed, never clears
        // its own entry.
        navigationSwipe.underlayRequests = navigationSwipe.underlayRequests.filter { [store] id, _ in
            Self.hasOpenChild(id, in: store)
        }
        refreshNavigationSwipeModes()
    }

    // `WKNavigationDelegatePrivate`: WebKit's own swipe. The own mode comes on
    // only after it is over (its snapshot removed), so that the trailing
    // events of a swipe that went back to the first page cannot also close the
    // tab. A watchdog clears the flag should the removal never be reported.

    @objc(_webViewDidBeginNavigationGesture:)
    func webViewDidBeginNavigationGesture(_ webView: WKWebView) {
        guard let webView = webView as? BrowserWebView else { return }
        webView.navigationSwipe.isWebKitGestureActive = true
        webView.navigationSwipe.webKitGestureGeneration += 1
        let generation = webView.navigationSwipe.webKitGestureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak webView] in
            guard let webView, webView.navigationSwipe.isWebKitGestureActive,
                  webView.navigationSwipe.webKitGestureGeneration == generation else { return }
            webView.navigationSwipe.isWebKitGestureActive = false
            // The window hosting the view now, which may not be this one.
            (webView.window?.windowController as? BrowserWindowController)?.refreshNavigationSwipeModes()
        }
    }

    @objc(_webViewDidRemoveNavigationGestureSnapshot:)
    func webViewDidRemoveNavigationGestureSnapshot(_ webView: WKWebView) {
        guard let webView = webView as? BrowserWebView, webView.navigationSwipe.isWebKitGestureActive else { return }
        webView.navigationSwipe.isWebKitGestureActive = false
        refreshNavigationSwipeModes()
    }

    // MARK: Starting a swipe

    /// `WKUIDelegatePrivate`: a scroll neither the page nor its scrolling tree
    /// used. WebKit reports these only while the view's own gesture is off
    /// and the edge does not rubber-band — that is, in the own mode.
    @objc(_webView:didNotHandleWheelEvent:)
    func webView(_ webView: WKWebView, didNotHandleWheelEvent event: NSEvent) {
        guard let webView = webView as? BrowserWebView else { return }
        let sample = NavigationSwipeScrollSample(event)
        guard case .ownSwipe(let canGoForward) = webView.navigationSwipe.mode, navigationSwipe.session == nil,
              event.type == .scrollWheel, NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
            webView.navigationSwipe.pending.reset()
            // For a hand check that never starts: `log stream --level debug
            // --predicate 'subsystem == "com.detourbrowser.mac" AND category == "NavigationSwipe"'`.
            log.debug("Unhandled scroll ignored: mode \(String(describing: webView.navigationSwipe.mode), privacy: .public), swipe tracking from scrolls \(NSEvent.isSwipeTrackingFromScrollEventsEnabled, privacy: .public), session \(self.navigationSwipe.session != nil, privacy: .public)")
            return
        }
        let direction = webView.navigationSwipe.pending.handle(
            sample, armedAt: webView.navigationSwipe.armedAt, allowsBack: true, allowsForward: canGoForward)
        log.debug("Unhandled scroll: phase \(String(describing: sample.phase), privacy: .public), momentum \(String(describing: sample.momentumPhase), privacy: .public), dx \(sample.deltaX, privacy: .public), dy \(sample.deltaY, privacy: .public), before arming \(sample.timestamp < webView.navigationSwipe.armedAt, privacy: .public) -> \(direction?.rawValue ?? "pending or no", privacy: .public)")
        guard let direction else { return }
        if !beginNavigationSwipe(on: webView, direction: direction, tracker: SystemNavigationSwipeTracker(event: event)) {
            log.info("Swipe \(direction.rawValue, privacy: .public) not started (no outcome, or tracking refused)")
        }
    }

    /// Starts a swipe on `webView`, a hosted pane's, tracked by `tracker`.
    /// False when it does nothing (the rules give no outcome) or cannot start.
    /// The Debug automation tool and tests call this with a scripted tracker,
    /// so a swipe's completion runs the same code as a trackpad's.
    @discardableResult
    func beginNavigationSwipe(on webView: BrowserWebView, direction: NavigationSwipeDirection,
                              tracker: NavigationSwipeTracking) -> Bool {
        guard navigationSwipe.session == nil, let selected = selectedTab,
              let tab = hostedPane(showing: webView) else { return false }
        let facts = navigationSwipeFacts(for: tab)
        let outcome = NavigationSwipeRules.outcome(of: direction, for: facts, isPeekOpen: peekOverlayView != nil)
        guard outcome != .none else { return false }

        removeFinishingNavigationSwipeOverlay()
        let pane: NSView = tab.webViewContainer.flatMap { $0.isDescendant(of: contentContainerView) ? $0 : nil } ?? webView
        let paneRect = pane.convert(pane.bounds, to: contentContainerView)
        guard paneRect.width > 0, paneRect.height > 0 else { return false }
        let isSplitPane = splitMembers(of: selected).count == 2
        // A split pane's close re-tiles the window (its partner goes full
        // width), so no picture would match: a plain background there.
        let underlay = direction == .back && outcome == .closeToOpener && !isSplitPane
            ? openerUnderlayPictures(for: parentTab(for: tab), paneRect: paneRect) : []
        let overlay = NavigationSwipeOverlayView(frame: paneRect, direction: direction,
                                                 page: direction == .back ? snapshotImage(of: pane) : nil,
                                                 underlay: underlay,
                                                 cornerRadius: isSplitPane ? (pane.layer?.cornerRadius ?? 0) : 0)
        contentContainerView.addSubview(overlay, positioned: .below, relativeTo: dragHandle)

        let session = NavigationSwipeSession(tabID: tab.id, webView: webView, direction: direction, outcome: outcome,
                                             factsAtStart: facts, overlay: overlay)
        navigationSwipe.session = session
        let started = tracker.track(direction: direction) { [weak self, weak session] amount, phase, isComplete in
            // A cancelled or replaced session stops its tracking.
            guard let self, let session, self.navigationSwipe.session === session else { return true }
            return self.navigationSwipeStep(session, amount: amount, phase: phase, isComplete: isComplete)
        }
        guard started else {
            cancelNavigationSwipe(reason: "tracking did not start")
            return false
        }
        log.info("Swipe \(direction.rawValue, privacy: .public) began on a pane, outcome \(outcome.rawValue, privacy: .public), underlay pictures \(underlay.count, privacy: .public)")
        return true
    }

    private func navigationSwipeStep(_ session: NavigationSwipeSession, amount: CGFloat, phase: NSEvent.Phase,
                                     isComplete: Bool) -> Bool {
        let progress = NavigationSwipeRules.clampedProgress(amount, direction: session.direction)
        session.progress = progress
        session.overlay.setProgress(progress)
        if phase.contains(.cancelled) { session.sawCancelledPhase = true }
        if isComplete {
            finishNavigationSwipe(session, completed: NavigationSwipeRules.swipeCompleted(
                finalProgress: progress, sawCancelledPhase: session.sawCancelledPhase))
        }
        return false
    }

    // MARK: Ending a swipe

    private func finishNavigationSwipe(_ session: NavigationSwipeSession, completed: Bool) {
        // Ended before anything else runs: the outcome's own navigation and
        // selection must not find a session to cancel.
        navigationSwipe.session = nil
        // Decided again for the same tab: still hosted here, and the rules
        // still give what the swipe started for.
        guard completed, let webView = session.webView,
              let tab = hostedPane(showing: webView), tab.id == session.tabID,
              NavigationSwipeRules.outcome(of: session.direction, for: navigationSwipeFacts(for: tab),
                                           isPeekOpen: peekOverlayView != nil) == session.outcome else {
            session.overlay.removeFromSuperview()
            log.info("Swipe \(session.direction.rawValue, privacy: .public) ended without acting (completed \(completed, privacy: .public))")
            return
        }
        navigationSwipe.momentumFilter.arm(at: ProcessInfo.processInfo.systemUptime)
        navigationSwipe.finishingOverlay = session.overlay
        log.info("Swipe \(session.direction.rawValue, privacy: .public) completed: \(session.outcome.rawValue, privacy: .public)")
        let opener = session.outcome == .closeToOpener ? parentTab(for: tab) : nil
        let openerWasAsleep = opener != nil && opener?.webView == nil
        navigationSwipe.finishingSelectionID = opener?.id ?? selectedTabID
        performNavigationSwipeOutcome(session.outcome, on: tab)
        guard let overlay = navigationSwipe.finishingOverlay else { return }
        // A claim puts the result right below the drag handle, over the
        // veneer: lift it back on top for its fade.
        if overlay.superview === contentContainerView {
            overlay.removeFromSuperview()
            contentContainerView.addSubview(overlay, positioned: .below, relativeTo: dragHandle)
        }
        // The forward page loads under the card; an opener woken from sleep
        // reloads under its picture. Either way, until the load commits.
        let loading = session.outcome == .goForward ? webView : openerWasAsleep ? opener?.webView : nil
        if let loading {
            navigationSwipe.coverWebView = loading
            let timeout = DispatchWorkItem { [weak self] in self?.fadeOutFinishingNavigationSwipeOverlay() }
            navigationSwipe.coverTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: timeout)
        } else {
            fadeOutFinishingNavigationSwipeOverlay()
        }
    }

    /// What a completed swipe does: the Back button's own rule for the tab
    /// that received it (close to the opener, or back), or forward.
    func performNavigationSwipeOutcome(_ outcome: NavigationSwipeOutcome, on tab: BrowserTab) {
        switch outcome {
        case .none:
            break
        case .goBack, .closeToOpener:
            navigateBackOrCloseChildTab(tab)
        case .goForward:
            tab.webView?.goForward()
        }
    }

    /// Ends the swipe being tracked without acting; its tracking stops at its
    /// next report.
    func cancelNavigationSwipe(reason: String) {
        guard let session = navigationSwipe.session else { return }
        navigationSwipe.session = nil
        session.overlay.removeFromSuperview()
        log.info("Swipe cancelled: \(reason, privacy: .public)")
    }

    func removeFinishingNavigationSwipeOverlay() {
        navigationSwipe.coverTimeout?.cancel()
        navigationSwipe.coverTimeout = nil
        navigationSwipe.coverWebView = nil
        navigationSwipe.finishingOverlay?.removeFromSuperview()
        navigationSwipe.finishingOverlay = nil
        navigationSwipe.finishingSelectionID = nil
    }

    /// `selectTab` is about to show `id`: a finished swipe's veneer pictures
    /// the tab that swipe left selected, and must not cover another.
    func navigationSwipeWillSelect(id: UUID) {
        guard navigationSwipe.finishingOverlay != nil, id != navigationSwipe.finishingSelectionID else { return }
        removeFinishingNavigationSwipeOverlay()
    }

    private func fadeOutFinishingNavigationSwipeOverlay() {
        navigationSwipe.coverTimeout?.cancel()
        navigationSwipe.coverTimeout = nil
        navigationSwipe.coverWebView = nil
        guard let overlay = navigationSwipe.finishingOverlay else { return }
        // The picture of the opener is from when it was left: a short fade
        // hides the jump to the live page.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            overlay.animator().alphaValue = 0
        }, onMain: { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if let self, self.navigationSwipe.finishingOverlay === overlay {
                self.navigationSwipe.finishingOverlay = nil
                self.navigationSwipe.finishingSelectionID = nil
            }
        })
    }

    /// The content area is going away or changing size: a veneer would no
    /// longer match what is under it.
    func navigationSwipeContentWillChange() {
        cancelNavigationSwipe(reason: "content changed")
        removeFinishingNavigationSwipeOverlay()
    }

    // MARK: Three-finger swipes and momentum

    /// A three-finger "swipe between pages" (one discrete event, as WebKit
    /// reads it: a positive deltaX is back) on a web view in the own mode.
    /// True when it acted.
    func handleDiscreteNavigationSwipe(_ event: NSEvent, on webView: BrowserWebView) -> Bool {
        guard webView.navigationSwipe.mode.isOwnSwipe, navigationSwipe.session == nil, event.deltaX != 0,
              let tab = hostedPane(showing: webView) else { return false }
        let direction: NavigationSwipeDirection = event.deltaX > 0 ? .back : .forward
        let outcome = NavigationSwipeRules.outcome(of: direction, for: navigationSwipeFacts(for: tab),
                                                   isPeekOpen: peekOverlayView != nil)
        guard outcome != .none else { return false }
        log.info("Three-finger swipe \(direction.rawValue, privacy: .public): \(outcome.rawValue, privacy: .public)")
        performNavigationSwipeOutcome(outcome, on: tab)
        return true
    }

    func swallowsScrollAfterNavigationSwipe(_ event: NSEvent) -> Bool {
        guard navigationSwipe.momentumFilter.armedAt != nil else { return false }
        return navigationSwipe.momentumFilter.swallows(NavigationSwipeScrollSample(event),
                                                       now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Opener pictures

    /// Whether some normal tab was opened from `tabID` and is still open.
    static func hasOpenChild(_ tabID: UUID, in store: TabStore) -> Bool {
        store.spaces.contains { space in space.tabs.contains { $0.parentID == tabID } }
    }

    /// Pictures `tab` at full size (at one pixel per point, which keeps a
    /// Retina capture to a quarter of the memory) as it leaves this window's
    /// screen, if a tab opened from it is still open: what shows under a back
    /// swipe that closes that tab. Taken now, while the page is still on
    /// screen at foreground priority; a later capture can take seconds, and
    /// none at all once it sleeps.
    func captureOpenerUnderlayIfNeeded(of tab: BrowserTab) {
        guard window?.isVisible == true, Self.hasOpenChild(tab.id, in: store),
              let webView = tab.webView, webView.isDescendant(of: contentContainerView),
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let frame = webView.convert(webView.bounds, to: contentContainerView)
        let contentSize = contentContainerView.bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let config = WKSnapshotConfiguration()
        // Points; the image comes back at the backing scale.
        config.snapshotWidth = NSNumber(value: Double(webView.bounds.width / scale))
        let request = (navigationSwipe.underlayRequests[tab.id] ?? 0) + 1
        navigationSwipe.underlayRequests[tab.id] = request
        webView.takeSnapshot(with: config) { [weak self, weak tab, weak webView] image, _ in
            guard let self, let tab, let image, self.navigationSwipe.underlayRequests[tab.id] == request else { return }
            self.navigationSwipe.underlayRequests[tab.id] = nil
            // Selected again before the picture came back: it is on screen,
            // and is pictured when it leaves next.
            guard webView?.isDescendant(of: self.contentContainerView) != true,
                  Self.hasOpenChild(tab.id, in: self.store) else { return }
            self.navigationSwipe.underlays.store(
                OpenerUnderlayCapture(image: image, frame: frame, contentSize: contentSize), for: tab.id)
        }
    }

    /// The tabs now on screen need no picture: they are pictured when they
    /// leave.
    func dropOpenerUnderlays(for tabs: [BrowserTab]) {
        navigationSwipe.underlays.remove(tabs.map(\.id))
        for tab in tabs { navigationSwipe.underlayRequests[tab.id] = nil }
    }

    /// What goes under the page as it slides off to `opener`, in the coordinates
    /// of a veneer at `paneRect`: each of the opener's panes at the frame it
    /// had when pictured (a split opener comes back as its split), else its
    /// switcher preview across the top, else nothing (a plain background).
    private func openerUnderlayPictures(for opener: BrowserTab?,
                                        paneRect: CGRect) -> [NavigationSwipeOverlayView.Picture] {
        guard let opener else { return [] }
        let size = contentContainerView.bounds.size
        let pictures = splitMembers(of: opener).compactMap { member -> NavigationSwipeOverlayView.Picture? in
            guard let capture = navigationSwipe.underlays.value(for: member.id) else { return nil }
            let frame = capture.frame(inContentOfSize: size).offsetBy(dx: -paneRect.minX, dy: -paneRect.minY)
            return .init(image: capture.image, frame: frame)
        }
        if !pictures.isEmpty { return pictures }
        if splitMembers(of: opener).count == 1, let preview = opener.switcherPreview {
            let bounds = CGRect(origin: .zero, size: paneRect.size)
            return [.init(image: preview, frame: openerPreviewFrame(imageSize: preview.size, in: bounds))]
        }
        return []
    }

    // MARK: State, for tests and the Debug tool

    func navigationSwipePaneStates() -> [NavigationSwipePaneState] {
        navigationSwipeHostedPanes.map { pane in
            let webView = pane.webView
            return NavigationSwipePaneState(
                tabID: pane.id,
                mode: (webView as? BrowserWebView)?.navigationSwipe.mode ?? .webKit,
                gesturesEnabled: webView?.allowsBackForwardNavigationGestures ?? false,
                rubberBandEdges: webView.flatMap(Self.rubberBandEdges(of:)),
                facts: navigationSwipeFacts(for: pane),
                openerID: parentTab(for: pane)?.id,
                hasOpenerPicture: parentTab(for: pane).map { navigationSwipe.underlays.value(for: $0.id) != nil } ?? false)
        }
    }
}
