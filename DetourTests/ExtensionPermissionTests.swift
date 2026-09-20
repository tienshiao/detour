import XCTest
import GRDB
import WebKit
@testable import Detour

final class ExtensionPermissionTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Configuration()) // in-memory
        return try AppDatabase(dbQueue: dbQueue)
    }

    private func sampleExtension(id: String = "ext-1") -> ExtensionRecord {
        ExtensionRecord(
            id: id,
            name: "Test Extension",
            version: "1.0",
            manifestJSON: "{}".data(using: .utf8)!,
            basePath: "/tmp/extensions/\(id)",
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        )
    }

    private func samplePermission(
        extensionID: String = "ext-1",
        key: String = "tabs",
        type: ExtensionPermissionType = .apiPermission,
        status: ExtensionPermissionStatus = .granted
    ) -> ExtensionPermissionRecord {
        ExtensionPermissionRecord(
            extensionID: extensionID,
            permissionKey: key,
            permissionType: type.rawValue,
            status: status.rawValue,
            grantedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - Positive Cases

    func testSaveAndLoadPermission() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission())

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.permissionKey, "tabs")
        XCTAssertEqual(loaded.first?.status, ExtensionPermissionStatus.granted.rawValue)
    }

    func testPermissionStatusQuery() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "storage", status: .granted))

        let status = db.permissionStatus(extensionID: "ext-1", key: "storage", type: .apiPermission)
        XCTAssertEqual(status, .granted)
    }

    func testDeleteExtensionCascadesPermissions() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "tabs"))
        db.savePermission(samplePermission(key: "storage"))
        db.deleteExtension(id: "ext-1")

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertTrue(loaded.isEmpty)
    }

    func testRevokePermission() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "tabs"))
        db.revokePermission(extensionID: "ext-1", key: "tabs", type: .apiPermission)

        let status = db.permissionStatus(extensionID: "ext-1", key: "tabs", type: .apiPermission)
        XCTAssertNil(status)
    }

    func testMultiplePermissionsForExtension() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermissions([
            samplePermission(key: "tabs"),
            samplePermission(key: "storage"),
            samplePermission(key: "<all_urls>", type: .matchPattern),
        ])

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(loaded.count, 3)
    }

    func testSavePermissionsUpserts() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "tabs", status: .granted))
        db.savePermission(samplePermission(key: "tabs", status: .denied))

        let status = db.permissionStatus(extensionID: "ext-1", key: "tabs", type: .apiPermission)
        XCTAssertEqual(status, .denied)

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(loaded.count, 1)
    }

    func testMatchPatternPermission() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "https://*.google.com/*", type: .matchPattern))

        let status = db.permissionStatus(extensionID: "ext-1", key: "https://*.google.com/*", type: .matchPattern)
        XCTAssertEqual(status, .granted)
    }

    // MARK: - Declared permissions vs saved decisions (TASK-63)

    /// Install and update record the manifest's permissions through
    /// `recordDeclaredPermissions`, which must never overwrite a decision the
    /// user already made — a denial turned off in Settings above all.
    func testRecordDeclaredPermissionsKeepsASavedAPIDenial() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "nativeMessaging", status: .denied))

        db.recordDeclaredPermissions([samplePermission(key: "nativeMessaging", status: .granted)])

        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "nativeMessaging", type: .apiPermission),
                       .denied, "a reinstall must not resurrect a denied permission")
        XCTAssertEqual(db.loadPermissions(extensionID: "ext-1").count, 1, "no duplicate row is inserted")
    }

    /// The same for a host pattern: a denied match-pattern row survives the
    /// manifest re-declaring it.
    func testRecordDeclaredPermissionsKeepsASavedMatchPatternDenial() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "https://example.com/*", type: .matchPattern, status: .denied))

        db.recordDeclaredPermissions([
            samplePermission(key: "https://example.com/*", type: .matchPattern, status: .granted),
        ])

        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "https://example.com/*", type: .matchPattern),
                       .denied)
    }

    /// A permission an update newly declares has no saved decision, so it is
    /// still recorded as granted — alongside the keys that keep theirs.
    func testRecordDeclaredPermissionsInsertsKeysWithNoSavedDecision() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "nativeMessaging", status: .denied))

        db.recordDeclaredPermissions([
            samplePermission(key: "nativeMessaging", status: .granted),
            samplePermission(key: "storage", status: .granted),
            samplePermission(key: "alarms", status: .granted),
            samplePermission(key: "https://new.example/*", type: .matchPattern, status: .granted),
        ])

        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "nativeMessaging", type: .apiPermission), .denied)
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "storage", type: .apiPermission), .granted)
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "alarms", type: .apiPermission), .granted)
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "https://new.example/*", type: .matchPattern),
                       .granted)
        XCTAssertEqual(db.loadPermissions(extensionID: "ext-1").count, 4)
    }

    /// An existing grant is left exactly as it was — the row is not rewritten,
    /// so its `grantedAt` still dates the decision rather than the last install.
    func testRecordDeclaredPermissionsLeavesAnExistingGrantUntouched() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        var original = samplePermission(key: "tabs", status: .granted)
        original.grantedAt = 1_000
        db.savePermission(original)

        var redeclared = samplePermission(key: "tabs", status: .granted)
        redeclared.grantedAt = 2_000
        db.recordDeclaredPermissions([redeclared])

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.status, ExtensionPermissionStatus.granted.rawValue)
        XCTAssertEqual(loaded.first?.grantedAt, 1_000, "the stored row is kept, not rewritten")
    }

    /// The prompt and Settings path keeps overwriting: only install/update go
    /// through `recordDeclaredPermissions`.
    func testSavePermissionsStillOverwritesASavedDecision() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "nativeMessaging", status: .denied))

        db.savePermissions([samplePermission(key: "nativeMessaging", status: .granted)])

        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "nativeMessaging", type: .apiPermission),
                       .granted, "a user decision replaces the saved one")
    }

    // MARK: - URL-keyed decisions (TASK-11)

    /// A decision recorded by the site-access prompt for one specific URL is a
    /// third kind of row: it must not be confused with a manifest match pattern,
    /// even when the key strings collide.
    func testURLPermissionTypeIsDistinct() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermissions([
            samplePermission(key: "https://example.com/", type: .url, status: .granted),
            samplePermission(key: "https://*.example.com/*", type: .matchPattern, status: .granted),
            samplePermission(key: "tabs", type: .apiPermission, status: .granted),
        ])

        let saved = db.loadPermissions(extensionID: "ext-1")

        let urlRows = saved.filter { $0.permissionType == ExtensionPermissionType.url.rawValue }
        XCTAssertEqual(urlRows.count, 1)
        XCTAssertEqual(urlRows.first?.permissionKey, "https://example.com/")

        let patternRows = saved.filter { $0.permissionType == ExtensionPermissionType.matchPattern.rawValue }
        XCTAssertEqual(patternRows.count, 1)
        XCTAssertEqual(patternRows.first?.permissionKey, "https://*.example.com/*")

        // Same key string, two types: the primary key keeps them apart.
        db.savePermission(samplePermission(key: "https://example.com/", type: .matchPattern, status: .denied))
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "https://example.com/", type: .url), .granted)
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "https://example.com/", type: .matchPattern), .denied)
    }

    /// A single fetch must be partitioned by type: merging every row into one
    /// dictionary lets a site-access URL row shadow a manifest pattern whose
    /// string happens to be identical.
    func testStatusByKeyDoesNotMergeTypes() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermissions([
            samplePermission(key: "https://example.com/", type: .url, status: .granted),
            samplePermission(key: "https://example.com/", type: .matchPattern, status: .denied),
        ])

        let saved = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(saved.statusByKey(type: .url)["https://example.com/"], .granted)
        XCTAssertEqual(saved.statusByKey(type: .matchPattern)["https://example.com/"], .denied)
        XCTAssertTrue(saved.statusByKey(type: .apiPermission).isEmpty)
    }

    // MARK: - Optional permissions and <all_urls> (TASK-19)

    /// A decision about an `optional_permissions` / `optional_host_permissions`
    /// entry (prompted when the extension calls `permissions.request`) is stored
    /// under exactly the same type and key as a required one — the row carries no
    /// "optional" marker. That is why `Profile.loadExtensionContext` has to look
    /// each key up in *both* manifest sets: the DB cannot tell it which list the
    /// key came from.
    func testOptionalPermissionDecisionsAreStoredLikeRequiredOnes() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermissions([
            // Required in the manifest.
            samplePermission(key: "tabs", type: .apiPermission, status: .granted),
            samplePermission(key: "https://a.example/*", type: .matchPattern, status: .granted),
            // Optional in the manifest, answered at a runtime prompt.
            samplePermission(key: "cookies", type: .apiPermission, status: .granted),
            samplePermission(key: "webNavigation", type: .apiPermission, status: .denied),
            samplePermission(key: "https://opt.example/*", type: .matchPattern, status: .denied),
        ])

        let saved = db.loadPermissions(extensionID: "ext-1")
        let api = saved.statusByKey(type: .apiPermission)
        let patterns = saved.statusByKey(type: .matchPattern)

        XCTAssertEqual(api["tabs"], .granted)
        XCTAssertEqual(api["cookies"], .granted, "an optional grant is an ordinary .apiPermission row")
        XCTAssertEqual(api["webNavigation"], .denied, "a denial is persisted, not just a missing row")
        XCTAssertEqual(patterns["https://a.example/*"], .granted)
        XCTAssertEqual(patterns["https://opt.example/*"], .denied)
        XCTAssertNil(api["https://opt.example/*"], "a host pattern is never an API permission")
    }

    /// The all-sites decision is an ordinary match-pattern row keyed by the
    /// literal string WebKit reports for the pattern, and both statuses are
    /// persisted — the restore applies either one.
    func testAllURLsRowIsAnOrdinaryMatchPatternRow() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "<all_urls>", type: .matchPattern, status: .denied))

        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "<all_urls>", type: .matchPattern),
                       .denied)
        XCTAssertEqual(db.loadPermissions(extensionID: "ext-1").statusByKey(type: .matchPattern)["<all_urls>"],
                       .denied)

        db.savePermission(samplePermission(key: "<all_urls>", type: .matchPattern, status: .granted))
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "<all_urls>", type: .matchPattern),
                       .granted, "answering the prompt again replaces the decision, it does not add one")
    }

    /// The restore turns a status into `.grantedExplicitly` / `.deniedExplicitly`,
    /// so an unrecognised raw value (a downgrade, a hand-edited DB) must read as
    /// denied rather than as a grant.
    func testUnknownStatusRawValueReadsAsDenied() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        var bogus = samplePermission(key: "cookies", type: .apiPermission, status: .granted)
        bogus.status = 99
        db.savePermission(bogus)

        let saved = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(saved.statusByKey(type: .apiPermission)["cookies"], .denied,
                       "an unknown status must fail closed")
        // The single-key lookup the native-host gate uses must agree (TASK-25):
        // a present-but-unreadable nativeMessaging row may not read as "no row".
        XCTAssertEqual(db.permissionStatus(extensionID: "ext-1", key: "cookies", type: .apiPermission), .denied,
                       "permissionStatus must fail closed too")
    }

    // MARK: - Native Messaging Host Gate (positive)

    /// Detour's own polyfill host is the transport for the polyfill bridge and the
    /// service-worker keep-alive, so it is accepted without any manifest permission.
    func testNativeHostAccessAllowsPolyfillHostWithoutPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: ExtensionPolyfillHandler.handlerName, manifestPermissions: [], savedDecision: nil)
        XCTAssertEqual(access, .polyfillHost)
    }

    func testNativeHostAccessAllowsRealHostWithNativeMessagingPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: "com.1password.browser-support", manifestPermissions: ["nativeMessaging"], savedDecision: nil)
        XCTAssertEqual(access, .allowed)
    }

    /// The WebSocket relay host is how a service worker opens a socket at all
    /// (TASK-8), and a worker may open one whether or not its manifest declares
    /// `nativeMessaging` — so, like the polyfill host, it is accepted without the
    /// manifest gate. It spawns no process: the port drives a URLSession socket.
    func testNativeHostAccessAllowsWebSocketRelayHostWithoutPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: [], savedDecision: nil)
        XCTAssertEqual(access, .webSocketRelayHost)
    }

    /// Declaring the permission changes nothing: the relay is still the relay, not
    /// a real host to spawn.
    func testNativeHostAccessKeepsRelayHostDistinctWithNativeMessaging() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: ["nativeMessaging"], savedDecision: nil)
        XCTAssertEqual(access, .webSocketRelayHost)
    }

    // MARK: - Negative Cases

    func testPermissionStatusForUnknownExtension() throws {
        let db = try makeDatabase()
        let status = db.permissionStatus(extensionID: "nonexistent", key: "tabs", type: .apiPermission)
        XCTAssertNil(status)
    }

    func testPermissionStatusForUnknownKey() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "tabs"))

        let status = db.permissionStatus(extensionID: "ext-1", key: "nonexistent", type: .apiPermission)
        XCTAssertNil(status)
    }

    func testDeniedPermissionPersists() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "history", status: .denied))

        let status = db.permissionStatus(extensionID: "ext-1", key: "history", type: .apiPermission)
        XCTAssertEqual(status, .denied)

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertEqual(loaded.first?.status, ExtensionPermissionStatus.denied.rawValue)
    }

    func testRevokedPermissionNotReturned() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        db.savePermission(samplePermission(key: "tabs"))
        db.revokePermission(extensionID: "ext-1", key: "tabs", type: .apiPermission)

        let loaded = db.loadPermissions(extensionID: "ext-1")
        XCTAssertTrue(loaded.isEmpty)

        let status = db.permissionStatus(extensionID: "ext-1", key: "tabs", type: .apiPermission)
        XCTAssertNil(status)
    }

    func testPermissionTypesAreIsolated() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleExtension())
        // Same key, different types
        db.savePermission(samplePermission(key: "tabs", type: .apiPermission, status: .granted))
        db.savePermission(samplePermission(key: "tabs", type: .matchPattern, status: .denied))

        let apiStatus = db.permissionStatus(extensionID: "ext-1", key: "tabs", type: .apiPermission)
        let matchStatus = db.permissionStatus(extensionID: "ext-1", key: "tabs", type: .matchPattern)
        XCTAssertEqual(apiStatus, .granted)
        XCTAssertEqual(matchStatus, .denied)
    }

    // MARK: - Native Messaging Host Gate (negative)

    func testNativeHostAccessDeniesRealHostWithoutPermissions() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: "com.1password.browser-support", manifestPermissions: [], savedDecision: nil)
        XCTAssertEqual(access, .denied)
    }

    func testNativeHostAccessDeniesRealHostWithUnrelatedPermissions() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: "com.1password.browser-support", manifestPermissions: ["storage", "tabs"], savedDecision: nil)
        XCTAssertEqual(access, .denied)
    }

    /// The polyfill exemption is an exact-match on the host name: a host that
    /// merely contains or suffixes it must not inherit the free pass.
    func testNativeHostAccessDeniesHostNameContainingPolyfillHost() {
        let name = "com.example." + ExtensionPolyfillHandler.handlerName
        let access = ExtensionManager.nativeHostAccess(hostName: name, manifestPermissions: [], savedDecision: nil)
        XCTAssertEqual(access, .denied)
    }

    /// Same exact-match rule for the relay host.
    func testNativeHostAccessDeniesHostNameContainingRelayHost() {
        let name = "com.example." + WebSocketRelaySession.hostName
        let access = ExtensionManager.nativeHostAccess(hostName: name, manifestPermissions: [], savedDecision: nil)
        XCTAssertEqual(access, .denied)
    }

    /// NEGATIVE: the relay is a port-only host. A one-shot `sendNativeMessage` to
    /// it must be refused rather than routed anywhere — `.webSocketRelayHost` is
    /// not `.allowed`, so the delegate's gate rejects it with its own error.
    func testNativeHostAccessForRelayHostIsNotAllowedForSendNativeMessage() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: ["nativeMessaging"], savedDecision: nil)
        XCTAssertNotEqual(access, .allowed,
                          "sendNativeMessage only proceeds on .allowed; the relay must never be that")
        XCTAssertNotEqual(access, .polyfillHost,
                          "nor may it be mistaken for the polyfill bridge's envelope host")
    }
}

