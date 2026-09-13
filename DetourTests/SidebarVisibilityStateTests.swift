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
                case .cancelAutoHide, .startHoverGrace: break
                }
            }
        }

        mutating func toggle() { send(.toggle(isCollapsed: isCollapsed)) }
        mutating func hoverReveal() { send(.hoverReveal(isCollapsed: isCollapsed)) }
        mutating func hoverHide() { send(.hoverHide(isCollapsed: isCollapsed)) }
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
        XCTAssertEqual(s.reduce(.hoverHide(isCollapsed: false)), [.setCollapsed(true)])
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
}
