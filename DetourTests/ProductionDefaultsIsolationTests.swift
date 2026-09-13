import XCTest
@testable import Detour

/// Opening and closing a real browser window in the test host must leave the
/// production app's autosave and Sparkle keys alone (TASK-41). The test host is
/// Detour.app, so `UserDefaults.standard` here *is* the production domain.
@MainActor
final class ProductionDefaultsIsolationTests: XCTestCase {

    private var controller: BrowserWindowController?

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        // The test writes the data-directory-scoped frame and divider; drop them
        // so no later window in this run (the split view autosave restores for
        // every controller, incognito included) starts from this test's
        // geometry. The bundle net also drops them at the end of the run — and
        // like it, never in the default data directory, where the scoped keys
        // *are* the production app's.
        if !WebKitStorageScope.currentIsDefaultDataDirectory {
            for key in ProductionDefaultsWatch.scopedAutosaveKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testWindowAutosaveDoesNotTouchTheProductionKeys() throws {
        try XCTSkipIf(
            WebKitStorageScope.currentIsDefaultDataDirectory,
            "in the default data directory the run legitimately owns these keys")

        let defaults = UserDefaults.standard
        let before = ProductionDefaultsWatch.snapshot()

        let wc = BrowserWindowController(incognito: true)
        controller = wc
        let window = try XCTUnwrap(wc.window)

        // The frame autosave: the convenience initialiser only arms it for a
        // first non-incognito window, so arm it here to exercise a save.
        window.setFrameAutosaveName(BrowserWindowController.frameAutosaveName)
        window.orderFront(nil)
        window.setFrame(NSRect(x: 130, y: 150, width: 920, height: 680), display: false)
        window.saveFrame(usingName: BrowserWindowController.frameAutosaveName)

        // The sidebar split view autosave: move the divider so it saves too.
        let splitView = wc.sidebarSplitView
        XCTAssertEqual(splitView.autosaveName, BrowserWindowController.splitViewAutosaveName)
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(260, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        window.close()
        controller = nil

        // Nothing the window did may have reached the production keys.
        let after = ProductionDefaultsWatch.snapshot()
        for (key, value) in before {
            XCTAssertTrue(
                ProductionDefaultsWatch.valuesEqual(value, after[key]),
                "the test host changed the production defaults key \(key)")
        }
        for key in after.keys where before[key] == nil {
            XCTFail("the test host created the production defaults key \(key)")
        }

        // But the data-directory-scoped frame key is written, so autosave still
        // works — in the default data directory that is the production key.
        XCTAssertNotNil(
            defaults.object(forKey: "NSWindow Frame \(BrowserWindowController.frameAutosaveName)"),
            "the scoped window frame autosave should have been written")
    }

    /// The bundle's safety net has a launch-time blind spot: the test host's
    /// AppDelegate opens a real non-incognito `BrowserWindowController` while
    /// the app finishes launching, *before* `testBundleWillStart` snapshots the
    /// production defaults, so anything that window wrote at launch is already
    /// in the baseline and invisible to the net. What keeps it off the
    /// production keys is the autosave names themselves, so pin those.
    func testLaunchWindowUsesTheScopedAutosaveNames() throws {
        let controllers = NSApp.windows
            .compactMap { $0.windowController as? BrowserWindowController }
            .filter { !$0.isIncognito }
        try XCTSkipIf(controllers.isEmpty, "no launch window in this host")

        for wc in controllers {
            XCTAssertEqual(
                wc.window?.frameAutosaveName, BrowserWindowController.frameAutosaveName,
                "the launch window's frame autosave name must be the scoped one")
            XCTAssertEqual(
                wc.sidebarSplitView.autosaveName, BrowserWindowController.splitViewAutosaveName,
                "the launch window's split view autosave name must be the scoped one")

            guard !WebKitStorageScope.currentIsDefaultDataDirectory else { continue }
            XCTAssertNotEqual(
                wc.window?.frameAutosaveName, "BrowserWindow",
                "outside the default data directory the launch window must not use the production frame name")
            XCTAssertNotEqual(
                wc.sidebarSplitView.autosaveName, "BrowserSplitView",
                "outside the default data directory the launch window must not use the production split view name")
        }
    }
}
