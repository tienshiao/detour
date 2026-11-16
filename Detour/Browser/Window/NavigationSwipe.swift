import AppKit

// TASK-325: the two-finger back swipe on a tab opened from another tab, which
// WebKit's own swipe cannot do (it needs a back item). The rules here are pure
// and unit-tested (NavigationSwipeTests); the window wiring is in
// BrowserWindowController+NavigationSwipe.swift. WebKit's behaviour behind them:
// wiki/platform/back-swipe-and-unhandled-scrolls.md.

/// Which way a horizontal swipe goes, read as WebKit reads it in a
/// left-to-right layout: a positive `scrollingDeltaX` (the content follows the
/// fingers to the right) is back.
enum NavigationSwipeDirection: String, Equatable {
    case back
    case forward
}

/// Who handles a tab web view's horizontal swipes.
enum NavigationSwipeMode: Equatable {
    /// WebKit's own back/forward gesture: it walks the history when there is
    /// an item that way and does nothing otherwise.
    case webKit
    /// Detour's own swipe: WebKit's gesture is off, the left edge (and, with a
    /// forward item, the right one) does not rubber-band, and the scrolls the
    /// page cannot use start Detour's tracker. Back closes the tab to its
    /// opener; forward goes forward when there is a forward item.
    case ownSwipe(canGoForward: Bool)

    var isOwnSwipe: Bool {
        if case .ownSwipe = self { return true }
        return false
    }
}

/// What the rules know about one tab.
struct NavigationSwipeFacts: Equatable {
    /// In its space's tab list: not a pinned tab, a favourite or a Peek. Only
    /// such a tab is closed by the Back button's close (`TabStore.closeTab`
    /// ignores the others).
    var isNormalTab: Bool
    /// Its opener resolves the way the Back button resolves it
    /// (`parentTab(for:)`: a tab, live pinned tab or live favourite of the
    /// window's active space, `Space.openerTab(id:)`).
    var hasOpener: Bool
    var canGoBack: Bool
    var canGoForward: Bool
}

/// What a completed swipe does to the tab whose web view received it.
enum NavigationSwipeOutcome: String, Equatable {
    case none
    case goBack
    /// The Back button's close: the tab closes (a closed-tab record, so Reopen
    /// Closed Tab brings it back) and its opener is selected.
    case closeToOpener
    case goForward
}

enum NavigationSwipeRules {

    /// The tab wants Detour's own swipe: a normal tab whose opener is still
    /// there, with no back item. A pinned tab or favourite keeps WebKit's
    /// gesture: a swipe never closes or leaves it.
    static func wantsOwnSwipe(_ facts: NavigationSwipeFacts) -> Bool {
        facts.isNormalTab && facts.hasOpener && !facts.canGoBack
    }

    /// The mode a hosted tab's web view should be in now.
    ///
    /// - `isMainFrameNavigationPending`: a main-frame load has started and not
    ///   committed. WebKit records the snapshot of the page being left (for its
    ///   own later swipe back to it) only while its gesture is on, at commit,
    ///   so the gesture goes back on as soon as a load starts.
    /// - `isWebKitGestureActive`: WebKit's own swipe has begun and its snapshot
    ///   is not yet removed. Leaving the own mode is immediate, but entering it
    ///   waits until that gesture is over, so a trailing event of a swipe that
    ///   only went back to the first page can never close the tab.
    static func mode(for facts: NavigationSwipeFacts, isMainFrameNavigationPending: Bool,
                     isWebKitGestureActive: Bool, current: NavigationSwipeMode) -> NavigationSwipeMode {
        guard wantsOwnSwipe(facts), !isMainFrameNavigationPending else { return .webKit }
        if !current.isOwnSwipe && isWebKitGestureActive { return .webKit }
        return .ownSwipe(canGoForward: facts.canGoForward)
    }

    // `_WKRectEdge` bits, as `_rubberBandingEnabled` takes them.
    static let leftEdge: UInt = 1
    static let rightEdge: UInt = 4
    static let allEdges: UInt = 15

