import XCTest
@testable import Detour

/// Which sections and rows the Profiles settings pane shows (TASK-189 part 2).
final class ProfileSettingsLayoutTests: XCTestCase {
    private let normal = ProfileSettingsState()
    private let privateProfile = ProfileSettingsState(isPrivate: true)

    // MARK: - Sections

    func testSectionsAreInReadingOrderWithTitles() {
        XCTAssertEqual(ProfileSettingsSection.allCases.map(\.title),
                       [nil, "Search", "Tabs", "Content Blocking", "Extensions", "User Agent", "External Apps"])
    }

    func testEveryRowBelongsToExactlyOneSection() {
        let all = ProfileSettingsSection.allCases.flatMap(\.rows)
        XCTAssertEqual(all.count, ProfileSettingsRow.allCases.count)
        XCTAssertEqual(Set(all.map { "\($0)" }), Set(ProfileSettingsRow.allCases.map { "\($0)" }))
    }

    func testHelpTextFollowsTheControlItDescribes() {
        XCTAssertEqual(ProfileSettingsSection.profile.rows, [.name, .privateNote])
        XCTAssertEqual(ProfileSettingsSection.tabs.rows, [.archiveTabs, .sleepTabs, .perTabIsolation, .isolationWarning])
        XCTAssertEqual(ProfileSettingsSection.userAgent.rows, [.userAgentMode, .customUserAgent, .userAgentPreview])
        XCTAssertEqual(ProfileSettingsRow.allCases.filter(\.isHelpText), [.privateNote, .isolationWarning, .userAgentPreview])
    }

    func testNormalProfileWithoutExtensionsHidesOnlyTheExtensionsSection() {
        XCTAssertEqual(ProfileSettingsLayout.visibleSections(in: normal),
                       [.profile, .search, .tabs, .contentBlocking, .userAgent, .externalApps])
    }

    func testNormalProfileWithExtensionsShowsEverySection() {
        var state = normal
        state.hasExtensions = true
        XCTAssertEqual(ProfileSettingsLayout.visibleSections(in: state), ProfileSettingsSection.allCases)
    }

    func testPrivateProfileHidesExternalAppsAsAWholeSection() {
        XCTAssertEqual(ProfileSettingsLayout.visibleSections(in: privateProfile),
                       [.profile, .search, .tabs, .contentBlocking, .userAgent])
    }

    func testPrivateProfileWithExtensionsShowsTheirSwitches() {
        // The switches are Private's "Allow in Private" opt-in (TASK-74).
        var state = privateProfile
        state.hasExtensions = true
        XCTAssertEqual(ProfileSettingsLayout.visibleSections(in: state),
                       [.profile, .search, .tabs, .contentBlocking, .extensions, .userAgent])
    }

    // MARK: - Rows

    func testNormalProfileRows() {
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .profile, in: normal), [.name])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .tabs, in: normal), [.archiveTabs, .sleepTabs, .perTabIsolation])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .userAgent, in: normal), [.userAgentMode, .userAgentPreview])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .contentBlocking, in: normal), [.contentBlocking, .filterLists])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .externalApps, in: normal), [.externalAppPermissions])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .extensions, in: normal), [])
    }

    func testPrivateProfileShowsItsNoteAndHidesArchiving() {
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .profile, in: privateProfile), [.name, .privateNote])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .tabs, in: privateProfile), [.sleepTabs, .perTabIsolation])
        XCTAssertEqual(ProfileSettingsLayout.visibleRows(of: .externalApps, in: privateProfile), [])
    }

    func testIsolationWarningNeedsIsolationAndSleeping() {
        var state = normal
        state.isPerTabIsolation = true
        XCTAssertFalse(ProfileSettingsLayout.isVisible(.isolationWarning, in: state))
        state.sleepsTabs = true
        XCTAssertTrue(ProfileSettingsLayout.isVisible(.isolationWarning, in: state))
        state.isPerTabIsolation = false
        XCTAssertFalse(ProfileSettingsLayout.isVisible(.isolationWarning, in: state))
    }

    func testCustomStringOnlyForACustomUserAgent() {
        var state = normal
        XCTAssertFalse(ProfileSettingsLayout.isVisible(.customUserAgent, in: state))
        state.usesCustomUserAgent = true
        XCTAssertTrue(ProfileSettingsLayout.isVisible(.customUserAgent, in: state))
        XCTAssertTrue(ProfileSettingsLayout.isVisible(.userAgentPreview, in: state))
    }

    // MARK: - Spacing

    func testFirstVisibleRowOfASectionHasNoSpaceAbove() {
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .name, in: normal), 0)
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .archiveTabs, in: normal), 0)
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .externalAppPermissions, in: normal), 0)
    }

    func testRowsAreARowGapApartAndHelpTextSitsCloseToItsControl() {
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .sleepTabs, in: normal), SettingsMetrics.rowGap)
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .filterLists, in: normal), SettingsMetrics.rowGap)
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .userAgentPreview, in: normal), SettingsMetrics.controlToHelp)
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .privateNote, in: privateProfile), SettingsMetrics.controlToHelp)
    }

    func testHiddenArchiveRowMovesTheFirstRowSpacingToSleep() {
        XCTAssertEqual(ProfileSettingsLayout.spacing(above: .sleepTabs, in: privateProfile), 0)
        XCTAssertNil(ProfileSettingsLayout.spacing(above: .archiveTabs, in: privateProfile))
    }

    func testHiddenRowsHaveNoSpacing() {
        XCTAssertNil(ProfileSettingsLayout.spacing(above: .privateNote, in: normal))
        XCTAssertNil(ProfileSettingsLayout.spacing(above: .isolationWarning, in: normal))
        XCTAssertNil(ProfileSettingsLayout.spacing(above: .extensionSwitches, in: normal))
    }
}
