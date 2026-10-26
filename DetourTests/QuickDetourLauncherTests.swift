import XCTest
import WebKit
@testable import Detour

/// The launcher panel (TASK-193.1, as changed on 2026-10-25): Opt-Cmd-N shows
/// the command palette alone in a panel, like Spotlight. Submitting closes it
/// and opens the Quick Detour window loading the page; Escape or clicking
/// away closes it and opens nothing, so no window ever has an empty page.
@MainActor
final class QuickDetourLauncherTests: XCTestCase {

    private var launcher: QuickDetourLauncher!
    private var opened: [(profile: Profile, url: URL, typed: Bool)] = []
    private var createdProfiles: [Profile] = []
    private static var retainedProfiles: [Profile] = []

    override func setUp() {
        super.setUp()
        launcher = QuickDetourLauncher()
        launcher.openWindow = { [unowned self] profile, _, url, typed in
            self.opened.append((profile, url, typed))
        }
    }

    override func tearDown() {
        launcher.close()
        launcher = nil
        opened.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        super.tearDown()
    }

    private func makeProfile() -> Profile {
        let profile = TabStore.shared.addProfile(name: "Quick Detour Launcher \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    // MARK: - The panel

    func testShowingOpensAPalettePanelAndNoWindow() throws {
        let profile = makeProfile()
        let windowsBefore = QuickDetourWindowController.openControllers.count
        let tabsBefore = TabStore.shared.quickDetourTabs.count

        launcher.show(profile: profile, sourceSpace: nil)

        let panel = try XCTUnwrap(launcher.panel)
        XCTAssertTrue(launcher.isShowing)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey, "it takes typing straight away")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel),
                      "it can take the keyboard while another app stays active (TASK-193.2)")
        XCTAssertFalse(panel.styleMask.contains(.titled), "no title bar")
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        let palette = try XCTUnwrap(launcher.palette)
        XCTAssertTrue(palette.isDescendant(of: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(palette.profile === profile)
        XCTAssertNil(palette.tabStore, "no open tabs: switching to one would open no Quick Detour")
        XCTAssertEqual(palette.activeSpaceID, QuickDetour.historySpaceID(forProfileID: profile.id))
        XCTAssertEqual(QuickDetourWindowController.openControllers.count, windowsBefore, "no window yet")
        XCTAssertEqual(TabStore.shared.quickDetourTabs.count, tabsBefore, "no page yet")
    }

    func testThePaletteSuggestsFromTheSourceSpaceOfTheSameProfile() throws {
        let profile = makeProfile()
        let space = TabStore.shared.addSpace(name: "Launcher Source", emoji: "L", colorHex: "007AFF",
                                             profileID: profile.id)
        defer { TabStore.shared.forceRemoveSpace(id: space.id) }

        launcher.show(profile: profile, sourceSpace: space)

        XCTAssertEqual(launcher.palette?.activeSpaceID, space.id)
    }

    func testSubmittingAURLClosesThePanelAndOpensTheWindowLoadingIt() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitInput: "https://example.com/page")

        XCTAssertFalse(launcher.isShowing)
        XCTAssertNil(launcher.panel)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.profile === profile)
        XCTAssertEqual(opened.first?.url, URL(string: "https://example.com/page"))
        XCTAssertEqual(opened.first?.typed, true, "a typed URL is a typed visit")
    }

    func testASearchUsesTheProfilesEngine() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitInput: "quick lookup words")

        XCTAssertEqual(opened.map(\.url), [profile.searchEngine.searchURL(for: "quick lookup words")].compactMap { $0 })
        XCTAssertEqual(opened.first?.typed, false)
    }

    func testChoosingASearchSuggestionOpensIt() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)

        launcher.commandPalette(palette, didSubmitSearch: "suggested")

        XCTAssertEqual(opened.map(\.url), [profile.searchEngine.searchURL(for: "suggested")].compactMap { $0 })
        XCTAssertFalse(launcher.isShowing)
    }

    func testEscapeClosesThePanelAndOpensNothing() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)

        // What Escape on an empty field ends in (`CommandPaletteView.dismiss`).
        launcher.palette?.dismiss()

        XCTAssertFalse(launcher.isShowing)
        XCTAssertNil(launcher.panel)
        XCTAssertTrue(opened.isEmpty)
    }

    func testClickingAwayClosesThePanelAndOpensNothing() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let panel = try XCTUnwrap(launcher.panel)

        // The panel resigning key: another window or app was clicked.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)

        XCTAssertFalse(launcher.isShowing)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(opened.isEmpty)
    }

    func testShowingAgainKeepsOnePanel() throws {
        let profile = makeProfile()
        launcher.show(profile: profile, sourceSpace: nil)
        let first = try XCTUnwrap(launcher.panel)

        launcher.show(profile: profile, sourceSpace: nil)

        XCTAssertTrue(launcher.panel === first, "Opt-Cmd-N again brings the open panel forward")
    }

    func testShowingForAnotherProfileReplacesThePanel() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        let other = makeProfile()

        launcher.show(profile: other, sourceSpace: nil)

        XCTAssertTrue(launcher.palette?.profile === other)
    }

    /// With nothing of its own window behind it, the palette's glass would
    /// show whatever the screen has there and read light over a light window
    /// in dark mode; the panel tints it to the appearance.
    func testThePanelsGlassIsTintedToTheAppearance() throws {
        launcher.show(profile: makeProfile(), sourceSpace: nil)
        XCTAssertTrue(launcher.palette?.glassTint === QuickDetourPalettePanel.glassTint)

        func white(in name: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                value = QuickDetourPalettePanel.glassTint.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
            }
            return value
        }
        XCTAssertLessThan(white(in: .darkAqua), 0.3, "dark in dark mode")
        XCTAssertGreaterThan(white(in: .aqua), 0.8, "light in light mode")
    }

    // MARK: - Placement

    func testThePanelIsCentredOnTheScreen() {
        let frame = QuickDetour.panelFrame(size: NSSize(width: 540, height: 400),
                                           in: NSRect(x: 100, y: 50, width: 1440, height: 875))
        XCTAssertEqual(frame, NSRect(x: 550, y: 288, width: 540, height: 400))
    }

    // MARK: - End to end

    /// The production `openWindow`: the window opens loading the page, so its
    /// page is never empty.
    func testTheRealWindowOpensWithThePage() throws {
        let profile = makeProfile()
        let real = QuickDetourLauncher()
        real.show(profile: profile, sourceSpace: nil)
        let palette = try XCTUnwrap(real.palette)
        let before = QuickDetourWindowController.openControllers.count

        real.commandPalette(palette, didSubmitInput: "https://quick-detour.invalid/")

        let controller = try XCTUnwrap(QuickDetourWindowController.openControllers.last)
        defer { controller.close() }
        XCTAssertEqual(QuickDetourWindowController.openControllers.count, before + 1)
        XCTAssertNotNil(controller.tab?.url, "the window never shows an empty page")
        XCTAssertNil(controller.commandPaletteView, "and no palette of its own")
        XCTAssertTrue(controller.profile === profile)
    }
}
