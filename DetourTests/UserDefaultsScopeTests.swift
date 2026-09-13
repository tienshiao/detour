import XCTest
@testable import Detour

/// The data-directory decision behind the autosave names (TASK-41).
final class UserDefaultsScopeTests: XCTestCase {

    func testDefaultDataDirectoryKeepsThePlainName() {
        XCTAssertEqual(
            UserDefaultsScope.autosaveName("BrowserWindow", dataDirectory: defaultDetourDataDirectoryName),
            "BrowserWindow",
            "production must keep reading and writing the keys it already saved")
        XCTAssertEqual(
            UserDefaultsScope.autosaveName("BrowserSplitView", dataDirectory: "Detour"),
            "BrowserSplitView")
    }

    func testIsolatedDataDirectorySuffixesTheName() {
        XCTAssertEqual(
            UserDefaultsScope.autosaveName("BrowserWindow", dataDirectory: "DetourTests"),
            "BrowserWindow-DetourTests")
        XCTAssertEqual(
            UserDefaultsScope.autosaveName("BrowserSplitView", dataDirectory: "Scratch"),
            "BrowserSplitView-Scratch")
    }

    func testNilDataDirectoryKeepsThePlainName() {
        XCTAssertEqual(UserDefaultsScope.autosaveName("BrowserWindow", dataDirectory: nil), "BrowserWindow")
    }

    /// The convenience overload follows this process's data directory, and the
    /// window controller's names go through it.
    func testCurrentProcessNamesFollowItsDataDirectory() {
        let expected = UserDefaultsScope.autosaveName(
            "BrowserWindow", dataDirectory: WebKitStorageScope.currentDataDirectoryName)
        XCTAssertEqual(UserDefaultsScope.autosaveName("BrowserWindow"), expected)
        XCTAssertEqual(BrowserWindowController.frameAutosaveName, expected)
        XCTAssertEqual(
            BrowserWindowController.splitViewAutosaveName,
            UserDefaultsScope.autosaveName("BrowserSplitView", dataDirectory: WebKitStorageScope.currentDataDirectoryName))

        if WebKitStorageScope.currentIsDefaultDataDirectory {
            XCTAssertEqual(BrowserWindowController.frameAutosaveName, "BrowserWindow")
            XCTAssertEqual(BrowserWindowController.splitViewAutosaveName, "BrowserSplitView")
        } else {
            XCTAssertNotEqual(BrowserWindowController.frameAutosaveName, "BrowserWindow")
            XCTAssertNotEqual(BrowserWindowController.splitViewAutosaveName, "BrowserSplitView")
        }
    }

    /// `WebKitStorageScope`'s registry-free flag agrees with its instance
    /// property — AppDelegate asks the former before the database exists.
    func testDefaultDataDirectoryFlagsAgree() {
        XCTAssertEqual(
            WebKitStorageScope.currentIsDefaultDataDirectory,
            WebKitStorageScope.current.isDefaultDataDirectory)
    }

    /// Sparkle must not run in the test host, whatever the data directory.
    func testUpdaterDoesNotStartInTheTestHost() {
        XCTAssertTrue(AppDelegate.isRunningUnitTests, "the test host should be detected as such")
        XCTAssertFalse(AppDelegate.startsUpdater)
    }
}