    /// The edges that rubber-band in `mode`, from the web view's own setting:
    /// in the own mode, not the left edge (the back-direction scrolls a page
    /// cannot use are then reported, not eaten by the bounce), and not the
    /// right one either while there is a forward item.
    static func rubberBandEdges(for mode: NavigationSwipeMode, original: UInt) -> UInt {
        switch mode {
        case .webKit: original
        case .ownSwipe(let canGoForward): original & ~(canGoForward ? leftEdge | rightEdge : leftEdge)
        }
    }

    /// What a completed swipe in `direction` does to the tab that received it
    /// — not necessarily the focused pane of a split. The Back button's rule,
    /// applied to that tab: back goes back in its history, or with none closes
    /// it to its opener; forward goes forward. Nothing while a Peek is over the
    /// tab: Back acts on the Peek then.
    static func outcome(of direction: NavigationSwipeDirection, for facts: NavigationSwipeFacts,
                        isPeekOpen: Bool) -> NavigationSwipeOutcome {
        guard !isPeekOpen else { return .none }
        switch direction {
        case .back:
            if facts.canGoBack { return .goBack }
            return facts.isNormalTab && facts.hasOpener ? .closeToOpener : .none
        case .forward:
            return facts.canGoForward ? .goForward : .none
        }
    }

    /// The gesture amount `NSEvent.trackSwipeEvent` reports, clamped as WebKit
    /// clamps it: 0…1 going back, -1…0 going forward.
    static func clampedProgress(_ amount: CGFloat, direction: NavigationSwipeDirection) -> CGFloat {
        switch direction {
        case .back: min(max(amount, 0), 1)
        case .forward: min(max(amount, -1), 0)
        }
    }

    /// Whether a finished tracking completed the swipe: the user did not
    /// cancel it, and the animation ended at the far end (it ends at -1, 0 or
    /// 1).
    static func swipeCompleted(finalProgress: CGFloat, sawCancelledPhase: Bool) -> Bool {
        !sawCancelledPhase && abs(finalProgress) > 0.5
    }
}

/// The own-swipe state of one tab web view, kept on the view itself
/// (`BrowserWebView.navigationSwipe`) so it travels with it between windows.
struct NavigationSwipeViewState {
    var mode: NavigationSwipeMode = .webKit
    /// When the own mode last came on (system uptime): a gesture that began
    /// before never starts the own swipe.
    var armedAt: TimeInterval = 0
    /// The rubber-band edges the view had before the own mode changed them.
    var originalRubberBandEdges: UInt?
    /// WebKit's own swipe began and its snapshot is not yet removed.
    var isWebKitGestureActive = false
    var webKitGestureGeneration = 0
    /// A main-frame load started and has not committed or failed.
    var isMainFrameNavigationPending = false
    var pending = PendingNavigationSwipe()
}

// MARK: - Scroll events

/// One scroll event, as the trackers below read it.
struct NavigationSwipeScrollSample: Equatable {
    enum Phase: Equatable {
        case none, mayBegin, began, stationary, changed, ended, cancelled
    }

    var phase: Phase
    var momentumPhase: Phase
    var hasPreciseScrollingDeltas: Bool
    var deltaX: CGFloat
    var deltaY: CGFloat
    var timestamp: TimeInterval

    var isMomentum: Bool { momentumPhase != .none }

    init(phase: Phase, momentumPhase: Phase = .none, hasPreciseScrollingDeltas: Bool = true,
         deltaX: CGFloat = 0, deltaY: CGFloat = 0, timestamp: TimeInterval = 0) {
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.timestamp = timestamp
    }

    init(_ event: NSEvent) {
        self.init(phase: Self.phase(event.phase), momentumPhase: Self.phase(event.momentumPhase),
                  hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                  deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, timestamp: event.timestamp)
    }

    static func phase(_ phase: NSEvent.Phase) -> Phase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.stationary) { return .stationary }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
    }
}

