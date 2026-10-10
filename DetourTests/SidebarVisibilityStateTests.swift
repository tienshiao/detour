import XCTest
import AppKit
@testable import Detour

/// TASK-39: the sidebar mode follows the user-visible collapsed state for every
/// non-hover change (toggle, divider drag, autosave restore); hover never
/// changes it.
final class SidebarVisibilityStateTests: XCTestCase {

    /// Simulates the window: applies `setCollapsed` like the controller does
    /// (including the synchronous `isCollapsed` KVO that `toggleSidebar` fires
    /// inside the call) and records safe-area writes.
    private struct Harness {
        var state = SidebarVisibilityState()
        var isCollapsed = false
        var safeAreaAdjusts: Bool?
        var toggleSidebarCalls = 0
        var autoHideScheduled = false
        /// Where the pointer really is. The reducer only learns it from the
        /// events below, so a test can move the pointer without telling it.
        var pointerInSidebar = false
        var log: [SidebarVisibilityState.Action] = []

        mutating func send(_ event: SidebarVisibilityState.Event) {
            let actions = state.reduce(event)
            log.append(contentsOf: actions)
            for action in actions {
                switch action {
                case .setSafeAreaAdjusts(let v): safeAreaAdjusts = v
                case .setCollapsed(let v):
                    if isCollapsed != v {
                        toggleSidebarCalls += 1
                        isCollapsed = v
                        let nested = state.reduce(.collapsedChanged(v))
                        XCTAssertEqual(nested, [], "own toggle must not re-enter with actions")
                    }
                case .cancelAutoHide: autoHideScheduled = false
                case .scheduleAutoHide: autoHideScheduled = true
                case .startHoverGrace: break
                }
            }
        }

        /// The sidebar's tracking area reported an exit.
        mutating func pointerExited() {
            pointerInSidebar = false
            send(.pointerObserved(inSidebar: false))
        }
        /// The sidebar's tracking area reported an enter.
        mutating func pointerEntered() {
            pointerInSidebar = true
            send(.pointerObserved(inSidebar: true))
        }
        /// The pointer moved and AppKit delivered no enter or exit for it.
        mutating func pointerMovedUnreported(inSidebar: Bool) { pointerInSidebar = inSidebar }
        /// The window's periodic look at where the pointer is.
        mutating func pointerSampled() { send(.pointerObserved(inSidebar: pointerInSidebar)) }
        /// The grace period after a hover reveal is over.
        mutating func graceEnded() { send(.hoverGraceEnded(pointerInSidebar: pointerInSidebar)) }
        /// The hide delay elapsed (if it was not cancelled meanwhile).
        mutating func autoHideDelayElapsed() {
            guard autoHideScheduled else { return }
            autoHideScheduled = false
            send(.hoverHide(isCollapsed: isCollapsed, pointerInSidebar: pointerInSidebar))
        }
        /// How many hide delays were started so far.
        var scheduledHides: Int { log.filter { $0 == .scheduleAutoHide }.count }

        mutating func toggle() { send(.toggle(isCollapsed: isCollapsed)) }
        /// The pointer reached the edge strip, which lies over the sidebar.
        mutating func hoverReveal() {
            pointerInSidebar = true
            send(.hoverReveal(isCollapsed: isCollapsed))
        }
        /// The hide delay elapsing with the pointer away from the sidebar,
        /// whether or not a delay was running.
        mutating func hoverHide() {
            pointerInSidebar = false
            send(.hoverHide(isCollapsed: isCollapsed, pointerInSidebar: false))
        }
        /// A change the window did not request: divider drag or autosave restore.
        mutating func externalCollapse(_ v: Bool) {
            isCollapsed = v
            send(.collapsedChanged(v))
        }
    }

    // MARK: - Toggle

    func testToggleFromPinnedCollapsesAndBackExpands() {
        var h = Harness()
        h.toggle()
        XCTAssertTrue(h.isCollapsed)
        XCTAssertTrue(h.state.autoHides)
        XCTAssertEqual(h.safeAreaAdjusts, true)
        h.toggle()
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
        XCTAssertEqual(h.safeAreaAdjusts, false)
        XCTAssertEqual(h.toggleSidebarCalls, 2)
    }

    // MARK: - AC1: divider drag collapse, then one toggle

    func testDragCollapseAdoptsAutoHideMode() {
        var h = Harness()
        h.externalCollapse(true)
        XCTAssertTrue(h.state.autoHides)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertEqual(h.safeAreaAdjusts, true, "safe area matches a toggle-collapsed sidebar")
    }

