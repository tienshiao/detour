import XCTest
import AppKit
@testable import Detour

/// TASK-292.10: the Help menu. Its pages are defined once (`HelpLinks`) and
/// are https pages on detourbrowser.com or on the project's GitHub; the
/// window a page opens in is a pure choice; the menu is the app's
/// registered help menu, last in the menu bar.
nonisolated final class HelpMenuTests: XCTestCase {

    // MARK: - The links

    @MainActor func testEveryLinkIsHttpsOnTheWebsiteOrGitHub() {
        for link in HelpLinks.allCases {
            let url = link.url
            XCTAssertEqual(url.scheme, "https", "\(link)")
            XCTAssertTrue(["detourbrowser.com", "github.com"].contains(url.host ?? ""), "\(link): \(url)")
        }
    }

    @MainActor func testReleasesAndIssuesAreOnGitHubTheRestOnTheWebsite() {
        XCTAssertEqual(HelpLinks.releaseNotes.url.host, "github.com")
        XCTAssertEqual(HelpLinks.reportAnIssue.url.host, "github.com")
        for link in [HelpLinks.detourHelp, .keyboardShortcuts, .switchingFromArc] {
            XCTAssertEqual(link.url.host, "detourbrowser.com", "\(link)")
        }
        XCTAssertEqual(HelpLinks.detourHelp.url.absoluteString, "https://detourbrowser.com/features/")
        XCTAssertEqual(HelpLinks.keyboardShortcuts.url.absoluteString, "https://detourbrowser.com/shortcuts/")
        XCTAssertEqual(HelpLinks.switchingFromArc.url.absoluteString, "https://detourbrowser.com/arc/")
        XCTAssertEqual(HelpLinks.releaseNotes.url.absoluteString, "https://github.com/tienshiao/detour/releases")
        XCTAssertEqual(HelpLinks.reportAnIssue.url.absoluteString, "https://github.com/tienshiao/detour/issues/new")
    }

    // MARK: - Where a page opens

    private typealias Window = LinkPlacementWindow<Int>

    @MainActor func testTheFrontmostNormalWindowGetsTheTab() {
        let windows = [Window(id: 1, activeSpaceID: UUID(), isPrivate: false),
                       Window(id: 2, activeSpaceID: UUID(), isPrivate: false)]
        XCTAssertEqual(HelpLinks.placement(windows: windows), .newTab(in: 1))
    }

    @MainActor func testAPrivateWindowInFrontIsPassedOver() {
        let windows = [Window(id: 1, activeSpaceID: UUID(), isPrivate: true),
                       Window(id: 2, activeSpaceID: UUID(), isPrivate: false)]
        XCTAssertEqual(HelpLinks.placement(windows: windows), .newTab(in: 2))
    }

    @MainActor func testOnlyPrivateWindowsOrNoneMeansANewWindow() {
        XCTAssertEqual(HelpLinks.placement(windows: [Window]()), .newWindow)
        XCTAssertEqual(HelpLinks.placement(windows: [Window(id: 1, activeSpaceID: UUID(), isPrivate: true)]), .newWindow)
    }

    @MainActor func testAWindowShowingNoSpaceIsPassedOver() {
        let windows = [Window(id: 1, activeSpaceID: nil, isPrivate: false),
                       Window(id: 2, activeSpaceID: UUID(), isPrivate: false)]
        XCTAssertEqual(HelpLinks.placement(windows: windows), .newTab(in: 2))
    }

    // MARK: - The menu

    @MainActor func testTheHelpMenuIsTheLastMenuAndTheRegisteredHelpMenu() throws {
        let help = try XCTUnwrap(NSApp.helpMenu)
        XCTAssertTrue(NSApp.mainMenu?.items.last?.submenu === help)
        XCTAssertEqual(help.title, "Help")
        XCTAssertEqual(help.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Detour Help", "Keyboard Shortcuts", "Switching from Arc", "Release Notes", "Report an Issue"])
    }

    // MARK: - Opening a page

    @MainActor func testAPageOpensAsASelectedTabInTheFrontNormalWindow() throws {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Help \(UUID().uuidString.prefix(4))")
        let space = store.addSpace(name: "Help", emoji: "❓", colorHex: "007AFF", profileID: profile.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        defer {
            wc.window?.close()
            for tab in space.tabs { tab.teardown() }
            store.forceRemoveSpace(id: space.id)
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            store.undoManager.removeAllActions()
        }
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let url = URL(string: "https://help-menu.invalid/page")!

        delegate.openHelpPage(url)

        let tab = try XCTUnwrap(space.tabs.last)
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(wc.selectedTabID, tab.id)
    }
}