/// WebKit's `PendingSwipeTracker`, fed only the scrolls the page did not use
/// (`_webView:didNotHandleWheelEvent:`). A swipe can start only from a
/// gesture's began event, received after the own mode came on, that is mostly
/// horizontal and goes a way the tab can go; it starts once the gesture's
/// horizontal travel reaches 15 pt without turning vertical.
struct PendingNavigationSwipe: Equatable {
    static let minimumHorizontalDistance: CGFloat = 15
    /// A delta is too vertical when |dy| ≥ |dx| × this (WebKit's
    /// `minimumScrollEventRatioForSwipe`).
    static let verticalRatio: CGFloat = 0.5

    private(set) var direction: NavigationSwipeDirection?
    private var cumulativeX: CGFloat = 0
    private var cumulativeY: CGFloat = 0

    mutating func reset() {
        direction = nil
        cumulativeX = 0
        cumulativeY = 0
    }

    /// Feeds one unhandled event. Returns the direction when the swipe should
    /// start with this event.
    ///
    /// - `armedAt`: when the own mode came on (system uptime, as event
    ///   timestamps are). A gesture that began before is never a swipe here.
    mutating func handle(_ sample: NavigationSwipeScrollSample, armedAt: TimeInterval,
                         allowsBack: Bool, allowsForward: Bool) -> NavigationSwipeDirection? {
        guard sample.hasPreciseScrollingDeltas, !sample.isMomentum,
              sample.phase != .ended, sample.phase != .cancelled else {
            reset()
            return nil
        }
        if sample.phase == .began {
            reset()
            guard sample.timestamp >= armedAt,
                  !Self.isTooVertical(dx: sample.deltaX, dy: sample.deltaY) else { return nil }
            let candidate: NavigationSwipeDirection = sample.deltaX > 0 ? .back : .forward
            guard candidate == .back ? allowsBack : allowsForward else { return nil }
            direction = candidate
        } else {
            // A changed (or stationary) event of a gesture whose began started
            // one; a phase-less wheel or a may-begin never influences a swipe.
            guard direction != nil, sample.phase == .changed || sample.phase == .stationary else { return nil }
        }
        guard let direction else { return nil }
        cumulativeX += sample.deltaX
        cumulativeY += sample.deltaY
        if Self.isTooVertical(dx: cumulativeX, dy: cumulativeY) {
            reset()
            return nil
        }
        let travel = direction == .back ? cumulativeX : -cumulativeX
        guard travel >= Self.minimumHorizontalDistance else { return nil }
        reset()
        return direction
    }

    static func isTooVertical(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dy) >= abs(dx) * verticalRatio
    }
}

/// After a completed swipe, the rest of that gesture — the trailing events and
/// the momentum the system adds after the fingers lift — must not scroll the
/// page now under the pointer (the opener, after a close). Disarms at the
/// next gesture's start, at the momentum's end, at a plain mouse wheel, or
/// after `maximumDuration`.
struct NavigationSwipeMomentumFilter: Equatable {
    static let maximumDuration: TimeInterval = 2

    private(set) var armedAt: TimeInterval?

    mutating func arm(at time: TimeInterval) {
        armedAt = time
    }

    /// Whether to drop `sample`, which arrives at `now`.
    mutating func swallows(_ sample: NavigationSwipeScrollSample, now: TimeInterval) -> Bool {
        guard let armedAt else { return false }
        guard now - armedAt <= Self.maximumDuration else {
            self.armedAt = nil
            return false
        }
        if sample.isMomentum {
            if sample.momentumPhase == .ended || sample.momentumPhase == .cancelled { self.armedAt = nil }
            return true
        }
        switch sample.phase {
        case .changed, .stationary, .ended, .cancelled:
            return true
        case .began, .mayBegin, .none:
            // A new gesture, or a mouse wheel: the swipe's events are over.
            self.armedAt = nil
            return false
        }
    }
}

// MARK: - Opener pictures

