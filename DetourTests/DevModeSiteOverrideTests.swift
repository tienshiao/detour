import XCTest
import AppKit
import GRDB
@testable import Detour

/// TASK-186.5: dev mode can be turned on for any site and off for a local one,
/// per profile. The choice is a `devMode` row of the `siteSetting` table, keyed
/// by host plus a non-default port and matched exactly.
final class DevModeSiteOverrideTests: XCTestCase {

    private let profileA = UUID()
    private let profileB = UUID()

    private let remote = URL(string: "https://example.com/page")!
    private let local3000 = URL(string: "http://localhost:3000/")!
    private let local4000 = URL(string: "http://localhost:4000/")!

    private func makeProfile(_ id: UUID) -> ProfileRecord {
        ProfileRecord(id: id.uuidString, name: "P", userAgentMode: 0, customUserAgent: nil,
                      archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                      searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true,
                      isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                      isMalwareFilterEnabled: true)
    }

    private func makeDatabase() throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        db.saveProfile(makeProfile(profileA))
        db.saveProfile(makeProfile(profileB))
        return db
    }

    // MARK: - The rule

    func testTheOverrideDecidesAndNilFallsBackToTheURLRule() {
        XCTAssertTrue(DevMode.isActive(url: remote, override: true), "on for a remote site")
        XCTAssertFalse(DevMode.isActive(url: local3000, override: false), "off for a local one")
        XCTAssertTrue(DevMode.isActive(url: local3000, override: nil), "nil falls back: local")
        XCTAssertFalse(DevMode.isActive(url: remote, override: nil), "nil falls back: remote")
        XCTAssertTrue(DevMode.isActive(url: local3000, override: true))
        XCTAssertFalse(DevMode.isActive(url: remote, override: false))
    }

    // MARK: - Site key

    func testTheSiteKeyIsTheHostPlusANonDefaultPort() {
        XCTAssertEqual(devModeSiteKey(for: local3000), "localhost:3000")
        XCTAssertEqual(devModeSiteKey(for: URL(string: "http://Example.COM:8080/a?b")), "example.com:8080")
        XCTAssertEqual(devModeSiteKey(for: URL(string: "https://example.com:443/")), "example.com")
        XCTAssertEqual(devModeSiteKey(for: URL(string: "http://example.com:80/")), "example.com")
        XCTAssertEqual(devModeSiteKey(for: URL(string: "http://[::1]:5173/")), "[::1]:5173")
        XCTAssertEqual(devModeSiteKey(for: URL(string: "http://localhost.:3000/")), "localhost:3000")
    }

    func testOnlyWebPagesHaveASiteKey() {
        XCTAssertNil(devModeSiteKey(for: nil))
        XCTAssertNil(devModeSiteKey(for: URL(string: "about:blank")))
        XCTAssertNil(devModeSiteKey(for: URL(string: "file:///Users/me/index.html")))
        XCTAssertNil(devModeSiteKey(for: URL(string: "detour://history")))
        XCTAssertNil(devModeSiteKey(for: URL(string: "webkit-extension://abc/popup.html")))
    }

    // MARK: - Store and switch

    func testTurningItOnForARemoteSiteStoresTrue() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: profileA, store: store))

        DevMode.setEnabled(true, for: remote, profileID: profileA, store: store)

        XCTAssertTrue(DevMode.isActive(for: remote, profileID: profileA, store: store))
        XCTAssertTrue(DevMode.isActive(for: URL(string: "http://example.com/other"), profileID: profileA, store: store),
                      "the site, not the page: any path and either scheme")
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: profileB, store: store), "per profile")
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: nil, store: store), "no profile, no override")
        let rows = db.loadSiteSettings()
        XCTAssertEqual(rows.map(\.site), ["example.com"])
        XCTAssertEqual(rows.map(\.setting), ["devMode"])
        XCTAssertEqual(rows.map(\.value), [true])
        XCTAssertTrue(DevMode.isActive(for: remote, profileID: profileA, store: SiteSettingsStore(database: db)),
                      "survives a new store")
    }

    func testTurningItOffForALocalURLStoresFalseForThatPortOnly() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)

        DevMode.setEnabled(false, for: local3000, profileID: profileA, store: store)

        XCTAssertFalse(DevMode.isActive(for: local3000, profileID: profileA, store: store))
        XCTAssertTrue(DevMode.isActive(for: local4000, profileID: profileA, store: store),
                      "another port is another app")
        XCTAssertTrue(DevMode.isActive(for: local3000, profileID: profileB, store: store))
        XCTAssertEqual(store.overrides(.devMode, profileID: profileA), ["localhost:3000": false])
    }

    func testAChoiceEqualToTheDefaultClearsTheRow() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)

        DevMode.setEnabled(true, for: remote, profileID: profileA, store: store)
        DevMode.setEnabled(false, for: remote, profileID: profileA, store: store)
        DevMode.setEnabled(false, for: local3000, profileID: profileA, store: store)
        DevMode.setEnabled(true, for: local3000, profileID: profileA, store: store)
        DevMode.setEnabled(true, for: local4000, profileID: profileA, store: store)

        XCTAssertTrue(store.overrides(.devMode, profileID: profileA).isEmpty)
        XCTAssertTrue(db.loadSiteSettings().isEmpty, "no redundant override is stored")
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: profileA, store: store))
        XCTAssertTrue(DevMode.isActive(for: local3000, profileID: profileA, store: store))
    }

    func testAURLWithoutASiteKeyStoresNothing() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        DevMode.setEnabled(true, for: URL(string: "detour://history"), profileID: profileA, store: store)
        DevMode.setEnabled(true, for: nil, profileID: profileA, store: store)
        XCTAssertTrue(db.loadSiteSettings().isEmpty)
        XCTAssertFalse(DevMode.isActive(for: URL(string: "detour://history"), profileID: profileA, store: store))
    }

    func testDevModeMatchesTheSiteKeyExactly() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        store.set(.devMode, site: "example.com", to: true, profileID: profileA)
        store.set(.devMode, site: "localhost:3000", to: false, profileID: profileA)

        XCTAssertEqual(store.override(.devMode, forSite: "example.com", profileID: profileA), true)
        XCTAssertNil(store.override(.devMode, forSite: "www.example.com", profileID: profileA),
                     "a stored site does not cover its subdomains")
        XCTAssertNil(store.override(.devMode, forSite: "example.com:8080", profileID: profileA))
        XCTAssertNil(store.override(.devMode, forSite: "localhost", profileID: profileA))
        XCTAssertNil(store.override(.devMode, forSite: "localhost:30001", profileID: profileA))
        XCTAssertNil(store.override(.devMode, forSite: "app.localhost:3000", profileID: profileA))
        XCTAssertFalse(DevMode.isActive(for: URL(string: "https://www.example.com/"), profileID: profileA, store: store))
        XCTAssertTrue(SiteSetting.devMode.site("Example.com", covers: "example.COM"), "case-insensitive")
        XCTAssertFalse(SiteSetting.devMode.site("example.com", covers: "www.example.com"))
    }

    // MARK: - Private

    func testAPrivateWindowsChoiceIsKeptInMemoryOnly() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        let privateID = TabStore.incognitoProfileID

        DevMode.setEnabled(true, for: remote, profileID: privateID, store: store)
        DevMode.setEnabled(false, for: local3000, profileID: privateID, store: store)

        XCTAssertTrue(DevMode.isActive(for: remote, profileID: privateID, store: store))
        XCTAssertFalse(DevMode.isActive(for: local3000, profileID: privateID, store: store))
        XCTAssertTrue(db.loadSiteSettings().isEmpty, "the sites a Private window visited are not written to disk")
        XCTAssertFalse(SiteSetting.devMode.persistsInPrivate)

        store.discardPrivateSession()
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: privateID, store: store))
        XCTAssertTrue(DevMode.isActive(for: local3000, profileID: privateID, store: store))
    }

    // MARK: - Other settings unaffected

    func testHostMatchedSettingsAreUnaffected() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)
        store.set(.pictureInPicture, site: "example.com", to: false, profileID: profileA)
        DevMode.setEnabled(true, for: URL(string: "https://other.com/"), profileID: profileA, store: store)

        XCTAssertEqual(store.override(.contentBlocking, forSite: "www.example.com", profileID: profileA), false,
                       "content blocking still covers subdomains")
        XCTAssertEqual(store.override(.pictureInPicture, forSite: "www.example.com", profileID: profileA), false,
                       "picture in picture still covers subdomains")
        XCTAssertNil(store.override(.contentBlocking, forSite: "other.com", profileID: profileA),
                     "settings are independent")
        XCTAssertNil(store.override(.devMode, forSite: "example.com", profileID: profileA))
        XCTAssertFalse(DevMode.isActive(for: remote, profileID: profileA, store: store),
                       "another setting's row is not a dev-mode override")
        XCTAssertFalse(SiteSetting.contentBlocking.persistsInPrivate)
        XCTAssertFalse(SiteSetting.pictureInPicture.persistsInPrivate)
    }

    // MARK: - Change notification

    func testTheStorePostsAChangeNamingTheSettingAndProfile() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        var received: [(SiteSetting?, UUID?)] = []
        let token = NotificationCenter.default.addObserver(forName: SiteSettingsStore.didChangeNotification,
                                                           object: store, queue: nil) { note in
            received.append((note.userInfo?[SiteSettingsStore.settingKey] as? SiteSetting,
                             note.userInfo?[SiteSettingsStore.profileIDKey] as? UUID))
        }
        defer { NotificationCenter.default.removeObserver(token) }

        DevMode.setEnabled(true, for: remote, profileID: profileA, store: store)
        DevMode.setEnabled(false, for: remote, profileID: profileA, store: store)
        store.clear(.devMode, sites: ["never-stored.com"], profileID: profileA)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileB)

        XCTAssertEqual(received.map(\.0), [.devMode, .devMode, .contentBlocking],
                       "clearing a site with no row changes nothing")
        XCTAssertEqual(received.map(\.1), [profileA, profileA, profileB])
    }

    // MARK: - Row marking

    func testRowMarkingFollowsTheOverride() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        DevMode.setEnabled(true, for: remote, profileID: profileA, store: store)
        DevMode.setEnabled(false, for: local3000, profileID: profileA, store: store)

        XCTAssertEqual(DevMode.rowMarking(for: remote, profileID: profileA, store: store),
                       .tab(hostLabel: "example.com"))
        XCTAssertEqual(DevMode.rowMarking(for: local3000, profileID: profileA, store: store), DevModeRowMarking.none)
        XCTAssertEqual(DevMode.rowMarking(for: remote, profileID: profileB, store: store), DevModeRowMarking.none)
        XCTAssertEqual(DevMode.splitRowMarking(left: local3000, right: remote, profileID: profileA, store: store),
                       .split(left: false, right: true))
    }

    // MARK: - Popover switch

    private func devModeSwitch(in view: NSView) -> NSSwitch? {
        if let control = view as? NSSwitch, control.accessibilityLabel() == "Dev mode for this site" { return control }
        for subview in view.subviews {
            if let found = devModeSwitch(in: subview) { return found }
        }
        return nil
    }

    func testThePopoverSwitchShowsTheEffectiveStateAndReportsTheNewOne() throws {
        let vc = SettingsPopoverViewController()
        vc.host = "example.com"
        vc.isDevModeAvailable = true
        vc.isDevModeEnabled = true
        var toggled: [Bool] = []
        vc.onDevModeToggle = { toggled.append($0) }

        let control = try XCTUnwrap(devModeSwitch(in: vc.view))
        XCTAssertEqual(control.state, .on)
        XCTAssertTrue(control.isEnabled)

        control.performClick(nil)
        XCTAssertEqual(toggled, [false])
    }

    /// The address bar button opens per-site settings now, not only extensions.
    func testTheAddressBarButtonIsLabelledSiteSettings() {
        let bar = FauxAddressBar()
        XCTAssertEqual(bar.settingsButton.image?.accessibilityDescription, "Site Settings")
        let expected = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        XCTAssertEqual(bar.settingsButton.image?.tiffRepresentation, expected?.tiffRepresentation)
    }

    func testThePopoverSwitchIsDisabledWithoutASite() throws {
        let vc = SettingsPopoverViewController()
        vc.host = ""
        vc.isDevModeAvailable = false
        let control = try XCTUnwrap(devModeSwitch(in: vc.view))
        XCTAssertFalse(control.isEnabled)
        XCTAssertEqual(control.state, .off)
    }
}