    func testSingleToggleAfterDragCollapseShowsSidebar() {
        var h = Harness()
        h.externalCollapse(true)
        h.toggle()
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
        XCTAssertEqual(h.toggleSidebarCalls, 1)
        XCTAssertEqual(h.safeAreaAdjusts, false)
    }

    func testDragExpandAdoptsPinnedMode() {
        var h = Harness()
        h.toggle()
        h.externalCollapse(false)
        XCTAssertFalse(h.state.autoHides)
        XCTAssertEqual(h.safeAreaAdjusts, false)
        h.toggle()
        XCTAssertTrue(h.isCollapsed, "one press hides it again")
    }

    func testDragCollapseAndBackOutWithinOneDrag() {
        var h = Harness()
        h.externalCollapse(true)
        h.externalCollapse(false)
        XCTAssertFalse(h.state.autoHides)
        XCTAssertFalse(h.isCollapsed)
    }

    // MARK: - AC2: hover after a drag collapse

    func testHoverRevealAndAutoHideAfterDragCollapse() {
        var h = Harness()
        h.externalCollapse(true)
        h.hoverReveal()
        XCTAssertFalse(h.isCollapsed, "edge hover reveals the drag-collapsed sidebar")
        XCTAssertTrue(h.state.openedByHover)
        XCTAssertTrue(h.log.contains(.startHoverGrace))
        h.hoverHide()
        XCTAssertTrue(h.isCollapsed, "auto-hides again on exit")
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertTrue(h.state.autoHides)
    }

    func testHoverRevealIgnoredWhenPinned() {
        var h = Harness()
        h.hoverReveal()
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertEqual(h.toggleSidebarCalls, 0)
    }

    // MARK: - AC3: hover never changes the mode

    func testHoverDoesNotChangeModeOrSafeArea() {
        var h = Harness()
        h.toggle()
        h.log.removeAll()
        h.hoverReveal()
        XCTAssertTrue(h.state.autoHides)
        h.hoverHide()
        XCTAssertTrue(h.state.autoHides)
        XCTAssertFalse(h.log.contains { if case .setSafeAreaAdjusts = $0 { return true } else { return false } })
    }

    func testDelayedHoverKVOIsStillAttributedToHover() {
        // An animated toggleSidebar whose KVO arrives after the call returns.
        var s = SidebarVisibilityState()
        _ = s.reduce(.toggle(isCollapsed: false))
        let reveal = s.reduce(.hoverReveal(isCollapsed: true))
        XCTAssertEqual(reveal, [.setCollapsed(false), .startHoverGrace])
        XCTAssertEqual(s.reduce(.collapsedChanged(false)), [], "late KVO of the hover reveal")
        XCTAssertTrue(s.autoHides)
        XCTAssertTrue(s.openedByHover)
        XCTAssertEqual(s.reduce(.hoverHide(isCollapsed: false, pointerInSidebar: false)), [.setCollapsed(true)])
        XCTAssertEqual(s.reduce(.collapsedChanged(true)), [], "late KVO of the auto-hide")
        XCTAssertTrue(s.autoHides)
        XCTAssertFalse(s.openedByHover)
    }

    func testDragAndToggleCollapsedStatesAreIdentical() {
        var dragged = Harness()
        dragged.externalCollapse(true)
        var toggled = Harness()
        toggled.toggle()
        XCTAssertEqual(dragged.state, toggled.state)
        XCTAssertEqual(dragged.safeAreaAdjusts, toggled.safeAreaAdjusts)
        XCTAssertEqual(dragged.isCollapsed, toggled.isCollapsed)
    }

