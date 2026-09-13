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
        h.send(.restored(isCollapsed: true))
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
        XCTAssertEqual(s.reduce(.restored(isCollapsed: false)), [])
        XCTAssertEqual(s, SidebarVisibilityState())
    }

    func testLateAutosaveRestoreViaKVOAdoptsMode() {
        var h = Harness()
        h.send(.restored(isCollapsed: false))
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

    private static let autosaveKey = "NSSplitView Subview Frames BrowserSplitView"
    private var savedAutosave: Any?
    private var controller: BrowserWindowController?

    override func setUp() {
        super.setUp()
        // The test host shares the app's defaults domain; never let a collapse
        // here leak into the real app's split view autosave.
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
        func findSplitView(in view: NSView) -> NSSplitView? {
            for sub in view.subviews {
                if let split = sub as? NSSplitView, split.subviews.contains(wc.tabSidebar.view)
                    || split.arrangedSubviews.contains(where: { wc.tabSidebar.view.isDescendant(of: $0) }) {
                    return split
                }
                if let found = findSplitView(in: sub) { return found }
            }
            return nil
        }
        let root = try XCTUnwrap(wc.window?.contentView?.superview ?? wc.window?.contentView)
        let splitView = try XCTUnwrap(findSplitView(in: root), "window's sidebar split view")
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
    func testAutosaveRestoreArrivesAsExternalCollapse() {
        let name = "DetourTestsTask39SidebarRestore"
        let key = "NSSplitView Subview Frames \(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

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

        // First "launch": collapse, which autosaves.
        do {
            let (window, svc, item) = makeSplit()
            window.contentView?.addSubview(svc.view)
            svc.view.frame = window.contentView!.bounds
            svc.view.layoutSubtreeIfNeeded()
            window.orderFront(nil)
            svc.toggleSidebar(nil)
            XCTAssertTrue(item.isCollapsed)
            // The autosave write is deferred past the toggle.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.close()
        }
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key))

        // Second "launch": observer first, then load the view, as the controller does.
        let (window, svc, item) = makeSplit()
        defer { window.close() }
        var state = SidebarVisibilityState()
        let observation = item.observe(\.isCollapsed, options: [.new]) { _, change in
            _ = state.reduce(.collapsedChanged(change.newValue ?? false))
        }
        window.contentView?.addSubview(svc.view)
        svc.view.frame = window.contentView!.bounds
        _ = state.reduce(.restored(isCollapsed: item.isCollapsed))
        observation.invalidate()

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
