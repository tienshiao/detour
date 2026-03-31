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
}