    func testDragCollapseWhileHoverOpenEndsHoverKeepsAutoHide() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        h.externalCollapse(true)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertTrue(h.state.autoHides)
        XCTAssertTrue(h.log.contains(.cancelAutoHide))
        h.hoverHide()
        XCTAssertTrue(h.isCollapsed)
    }

    func testToggleWhileHoverOpenPinsSidebar() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        let calls = h.toggleSidebarCalls
        h.toggle()
        XCTAssertFalse(h.isCollapsed, "a hover-revealed sidebar stays and becomes pinned")
        XCTAssertFalse(h.state.autoHides)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertEqual(h.toggleSidebarCalls, calls)
        h.hoverHide()
        XCTAssertFalse(h.isCollapsed, "a stale auto-hide does nothing after pinning")
    }

    // MARK: - TASK-127: an open popover holds a hover-revealed sidebar

    private func hoverRevealedHarness() -> Harness {
        var h = Harness()
        h.toggle()        // auto-hide mode, collapsed
        h.hoverReveal()
        h.graceEnded()    // with the pointer in the sidebar
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.autoHideScheduled)
        return h
    }

    func testPopoverHoldsHoverRevealedSidebarOpen() {
        var h = hoverRevealedHarness()
        h.send(.holdBegan)
        // The pointer moves from the sidebar into the popover.
        h.pointerExited()
        XCTAssertFalse(h.autoHideScheduled, "no hide delay starts while held")
        h.pointerSampled()
        XCTAssertFalse(h.autoHideScheduled, "nor from the periodic sample")
        h.hoverHide()     // a delay that elapsed anyway
        XCTAssertFalse(h.isCollapsed, "the sidebar anchors the popover")
        XCTAssertTrue(h.state.openedByHover, "still a hover session")
        XCTAssertTrue(h.state.autoHides)
    }

    func testHoldCancelsAHideAlreadyPending() {
        var h = hoverRevealedHarness()
        // The pointer left before the popover finished appearing.
        h.pointerExited()
        XCTAssertTrue(h.autoHideScheduled)
        h.send(.holdBegan)
        XCTAssertFalse(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertFalse(h.isCollapsed)
    }

    func testSidebarHidesAfterPopoverClosesWithPointerOutside() {
        var h = hoverRevealedHarness()
        h.send(.holdBegan)
        h.pointerExited()
        h.autoHideDelayElapsed()
        h.send(.holdEnded(pointerInSidebar: false))
        XCTAssertTrue(h.autoHideScheduled, "no further exit event will come")
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertTrue(h.state.autoHides, "hover never changes the mode")
    }

    func testSidebarStaysAfterPopoverClosesWithPointerInside() {
        var h = hoverRevealedHarness()
        h.send(.holdBegan)
        h.send(.holdEnded(pointerInSidebar: true))
        XCTAssertFalse(h.autoHideScheduled)
        XCTAssertFalse(h.isCollapsed)
        // The next exit hides as usual.
        h.pointerExited()
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testHoldDoesNothingToAPinnedSidebar() {
        var h = Harness()
        h.send(.holdBegan)
        h.send(.holdEnded(pointerInSidebar: false))
        XCTAssertEqual(h.log, [])
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
    }

    func testToggleWhileHeldPinsTheSidebar() {
        var h = hoverRevealedHarness()
        h.send(.holdBegan)
        h.toggle()
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
        h.send(.holdEnded(pointerInSidebar: false))
        XCTAssertFalse(h.autoHideScheduled, "pinned sidebars never auto-hide")
    }

    func testPopoverOpenedWhileCollapsedDoesNotBlockLaterHover() {
        var h = Harness()
        h.toggle()
        h.send(.holdBegan)
        h.send(.holdEnded(pointerInSidebar: false))
        XCTAssertFalse(h.autoHideScheduled)
        h.hoverReveal()
        h.graceEnded()
        h.pointerExited()
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    // MARK: - TASK-169: the hover hide does not depend on one exit event

    func testExitDuringRevealGraceHidesOnceTheGraceEnds() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        // A quick in-and-out: the exit arrives while the sidebar slides in.
        h.pointerExited()
        XCTAssertFalse(h.autoHideScheduled, "the exit right after a reveal starts no delay")
        XCTAssertFalse(h.isCollapsed)
        h.graceEnded()
        XCTAssertTrue(h.autoHideScheduled, "the pointer is looked at again when the grace period ends")
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertTrue(h.state.autoHides, "hover never changes the mode")
    }

    func testGraceEndingWithThePointerInsideStartsNoDelay() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        h.graceEnded()
        XCTAssertFalse(h.autoHideScheduled)
        XCTAssertFalse(h.isCollapsed)
        XCTAssertTrue(h.state.openedByHover)
    }

    func testSampleDuringRevealGraceStartsNoDelay() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        h.pointerMovedUnreported(inSidebar: false)
        h.pointerSampled()
        XCTAssertFalse(h.autoHideScheduled)
        h.graceEnded()
        XCTAssertTrue(h.autoHideScheduled)
    }

    /// A tab picked in the revealed sidebar, then the pointer back over the
    /// page with no exit event (a button held across the boundary, a drag
    /// session, the view under the pointer changing): the sample finds it.
    func testMissedExitIsCaughtByThePointerSample() {
        var h = hoverRevealedHarness()
        h.pointerMovedUnreported(inSidebar: false)
        XCTAssertFalse(h.autoHideScheduled, "nothing has told the reducer yet")
        h.pointerSampled()
        XCTAssertTrue(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
        XCTAssertFalse(h.state.openedByHover)
        XCTAssertTrue(h.state.autoHides)
    }

    func testRepeatedReportsDoNotRestartTheHideDelay() {
        var h = hoverRevealedHarness()
        h.pointerExited()
        XCTAssertEqual(h.scheduledHides, 1)
        h.pointerSampled()
        h.pointerSampled()
        h.pointerExited()
        XCTAssertEqual(h.scheduledHides, 1, "one delay, however often the pointer is reported outside")
        XCTAssertTrue(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testSampleWithThePointerInsideDoesNothing() {
        var h = hoverRevealedHarness()
        h.log.removeAll()
        h.pointerSampled()
        h.pointerSampled()
        XCTAssertEqual(h.log, [])
        XCTAssertFalse(h.isCollapsed)
        XCTAssertTrue(h.state.openedByHover)
    }

    func testEnterCancelsThePendingHide() {
        var h = hoverRevealedHarness()
        h.pointerExited()
        h.pointerEntered()
        XCTAssertFalse(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertFalse(h.isCollapsed)
        // The next exit starts a new delay.
        h.pointerExited()
        XCTAssertEqual(h.scheduledHides, 2)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testSampleCancelsThePendingHideWhenTheEnterWasMissed() {
        var h = hoverRevealedHarness()
        h.pointerExited()
        h.pointerMovedUnreported(inSidebar: true)
        h.pointerSampled()
        XCTAssertFalse(h.autoHideScheduled)
        XCTAssertFalse(h.isCollapsed)
    }

    /// The sidebar stays while the pointer is in it, even when the enter
    /// event that should have cancelled the delay never came.
    func testHideDelayElapsingWithThePointerBackInsideKeepsTheSidebar() {
        var h = hoverRevealedHarness()
        h.pointerExited()
        h.pointerMovedUnreported(inSidebar: true)
        h.autoHideDelayElapsed()
        XCTAssertFalse(h.isCollapsed)
        XCTAssertTrue(h.state.openedByHover, "still a hover session")
        // Leaving again, reported or not, hides it.
        h.pointerMovedUnreported(inSidebar: false)
        h.pointerSampled()
        XCTAssertTrue(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testSampleAfterAHoldEndsStartsTheDelay() {
        var h = hoverRevealedHarness()
        h.send(.holdBegan)
        h.pointerMovedUnreported(inSidebar: false)
        h.pointerSampled()
        XCTAssertFalse(h.autoHideScheduled, "held")
        // The popover goes away while the pointer is back in the sidebar…
        h.send(.holdEnded(pointerInSidebar: true))
        XCTAssertFalse(h.autoHideScheduled)
        // …and then the pointer is found outside, with no exit event.
        h.pointerSampled()
        XCTAssertTrue(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testHoldEndingDuringRevealGraceWaitsForTheGraceToEnd() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        h.send(.holdBegan)
        h.pointerMovedUnreported(inSidebar: false)
        h.send(.holdEnded(pointerInSidebar: false))
        XCTAssertFalse(h.autoHideScheduled)
        h.graceEnded()
        XCTAssertTrue(h.autoHideScheduled)
    }

    func testPointerReportsDoNothingToAPinnedOrCollapsedSidebar() {
        var h = Harness()
        h.pointerSampled()
        h.pointerExited()
        h.graceEnded()
        XCTAssertEqual(h.log, [], "pinned")
        XCTAssertFalse(h.isCollapsed)

        h.toggle()        // auto-hide mode, collapsed, not revealed
        h.log.removeAll()
        h.pointerSampled()
        h.pointerExited()
        h.graceEnded()
        XCTAssertEqual(h.log, [], "collapsed")
        XCTAssertTrue(h.isCollapsed)
        XCTAssertTrue(h.state.autoHides)
    }

    func testToggleDuringRevealGracePinsAndTheGraceEndIsIgnored() {
        var h = Harness()
        h.toggle()
        h.hoverReveal()
        h.toggle()        // pins the revealed sidebar
        h.log.removeAll()
        h.pointerMovedUnreported(inSidebar: false)
        h.graceEnded()
        h.pointerSampled()
        XCTAssertEqual(h.log, [], "pinned sidebars never auto-hide")
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
    }

    func testTogglePinsWhileAHideIsPending() {
        var h = hoverRevealedHarness()
        h.pointerExited()
        XCTAssertTrue(h.autoHideScheduled)
        h.toggle()
        XCTAssertFalse(h.autoHideScheduled, "the pending hide is cancelled")
        XCTAssertFalse(h.isCollapsed)
        XCTAssertFalse(h.state.autoHides)
        h.pointerSampled()
        XCTAssertFalse(h.autoHideScheduled)
    }

    func testEachRevealStartsAFreshSession() {
        var collapsedInAutoHide = SidebarVisibilityState()
        _ = collapsedInAutoHide.reduce(.toggle(isCollapsed: false))

        var h = hoverRevealedHarness()
        h.pointerExited()
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
        XCTAssertEqual(h.state, collapsedInAutoHide, "a finished hover session leaves nothing behind")

        h.hoverReveal()
        h.pointerExited()
        XCTAssertFalse(h.autoHideScheduled, "in the new reveal's grace period")
        h.graceEnded()
        XCTAssertTrue(h.autoHideScheduled)
        h.autoHideDelayElapsed()
        XCTAssertTrue(h.isCollapsed)
    }

    func testPointerIsWatchedOnlyWhileHoverRevealed() {
        var h = Harness()
        XCTAssertFalse(h.state.watchesPointer, "pinned")
        h.toggle()
        XCTAssertFalse(h.state.watchesPointer, "collapsed")
        h.hoverReveal()
        XCTAssertTrue(h.state.watchesPointer, "revealed, in the grace period")
        h.graceEnded()
        XCTAssertTrue(h.state.watchesPointer)
        h.send(.holdBegan)
        XCTAssertTrue(h.state.watchesPointer, "held: the sample is what notices a popover that is gone")
        h.send(.holdEnded(pointerInSidebar: true))
        h.pointerExited()
        h.autoHideDelayElapsed()
        XCTAssertFalse(h.state.watchesPointer, "hidden again")
        h.hoverReveal()
        h.toggle()
        XCTAssertFalse(h.state.watchesPointer, "pinned from a reveal")
    }

    // MARK: - AC4: autosave restore

    func testRestoredCollapsedAtLaunchStartsInAutoHideMode() {
        var h = Harness()
        h.isCollapsed = true
        // The setup-time sync, or the restore's own KVO: either way the first
        // observation disagrees with `expectedCollapsed` and is adopted.
        h.send(.collapsedChanged(true))
        XCTAssertTrue(h.state.autoHides)
        XCTAssertEqual(h.safeAreaAdjusts, true)
        h.hoverReveal()
        XCTAssertFalse(h.isCollapsed)
        h.hoverHide()
        h.toggle()
        XCTAssertFalse(h.isCollapsed, "one press shows a restored-collapsed sidebar")
        XCTAssertEqual(h.toggleSidebarCalls, 3)
    }

    func testRestoredExpandedAtLaunchIsANoOp() {
        var s = SidebarVisibilityState()
        XCTAssertEqual(s.reduce(.collapsedChanged(false)), [])
        XCTAssertEqual(s, SidebarVisibilityState())
    }

    func testLateAutosaveRestoreViaKVOAdoptsMode() {
        var h = Harness()
        h.send(.collapsedChanged(false))
        h.externalCollapse(true)
        XCTAssertTrue(h.state.autoHides)
    }

    func testRedundantKVOIsIgnored() {
        var s = SidebarVisibilityState()
        XCTAssertEqual(s.reduce(.collapsedChanged(false)), [])
        XCTAssertFalse(s.autoHides)
    }
}

/// Drives the real `BrowserWindowController` split view (TASK-39 AC1/AC4).
@MainActor
final class BrowserWindowSidebarModeTests: XCTestCase {

    /// The split view autosave key this process actually writes: the name is
    /// scoped to the data directory since TASK-41, so hard-coding the unscoped
    /// "BrowserSplitView" would guard a key the host never touches.
    private static let autosaveKey =
        "NSSplitView Subview Frames \(BrowserWindowController.splitViewAutosaveName)"
    private var savedAutosave: Any?
    private var controller: BrowserWindowController?

    override func setUp() {
        super.setUp()
        // The test host shares the app's defaults domain — and in the default
        // data directory the scoped key is the production one — so never let a
        // collapse here leak into the app's split view autosave.
        savedAutosave = UserDefaults.standard.object(forKey: Self.autosaveKey)
    }

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        // Only put the value back if something here changed it, so a write by
        // the real app in the meantime is not clobbered.
        let current = UserDefaults.standard.object(forKey: Self.autosaveKey) as? NSObject
        if current != savedAutosave as? NSObject {
            UserDefaults.standard.set(savedAutosave, forKey: Self.autosaveKey)
        }
        super.tearDown()
    }

    private func makeController() throws -> (BrowserWindowController, NSSplitView) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        let splitView = wc.sidebarSplitView
        splitView.autosaveName = nil
        wc.window?.orderFront(nil)
        splitView.layoutSubtreeIfNeeded()
        return (wc, splitView)
    }

    func testDividerCollapseThenSingleToggleExpands() throws {
        let (wc, splitView) = try makeController()
        if wc.sidebarItem.isCollapsed {
            // Restored collapsed from the host's autosave: starts in auto-hide.
            XCTAssertTrue(wc.sidebarVisibility.autoHides)
            wc.toggleSidebarMode(nil)
        }
        XCTAssertFalse(wc.sidebarItem.isCollapsed)
        XCTAssertFalse(wc.sidebarVisibility.autoHides)

        splitView.setPosition(0, ofDividerAt: 0)
        XCTAssertTrue(wc.sidebarItem.isCollapsed, "divider drag to 0 collapses the sidebar")
        XCTAssertTrue(wc.sidebarVisibility.autoHides, "mode follows the divider collapse")
        XCTAssertEqual(wc.window?.standardWindowButton(.closeButton)?.isHidden, true)

        wc.toggleSidebarMode(nil)
        XCTAssertFalse(wc.sidebarItem.isCollapsed, "one Toggle Sidebar press shows it")
        XCTAssertFalse(wc.sidebarVisibility.autoHides)

        wc.toggleSidebarMode(nil)
        XCTAssertTrue(wc.sidebarItem.isCollapsed)
        XCTAssertTrue(wc.sidebarVisibility.autoHides)
    }

    /// The AppKit behaviour the controller relies on for AC4: a split view
    /// autosave restores a collapsed sidebar when the view loads — after the
    /// controller registered its `isCollapsed` observer — so the restore reaches
    /// the reducer as an external `collapsedChanged`. Uses its own autosave name.
    func testAutosaveRestoreArrivesAsExternalCollapse() throws {
        let name = "DetourTestsTask39SidebarRestore"
        let key = "NSSplitView Subview Frames \(name)"

        func makeSplit() -> (NSWindow, NSSplitViewController, NSSplitViewItem) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let svc = NSSplitViewController()
            let side = NSViewController()
            side.view = NSView()
            let content = NSViewController()
            content.view = NSView()
            let item = NSSplitViewItem(sidebarWithViewController: side)
            item.minimumThickness = 200
            item.maximumThickness = 350
            item.canCollapse = true
            svc.addSplitViewItem(item)
            svc.addSplitViewItem(NSSplitViewItem(viewController: content))
            svc.splitView.autosaveName = name
            return (window, svc, item)
        }

        /// Spins the main run loop until `condition` holds or `timeout` passes.
        /// AppKit defers both the autosave write and the restore past the calls
        /// that trigger them, by an amount that varies with system load.
        func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }

        // First "launch": collapse, which autosaves.
        do {
            let (window, svc, item) = makeSplit()
            window.contentView?.addSubview(svc.view)
            svc.view.frame = window.contentView!.bounds
            svc.view.layoutSubtreeIfNeeded()
            window.orderFront(nil)
            // Let the expanded layout's own deferred autosave (and any late write
            // from an earlier run's closed window) land, then clear the key so the
            // only write that can recreate it is the collapse below.
            _ = spin(timeout: 0.5) { false }
            UserDefaults.standard.removeObject(forKey: key)
            svc.toggleSidebar(nil)
            XCTAssertTrue(item.isCollapsed)
            // Wait for the deferred write of the collapsed frames, not a fixed delay.
            // AppKit occasionally does not write it at all for an offscreen test
            // window (about 1 run in 15 under load); that is AppKit's scheduling,
            // not the behaviour under test, so skip rather than fail. The mode
            // logic for a late restore is covered deterministically by
            // testExternalIsCollapsedSetAdoptsModeAndExpandBack and the reducer tests.
            let saved = spin(timeout: 5) { UserDefaults.standard.object(forKey: key) != nil }
            window.close()
            guard saved else {
                _ = spin(timeout: 0.5) { false }
                UserDefaults.standard.removeObject(forKey: key)
                throw XCTSkip("AppKit did not autosave the collapsed split view within 5 s")
            }
        }

        // Second "launch": observer first, then load the view, as the controller does.
        // The observer stays registered until the restore has landed: AppKit may apply
        // the autosave during a later layout pass, after the setup-time sync, and then
        // only the KVO path sees it — the same as in the window controller.
        let (window, svc, item) = makeSplit()
        defer {
            // Closing the window autosaves again after a delay; let that write land
            // before removing the key, so nothing is left in the defaults domain and
            // a later run does not start from this run's layout.
            window.close()
            _ = spin(timeout: 0.5) { false }
            UserDefaults.standard.removeObject(forKey: key)
        }
        var state = SidebarVisibilityState()
        let observation = item.observe(\.isCollapsed, options: [.new]) { _, change in
            _ = state.reduce(.collapsedChanged(change.newValue ?? false))
        }
        defer { observation.invalidate() }
        window.contentView?.addSubview(svc.view)
        svc.view.frame = window.contentView!.bounds
        _ = state.reduce(.collapsedChanged(item.isCollapsed))
        svc.view.layoutSubtreeIfNeeded()
        _ = spin(timeout: 5) { item.isCollapsed }

        XCTAssertTrue(item.isCollapsed, "autosave restored the collapsed sidebar")
        XCTAssertTrue(state.autoHides, "the restored collapse starts in auto-hide mode")
        var toggled = state
        XCTAssertEqual(toggled.reduce(.toggle(isCollapsed: true)).last, .setCollapsed(false),
                       "one Toggle press expands it")
    }

    func testExternalIsCollapsedSetAdoptsModeAndExpandBack() throws {
        let (wc, _) = try makeController()
        if wc.sidebarItem.isCollapsed { wc.toggleSidebarMode(nil) }
        wc.sidebarItem.isCollapsed = true
        XCTAssertTrue(wc.sidebarVisibility.autoHides)
        wc.sidebarItem.isCollapsed = false
        XCTAssertFalse(wc.sidebarVisibility.autoHides)
        XCTAssertFalse(wc.sidebarVisibility.openedByHover)
    }

    // MARK: - TASK-169: the window's timers and pointer sample around the hover hide

    /// Spins the main run loop in the default mode — the only mode the
    /// sidebar's timers run in — until `condition` holds or `timeout` passes.
    private func spin(timeout: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// The window's hover timing, shortened: these tests wait on real timers.
    /// Every wait is safe in one direction only — a timer never fires early,
    /// so "hid no sooner than" cannot fail on a slow machine, and "still shown
    /// after" can only pass wrongly there, never fail.
    private static let hoverDelay: TimeInterval = 0.15
    private static let sampleInterval: TimeInterval = 0.05

    /// Well past the reveal grace period plus the hide delay plus a pointer
    /// sample: a sidebar still shown after this is being kept, not just slow.
    private static let longerThanAHide: TimeInterval = 4 * hoverDelay + sampleInterval

    /// A window in auto-hide mode whose pointer position is whatever the
    /// returned box says. Enter and exit events cannot be synthesized, and the
    /// real pointer belongs to whoever is at the machine.
    private func makeAutoHidingController() throws -> (BrowserWindowController, PointerBox) {
        let (wc, _) = try makeController()
        if !wc.sidebarVisibility.autoHides { wc.toggleSidebarMode(nil) }
        XCTAssertTrue(wc.sidebarItem.isCollapsed)
        XCTAssertTrue(wc.sidebarVisibility.autoHides)
        // Let the collapse settle. An expand issued in the same run loop turn
        // as a collapse does not hold: AppKit collapses the sidebar again right
        // after (TASK-169 probe), and every test below would see a sidebar
        // that "hid" for that reason.
        _ = spin(timeout: 0.3)
        let pointer = PointerBox()
        wc.sidebarPointerProbeForTesting = { pointer.inSidebar }
        wc.sidebarHoverDelay = Self.hoverDelay
        wc.sidebarPointerSampleInterval = Self.sampleInterval
        return (wc, pointer)
    }

    private final class PointerBox {
        var inSidebar = false
    }

    /// The edge hover with the pointer in the sidebar, checked a moment
    /// later: the reveal held.
    private func hoverReveal(_ wc: BrowserWindowController, file: StaticString = #filePath, line: UInt = #line) {
        wc.sidebarHoverZoneEntered(.edge)
        _ = spin(timeout: 0.2)
        XCTAssertFalse(wc.sidebarItem.isCollapsed, "the edge hover reveals the sidebar", file: file, line: line)
        XCTAssertTrue(wc.sidebarVisibility.openedByHover, file: file, line: line)
        XCTAssertTrue(wc.sidebarVisibility.autoHides, file: file, line: line)
    }

    /// The grace period plus the hide delay, less a margin. A hide earlier
    /// than this did not come from the hover rule.
    private static let earliestHoverHide: TimeInterval = 2 * hoverDelay - 0.02

    func testHoverRevealedSidebarHidesWithoutAnyExitEvent() throws {
        let (wc, pointer) = try makeAutoHidingController()
        pointer.inSidebar = false
        let revealed = Date()
        wc.sidebarHoverZoneEntered(.edge)
        XCTAssertFalse(wc.sidebarItem.isCollapsed, "the edge hover reveals the sidebar")
        XCTAssertTrue(wc.sidebarVisibility.openedByHover)

        // Nothing reports an exit: the sample has to find the pointer gone.
        XCTAssertTrue(spin(timeout: 10) { wc.sidebarItem.isCollapsed }, "hides although no exit event came")
        XCTAssertGreaterThan(Date().timeIntervalSince(revealed), Self.earliestHoverHide)
        XCTAssertTrue(wc.sidebarVisibility.autoHides, "hover never changes the mode")
        XCTAssertFalse(wc.sidebarVisibility.openedByHover)
        XCTAssertFalse(wc.sidebarVisibility.watchesPointer)
    }

    func testExitDuringTheRevealGracePeriodStillHides() throws {
        let (wc, pointer) = try makeAutoHidingController()
        pointer.inSidebar = true
        let revealed = Date()
        wc.sidebarHoverZoneEntered(.edge)
        XCTAssertFalse(wc.sidebarItem.isCollapsed)
        pointer.inSidebar = false
        wc.sidebarHoverZoneExited(.sidebar)
        XCTAssertFalse(wc.sidebarVisibility.hidePending, "the exit right after the reveal starts no delay")
        XCTAssertTrue(spin(timeout: 10) { wc.sidebarItem.isCollapsed })
        XCTAssertGreaterThan(Date().timeIntervalSince(revealed), Self.earliestHoverHide)
        XCTAssertTrue(wc.sidebarVisibility.autoHides)
    }

    func testHoverRevealedSidebarStaysWhileThePointerIsInIt() throws {
        let (wc, pointer) = try makeAutoHidingController()
        pointer.inSidebar = true
        hoverReveal(wc)
        XCTAssertFalse(spin(timeout: Self.longerThanAHide) { wc.sidebarItem.isCollapsed })
        XCTAssertTrue(wc.sidebarVisibility.openedByHover)

        // A stray exit while the pointer has not moved does not hide it either.
        wc.sidebarHoverZoneExited(.sidebar)
        XCTAssertFalse(spin(timeout: Self.longerThanAHide) { wc.sidebarItem.isCollapsed })
        XCTAssertTrue(wc.sidebarVisibility.openedByHover)

        pointer.inSidebar = false
        XCTAssertTrue(spin(timeout: 10) { wc.sidebarItem.isCollapsed }, "hides once the pointer is elsewhere")
    }

    func testOpenPopoverHoldsHoverRevealedSidebarUntilItCloses() throws {
        let (wc, pointer) = try makeAutoHidingController()
        pointer.inSidebar = true
        hoverReveal(wc)

        let popover = NSPopover()
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        popover.contentViewController = content
        popover.behavior = .applicationDefined
        popover.animates = false
        let sidebarView = wc.tabSidebar.view
        popover.show(relativeTo: NSRect(x: sidebarView.bounds.midX, y: sidebarView.bounds.midY, width: 10, height: 10),
                     of: sidebarView, preferredEdge: .maxX)
        defer { popover.close() }
        guard spin(timeout: 5, until: { wc.sidebarVisibility.heldOpen }) else {
            throw XCTSkip("the test host did not post NSPopover.didShowNotification within 5 s")
        }

        // The pointer moves into the popover.
        pointer.inSidebar = false
        wc.sidebarHoverZoneExited(.sidebar)
        XCTAssertFalse(spin(timeout: Self.longerThanAHide) { wc.sidebarItem.isCollapsed },
                       "the sidebar anchors the popover")
        XCTAssertTrue(wc.sidebarVisibility.openedByHover)

        popover.close()
        XCTAssertTrue(spin(timeout: 10) { wc.sidebarItem.isCollapsed }, "hides once the popover is gone")
        XCTAssertFalse(wc.sidebarVisibility.heldOpen)
        XCTAssertTrue(wc.sidebarVisibility.autoHides)
    }

    func testToggleSidebarPinsAHoverRevealedSidebar() throws {
        let (wc, pointer) = try makeAutoHidingController()
        pointer.inSidebar = true
        hoverReveal(wc)
        wc.toggleSidebarMode(nil)
        XCTAssertFalse(wc.sidebarItem.isCollapsed)
        XCTAssertFalse(wc.sidebarVisibility.autoHides)

        pointer.inSidebar = false
        wc.sidebarHoverZoneExited(.sidebar)
        XCTAssertFalse(spin(timeout: Self.longerThanAHide) { wc.sidebarItem.isCollapsed }, "pinned sidebars stay")
        XCTAssertFalse(wc.sidebarVisibility.watchesPointer)
    }
}
