import XCTest
import AppKit
@testable import Detour

/// TASK-309: the Dock menu's Hide All / Show All Quick Detour Windows item.
/// The title rule is pure; the rest drives real Quick Detour windows (a
/// profile of the test's own, a Private one, a quarantine) through the
/// AppDelegate's Dock menu.
nonisolated final class QuickDetourDockMenuTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var quickDetours: [QuickDetourWindowController] = []
    private var quickDetoursBefore: [QuickDetourWindowController] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        // Windows another suite left open would be acted on too: set them
        // apart, as minimized windows are ("elsewhere").
        quickDetoursBefore = QuickDetourWindowController.openControllers
        for controller in quickDetoursBefore { controller.window?.orderOut(nil) }
        profile = store.addProfile(name: "Dock \(UUID().uuidString.prefix(4))")
    }

    @MainActor override func tearDown() async throws {
        for controller in quickDetours {
            controller.closeDisposition = .discard
            controller.close()
        }
        quickDetours.removeAll()
        store.forceRemoveProfile(id: profile.id)
        AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        Self.retainedProfiles.append(profile)
        for controller in quickDetoursBefore { controller.window?.orderBack(nil) }
        try await super.tearDown()
    }

    @MainActor private func open(_ profile: Profile, _ path: String) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile,
                                                          url: URL(string: "https://dock-menu.invalid/\(path)")!)
        quickDetours.append(controller)
        return controller
    }

    @MainActor private func dockItem() throws -> NSMenuItem? {
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let menu = try XCTUnwrap(delegate.applicationDockMenu(NSApp))
        return menu.items.first { $0.action == #selector(AppDelegate.quickDetourDockMenuItemChosen(_:)) }
    }

    @MainActor private func choose(_ item: NSMenuItem?) throws {
        let item = try XCTUnwrap(item)
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
    }

    // MARK: - The rule

    @MainActor func testTheItemFollowsTheWindowsStates() {
        XCTAssertNil(QuickDetourDockAction.action(for: []), "no Quick Detour: no item")
        XCTAssertEqual(QuickDetourDockAction.action(for: [.onScreen]), .hideAll)
        XCTAssertEqual(QuickDetourDockAction.action(for: [.hiddenByDockMenu, .onScreen]), .hideAll,
                       "a new one shows normally, and the item hides it with the rest")
        XCTAssertEqual(QuickDetourDockAction.action(for: [.hiddenByDockMenu, .hiddenByDockMenu]), .showAll)
        XCTAssertEqual(QuickDetourDockAction.action(for: [.hiddenByDockMenu, .elsewhere]), .showAll)
        XCTAssertNil(QuickDetourDockAction.action(for: [.elsewhere, .elsewhere]), "all minimized: nothing to do")
    }

    @MainActor func testTheTitles() {
        XCTAssertEqual(QuickDetourDockAction.hideAll.title, "Hide All Quick Detour Windows")
        XCTAssertEqual(QuickDetourDockAction.showAll.title, "Show All Quick Detour Windows")
    }

    // MARK: - The Dock menu

    @MainActor func testNoItemWithoutAQuickDetour() throws {
        XCTAssertNil(try dockItem())
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let titles = try XCTUnwrap(delegate.applicationDockMenu(NSApp)).items.map(\.title)
        XCTAssertEqual(titles, ["New Window", "New Private Window"])
    }

    @MainActor func testHideAllThenShowAllIncludingPrivate() throws {
        let first = open(profile, "first")
        let second = open(profile, "second")
        let privateOne = open(store.ensureIncognitoProfile(), "private")
        let all = [first, second, privateOne]

        let hide = try dockItem()
        XCTAssertEqual(hide?.title, "Hide All Quick Detour Windows")
        try choose(hide)

        for controller in all {
            XCTAssertEqual(controller.window?.isVisible, false)
            XCTAssertTrue(QuickDetourWindowController.openControllers.contains { $0 === controller }, "still open")
            XCTAssertNotNil(controller.tab?.url, "its page kept")
        }

        let show = try dockItem()
        XCTAssertEqual(show?.title, "Show All Quick Detour Windows")
        try choose(show)

        for controller in all { XCTAssertEqual(controller.window?.isVisible, true) }
        XCTAssertEqual(try dockItem()?.title, "Hide All Quick Detour Windows")
    }

    @MainActor func testAHiddenWindowIsNeverFrontmostSoItsIdleTimerRuns() throws {
        let controller = open(profile, "idle")
        try choose(try dockItem())
        XCTAssertFalse(controller.idleState.isFrontmost)
        let later = controller.idleState.lastUsedAt.addingTimeInterval(3600)
        XCTAssertTrue(QuickDetour.shouldAutoClose(controller.idleState, now: later, interval: 3600))
    }

    @MainActor func testANewQuickDetourShowsAloneAndTheItemHidesItWithTheRest() throws {
        let hidden = open(profile, "hidden")
        try choose(try dockItem())
        XCTAssertEqual(hidden.window?.isVisible, false)

        let fresh = open(profile, "fresh")

        XCTAssertEqual(fresh.window?.isVisible, true)
        XCTAssertEqual(hidden.window?.isVisible, false, "the others stay hidden")
        let item = try dockItem()
        XCTAssertEqual(item?.title, "Hide All Quick Detour Windows")
        try choose(item)
        XCTAssertEqual(fresh.window?.isVisible, false)
        XCTAssertEqual(try dockItem()?.title, "Show All Quick Detour Windows")
        try choose(try dockItem())
        XCTAssertEqual(hidden.window?.isVisible, true)
        XCTAssertEqual(fresh.window?.isVisible, true)
    }

    @MainActor func testAQuarantineIsLeftAlone() throws {
        let quarantine = QuickDetourWindowController.openQuarantine(
            url: URL(string: "https://dock-menu.invalid/quarantine")!, privateProfile: store.ensureIncognitoProfile())
        quickDetours.append(quarantine)
        XCTAssertNil(try dockItem(), "a quarantine alone: no item")

        let quick = open(profile, "quick")
        try choose(try dockItem())

        XCTAssertEqual(quick.window?.isVisible, false)
        XCTAssertEqual(quarantine.window?.isVisible, true)
    }
}
