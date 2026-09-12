import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-11: decisions the site-access prompt recorded for a specific URL
/// (`ExtensionPermissionType.url`) must be re-applied whenever a context is
/// (re)loaded — at launch, after a disable/enable, and after the mid-session
/// reload in `Profile.recoverFromBackgroundLoadFailure`.
///
/// These tests use the real shared `AppDatabase` (the test scheme points
/// `DETOUR_DATA_DIR` at an isolated directory) and a real `Profile`, so they
/// exercise exactly what production runs: `Profile.loadExtensionContext`.
@MainActor
final class ExtensionPermissionRestoreTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []

    override func tearDown() {
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            // The shared DB outlives the test; drop every row this extension left.
            try? AppDatabase.shared.dbQueue.write { db in
                _ = try ExtensionPermissionRecord
                    .filter(Column("extensionID") == id)
                    .deleteAll(db)
            }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A minimal MV3 extension with no background content. `host_permissions`
    /// are *requested*, never granted: nothing is granted unless a test saves a
    /// permission row for it.
    private func makeTestExtension(
        hostPermissions: [String] = ["<all_urls>"],
        optionalHostPermissions: [String] = []
    ) async throws -> WebExtension {
        let id = "perm-restore-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let hosts = hostPermissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let optionalHosts = optionalHostPermissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let optionalHostsEntry = optionalHostPermissions.isEmpty
            ? ""
            : ",\n            \"optional_host_permissions\": [\(optionalHosts)]"
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Permission Restore Test",
            "version": "1.0.0",
            "host_permissions": [\(hosts)]\(optionalHostsEntry)
        }
        """
        try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"),
                               atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)

        // The permission rows reference the extension row (FK, cascade delete).
        AppDatabase.shared.saveExtension(ExtensionRecord(
            id: id,
            name: manifest.name,
            version: manifest.version,
            manifestJSON: manifestJSON.data(using: .utf8)!,
            basePath: dir.path,
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        ))
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    private func savePermission(
        _ ext: WebExtension, key: String,
        type: ExtensionPermissionType, status: ExtensionPermissionStatus
    ) {
        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: ext.id, key: key, type: type, status: status))
    }

    /// Exactly what production does on launch and on recovery.
    private func loadContext(_ profile: Profile, _ ext: WebExtension) throws -> WKWebExtensionContext {
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        return try XCTUnwrap(profile.extensionContexts[ext.id],
                             "the context should be loaded in the profile's controller")
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    // MARK: - AC #1 / #3: positive

    func testGrantedURLIsAccessibleAfterLoad() async throws {
        let ext = try await makeTestExtension()
        savePermission(ext, key: "https://granted.example/", type: .url, status: .granted)

        let profile = makeProfile("URL Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://granted.example/some/page")),
                      "a URL granted at prompt time must be accessible after the context loads")
        XCTAssertEqual(context.permissionStatus(for: try url("https://granted.example/")),
                       .grantedExplicitly)
        XCTAssertFalse(context.hasAccess(to: try url("https://other.example/")),
                       "the grant must not spill onto an unrelated origin")
    }

    // MARK: - AC #1 / #3: negative

    func testDeniedURLStaysDeniedAfterLoad() async throws {
        let ext = try await makeTestExtension()
        savePermission(ext, key: "https://denied.example/", type: .url, status: .denied)

        let profile = makeProfile("URL Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://denied.example/")))
        XCTAssertEqual(context.permissionStatus(for: try url("https://denied.example/")),
                       .deniedExplicitly)
    }

    // MARK: - AC #1: the recovery path (unload + reload mid-session)

    /// `recoverFromBackgroundLoadFailure` unloads the context and loads a fresh
    /// one, which WebKit gives a brand new `webkit-extension://<UUID>/` base URL.
    /// The decisions must ride along, so the user is not re-prompted.
    func testURLDecisionsSurviveContextReload() async throws {
        let ext = try await makeTestExtension()
        savePermission(ext, key: "https://granted.example/", type: .url, status: .granted)
        savePermission(ext, key: "https://denied.example/", type: .url, status: .denied)

        let profile = makeProfile("URL Reload Profile")
        let first = try loadContext(profile, ext)
        let firstHost = try XCTUnwrap(first.baseURL.host)
        XCTAssertTrue(first.hasAccess(to: try url("https://granted.example/")))

        profile.unloadExtension(id: ext.id)
        XCTAssertNil(profile.extensionContexts[ext.id])

        let second = try loadContext(profile, ext)
        let secondHost = try XCTUnwrap(second.baseURL.host)
        XCTAssertNotEqual(firstHost, secondHost,
                          "precondition: a reloaded context gets a fresh origin")

        XCTAssertTrue(second.hasAccess(to: try url("https://granted.example/page")),
                      "the reloaded context must not re-prompt for a granted site")
        XCTAssertFalse(second.hasAccess(to: try url("https://denied.example/")),
                       "the reloaded context must keep the denial")
    }

    // MARK: - AC #3: interaction with broader grants

    /// A specific denial must not be washed out by a broad `<all_urls>` grant.
    func testDeniedURLWinsOverGrantedAllURLs() async throws {
        let ext = try await makeTestExtension()
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .granted)
        savePermission(ext, key: "https://denied.example/", type: .url, status: .denied)

        let profile = makeProfile("URL Deny Over AllURLs Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://elsewhere.example/")),
                      "the <all_urls> grant should still cover unrelated sites")
        XCTAssertFalse(context.hasAccess(to: try url("https://denied.example/")),
                       "the explicit per-URL denial must win over the broad grant")
    }

    /// The mirror case: a denied host pattern plus a per-URL grant inside it.
    func testGrantedURLInsideDeniedPattern() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["https://*.example.com/*"])
        savePermission(ext, key: "https://*.example.com/*", type: .matchPattern, status: .denied)
        savePermission(ext, key: "https://app.example.com/", type: .url, status: .granted)

        let profile = makeProfile("URL Grant In Denied Pattern Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://www.example.com/")),
                       "a host covered only by the denied pattern stays denied")

        // Observed WebKit behaviour (macOS 15 SDK): the denied pattern wins.
        // The per-URL grant *is* applied — WebKit widens the URL into the origin
        // pattern "*://*.app.example.com/*" and puts it in
        // grantedPermissionMatchPatterns — but the overlapping
        // "https://*.example.com/*" denial takes precedence, so the URL reports
        // .deniedExplicitly and hasAccess is false. Detour records at most one
        // decision per key, so this only arises when the user denied the broad
        // pattern *and* granted a URL inside it; deny-wins is the safe answer.
        XCTAssertTrue(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "*://*.app.example.com/*" },
                      "the per-URL grant should still be recorded as an origin pattern")
        XCTAssertFalse(context.hasAccess(to: try url("https://app.example.com/")),
                       "observed WebKit behaviour: the denied pattern wins over the per-URL grant")
        XCTAssertEqual(context.permissionStatus(for: try url("https://app.example.com/")),
                       .deniedExplicitly)
    }

    // MARK: - Gating on the manifest's host patterns

    /// `setPermissionStatus(_:for:)` with a URL is not validated against the
    /// manifest, and rows are never purged on extension update, so a grant for
    /// an origin a newer manifest no longer asks about must not be silently
    /// re-applied.
    func testURLGrantOutsideRequestedPatternsIsNotApplied() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["https://a.example/*"])
        savePermission(ext, key: "https://b.other/", type: .url, status: .granted)
        savePermission(ext, key: "https://a.example/", type: .url, status: .granted)

        let profile = makeProfile("URL Outside Patterns Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://b.other/")),
                       "a stale grant outside the manifest's host patterns must be skipped")
        XCTAssertTrue(context.hasAccess(to: try url("https://a.example/page")),
                      "a grant inside a requested host pattern is still restored")
    }

    /// The gate accepts optional host permissions too — the extension may ask
    /// for those at runtime, which is exactly how such a prompt row is created.
    func testURLGrantInsideOptionalHostPatternIsApplied() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        savePermission(ext, key: "https://opt.example/", type: .url, status: .granted)

        let profile = makeProfile("URL Optional Pattern Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(ext.wkExtension?.optionalPermissionMatchPatterns.isEmpty ?? true,
                       "precondition: the manifest's optional_host_permissions parsed")
        XCTAssertTrue(context.hasAccess(to: try url("https://opt.example/page")),
                      "a grant covered by an optional host pattern is restored")
    }

    /// The predicate itself, shared by the restore loop and the Settings
    /// site-access list so the two can never disagree about which stored `.url`
    /// decisions are live.
    func testCanAskForAccessCoversRequestedAndOptionalPatternsOnly() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])

        XCTAssertTrue(ext.canAskForAccess(to: try url("https://a.example/x")),
                      "a requested host pattern is askable")
        XCTAssertTrue(ext.canAskForAccess(to: try url("https://opt.example/")),
                      "an optional host pattern is askable")
        XCTAssertFalse(ext.canAskForAccess(to: try url("https://b.other/")),
                       "an origin no pattern covers is stale, not askable")

        ext.wkExtension = nil
        XCTAssertFalse(ext.canAskForAccess(to: try url("https://a.example/x")),
                       "with no loaded WKWebExtension there are no patterns to consult")
    }

    // MARK: - Regression: the pre-TASK-11 row shape

    /// Before TASK-11 the site-access prompt stored full URLs under the
    /// match-pattern type. The restore loop only consults the manifest's
    /// *requested* patterns, so such a row is inert — and it is deliberately
    /// left alone: no migration reclassifies it, because a `*`-free key is
    /// indistinguishable from a legitimate wildcard-free manifest host
    /// permission (e.g. "https://mail.google.com/"), which must not be widened
    /// into an origin grant. The cost of leaving it is at most one re-prompt.
    func testLegacyRowsAreNotAppliedAsPatterns() async throws {
        let ext = try await makeTestExtension()
        savePermission(ext, key: "https://legacy.example/page", type: .matchPattern, status: .granted)

        let profile = makeProfile("Legacy Row Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://legacy.example/page")),
                       "a full URL stored under the match-pattern type is never restored")
    }
}