/// A full-size picture of an opener's page, taken as it left the screen, for
/// what shows under a back swipe that closes a tab it opened.
struct OpenerUnderlayCapture {
    let image: NSImage
    /// The web view's frame in the content area when it was taken, and the
    /// content area's size then.
    let frame: CGRect
    let contentSize: CGSize

    /// `frame`, scaled for a content area of `size`.
    func frame(inContentOfSize size: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return frame }
        let sx = size.width / contentSize.width
        let sy = size.height / contentSize.height
        return CGRect(x: frame.minX * sx, y: frame.minY * sy, width: frame.width * sx, height: frame.height * sy)
    }
}

/// The swipe pictures a window keeps per tab (the openers', TASK-325; the
/// pages left going back, TASK-355): a few, most recently stored last; the
/// oldest goes when a new one would exceed `capacity`.
struct SwipePictureCache<Value> {
    static var capacity: Int { 4 }

    private(set) var entries: [(id: UUID, value: Value)] = []

    var ids: [UUID] { entries.map(\.id) }

    func value(for id: UUID) -> Value? {
        entries.first { $0.id == id }?.value
    }

    mutating func store(_ value: Value, for id: UUID) {
        entries.removeAll { $0.id == id }
        entries.append((id, value))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func remove<S: Sequence>(_ ids: S) where S.Element == UUID {
        let ids = Set(ids)
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func prune(keeping keep: (UUID) -> Bool) {
        entries.removeAll { !keep($0.id) }
    }

    /// Re-checks the value for `id` in place (its place in the order kept):
    /// `keep` may update it, and returns false to drop it.
    mutating func revise(_ id: UUID, _ keep: (inout Value) -> Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !keep(&entries[index].value) { entries.remove(at: index) }
    }
}

// MARK: - Pictures of pages left going back (TASK-355)

extension NavigationSwipeRules {
    /// Whether to picture a tab's page as a back navigation leaves it, for the
    /// forward swipe that returns to it: only when the back lands on the tab's
    /// first page (`backListCount` 1) and the tab is a normal tab with an
    /// opener. Only there does Detour's own swipe run forward
    /// (`.ownSwipe(canGoForward: true)`); everywhere else WebKit's own swipe
    /// shows WebKit's own picture of the forward page.
    static func picturesPageLeftGoingBack(_ facts: NavigationSwipeFacts, backListCount: Int) -> Bool {
        facts.isNormalTab && facts.hasOpener && backListCount == 1
    }
}

/// A picture of a page taken as a back navigation left it, kept with the
/// back/forward item it is of, for the forward swipe that returns to it.
/// `Item` is `WKBackForwardListItem` in the app (WebKit keeps one wrapper per
/// item, so identity holds); tests use a plain class.
struct ForwardPagePicture<Item: AnyObject> {
    let item: Item
    let image: NSImage
    /// The web view's size when pictured.
    let size: CGSize
    /// The back navigation has left `item`: once it is current again (the
    /// forward swipe or Forward returned to it) the picture is spent.
    private(set) var hasBeenLeft = false

    init(item: Item, image: NSImage, size: CGSize) {
        self.item = item
        self.image = image
        self.size = size
    }

    /// Whether the picture still belongs to a page a forward swipe can return
    /// to, from the web view's history now. It does while `item` is still the
    /// current item (the back navigation that leaves it has not committed:
    /// while a load is provisional `currentItem` is the old entry) and then
    /// while it is the forward item. A navigation from the first page replaces
    /// the forward list, a jump elsewhere in the history moves it, and a return
    /// to the pictured page uses it up: each drops it.
    mutating func stillApplies(currentItem: Item?, forwardItem: Item?) -> Bool {
        if currentItem === item { return !hasBeenLeft }
        hasBeenLeft = true
        return forwardItem === item
    }

    /// Whether a forward swipe on a web view whose forward item is
    /// `forwardItem` and whose size is `webViewSize` shows it. A pane resized
    /// since (window, split divider, dev toolbar) would stretch the picture:
    /// the plain card then.
    func shows(forwardItem: Item?, webViewSize: CGSize) -> Bool {
        forwardItem === item && abs(size.width - webViewSize.width) <= 1 && abs(size.height - webViewSize.height) <= 1
    }
}

/// Where the opener's switcher preview (480 px wide) goes when there is no
/// full-size picture: the width of the area, from its top (non-flipped
/// coordinates).
func openerPreviewFrame(imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
    let height = bounds.width * imageSize.height / imageSize.width
    return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
}

// MARK: - The tracker seam

/// Tracks one swipe and reports its progress, so the swipe's decisions can be
/// tested and driven without a trackpad. The handler gets the gesture amount,
/// the physical phase and whether tracking is over, and returns true to stop
/// tracking early.
protocol NavigationSwipeTracking: AnyObject {
    /// False when tracking could not start; the handler is then never called.
    func track(direction: NavigationSwipeDirection,
               handler: @escaping @MainActor (_ amount: CGFloat, _ phase: NSEvent.Phase, _ isComplete: Bool) -> Bool) -> Bool
}

/// The real tracker: `NSEvent.trackSwipeEvent` on the scroll event that
/// crossed the threshold, as WebKit starts its own swipe from a stored event.
/// It follows the fingers, springs back on a release short of the threshold,
/// and runs the completion animation itself.
final class SystemNavigationSwipeTracker: NavigationSwipeTracking {
    private let event: NSEvent

    init(event: NSEvent) {
        self.event = event
    }

    /// WebKit's options (`NSEventSwipeTrackingConsumeMouseEvents`, an AppKit
    /// SPI bit, `0x1 << 2` in WebKit's `pal/spi/mac/NSEventSPI.h`): mouse
    /// events during the swipe's animation are consumed.
    private static let consumeMouseEvents = NSEvent.SwipeTrackingOptions(rawValue: 1 << 2)

    func track(direction: NavigationSwipeDirection,
               handler: @escaping @MainActor (CGFloat, NSEvent.Phase, Bool) -> Bool) -> Bool {
        // AppKit raises (an Objective-C exception Swift cannot catch) for any
        // other event: only a scroll event in its began or changed phase.
        guard event.type == .scrollWheel, event.phase == .began || event.phase == .changed,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
        let maxAmount: CGFloat = direction == .back ? 1 : 0
        let minAmount: CGFloat = direction == .back ? 0 : -1
        event.trackSwipeEvent(options: Self.consumeMouseEvents, dampenAmountThresholdMin: minAmount,
                              max: maxAmount, onMain: handler)
        return true
    }
}

/// A tracker driven by hand: tests, and the Debug automation tool that runs a
/// swipe's completion in the running app (synthetic events cannot drive
/// `trackSwipeEvent`).
final class ScriptedNavigationSwipeTracker: NavigationSwipeTracking {
    private var handler: (@MainActor (CGFloat, NSEvent.Phase, Bool) -> Bool)?

    var isTracking: Bool { handler != nil }

    func track(direction: NavigationSwipeDirection,
               handler: @escaping @MainActor (CGFloat, NSEvent.Phase, Bool) -> Bool) -> Bool {
        self.handler = handler
        return true
    }

    /// Reports one step; returns whether tracking goes on.
    @discardableResult
    func step(_ amount: CGFloat, phase: NSEvent.Phase, isComplete: Bool = false) -> Bool {
        guard let handler else { return false }
        let stop = handler(amount, phase, isComplete)
        if stop || isComplete { self.handler = nil }
        return self.handler != nil
    }

    /// The fingers lift past the threshold and the animation runs to the end.
    func complete(direction: NavigationSwipeDirection) {
        let end: CGFloat = direction == .back ? 1 : -1
        guard step(end * 0.9, phase: .ended) else { return }
        step(end, phase: [], isComplete: true)
    }

    /// The fingers lift short of the threshold and the page springs back.
    func cancel() {
        guard step(0.1, phase: .cancelled) else { return }
        step(0, phase: [], isComplete: true)
    }
}
