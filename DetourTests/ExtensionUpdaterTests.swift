import XCTest
import CryptoKit
@testable import Detour

/// TASK-113: the whole update path against canned update2 responses — a real
/// extension installed through `ExtensionManager.install`, a real CRX3 built and
/// signed in the test, and the replace-in-place that follows.
@MainActor
final class ExtensionUpdaterTests: XCTestCase {

    /// Serves canned bytes per URL and records what was asked for.
    private final class FakeFetcher: ExtensionUpdateFetching, @unchecked Sendable {
        var responses: [URL: Data] = [:]
        private(set) var requests: [URL] = []
        struct NotFound: Error {}

        func fetch(_ url: URL) async throws -> Data {
            requests.append(url)
            guard let data = responses[url] else { throw NotFound() }
            return data
        }
    }

    private struct Fixture {
        let pair: CRX3TestBuilder.RSAKeyPair
        let id: String
        let updateURL = URL(string: "https://updates.test/service/update2/crx")!
        let codebase = URL(string: "https://updates.test/blobs/ext_2_0.crx")!
    }

    private var installedIDs: [String] = []
    private var tempDirs: [URL] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []

    override func tearDown() {
        for spaceID in createdSpaceIDs {
            guard let space = TabStore.shared.space(withID: spaceID) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: spaceID)
        }
        createdSpaceIDs.removeAll()
        for id in installedIDs {
            ExtensionManager.shared.stagedUpdate(for: id)?.discard()
            ExtensionManager.shared.uninstall(id: id)
        }
        installedIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func manifestJSON(version: String, permissions: [String] = ["storage"],
                              hostPermissions: [String] = [], updateURL: String? = nil) -> String {
        var fields = [
            "\"manifest_version\": 3",
            "\"name\": \"Updater Test\"",
            "\"version\": \"\(version)\"",
            "\"permissions\": [\(permissions.map { "\"\($0)\"" }.joined(separator: ","))]",
            "\"host_permissions\": [\(hostPermissions.map { "\"\($0)\"" }.joined(separator: ","))]",
            "\"options_ui\": { \"page\": \"options.html\" }",
        ]
        if let updateURL { fields.append("\"update_url\": \"\(updateURL)\"") }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    /// Install version 1.0 as a Web Store extension whose id is derived from a
    /// fresh RSA key, the way a real CRX install records it.
    private func installVersionOne(permissions: [String] = ["storage"]) async throws -> Fixture {
        let pair = try CRX3TestBuilder.RSAKeyPair.generate()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-updater-src-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        tempDirs.append(source)
        try manifestJSON(version: "1.0", permissions: permissions)
            .write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: source.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)

        var fixture = Fixture(pair: pair, id: ExtensionInstaller.deriveExtensionID(from: pair.publicKeySPKI))
        var options = ExtensionInstaller.Options()
        options.source = .webStore
        options.updateURL = fixture.updateURL
        let ext = try ExtensionManager.shared.install(from: source, publicKey: pair.publicKeySPKI, options: options)
        installedIDs.append(ext.id)
        XCTAssertEqual(ext.id, fixture.id)
        try await waitUntil("the install to load") { ext.wkExtension != nil }
        fixture = Fixture(pair: pair, id: ext.id)
        return fixture
    }

    private func crx(_ fixture: Fixture, version: String, permissions: [String] = ["storage"],
                     hostPermissions: [String] = [], signer: CRX3TestBuilder.Signer? = nil) throws -> Data {
        let zip = try CRX3TestBuilder.zip(files: [
            "manifest.json": manifestJSON(version: version, permissions: permissions,
                                          hostPermissions: hostPermissions, updateURL: fixture.updateURL.absoluteString),
            "options.html": "<html><body>v\(version)</body></html>",
        ])
        return try CRX3TestBuilder.build(zip: zip, signers: [signer ?? .rsa(fixture.pair)],
                                         declaredKey: fixture.pair.publicKeySPKI)
    }

    private func updateXML(_ fixture: Fixture, version: String, crx: Data, announceHash: Bool = true) -> Data {
        let hash = announceHash ? " hash_sha256=\"\(SHA256.hash(data: crx).map { String(format: "%02x", $0) }.joined())\"" : ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
          <app appid="\(fixture.id)" status="ok">
            <updatecheck codebase="\(fixture.codebase.absoluteString)"\(hash) status="ok" version="\(version)"/>
          </app>
        </gupdate>
        """.utf8)
    }

    private func makeUpdater(_ fetcher: FakeFetcher, now: @escaping () -> Date = Date.init) -> ExtensionUpdater {
        ExtensionUpdater(fetcher: fetcher, now: now)
    }

    private func requestURL(_ fixture: Fixture, version: String, updater: ExtensionUpdater) throws -> URL {
        try XCTUnwrap(UpdateManifest.requestURL(updateURL: fixture.updateURL, extensionID: fixture.id,
                                                version: version, prodVersion: updater.prodVersion))
    }

    // MARK: - AC #2 / #5: a newer version installs in place and keeps everything

    func testANewerVersionIsInstalledInPlaceKeepingRowsPermissionsAndTheLedger() async throws {
        let fixture = try await installVersionOne()
        let db = AppDatabase.shared
        // A real profile: the per-profile row has a foreign key to it. Adding it
        // loads the fixture there (it is enabled), which the update must unload
        // and, with the row below off, not reload.
        let profile = TabStore.shared.addProfile(name: "Updater Test")
        createdProfiles.append(profile)
        let profileID = profile.id.uuidString
        // Per-profile choice, a saved denial and a delivered onInstalled.
        db.setProfileExtensionEnabled(extensionID: fixture.id, profileID: profileID, enabled: false)
        db.savePermission(ExtensionPermissionRecord(extensionID: fixture.id, key: "storage", type: .apiPermission, status: .denied))
        XCTAssertEqual(db.claimRuntimeInstalledEvent(extensionID: fixture.id, profileID: profileID, isPrivateProfile: false, currentVersion: "1.0"),
                       .init(reason: .install, previousVersion: nil))

        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0")
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx

        let outcome = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome, .updated(version: "2.0"))

        let updated = try XCTUnwrap(ExtensionManager.shared.extension(withID: fixture.id))
        XCTAssertEqual(updated.manifest.version, "2.0")
        XCTAssertTrue(updated.isEnabled)
        XCTAssertNil(updated.pendingPermissionApproval)
        XCTAssertEqual(updated.source, .webStore)
        XCTAssertEqual(updated.updateURL, fixture.updateURL, "the manifest's update_url is kept")
        try await waitUntil("the update to load") { updated.wkExtension != nil }

        let row = try XCTUnwrap(db.loadExtensions().first { $0.id == fixture.id })
        XCTAssertEqual(row.version, "2.0")
        XCTAssertEqual(row.source, "webStore")
        XCTAssertEqual(row.updateURL, fixture.updateURL.absoluteString)
        XCTAssertTrue(row.isEnabled)
        XCTAssertNil(row.pendingPermissionApprovalJSON)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: row.basePath).appendingPathComponent("options.html")),
                       "<html><body>v2.0</body></html>", "the files on disk are the new version's")

        XCTAssertFalse(db.isExtensionEnabledByProfile(extensionID: fixture.id, profileID: profileID),
                       "the per-profile choice survives (AC #5)")
        XCTAssertNil(profile.extensionContext(for: fixture.id), "and is honoured by the replacement's load")
        XCTAssertEqual(db.permissionStatus(extensionID: fixture.id, key: "storage", type: .apiPermission), .denied,
                       "a saved denial survives the update's declared-permission recording (TASK-63)")
        XCTAssertEqual(db.pendingRuntimeInstalledEvent(extensionID: fixture.id, profileID: profileID, isPrivateProfile: false, currentVersion: "2.0"),
                       .init(reason: .update, previousVersion: "1.0"),
                       "runtime.onInstalled owes 'update' from 1.0 (AC #5)")
        XCTAssertEqual(fetcher.requests.count, 2, "one check, one download")
    }

    func testNoUpdateLeavesTheInstallAlone() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = Data("""
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <app appid="\(fixture.id)" status="ok"><updatecheck status="noupdate"/></app>
        </gupdate>
        """.utf8)
        let outcome1 = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome1, .upToDate)
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
        XCTAssertEqual(fetcher.requests.count, 1, "nothing is downloaded")
    }

    func testAServerSideUpdateCheckErrorIsReportedAsAFailureNotAsUpToDate() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = Data("""
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <app appid="\(fixture.id)" status="ok"><updatecheck status="error-internal"/></app>
        </gupdate>
        """.utf8)
        let outcome = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome, .failed("update server: error-internal"))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
        XCTAssertEqual(fetcher.requests.count, 1, "nothing is downloaded")
    }

    // MARK: - AC #3: rejected candidates

    func testAnAnnouncedVersionThatIsNotNewerIsNotDownloaded() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "1.0")
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "1.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx
        let outcome2 = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome2, .upToDate)
        XCTAssertEqual(fetcher.requests, [try requestURL(fixture, version: "1.0", updater: updater)])
    }

    func testACRXSignedByAnotherKeyIsRejected() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        // Declares the installed key but was signed by someone else: the
        // signature fails. A file honestly signed by another key derives another
        // id and is rejected by the id check instead — both leave 1.0 in place.
        let forger = try CRX3TestBuilder.RSAKeyPair.generate()
        let forged = try crx(fixture, version: "2.0",
                             signer: .rsaDeclaring(publicKey: fixture.pair.publicKeySPKI, signingWith: forger))
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: forged)
        fetcher.responses[fixture.codebase] = forged
        guard case .failed(let reason) = await updater.checkForUpdate(extensionID: fixture.id) else {
            return XCTFail("a forged CRX must fail")
        }
        XCTAssertTrue(reason.contains("signature"), reason)
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")

        let otherZip = try CRX3TestBuilder.zip(files: ["manifest.json": manifestJSON(version: "2.0")])
        let otherKey = try CRX3TestBuilder.build(zip: otherZip, signers: [.rsa(forger)])
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: otherKey)
        fetcher.responses[fixture.codebase] = otherKey
        guard case .failed(let idReason) = await updater.checkForUpdate(extensionID: fixture.id) else {
            return XCTFail("another publisher's CRX must fail")
        }
        XCTAssertTrue(idReason.contains("signed for extension"), idReason)
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
    }

    func testADownloadThatDoesNotMatchTheAnnouncedHashIsRejected() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0")
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: crx + Data([0]))
        fetcher.responses[fixture.codebase] = crx
        guard case .failed(let reason) = await updater.checkForUpdate(extensionID: fixture.id) else {
            return XCTFail("a hash mismatch must fail")
        }
        XCTAssertTrue(reason.contains("hash"), reason)
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
    }

    // MARK: - AC #4: added permissions hold the update disabled

    func testAnUpdateThatAddsPermissionsInstallsDisabledUntilApproved() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0", permissions: ["storage", "history"], hostPermissions: ["https://*.example.com/*"])
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx

        let delta = ExtensionUpdatePolicy.PermissionDelta(permissions: ["history"], hostPermissions: ["https://*.example.com/*"])
        let outcome3 = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome3, .updatedPendingPermissions(version: "2.0", delta: delta))

        let updated = try XCTUnwrap(ExtensionManager.shared.extension(withID: fixture.id))
        XCTAssertEqual(updated.manifest.version, "2.0", "the files are installed…")
        XCTAssertFalse(updated.isEnabled, "…but the extension is off until the user accepts")
        XCTAssertEqual(updated.pendingPermissionApproval, .init(version: "2.0", delta: delta))
        try await waitUntil("the update to load its WKWebExtension") { updated.wkExtension != nil }
        for profile in TabStore.shared.profiles {
            XCTAssertNil(profile.extensionContext(for: fixture.id), "no context loads while disabled (\(profile.name))")
        }
        let row = try XCTUnwrap(AppDatabase.shared.loadExtensions().first { $0.id == fixture.id })
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(try JSONDecoder().decode(ExtensionUpdatePolicy.PendingApproval.self,
                                                from: XCTUnwrap(row.pendingPermissionApprovalJSON)).delta, delta)

        ExtensionManager.shared.approvePendingPermissions(id: fixture.id)
        XCTAssertTrue(updated.isEnabled)
        XCTAssertNil(updated.pendingPermissionApproval)
        let approvedRow = try XCTUnwrap(AppDatabase.shared.loadExtensions().first { $0.id == fixture.id })
        XCTAssertTrue(approvedRow.isEnabled)
        XCTAssertNil(approvedRow.pendingPermissionApprovalJSON)
    }

    func testAnUpdateThatAddsOnlyWarningFreePermissionsStaysEnabled() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "1.1", permissions: ["storage", "alarms", "offscreen"])
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "1.1", crx: crx, announceHash: false)
        fetcher.responses[fixture.codebase] = crx
        let outcome4 = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome4, .updated(version: "1.1"))
        XCTAssertTrue(ExtensionManager.shared.extension(withID: fixture.id)?.isEnabled == true)
    }

    // MARK: - Sources that never update, throttling, scheduling

    func testUnpackedAndURLLessInstallsAreNotChecked() async throws {
        let fixture = try await installVersionOne()
        let ext = try XCTUnwrap(ExtensionManager.shared.extension(withID: fixture.id))
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)

        ext.source = .unpacked
        guard case .notUpdatable = await updater.checkForUpdate(extensionID: fixture.id) else { return XCTFail("unpacked") }
        ext.source = .crx
        ext.updateURL = nil
        guard case .notUpdatable = await updater.checkForUpdate(extensionID: fixture.id) else { return XCTFail("no URL") }
        XCTAssertTrue(fetcher.requests.isEmpty)
        let outcome5 = await updater.checkForUpdate(extensionID: "not-installed")
        XCTAssertEqual(outcome5, .failed("extension not-installed is not installed"))
    }

    func testRequestUpdateCheckIsThrottledPerExtension() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let updater = makeUpdater(fetcher) { clock }
        let noUpdate = Data("""
        <gupdate><app appid="\(fixture.id)" status="ok"><updatecheck status="noupdate"/></app></gupdate>
        """.utf8)
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = noUpdate

        let outcome6 = await updater.requestUpdateCheck(extensionID: fixture.id)
        XCTAssertEqual(outcome6, .upToDate)
        let outcome7 = await updater.requestUpdateCheck(extensionID: fixture.id)
        XCTAssertEqual(outcome7, .throttled)
        XCTAssertEqual(fetcher.requests.count, 1)
        clock = clock.addingTimeInterval(updater.requestUpdateCheckThrottle)
        let outcome8 = await updater.requestUpdateCheck(extensionID: fixture.id)
        XCTAssertEqual(outcome8, .upToDate)
        XCTAssertEqual(fetcher.requests.count, 2)
        let outcome9 = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome9, .upToDate,
                       "the throttle is only for the extension's own API; Settings and the schedule are not held back")
    }

    func testCheckAllRecordsTheTimeAndPostsTheOutcomes() async throws {
        let fixture = try await installVersionOne()
        let fetcher = FakeFetcher()
        let clock = Date(timeIntervalSince1970: 2_000_000)
        let updater = makeUpdater(fetcher) { clock }
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = Data("""
        <gupdate><app appid="\(fixture.id)" status="ok"><updatecheck status="noupdate"/></app></gupdate>
        """.utf8)

        var posted: [String: ExtensionUpdateOutcome]?
        let observer = NotificationCenter.default.addObserver(forName: ExtensionUpdater.didFinishCheckNotification,
                                                              object: updater, queue: nil) { note in
            posted = note.userInfo?["outcomes"] as? [String: ExtensionUpdateOutcome]
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(updater.isCheckDue || updater.lastCheckAt != nil)
        let outcomes = await updater.checkAllForUpdates()
        XCTAssertEqual(outcomes[fixture.id], .upToDate)
        XCTAssertEqual(posted?[fixture.id], .upToDate)
        XCTAssertEqual(updater.lastCheckAt?.timeIntervalSince1970 ?? 0, clock.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(updater.isCheckDue, "just checked")
        let later = makeUpdater(fetcher) { clock.addingTimeInterval(updater.checkInterval + 1) }
        XCTAssertTrue(later.isCheckDue)
    }

    // MARK: - AC #6: unpacked reload

    func testReloadUnpackedReinstallsFromTheSourceFolderKeepingTheID() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-reload-src-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        tempDirs.append(source)
        // No manifest key: a plain install would mint a new UUID on every load.
        try manifestJSON(version: "0.1").write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html>one</html>".write(to: source.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
        var options = ExtensionInstaller.Options()
        options.source = .unpacked
        options.sourcePath = source
        let ext = try ExtensionManager.shared.install(from: source, options: options)
        installedIDs.append(ext.id)
        try await waitUntil("the install to load") { ext.wkExtension != nil }
        XCTAssertEqual(ext.source, .unpacked)
        XCTAssertEqual(ext.sourcePath, source)
        let row = try XCTUnwrap(AppDatabase.shared.loadExtensions().first { $0.id == ext.id })
        XCTAssertEqual(row.source, "unpacked")
        XCTAssertEqual(row.sourcePath, source.path)

        // Edit in place — same version, new file — and reload.
        try "<html>two</html>".write(to: source.appendingPathComponent("options.html"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ExtensionManager.shared.reloadUnpacked(id: ext.id), .installed(version: "0.1"))
        let reloaded = try XCTUnwrap(ExtensionManager.shared.extension(withID: ext.id))
        XCTAssertTrue(reloaded !== ext)
        XCTAssertEqual(reloaded.id, ext.id, "the id survives without a manifest key")
        XCTAssertEqual(reloaded.sourcePath, source)
        try await waitUntil("the reload to load") { reloaded.wkExtension != nil }
        XCTAssertEqual(try String(contentsOf: reloaded.basePath.appendingPathComponent("options.html")), "<html>two</html>")
        XCTAssertEqual(ExtensionManager.shared.extensions.filter { $0.id == ext.id }.count, 1)

        // A manifest that grows permissions is held like an update.
        try manifestJSON(version: "0.1", permissions: ["storage", "tabs"])
            .write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ExtensionManager.shared.reloadUnpacked(id: ext.id),
                       .installedPendingPermissions(version: "0.1", delta: .init(permissions: ["tabs"], hostPermissions: [])))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: ext.id)?.isEnabled, false)

        // The folder going away makes Reload impossible, and says so.
        try FileManager.default.removeItem(at: source.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ExtensionManager.shared.reloadUnpacked(id: ext.id)) {
            guard case ExtensionManager.UpdateError.sourceFolderMissing(let url)? = $0 as? ExtensionManager.UpdateError else {
                return XCTFail("\($0)")
            }
            XCTAssertEqual(url, source)
        }
    }

    // MARK: - TASK-123: a busy extension's update waits

    /// The fixture, a profile that loads it, and one of its options pages open in
    /// a space of that profile — an extension the user is in the middle of using.
    private func busyFixture() async throws -> (fixture: Fixture, profile: Profile, space: Space, tab: BrowserTab) {
        let fixture = try await installVersionOne()
        let profile = TabStore.shared.addProfile(name: "Busy Updater Test")
        createdProfiles.append(profile)
        // The test host's manager does not load extensions into added profiles;
        // load the context by hand, as the other extension-page suites do.
        let context = try loadTestContext(try XCTUnwrap(ExtensionManager.shared.extension(withID: fixture.id)), in: profile)
        let space = TabStore.shared.addSpace(name: "Busy", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let tab = TabStore.shared.addExtensionTab(in: space, url: try XCTUnwrap(context.optionsPageURL),
                                                  configuration: try XCTUnwrap(context.webViewConfiguration))
        return (fixture, profile, space, tab)
    }

    func testActivityCountsOpenPagesPopupsHostsAndBackgroundTraffic() async throws {
        let (fixture, profile, space, tab) = try await busyFixture()
        var activity = ExtensionManager.shared.activity(for: fixture.id)
        XCTAssertEqual(activity.openPages, 1)
        XCTAssertFalse(activity.popupOpen)
        XCTAssertEqual(activity.liveNativeHosts, 0)
        XCTAssertNil(activity.lastBackgroundRequestAt)
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(activity))

        tab.teardown()
        TabStore.shared.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
        activity = ExtensionManager.shared.activity(for: fixture.id)
        XCTAssertEqual(activity.openPages, 0, "the page is closed (\(profile.name))")
        XCTAssertFalse(ExtensionUpdateDeferral.shouldDefer(activity))

        ExtensionManager.shared.noteBackgroundActivity(extensionID: fixture.id)
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(ExtensionManager.shared.activity(for: fixture.id)),
                      "a worker that just spoke counts as busy")
        ExtensionManager.shared.noteBackgroundActivity(extensionID: fixture.id, at: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(ExtensionUpdateDeferral.shouldDefer(ExtensionManager.shared.activity(for: fixture.id)))
    }

    func testABusyExtensionsUpdateIsStagedThenInstalledWhenIdle() async throws {
        let (fixture, profile, space, tab) = try await busyFixture()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0")
        let checkURL = try requestURL(fixture, version: "1.0", updater: updater)
        fetcher.responses[checkURL] = updateXML(fixture, version: "2.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx

        // A background context waiting for the event hears about the staged copy.
        var delivered: [String: Any]?
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id) { reply, _ in
            delivered = reply as? [String: Any]
        }
        XCTAssertEqual(ExtensionManager.shared.updateAvailableWaiterCountForTesting(extensionID: fixture.id), 1)

        let outcome = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome, .deferred(version: "2.0"))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0", "not installed yet")
        let staged = try XCTUnwrap(ExtensionManager.shared.stagedUpdate(for: fixture.id))
        XCTAssertEqual(staged.version, "2.0")
        XCTAssertEqual(staged.publicKey, fixture.pair.publicKeySPKI)
        XCTAssertEqual(delivered?["version"] as? String, "2.0", "runtime.onUpdateAvailable fired (AC #1)")
        XCTAssertEqual(ExtensionManager.shared.updateAvailableWaiterCountForTesting(extensionID: fixture.id), 0)
        XCTAssertEqual(ExtensionPolyfillHandler.requestUpdateCheckReply(for: outcome)["status"] as? String, "update_available")

        // A waiter that arrives while a copy is staged is answered at once — once
        // the reload window after the last delivery to that context has passed.
        var immediate: [String: Any]?
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id, reply: { reply, _ in
            immediate = reply as? [String: Any]
        }, now: Date().addingTimeInterval(ExtensionManager.reloadAfterUpdateAvailableWindow + 1))
        XCTAssertEqual(immediate?["version"] as? String, "2.0")
        ExtensionManager.shared.forgetUpdateAvailableState(extensionID: fixture.id)

        // Still busy: the poll leaves it, and a second check does not download again.
        XCTAssertTrue(updater.applyStagedUpdatesIfIdle().isEmpty)
        let again = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(again, .deferred(version: "2.0"))
        XCTAssertEqual(fetcher.requests.filter { $0 == fixture.codebase }.count, 1, "downloaded once")

        // Idle: the poll installs it (AC #2).
        tab.teardown()
        TabStore.shared.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
        let applied = updater.applyStagedUpdatesIfIdle()
        XCTAssertEqual(applied[fixture.id], .updated(version: "2.0"))
        let updated = try XCTUnwrap(ExtensionManager.shared.extension(withID: fixture.id))
        XCTAssertEqual(updated.manifest.version, "2.0")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id), "the staged copy is consumed")
        try await waitUntil("the update to load") { updated.wkExtension != nil }
    }

    func testRuntimeReloadAppliesAStagedUpdateNow() async throws {
        let (fixture, _, _, _) = try await busyFixture()
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0")
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx
        let outcome = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome, .deferred(version: "2.0"))

        // What the polyfill's runtime.reload() asks for: apply whatever is staged.
        XCTAssertEqual(try ExtensionManager.shared.applyStagedUpdate(for: fixture.id), .installed(version: "2.0"))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "2.0")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id))
        XCTAssertNil(try ExtensionManager.shared.applyStagedUpdate(for: fixture.id), "nothing left to apply")
    }

    /// `runtime.reload()` cannot be intercepted, so the reload an extension makes
    /// in answer to `onUpdateAvailable` is recognised by the background start
    /// that follows the delivery; that start installs the staged copy.
    func testABackgroundStartSoonAfterTheEventIsTheReloadThatInstallsTheUpdate() async throws {
        let (fixture, profile, _, _) = try await busyFixture()
        defer { ExtensionManager.shared.forgetUpdateAvailableState(extensionID: fixture.id) }
        let fetcher = FakeFetcher()
        let updater = makeUpdater(fetcher)
        let crx = try crx(fixture, version: "2.0")
        fetcher.responses[try requestURL(fixture, version: "1.0", updater: updater)] = updateXML(fixture, version: "2.0", crx: crx)
        fetcher.responses[fixture.codebase] = crx

        let t0 = Date()
        var delivered: [String: Any]?
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id, reply: { reply, _ in
            delivered = reply as? [String: Any]
        }, now: t0)
        let outcome = await updater.checkForUpdate(extensionID: fixture.id)
        XCTAssertEqual(outcome, .deferred(version: "2.0"))
        XCTAssertEqual(delivered?["version"] as? String, "2.0")

        // The reloaded worker re-adds its listener: not answered again (no reload loop)…
        var again: [String: Any]?
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id, reply: { reply, _ in
            again = reply as? [String: Any]
        }, now: t0.addingTimeInterval(1))
        XCTAssertNil(again, "the same version was just delivered to this context")
        XCTAssertEqual(ExtensionManager.shared.updateAvailableWaiterCountForTesting(extensionID: fixture.id), 1, "parked instead")

        // …and a start from another profile, or long after, is not a reload.
        XCTAssertFalse(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: UUID(),
                                                                          now: t0.addingTimeInterval(1)))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")

        // The start that follows the delivery installs it, pages open or not (AC #2).
        XCTAssertTrue(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: profile.id,
                                                                         now: t0.addingTimeInterval(2)))
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "2.0")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id))
        XCTAssertFalse(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: profile.id,
                                                                          now: t0.addingTimeInterval(3)), "nothing left")
    }

    func testABackgroundStartLongAfterTheEventIsNotAReload() async throws {
        let (fixture, profile, _, _) = try await busyFixture()
        defer { ExtensionManager.shared.forgetUpdateAvailableState(extensionID: fixture.id) }
        let crx = try crx(fixture, version: "2.0")
        let unpacked = try CRXUnpacker.unpack(data: crx)
        let t0 = Date()
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id, reply: { _, _ in }, now: t0)
        _ = try ExtensionManager.shared.stageUpdate(from: unpacked.directory, publicKey: fixture.pair.publicKeySPKI,
                                                    version: "2.0", for: fixture.id)
        let late = t0.addingTimeInterval(ExtensionManager.reloadAfterUpdateAvailableWindow + 1)
        XCTAssertFalse(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: profile.id, now: late),
                       "an event waking the worker a minute later is not the reload")
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
        XCTAssertNotNil(ExtensionManager.shared.stagedUpdate(for: fixture.id), "still waiting for idle")
    }

    /// The listener is added at script evaluation and answered at once when a
    /// copy is already staged; the claim runs on a later task of the same start.
    /// That answer is not the delivery a reload followed: the incarnation that
    /// asked for it does not install the copy, only a later incarnation does.
    func testAStartWhoseOwnListenerWasAnsweredIsNotAReload() async throws {
        let (fixture, profile, _, _) = try await busyFixture()
        defer { ExtensionManager.shared.forgetUpdateAvailableState(extensionID: fixture.id) }
        let crx = try crx(fixture, version: "2.0")
        let unpacked = try CRXUnpacker.unpack(data: crx)
        _ = try ExtensionManager.shared.stageUpdate(from: unpacked.directory, publicKey: fixture.pair.publicKeySPKI,
                                                    version: "2.0", for: fixture.id)
        let t0 = Date()
        var delivered: [String: Any]?
        ExtensionManager.shared.awaitUpdateAvailable(extensionID: fixture.id, profileID: profile.id, instance: "wake-1",
                                                     reply: { reply, _ in delivered = reply as? [String: Any] }, now: t0)
        XCTAssertEqual(delivered?["version"] as? String, "2.0", "answered at once: a copy is staged")
        XCTAssertFalse(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: profile.id,
                                                                          instance: "wake-1", now: t0.addingTimeInterval(0.1)),
                       "the same incarnation's claim: an event woke the worker, nothing reloaded")
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "1.0")
        XCTAssertNotNil(ExtensionManager.shared.stagedUpdate(for: fixture.id), "left for the idle poll")

        XCTAssertTrue(ExtensionManager.shared.backgroundContextDidStart(extensionID: fixture.id, profileID: profile.id,
                                                                         instance: "reload-2", now: t0.addingTimeInterval(1)),
                      "a start in another incarnation soon after is the reload")
        XCTAssertEqual(ExtensionManager.shared.extension(withID: fixture.id)?.manifest.version, "2.0")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id))
    }

    func testAStagedUpdateInstallsAtTheNextLaunch() async throws {
        let fixture = try await installVersionOne()
        let db = AppDatabase.shared
        db.savePermission(ExtensionPermissionRecord(extensionID: fixture.id, key: "storage", type: .apiPermission, status: .denied))

        // Stage a verified copy by hand, as the updater would have at the last quit.
        let crx = try crx(fixture, version: "2.0", permissions: ["storage", "history"])
        let unpacked = try CRXUnpacker.unpack(data: crx)
        _ = try ExtensionManager.shared.stageUpdate(from: unpacked.directory, publicKey: fixture.pair.publicKeySPKI,
                                                    version: "2.0", for: fixture.id)

        // The launch path: before any record is read or context loaded.
        ExtensionManager.shared.applyStagedUpdatesBeforeLoad()

        let row = try XCTUnwrap(db.loadExtensions().first { $0.id == fixture.id })
        XCTAssertEqual(row.version, "2.0")
        XCTAssertEqual(row.source, "webStore")
        XCTAssertEqual(row.updateURL, fixture.updateURL.absoluteString)
        XCTAssertFalse(row.isEnabled, "it added history: installed disabled pending approval, as a live update would")
        XCTAssertEqual(try JSONDecoder().decode(ExtensionUpdatePolicy.PendingApproval.self,
                                                from: XCTUnwrap(row.pendingPermissionApprovalJSON)).delta.permissions, ["history"])
        XCTAssertEqual(db.permissionStatus(extensionID: fixture.id, key: "storage", type: .apiPermission), .denied)
        XCTAssertEqual(try ExtensionManifest.parse(at: URL(fileURLWithPath: row.basePath).appendingPathComponent("manifest.json")).version, "2.0")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id))

        // A staged copy for an extension that is no longer installed is dropped.
        let orphanDir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-orphan-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try manifestJSON(version: "1.0").write(to: orphanDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let orphan = try StagedExtensionUpdate.stage(unpackedDirectory: orphanDir, publicKey: Data([1]), version: "1.0", for: "gone-extension")
        ExtensionManager.shared.applyStagedUpdatesBeforeLoad()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.directory.path))
    }

    func testAStaleStagedCopyIsDiscardedWhenTheExtensionMovedOn() async throws {
        let (fixture, _, _, _) = try await busyFixture()
        let crx = try crx(fixture, version: "1.0")
        let unpacked = try CRXUnpacker.unpack(data: crx)
        _ = try ExtensionManager.shared.stageUpdate(from: unpacked.directory, publicKey: fixture.pair.publicKeySPKI,
                                                    version: "1.0", for: fixture.id)
        XCTAssertNil(try ExtensionManager.shared.applyStagedUpdate(for: fixture.id), "not newer: rejected, not installed")
        XCTAssertNil(ExtensionManager.shared.stagedUpdate(for: fixture.id), "and gone")
    }

    func testReloadRefusesACRXInstall() async throws {
        let fixture = try await installVersionOne()
        XCTAssertThrowsError(try ExtensionManager.shared.reloadUnpacked(id: fixture.id)) {
            guard case ExtensionManager.UpdateError.notUnpacked? = $0 as? ExtensionManager.UpdateError else {
                return XCTFail("\($0)")
            }
        }
    }
}
