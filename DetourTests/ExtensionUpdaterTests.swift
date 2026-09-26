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

    override func tearDown() {
        for id in installedIDs {
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

    func testReloadRefusesACRXInstall() async throws {
        let fixture = try await installVersionOne()
        XCTAssertThrowsError(try ExtensionManager.shared.reloadUnpacked(id: fixture.id)) {
            guard case ExtensionManager.UpdateError.notUnpacked? = $0 as? ExtensionManager.UpdateError else {
                return XCTFail("\($0)")
            }
        }
    }
}