// MARK: - TASK-25: the user's saved nativeMessaging decision

extension ExtensionPermissionTests {

    private static let realHost = "com.1password.browser-support"

    // MARK: Positive

    /// No saved decision: a declared permission is in force, as in Chrome.
    func testNativeHostAccessAllowsRealHostWithNoSavedDecision() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: Self.realHost, manifestPermissions: ["nativeMessaging"], savedDecision: nil), .allowed)
    }

    func testNativeHostAccessAllowsRealHostWithSavedGrant() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: Self.realHost, manifestPermissions: ["nativeMessaging"], savedDecision: .granted), .allowed)
    }

    /// The built-in hosts are Detour's own bridge, not the user-facing
    /// capability: a denial never reaches them.
    func testNativeHostAccessIgnoresDenialForPolyfillHost() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: ExtensionPolyfillHandler.handlerName,
            manifestPermissions: ["nativeMessaging"], savedDecision: .denied), .polyfillHost)
    }

    func testNativeHostAccessIgnoresDenialForWebSocketRelayHost() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName,
            manifestPermissions: ["nativeMessaging"], savedDecision: .denied), .webSocketRelayHost)
    }

    /// The saved decision is only read for a real host (it is a DB lookup).
    func testNativeHostAccessDoesNotReadSavedDecisionForBuiltInHosts() {
        var reads = 0
        func decision() -> ExtensionPermissionStatus? { reads += 1; return .denied }
        _ = ExtensionManager.nativeHostAccess(
            hostName: ExtensionPolyfillHandler.handlerName, manifestPermissions: ["nativeMessaging"],
            savedDecision: decision())
        _ = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: ["nativeMessaging"],
            savedDecision: decision())
        XCTAssertEqual(reads, 0)
    }

    // MARK: Negative

    func testNativeHostAccessDeniesRealHostWithSavedDenial() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: Self.realHost, manifestPermissions: ["nativeMessaging"], savedDecision: .denied), .deniedByUser)
    }

    /// A saved grant cannot stand in for the manifest declaration: the manifest
    /// gate still comes first.
    func testNativeHostAccessSavedGrantDoesNotBypassManifestGate() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: Self.realHost, manifestPermissions: [], savedDecision: .granted), .denied)
    }

    /// The built-in exemption is still an exact match with a denial saved.
    func testNativeHostAccessDeniesLookalikeOfBuiltInHostWithSavedDenial() {
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: "com.example." + ExtensionPolyfillHandler.handlerName,
            manifestPermissions: ["nativeMessaging"], savedDecision: .denied), .deniedByUser)
    }

    func testNativeHostForbiddenErrorUsesChromeWording() {
        let error = ExtensionManager.nativeHostForbiddenError()
        XCTAssertEqual(error.localizedDescription, "Access to the specified native messaging host is forbidden.")
        XCTAssertEqual(error.domain, "DetourExtension")
    }
}

