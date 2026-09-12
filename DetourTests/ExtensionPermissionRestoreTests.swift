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

    /// A minimal MV3 extension with no background content. `permissions` /
    /// `host_permissions` and their `optional_` counterparts are *requested*,
    /// never granted: nothing is granted unless a test saves a permission row
    /// for it.
    private func makeTestExtension(
        permissions: [String] = [],
        optionalPermissions: [String] = [],
        hostPermissions: [String] = ["<all_urls>"],
        optionalHostPermissions: [String] = [],
        contentScriptMatches: [String] = []
    ) async throws -> WebExtension {
        let id = "perm-restore-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        func jsonArrayEntry(_ key: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "" }
            let list = values.map { "\"\($0)\"" }.joined(separator: ", ")
            return ",\n            \"\(key)\": [\(list)]"
        }

        /// A one-entry `content_scripts` list, plus the `cs.js` file it names.
        func contentScriptsEntry(_ matches: [String]) throws -> String {
            guard !matches.isEmpty else { return "" }
            try "// content script\n".write(to: dir.appendingPathComponent("cs.js"),
                                           atomically: true, encoding: .utf8)
            let list = matches.map { "\"\($0)\"" }.joined(separator: ", ")
            return ",\n            \"content_scripts\": [{\"matches\": [\(list)], \"js\": [\"cs.js\"]}]"
        }

        let hosts = hostPermissions.map { "\"\($0)\"" }.joined(separator: ", ")
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Permission Restore Test",
            "version": "1.0.0",
            "host_permissions": [\(hosts)]\(jsonArrayEntry("optional_host_permissions", optionalHostPermissions))\(jsonArrayEntry("permissions", permissions))\(jsonArrayEntry("optional_permissions", optionalPermissions))\(try contentScriptsEntry(contentScriptMatches))
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

    // MARK: - TASK-19: how WebKit reports the manifest's permission sets

    /// The restore loop keys saved rows off `pattern.string` and
    /// `permission.rawValue`, so what WebKit puts in the four sets *is* the
    /// contract. Pinned here because `Profile.loadExtensionContext` no longer
    /// special-cases `<all_urls>`: it relies on WebKit reporting it verbatim in
    /// whichever set the manifest lists it in.
    func testWebKitReportsAllURLsVerbatimInBothPatternSets() async throws {
        let allURLs = try XCTUnwrap(try? WKWebExtension.MatchPattern(string: "<all_urls>"))
        XCTAssertEqual(allURLs.string, "<all_urls>",
                       "the literal pattern round-trips as its own string, not as an expansion")

        let required = try await makeTestExtension(
            permissions: ["tabs"],
            optionalPermissions: ["cookies"],
            hostPermissions: ["<all_urls>"])
        let requiredWK = try XCTUnwrap(required.wkExtension)
        XCTAssertEqual(Set(requiredWK.requestedPermissionMatchPatterns.map(\.string)), ["<all_urls>"],
                       "host_permissions: <all_urls> is reported verbatim, not expanded per scheme")
        XCTAssertTrue(requiredWK.requestedPermissionMatchPatterns.contains(allURLs))
        XCTAssertEqual(Set(requiredWK.requestedPermissions.map(\.rawValue)), ["tabs"])
        XCTAssertEqual(Set(requiredWK.optionalPermissions.map(\.rawValue)), ["cookies"])

        let optional = try await makeTestExtension(
            optionalPermissions: ["cookies"],
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        let optionalWK = try XCTUnwrap(optional.wkExtension)
        XCTAssertEqual(Set(optionalWK.optionalPermissionMatchPatterns.map(\.string)), ["<all_urls>"],
                       "optional_host_permissions: <all_urls> lands in the optional set, verbatim")
        XCTAssertTrue(optionalWK.optionalPermissionMatchPatterns.contains(allURLs))
        XCTAssertEqual(Set(optionalWK.requestedPermissionMatchPatterns.map(\.string)), ["https://a.example/*"],
                       "an optional pattern never leaks into the requested set")
    }

    // MARK: - TASK-19 AC #1 / #2: optional API permissions

    func testGrantedOptionalAPIPermissionIsRestored() async throws {
        let ext = try await makeTestExtension(
            permissions: ["tabs"], optionalPermissions: ["cookies"])
        savePermission(ext, key: "cookies", type: .apiPermission, status: .granted)

        let profile = makeProfile("Optional API Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasPermission(.cookies),
                      "an optional permission granted at the prompt must be restored on load")
        XCTAssertEqual(context.permissionStatus(for: .cookies), .grantedExplicitly)
        XCTAssertFalse(context.hasPermission(.tabs),
                       "an undecided required permission stays for WebKit to prompt")
    }

    func testDeniedOptionalAPIPermissionStaysDenied() async throws {
        let ext = try await makeTestExtension(
            permissions: ["tabs"], optionalPermissions: ["cookies"])
        savePermission(ext, key: "cookies", type: .apiPermission, status: .denied)

        let profile = makeProfile("Optional API Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasPermission(.cookies))
        XCTAssertEqual(context.permissionStatus(for: .cookies), .deniedExplicitly,
                       "a denial must be re-applied explicitly, or WebKit prompts again")
        XCTAssertTrue(context.deniedPermissions.keys.contains(.cookies))
    }

    /// A required (non-optional) API permission decision keeps working — the
    /// union must not drop what the pre-TASK-19 loop already restored.
    func testRequiredAPIPermissionDecisionsStillRestore() async throws {
        let ext = try await makeTestExtension(
            permissions: ["tabs", "storage"], optionalPermissions: ["cookies"])
        savePermission(ext, key: "tabs", type: .apiPermission, status: .granted)
        savePermission(ext, key: "storage", type: .apiPermission, status: .denied)

        let profile = makeProfile("Required API Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasPermission(.tabs))
        XCTAssertEqual(context.permissionStatus(for: .storage), .deniedExplicitly)
    }

    // MARK: - TASK-19 AC #3: optional host patterns

    func testGrantedOptionalHostPatternIsRestored() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        savePermission(ext, key: "https://opt.example/*", type: .matchPattern, status: .granted)

        let profile = makeProfile("Optional Pattern Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://opt.example/page")),
                      "a granted optional host pattern must be restored on load")
        XCTAssertFalse(context.hasAccess(to: try url("https://a.example/page")),
                       "the undecided required pattern is not granted as a side effect")
    }

    func testDeniedOptionalHostPatternStaysDenied() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        savePermission(ext, key: "https://opt.example/*", type: .matchPattern, status: .denied)

        let profile = makeProfile("Optional Pattern Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://opt.example/page")))
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "https://opt.example/*" },
                      "the denial must be re-applied explicitly, or WebKit prompts again")
    }

    /// The recovery path for the optional decisions: `unloadExtension` +
    /// `loadExtensionContext`, as `recoverFromBackgroundLoadFailure` does.
    func testOptionalDecisionsSurviveContextReload() async throws {
        let ext = try await makeTestExtension(
            optionalPermissions: ["cookies", "webNavigation"],
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*", "https://no.example/*"])
        savePermission(ext, key: "cookies", type: .apiPermission, status: .granted)
        savePermission(ext, key: "webNavigation", type: .apiPermission, status: .denied)
        savePermission(ext, key: "https://opt.example/*", type: .matchPattern, status: .granted)
        savePermission(ext, key: "https://no.example/*", type: .matchPattern, status: .denied)

        let profile = makeProfile("Optional Reload Profile")
        let first = try loadContext(profile, ext)
        XCTAssertTrue(first.hasPermission(.cookies))

        profile.unloadExtension(id: ext.id)
        XCTAssertNil(profile.extensionContexts[ext.id])

        let second = try loadContext(profile, ext)
        XCTAssertTrue(second.hasPermission(.cookies),
                      "the reloaded context must not re-prompt for a granted optional permission")
        XCTAssertEqual(second.permissionStatus(for: .webNavigation), .deniedExplicitly)
        XCTAssertTrue(second.hasAccess(to: try url("https://opt.example/x")))
        XCTAssertFalse(second.hasAccess(to: try url("https://no.example/x")))
    }

    // MARK: - TASK-19 AC #4: <all_urls>, both statuses

    func testGrantedAllURLsIsRestored() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .granted)

        let profile = makeProfile("AllURLs Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://anything.example/page")))
        XCTAssertTrue(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" },
                      "the grant is applied once, as the <all_urls> pattern itself")
    }

    func testDeniedAllURLsIsRestoredAsDenied() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .denied)

        let profile = makeProfile("AllURLs Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://anything.example/page")))
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" },
                      "a refused all-sites prompt must not be forgotten on the next load")
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty,
                      "nothing is granted as a side effect of applying the denial")
    }

    /// `<all_urls>` listed only under optional_host_permissions: the decision
    /// lives in the optional set, which the restore now walks too.
    func testOptionalAllURLsDecisionsAreRestored() async throws {
        let granted = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"], optionalHostPermissions: ["<all_urls>"])
        savePermission(granted, key: "<all_urls>", type: .matchPattern, status: .granted)
        let grantedContext = try loadContext(makeProfile("Optional AllURLs Grant"), granted)
        XCTAssertTrue(grantedContext.hasAccess(to: try url("https://anything.example/")))

        let denied = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"], optionalHostPermissions: ["<all_urls>"])
        savePermission(denied, key: "<all_urls>", type: .matchPattern, status: .denied)
        let deniedContext = try loadContext(makeProfile("Optional AllURLs Deny"), denied)
        XCTAssertFalse(deniedContext.hasAccess(to: try url("https://anything.example/")))
        XCTAssertTrue(deniedContext.deniedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" })
    }

    // MARK: - TASK-19 AC #5: the stale-row rule still holds

    /// Rows are never purged when an extension updates, so a decision for a key
    /// the current manifest asks for in neither list must stay inert — applying
    /// a stale grant would widen access the manifest no longer justifies.
    func testStaleAPIPermissionRowIsNotApplied() async throws {
        let ext = try await makeTestExtension(
            permissions: ["tabs"], optionalPermissions: ["cookies"])
        // An older manifest asked for webNavigation; this one does not.
        savePermission(ext, key: "webNavigation", type: .apiPermission, status: .granted)
        savePermission(ext, key: "cookies", type: .apiPermission, status: .granted)

        let profile = makeProfile("Stale API Row Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasPermission(.webNavigation),
                       "a grant for a permission outside permissions + optional_permissions is skipped")
        XCTAssertEqual(context.permissionStatus(for: .webNavigation), .unknown)
        XCTAssertTrue(context.hasPermission(.cookies),
                      "the optional permission the manifest does ask for is still restored")
    }

    func testStaleHostPatternRowIsNotApplied() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        savePermission(ext, key: "https://stale.example/*", type: .matchPattern, status: .granted)
        // Verified against WebKit: neither "https://a.example/*" nor
        // "https://opt.example/*" *matches* "<all_urls>" (a narrow pattern never
        // subsumes a broader one), so the match gate rejects the row.
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .granted)

        let profile = makeProfile("Stale Pattern Row Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://stale.example/page")),
                       "a grant for a pattern outside host_permissions + optional_host_permissions is skipped")
        XCTAssertFalse(context.hasAccess(to: try url("https://anything.example/page")),
                       "an <all_urls> grant is not applied to a manifest that never asks for all sites")
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
    }

    // MARK: - Regression: the pre-TASK-11 row shape

    /// Before TASK-11 the site-access prompt stored full URLs under the
    /// match-pattern type. Such a row is deliberately left alone: no migration
    /// reclassifies it, because a `*`-free key is indistinguishable from a
    /// legitimate wildcard-free manifest host permission (e.g.
    /// "https://mail.google.com/"), which must not be widened into an origin
    /// grant. Outside the manifest's host patterns it stays inert, exactly like
    /// any other stale pattern row; the cost is at most one re-prompt.
    func testLegacyRowsAreNotAppliedAsPatterns() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["https://a.example/*"])
        savePermission(ext, key: "https://legacy.example/page", type: .matchPattern, status: .granted)

        let profile = makeProfile("Legacy Row Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://legacy.example/page")),
                       "a full URL stored under the match-pattern type is never restored")
    }

    /// The other half of the legacy shape: when the manifest *does* cover the
    /// key, the match gate accepts it and it is applied as its own (exact-path)
    /// pattern — narrower than the origin-wide grant a `.url` row produces, so
    /// this is no widening beyond what the user was prompted for.
    func testLegacyRowCoveredByTheManifestIsAppliedAsItsOwnPattern() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(ext, key: "https://legacy.example/page", type: .matchPattern, status: .granted)

        let profile = makeProfile("Legacy Row Covered Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://legacy.example/page")))
        XCTAssertFalse(context.hasAccess(to: try url("https://legacy.example/other")),
                       "the row grants only the path it names, not the whole origin")
    }

    // MARK: - TASK-19 review: the activeTab content-script grant vs. the restore

    /// The implicit activeTab content-script grant is applied before the DB
    /// restore, so a saved denial for the same pattern wins.
    func testRestoredDenialWinsOverActiveTabContentScriptGrant() async throws {
        let ext = try await makeTestExtension(
            permissions: ["activeTab"],
            hostPermissions: ["<all_urls>"],
            contentScriptMatches: ["<all_urls>"])
        XCTAssertEqual(ext.manifest.contentScripts?.count, 1,
                       "precondition: the content_scripts entry parsed")
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .denied)

        let profile = makeProfile("ActiveTab Denial Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://anything.example/page")),
                       "a saved <all_urls> denial must survive the implicit activeTab grant")
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" },
                      "the denial is applied explicitly, last, so nothing can erase it")
        // Observed WebKit behaviour: `<all_urls>` is an all-hosts pattern, and
        // writing one only removes an *equal* entry from the opposite dictionary
        // (a narrower overlapping pattern is removed, an all-hosts one is not),
        // so the implicit grant entry lingers in grantedPermissionMatchPatterns.
        // The deny side wins at query time, which is what hasAccess reports —
        // though with both entries present a URL query resolves to
        // .deniedImplicitly rather than .deniedExplicitly.
        XCTAssertTrue(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" },
                      "precondition for the note above: the all-hosts grant is not erased")
    }

    /// The positive companion: with no saved decision the implicit grant stands.
    func testActiveTabContentScriptGrantStillAppliesWithoutASavedDecision() async throws {
        let ext = try await makeTestExtension(
            permissions: ["activeTab"],
            hostPermissions: ["<all_urls>"],
            contentScriptMatches: ["<all_urls>"])

        let profile = makeProfile("ActiveTab Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://anything.example/page")),
                      "content-script hosts are still granted implicitly under activeTab")
    }

    // MARK: - TASK-19 review: permissions.request sub-patterns

    /// `permissions.request({origins: ["https://mail.example/*"]})` prompts with
    /// the caller's pattern verbatim, gated only by whether some optional
    /// manifest pattern matches it — and the answer is saved under that
    /// sub-pattern's own string, which is in neither manifest set. The restore
    /// must therefore gate by match, not by exact membership.
    func testRequestedSubPatternDecisionIsRestoredUnderOptionalAllURLs() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        savePermission(ext, key: "https://mail.example/*", type: .matchPattern, status: .granted)

        let profile = makeProfile("Sub Pattern Grant Profile")
        let context = try loadContext(profile, ext)

        XCTAssertTrue(context.hasAccess(to: try url("https://mail.example/inbox")),
                      "a granted permissions.request sub-pattern must be restored")
        XCTAssertTrue(context.grantedPermissionMatchPatterns.keys.contains { $0.string == "https://mail.example/*" },
                      "the row is applied as its own pattern, verbatim")
    }

    func testRequestedSubPatternDenialIsRestoredUnderOptionalAllURLs() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        savePermission(ext, key: "https://mail.example/*", type: .matchPattern, status: .denied)

        let profile = makeProfile("Sub Pattern Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://mail.example/inbox")))
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "https://mail.example/*" },
                      "a refused permissions.request must not be forgotten on the next load")
    }

    /// The negative: no manifest pattern matches the row, so it stays inert.
    func testSubPatternOutsideEveryManifestPatternIsNotApplied() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["https://a.example/*"])
        savePermission(ext, key: "https://mail.example/*", type: .matchPattern, status: .granted)

        let profile = makeProfile("Sub Pattern Outside Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://mail.example/inbox")),
                       "the extension can never ask for this pattern, so the row is stale")
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
    }

    // MARK: - TASK-19 review: ordering of overlapping decisions

    /// WebKit widens each `.url` row into an origin pattern, so two rows on one
    /// origin overlap: the later write erases the earlier entry from the
    /// opposite dictionary. Denials go last, so the origin ends up denied
    /// regardless of the order the rows were saved in.
    func testOppositeSiteAccessDecisionsOnOneOriginFailClosed() async throws {
        let grantFirst = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(grantFirst, key: "https://a.example/x", type: .url, status: .granted)
        savePermission(grantFirst, key: "https://a.example/y", type: .url, status: .denied)
        let grantFirstContext = try loadContext(makeProfile("URL Order Grant First"), grantFirst)
        XCTAssertFalse(grantFirstContext.hasAccess(to: try url("https://a.example/z")),
                       "grant saved first: the denial must still win")

        let denyFirst = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(denyFirst, key: "https://a.example/y", type: .url, status: .denied)
        savePermission(denyFirst, key: "https://a.example/x", type: .url, status: .granted)
        let denyFirstContext = try loadContext(makeProfile("URL Order Deny First"), denyFirst)
        XCTAssertFalse(denyFirstContext.hasAccess(to: try url("https://a.example/z")),
                       "denial saved first: the grant must not erase it")
    }

    /// Pins the mechanism the ordering defends against: setting a broad pattern
    /// REMOVES a narrower entry from the opposite dictionary, so a grant applied
    /// after a denial would silently drop it.
    func testBroadGrantDoesNotEraseNarrowDenial() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["*://*.example.com/*", "https://sub.example.com/*"])
        savePermission(ext, key: "*://*.example.com/*", type: .matchPattern, status: .granted)
        savePermission(ext, key: "https://sub.example.com/*", type: .matchPattern, status: .denied)

        let profile = makeProfile("Broad Grant Narrow Deny Profile")
        let context = try loadContext(profile, ext)

        XCTAssertFalse(context.hasAccess(to: try url("https://sub.example.com/x")),
                       "the narrow denial must survive the broad grant")
        XCTAssertTrue(context.hasAccess(to: try url("https://www.example.com/x")),
                      "the broad grant still covers the rest of the origin")
    }

    // MARK: - TASK-25: Settings rows for optional host permissions

    private func savedStatus(_ ext: WebExtension, _ key: String,
                             _ type: ExtensionPermissionType) -> ExtensionPermissionStatus? {
        AppDatabase.shared.permissionStatus(extensionID: ext.id, key: key, type: type)
    }

    func testManifestParsesOptionalHostPermissions() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*", "<all_urls>"])
        XCTAssertEqual(ext.manifest.optionalHostPermissions, ["https://opt.example/*", "<all_urls>"])
    }

    /// POSITIVE: turning an optional host pattern on writes the row and grants it
    /// on the already-loaded context — no reload.
    func testGrantingOptionalHostPatternAppliesToLoadedContext() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        let profile = makeProfile("Toggle Optional Grant Profile")
        let context = try loadContext(profile, ext)
        XCTAssertFalse(context.hasAccess(to: try url("https://opt.example/page")))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://opt.example/*", type: .matchPattern, granted: true)

        XCTAssertEqual(savedStatus(ext, "https://opt.example/*", .matchPattern), .granted)
        XCTAssertTrue(context.hasAccess(to: try url("https://opt.example/page")),
                      "the grant must take effect on the loaded context")
        XCTAssertTrue(profile.extensionContexts[ext.id] === context, "no reload happened")
    }

    /// NEGATIVE: turning it off writes a denial and revokes access live.
    func testDenyingOptionalHostPatternAppliesToLoadedContext() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        savePermission(ext, key: "https://opt.example/*", type: .matchPattern, status: .granted)
        let profile = makeProfile("Toggle Optional Deny Profile")
        let context = try loadContext(profile, ext)
        XCTAssertTrue(context.hasAccess(to: try url("https://opt.example/page")))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://opt.example/*", type: .matchPattern, granted: false)

        XCTAssertEqual(savedStatus(ext, "https://opt.example/*", .matchPattern), .denied)
        XCTAssertFalse(context.hasAccess(to: try url("https://opt.example/page")))
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "https://opt.example/*" },
                      "an explicit denial, so WebKit does not prompt again")
    }

    /// The reversal the task exists for: a Deny taken at a prompt is undone from
    /// Settings, and the grant survives a reload (it is the saved row).
    func testReversingDeniedSubPatternFromSettingsSurvivesReload() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        savePermission(ext, key: "https://mail.example/*", type: .matchPattern, status: .denied)
        let profile = makeProfile("Toggle Sub Pattern Profile")
        let context = try loadContext(profile, ext)
        XCTAssertFalse(context.hasAccess(to: try url("https://mail.example/inbox")))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://mail.example/*", type: .matchPattern, granted: true)
        XCTAssertTrue(context.hasAccess(to: try url("https://mail.example/inbox")),
                      "the reversed denial must take effect on the loaded context")
        XCTAssertFalse(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "https://mail.example/*" })

        profile.unloadExtension(id: ext.id)
        let reloaded = try loadContext(profile, ext)
        XCTAssertTrue(reloaded.hasAccess(to: try url("https://mail.example/inbox")))
    }

    /// Pins the WebKit behaviour `setPermissionDecision` works around (probed
    /// 2026-09-12): for the all-hosts pattern neither `.unknown` nor a grant
    /// removes an existing `<all_urls>` denial, and the denial keeps winning;
    /// only replacing the denied dictionary does. If this starts failing, WebKit
    /// changed and the dictionary filtering there may be unnecessary.
    func testWebKitAllHostsGrantDoesNotEraseAllHostsDenial() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .denied)
        let context = try loadContext(makeProfile("All Hosts Pin Profile"), ext)
        let allURLs = try WKWebExtension.MatchPattern(string: "<all_urls>")
        let anySite = try url("https://anything.example/")

        context.setPermissionStatus(.unknown, for: allURLs)
        XCTAssertTrue(context.deniedPermissionMatchPatterns.keys.contains { $0.string == "<all_urls>" },
                      ".unknown does not clear an all-hosts denial")
        context.setPermissionStatus(.grantedExplicitly, for: allURLs)
        XCTAssertFalse(context.hasAccess(to: anySite), "the stale all-hosts denial still wins over the grant")

        context.deniedPermissionMatchPatterns = context.deniedPermissionMatchPatterns
            .filter { $0.key.string != "<all_urls>" }
        XCTAssertTrue(context.hasAccess(to: anySite), "dropping the denial from the dictionary does")
    }

    /// `<all_urls>` is WebKit's all-hosts pattern, which it special-cases; the
    /// toggle must still flip it both ways on a live context.
    func testTogglingOptionalAllURLsBothWaysOnLoadedContext() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        savePermission(ext, key: "<all_urls>", type: .matchPattern, status: .denied)
        let profile = makeProfile("Toggle All URLs Profile")
        let context = try loadContext(profile, ext)
        XCTAssertFalse(context.hasAccess(to: try url("https://anything.example/")))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "<all_urls>", type: .matchPattern, granted: true)
        XCTAssertTrue(context.hasAccess(to: try url("https://anything.example/")),
                      "granting a denied <all_urls> must take effect live")

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "<all_urls>", type: .matchPattern, granted: false)
        XCTAssertFalse(context.hasAccess(to: try url("https://anything.example/")),
                       "denying it again must take effect live")
    }

    /// NEGATIVE: the live state after a toggle is the post-relaunch state. A
    /// broad grant toggled on must not erase a narrower saved denial for the
    /// session (setting the key alone would: WebKit's broad write subsumes it).
    func testBroadGrantToggleKeepsNarrowSavedDenialLive() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["*://*.example.com/*"])
        savePermission(ext, key: "https://sub.example.com/*", type: .matchPattern, status: .denied)
        let profile = makeProfile("Toggle Broad Grant Profile")
        let context = try loadContext(profile, ext)

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "*://*.example.com/*", type: .matchPattern, granted: true)

        XCTAssertTrue(context.hasAccess(to: try url("https://www.example.com/x")))
        XCTAssertFalse(context.hasAccess(to: try url("https://sub.example.com/x")),
                       "the narrow denial must survive the broad grant, as it does on reload")
    }

    /// NEGATIVE: a pattern outside every manifest pattern is saved but stays
    /// inert — the toggle obeys the restore's gate.
    func testTogglingPatternOutsideManifestDoesNotGrant() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["https://a.example/*"])
        let profile = makeProfile("Toggle Stale Pattern Profile")
        let context = try loadContext(profile, ext)

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://mail.example/*", type: .matchPattern, granted: true)

        XCTAssertFalse(context.hasAccess(to: try url("https://mail.example/inbox")))
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
    }

    /// Every profile that has the extension loaded is updated.
    func testToggleAppliesToEveryProfilesContext() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://opt.example/*"])
        let first = try loadContext(makeProfile("Toggle Profile One"), ext)
        let second = try loadContext(makeProfile("Toggle Profile Two"), ext)

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://opt.example/*", type: .matchPattern, granted: true)

        XCTAssertTrue(first.hasAccess(to: try url("https://opt.example/page")))
        XCTAssertTrue(second.hasAccess(to: try url("https://opt.example/page")))
    }

    /// A site-access (`.url`) toggle still applies live through the same path.
    func testSiteAccessURLToggleAppliesToLoadedContext() async throws {
        let ext = try await makeTestExtension(hostPermissions: ["<all_urls>"])
        savePermission(ext, key: "https://site.example/page", type: .url, status: .granted)
        let profile = makeProfile("Toggle URL Profile")
        let context = try loadContext(profile, ext)
        XCTAssertTrue(context.hasAccess(to: try url("https://site.example/page")))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "https://site.example/page", type: .url, granted: false)

        XCTAssertEqual(savedStatus(ext, "https://site.example/page", .url), .denied)
        XCTAssertFalse(context.hasAccess(to: try url("https://site.example/page")))
    }

    /// An API permission toggle is applied to the context directly.
    func testOptionalAPIPermissionToggleAppliesToLoadedContext() async throws {
        let ext = try await makeTestExtension(optionalPermissions: ["cookies"])
        let profile = makeProfile("Toggle API Profile")
        let context = try loadContext(profile, ext)
        XCTAssertFalse(context.hasPermission(.cookies))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "cookies", type: .apiPermission, granted: true)
        XCTAssertTrue(context.hasPermission(.cookies))

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "cookies", type: .apiPermission, granted: false)
        XCTAssertEqual(context.permissionStatus(for: .cookies), .deniedExplicitly)
    }

    /// NEGATIVE: denying nativeMessaging never reaches the context — the context
    /// keeps it so Detour's built-in hosts work, and the denial is enforced at
    /// host dispatch instead (see NativeMessagingEnforcementTests).
    func testNativeMessagingDenialIsNotAppliedToTheContext() async throws {
        let ext = try await makeTestExtension(permissions: ["nativeMessaging"])
        let profile = makeProfile("Toggle Native Messaging Profile")
        let context = try loadContext(profile, ext)

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, granted: false)

        XCTAssertEqual(savedStatus(ext, "nativeMessaging", .apiPermission), .denied, "the row is written")
        XCTAssertTrue(context.hasPermission(.nativeMessaging),
                      "the context must keep nativeMessaging for the polyfill bridge")

        profile.unloadExtension(id: ext.id)
        let reloaded = try loadContext(profile, ext)
        XCTAssertTrue(reloaded.hasPermission(.nativeMessaging), "nor may a reload apply the denial")
    }

    // MARK: TASK-25: which saved sub-pattern rows Settings lists

    func testSavedSubPatternKeysListRestorableRowsNotInTheManifest() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["<all_urls>"])
        let keys = ext.savedSubPatternDecisionKeys(in: [
            "https://mail.example/*": .denied,
            "https://docs.example/*": .granted,
            "https://a.example/*": .granted,     // a manifest host permission: its own row
            "<all_urls>": .granted,              // a manifest optional pattern: its own row
        ])
        XCTAssertEqual(keys, ["https://docs.example/*", "https://mail.example/*"])
    }

    /// NEGATIVE: rows outside every manifest pattern, and keys that do not parse,
    /// are stale — listing one would offer a switch the next launch ignores.
    func testSavedSubPatternKeysOmitStaleAndInvalidRows() async throws {
        let ext = try await makeTestExtension(
            hostPermissions: ["https://a.example/*"],
            optionalHostPermissions: ["https://*.opt.example/*"])
        let keys = ext.savedSubPatternDecisionKeys(in: [
            "https://mail.opt.example/*": .granted,
            "https://mail.example/*": .granted,
            "not a pattern": .denied,
        ])
        XCTAssertEqual(keys, ["https://mail.opt.example/*"])
    }
}
