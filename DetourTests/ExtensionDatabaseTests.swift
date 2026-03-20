import XCTest
import GRDB
@testable import Detour

final class ExtensionDatabaseTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Configuration()) // in-memory
        return try AppDatabase(dbQueue: dbQueue)
    }

    private func sampleRecord(id: String = "ext-1", name: String = "Test Extension") -> ExtensionRecord {
        ExtensionRecord(
            id: id,
            name: name,
            version: "1.0",
            manifestJSON: "{}".data(using: .utf8)!,
            basePath: "/tmp/extensions/\(id)",
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - Extension CRUD

    func testSaveAndLoadExtension() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())

        let loaded = db.loadExtensions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "ext-1")
        XCTAssertEqual(loaded.first?.name, "Test Extension")
        XCTAssertTrue(loaded.first?.isEnabled ?? false)
    }

    func testDeleteExtension() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.deleteExtension(id: "ext-1")

        let loaded = db.loadExtensions()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDeleteExtensionCascadesStorage() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["key": "value"])
        db.deleteExtension(id: "ext-1")

        // Storage should be cascade-deleted
        let result = db.storageGetAll(extensionID: "ext-1")
        XCTAssertTrue(result.isEmpty)
    }

    func testSetEnabled() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.setEnabled(id: "ext-1", enabled: false)

        let loaded = db.loadExtensions()
        XCTAssertFalse(loaded.first?.isEnabled ?? true)
    }

    func testMultipleExtensions() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord(id: "ext-1", name: "First"))
        db.saveExtension(sampleRecord(id: "ext-2", name: "Second"))

        let loaded = db.loadExtensions()
        XCTAssertEqual(loaded.count, 2)
    }

    // MARK: - chrome.storage.local

    func testStorageSetAndGet() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["count": 42])

        let result = db.storageGet(extensionID: "ext-1", keys: ["count"])
        XCTAssertEqual(result["count"] as? Int, 42)
    }

    func testStorageGetMissingKey() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())

        let result = db.storageGet(extensionID: "ext-1", keys: ["nonexistent"])
        XCTAssertTrue(result.isEmpty)
    }

    func testStorageGetAll() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["a": 1, "b": "hello"])

        let result = db.storageGetAll(extensionID: "ext-1")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["a"] as? Int, 1)
        XCTAssertEqual(result["b"] as? String, "hello")
    }

    func testStorageOverwritesExistingKey() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["key": "old"])
        db.storageSet(extensionID: "ext-1", items: ["key": "new"])

        let result = db.storageGet(extensionID: "ext-1", keys: ["key"])
        XCTAssertEqual(result["key"] as? String, "new")
    }

    func testStorageRemove() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["a": 1, "b": 2])
        db.storageRemove(extensionID: "ext-1", keys: ["a"])

        let result = db.storageGetAll(extensionID: "ext-1")
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result["a"])
        XCTAssertEqual(result["b"] as? Int, 2)
    }

    func testStorageClear() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: ["a": 1, "b": 2, "c": 3])
        db.storageClear(extensionID: "ext-1")

        let result = db.storageGetAll(extensionID: "ext-1")
        XCTAssertTrue(result.isEmpty)
    }

    func testStorageIsolatedBetweenExtensions() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord(id: "ext-1"))
        db.saveExtension(sampleRecord(id: "ext-2"))
        db.storageSet(extensionID: "ext-1", items: ["key": "from-ext-1"])
        db.storageSet(extensionID: "ext-2", items: ["key": "from-ext-2"])

        let result1 = db.storageGet(extensionID: "ext-1", keys: ["key"])
        let result2 = db.storageGet(extensionID: "ext-2", keys: ["key"])
        XCTAssertEqual(result1["key"] as? String, "from-ext-1")
        XCTAssertEqual(result2["key"] as? String, "from-ext-2")
    }

    func testStorageComplexValues() throws {
        let db = try makeDatabase()
        db.saveExtension(sampleRecord())
        db.storageSet(extensionID: "ext-1", items: [
            "array": [1, 2, 3],
            "nested": ["key": "value"]
        ])

        let result = db.storageGetAll(extensionID: "ext-1")
        XCTAssertEqual(result["array"] as? [Int], [1, 2, 3])
        let nested = result["nested"] as? [String: String]
        XCTAssertEqual(nested?["key"], "value")
    }

    // MARK: - Per-Profile Extension State

    func testProfileExtensionEnabledByDefault() throws {
        let db = try makeDatabase()
        db.saveProfile(ProfileRecord(id: "profile-1", name: "Default", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        db.saveExtension(sampleRecord())

        // No per-profile row means enabled
        XCTAssertTrue(db.isExtensionEnabled(extensionID: "ext-1", profileID: "profile-1"))
    }

    func testProfileExtensionDisabled() throws {
        let db = try makeDatabase()
        db.saveProfile(ProfileRecord(id: "profile-1", name: "Default", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        db.saveExtension(sampleRecord())
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: "profile-1", enabled: false)

        XCTAssertFalse(db.isExtensionEnabled(extensionID: "ext-1", profileID: "profile-1"))
    }

    func testGlobalDisableOverridesProfileEnabled() throws {
        let db = try makeDatabase()
        db.saveProfile(ProfileRecord(id: "profile-1", name: "Default", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        db.saveExtension(sampleRecord())
        // Globally disable
        db.setEnabled(id: "ext-1", enabled: false)

        // Even without per-profile row, should be disabled
        XCTAssertFalse(db.isExtensionEnabled(extensionID: "ext-1", profileID: "profile-1"))
    }

    func testEnabledExtensionIDsForProfile() throws {
        let db = try makeDatabase()
        db.saveProfile(ProfileRecord(id: "profile-1", name: "Default", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        db.saveExtension(sampleRecord(id: "ext-1"))
        db.saveExtension(sampleRecord(id: "ext-2"))
        db.setProfileExtensionEnabled(extensionID: "ext-2", profileID: "profile-1", enabled: false)

        let ids = db.enabledExtensionIDs(for: "profile-1")
        XCTAssertTrue(ids.contains("ext-1"))
        XCTAssertFalse(ids.contains("ext-2"))
    }

    func testDeleteExtensionCascadesProfileState() throws {
        let db = try makeDatabase()
        db.saveProfile(ProfileRecord(id: "profile-1", name: "Default", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        db.saveExtension(sampleRecord())
        db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: "profile-1", enabled: false)
        db.deleteExtension(id: "ext-1")

        // Should not crash and should report no enabled extensions
        let ids = db.enabledExtensionIDs(for: "profile-1")
        XCTAssertTrue(ids.isEmpty)
    }
}