// MARK: - TASK-75: match patterns with a port, on the storage side

extension ExtensionPermissionTests {

    /// Can a `.matchPattern` row keyed by a pattern *with a port* ever mean
    /// anything? No — and this pins why, so the polyfill's port stripping stays
    /// a JS-side concern and nothing normalises keys on the way into the DB.
    ///
    /// The two ways a `.matchPattern` row is written are the permission prompt
    /// (`ExtensionManager.handlePermissionPrompt` keys it by
    /// `WKWebExtension.MatchPattern.string`, i.e. a pattern WebKit itself
    /// parsed — and after the TASK-75 wrapper the delegate is handed port-less
    /// patterns anyway) and a Settings toggle, which keys it by the raw manifest
    /// string. Only the second can carry a port, and a row that does is inert by
    /// construction: `WKWebExtension.MatchPattern(string:)` throws on it, so
    /// `Profile.applySavedHostAccessDecisions` skips it, and the port-less
    /// pattern it would normalise to is not in the extension's askable set
    /// either, because WebKit drops an unparseable host permission instead of
    /// reporting it. Normalising the write would therefore grant nothing extra
    /// that the gate lets through — while turning a port-scoped declaration into
    /// a whole-host one.
    @MainActor
    func testPortedHostPermissionNeverBecomesAnAskablePattern() async throws {
        XCTAssertNil(try? WKWebExtension.MatchPattern(string: "http://127.0.0.1:8471/*"),
                     "WebKit's match-pattern parser must still reject a port (TASK-75's whole premise)")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-ported-host-perm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {
            "manifest_version": 3,
            "name": "Ported Host Permission",
            "version": "1.0.0",
            "host_permissions": ["http://127.0.0.1:8471/*", "https://example.com/*"]
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: "ported-host-perm", manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt

        let askable = Set(ext.askableMatchPatterns.map(\.string))
        XCTAssertTrue(askable.contains("https://example.com/*"),
                      "the parseable host permission is askable; got \(askable)")
        XCTAssertFalse(askable.contains("http://127.0.0.1:8471/*"),
                       "WebKit must not report a host permission it cannot parse")
        XCTAssertFalse(askable.contains("http://127.0.0.1/*"),
                       "nor a port-stripped repair of it — so a normalised row would still be skipped")

        // The manifest itself keeps the raw string, which is what a Settings row
        // for it would be keyed by: the one path a ported key can reach the DB.
        XCTAssertEqual(ext.manifest.hostPermissions?.contains("http://127.0.0.1:8471/*"), true)
    }
}
