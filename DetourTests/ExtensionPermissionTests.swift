import XCTest
import GRDB
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

    // MARK: - Native Messaging Host Gate (positive)

    /// Detour's own polyfill host is the transport for the polyfill bridge and the
    /// service-worker keep-alive, so it is accepted without any manifest permission.
    func testNativeHostAccessAllowsPolyfillHostWithoutPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: ExtensionPolyfillHandler.handlerName, manifestPermissions: [])
        XCTAssertEqual(access, .polyfillHost)
    }

    func testNativeHostAccessAllowsRealHostWithNativeMessagingPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: "com.1password.browser-support", manifestPermissions: ["nativeMessaging"])
        XCTAssertEqual(access, .allowed)
    }

    /// The WebSocket relay host is how a service worker opens a socket at all
    /// (TASK-8), and a worker may open one whether or not its manifest declares
    /// `nativeMessaging` — so, like the polyfill host, it is accepted without the
    /// manifest gate. It spawns no process: the port drives a URLSession socket.
    func testNativeHostAccessAllowsWebSocketRelayHostWithoutPermission() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: [])
        XCTAssertEqual(access, .webSocketRelayHost)
    }

    /// Declaring the permission changes nothing: the relay is still the relay, not
    /// a real host to spawn.
    func testNativeHostAccessKeepsRelayHostDistinctWithNativeMessaging() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: ["nativeMessaging"])
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
            hostName: "com.1password.browser-support", manifestPermissions: [])
        XCTAssertEqual(access, .denied)
    }

    func testNativeHostAccessDeniesRealHostWithUnrelatedPermissions() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: "com.1password.browser-support", manifestPermissions: ["storage", "tabs"])
        XCTAssertEqual(access, .denied)
    }

    /// The polyfill exemption is an exact-match on the host name: a host that
    /// merely contains or suffixes it must not inherit the free pass.
    func testNativeHostAccessDeniesHostNameContainingPolyfillHost() {
        let name = "com.example." + ExtensionPolyfillHandler.handlerName
        let access = ExtensionManager.nativeHostAccess(hostName: name, manifestPermissions: [])
        XCTAssertEqual(access, .denied)
    }

    /// Same exact-match rule for the relay host.
    func testNativeHostAccessDeniesHostNameContainingRelayHost() {
        let name = "com.example." + WebSocketRelaySession.hostName
        let access = ExtensionManager.nativeHostAccess(hostName: name, manifestPermissions: [])
        XCTAssertEqual(access, .denied)
    }

    /// NEGATIVE: the relay is a port-only host. A one-shot `sendNativeMessage` to
    /// it must be refused rather than routed anywhere — `.webSocketRelayHost` is
    /// not `.allowed`, so the delegate's gate rejects it with its own error.
    func testNativeHostAccessForRelayHostIsNotAllowedForSendNativeMessage() {
        let access = ExtensionManager.nativeHostAccess(
            hostName: WebSocketRelaySession.hostName, manifestPermissions: ["nativeMessaging"])
        XCTAssertNotEqual(access, .allowed,
                          "sendNativeMessage only proceeds on .allowed; the relay must never be that")
        XCTAssertNotEqual(access, .polyfillHost,
                          "nor may it be mistaken for the polyfill bridge's envelope host")
    }
}
