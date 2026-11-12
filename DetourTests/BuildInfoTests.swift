import XCTest
import AppKit
@testable import Detour

/// TASK-321: About shows the commit the app was built from.
nonisolated final class BuildInfoTests: XCTestCase {

    @MainActor func testAboutVersionJoinsBuildAndCommit() {
        XCTAssertEqual(BuildInfo.aboutPanelVersion(build: "10", commit: "3cb6022abc"), "10 · 3cb6022abc")
        XCTAssertEqual(BuildInfo.aboutPanelVersion(build: "10", commit: "3cb6022abc-dirty"), "10 · 3cb6022abc-dirty")
    }

    @MainActor func testAboutVersionWithoutCommitIsTheBuildNumber() {
        XCTAssertEqual(BuildInfo.aboutPanelVersion(build: "10", commit: nil), "10")
        XCTAssertEqual(BuildInfo.aboutPanelVersion(build: "10", commit: ""), "10")
    }

    @MainActor func testAboutVersionWithNothingLeavesAppKitsDefault() {
        XCTAssertNil(BuildInfo.aboutPanelVersion(build: nil, commit: nil))
        XCTAssertEqual(BuildInfo.aboutPanelVersion(build: nil, commit: "3cb6022abc"), "3cb6022abc")
    }

    /// The test host is the built Detour.app, so its Info.plist went through
    /// the "Stamp git commit" build phase.
    @MainActor func testBuiltAppCarriesTheCommit() throws {
        let commit = try XCTUnwrap(BuildInfo.commit, "the build phase did not stamp DetourGitCommit")
        XCTAssertNotNil(commit.range(of: #"^[0-9a-f]{7,40}(-dirty)?$"#, options: .regularExpression),
                        "unexpected commit stamp: \(commit)")
    }

    /// The menu item goes through BuildInfo, not AppKit's plain About panel.
    @MainActor func testAboutMenuItemShowsTheCommitPanel() throws {
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let about = try XCTUnwrap(appMenu.items.first { $0.title == "About Detour" })
        XCTAssertEqual(about.action, #selector(AppDelegate.showAboutPanel(_:)))
    }
}
