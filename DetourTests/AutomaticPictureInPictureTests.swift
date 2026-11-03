import XCTest
import GRDB
@testable import Detour

/// TASK-188: a per-site switch for the picture in picture Detour enters by
/// itself when the user switches away from a playing tab. Stored as the
/// `pictureInPicture` site setting (default on); a page's own PiP request is
/// not affected.
nonisolated final class AutomaticPictureInPictureTests: XCTestCase {

    // MARK: - The rule

    @MainActor func testAPlayingTabEntersPiPWhenTheSiteHasNoSetting() {
        XCTAssertTrue(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: false, leavesClosingTab: false,
                                                            siteOverride: nil))
    }

    @MainActor func testATabThatIsNotPlayingDoesNotEnterPiP() {
        XCTAssertFalse(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: false, isMuted: false, leavesClosingTab: false,
                                                             siteOverride: nil))
    }

    /// TASK-192: page mute keeps `_isPlayingAudio` true, where the old script
    /// mute turned it off. A muted tab still does not go into PiP when left.
    @MainActor func testAMutedPlayingTabDoesNotEnterPiP() {
        XCTAssertFalse(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: true,
                                                             leavesClosingTab: false, siteOverride: nil))
    }

    @MainActor func testAnUnmutedPlayingTabStillEntersPiP() {
        XCTAssertTrue(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: false,
                                                            leavesClosingTab: false, siteOverride: nil))
    }

    @MainActor func testAClosingTabDoesNotEnterPiP() {
        XCTAssertFalse(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: false, leavesClosingTab: true,
                                                             siteOverride: nil),
                       "TASK-79: the close path never starts PiP")
    }

    @MainActor func testASiteWithTheSwitchOffDoesNotEnterPiP() {
        XCTAssertFalse(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: false, leavesClosingTab: false,
                                                             siteOverride: false))
    }

    @MainActor func testASiteWithTheSwitchExplicitlyOnEntersPiP() {
        XCTAssertTrue(AutomaticPictureInPicture.shouldEnter(isPlayingAudio: true, isMuted: false, leavesClosingTab: false,
                                                            siteOverride: true))
    }

    // MARK: - The stored switch

    private let profileID = UUID()

    @MainActor private func makeDatabase() throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        for id in [profileID, TabStore.incognitoProfileID] {
            db.saveProfile(ProfileRecord(id: id.uuidString, name: "P", userAgentMode: 0, customUserAgent: nil,
                                         archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                                         searchSuggestionsEnabled: true, isPerTabIsolation: false,
                                         isAdBlockingEnabled: true, isEasyListEnabled: true,
                                         isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                                         isMalwareFilterEnabled: true))
        }
        return db
    }

    @MainActor func testTheSwitchCoversTheHostAndItsSubdomains() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        store.set(.pictureInPicture, site: "youtube.com", to: false, profileID: profileID)

        XCTAssertEqual(store.override(.pictureInPicture, forSite: "www.youtube.com", profileID: profileID), false)
        XCTAssertNil(store.override(.pictureInPicture, forSite: "notyoutube.com", profileID: profileID))
        XCTAssertNil(store.override(.contentBlocking, forSite: "youtube.com", profileID: profileID),
                     "settings are independent")
    }

    @MainActor func testTurningTheSwitchBackOnClearsEveryRowCoveringTheHost() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.pictureInPicture, site: "youtube.com", to: false, profileID: profileID)
        store.set(.pictureInPicture, site: "music.youtube.com", to: false, profileID: profileID)
        store.set(.pictureInPicture, site: "other.test", to: false, profileID: profileID)

        store.resetToDefault(.pictureInPicture, forSite: "music.youtube.com", profileID: profileID)

        XCTAssertNil(store.override(.pictureInPicture, forSite: "music.youtube.com", profileID: profileID),
                     "a parent row left behind would keep the switch off")
        XCTAssertEqual(store.overrides(.pictureInPicture, profileID: profileID), ["other.test": false])
        XCTAssertEqual(SiteSettingsStore(database: db).overrides(.pictureInPicture, profileID: profileID),
                       ["other.test": false])
    }

    @MainActor func testAPrivateWindowsSwitchIsKeptInMemoryOnly() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)

        XCTAssertEqual(store.override(.pictureInPicture, forSite: "youtube.com",
                                      profileID: TabStore.incognitoProfileID), false)
        XCTAssertTrue(db.loadSiteSettings().isEmpty, "the site a Private window visited is not written to disk")
    }

    @MainActor func testEndingThePrivateSessionForgetsItsSwitches() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)
        store.set(.pictureInPicture, site: "youtube.com", to: false, profileID: profileID)

        store.discardPrivateSession()

        XCTAssertNil(store.override(.pictureInPicture, forSite: "youtube.com", profileID: TabStore.incognitoProfileID))
        XCTAssertEqual(store.override(.pictureInPicture, forSite: "youtube.com", profileID: profileID), false,
                       "other profiles keep theirs")
    }

    /// Content blocking's Private switch is kept in memory too (TASK-195):
    /// nothing reaches the database and the session's end drops it.
    @MainActor func testContentBlockingKeepsPrivateRowsInMemoryToo() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: TabStore.incognitoProfileID)
        XCTAssertTrue(db.loadSiteSettings().isEmpty)
        XCTAssertEqual(store.override(.contentBlocking, forSite: "example.com",
                                      profileID: TabStore.incognitoProfileID), false)

        store.discardPrivateSession()

        XCTAssertNil(store.override(.contentBlocking, forSite: "example.com",
                                    profileID: TabStore.incognitoProfileID))
    }

    @MainActor func testClosingTheLastPrivateSpaceEndsThePrivateSession() throws {
        let db = try makeDatabase()
        let settings = SiteSettingsStore(database: db)
        let store = TabStore(appDB: db)
        store.siteSettings = settings
        let first = store.addIncognitoSpace()
        let second = store.addIncognitoSpace()
        settings.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)

        store.removeIncognitoSpace(id: first.id)
        XCTAssertEqual(settings.override(.pictureInPicture, forSite: "youtube.com",
                                         profileID: TabStore.incognitoProfileID), false,
                       "another Private window is still open")

        store.removeIncognitoSpace(id: second.id)
        XCTAssertNil(settings.override(.pictureInPicture, forSite: "youtube.com",
                                       profileID: TabStore.incognitoProfileID))
    }
}
