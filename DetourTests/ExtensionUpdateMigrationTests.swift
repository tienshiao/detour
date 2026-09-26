import XCTest
import GRDB
@testable import Detour

/// TASK-113 AC #1: installs that predate source tracking are classified from
/// their on-disk manifest and id shape.
final class ExtensionUpdateMigrationTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func folder(manifest: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-migration-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        if let manifest {
            try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testV17ClassifiesExistingInstalls() throws {
        let storeID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let selfHostedID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let goneID = "cccccccccccccccccccccccccccccccc"
        let keyedUnpackedID = "dddddddddddddddddddddddddddddddd"
        let uuidID = UUID().uuidString

        let storeDir = try folder(manifest: #"{"manifest_version":3,"name":"s","version":"1","update_url":"https://clients2.google.com/service/update2/crx"}"#)
        let selfHostedDir = try folder(manifest: #"{"manifest_version":3,"name":"h","version":"1","update_url":"https://updates.example.test/manifest.xml"}"#)
        let goneDir = try folder(manifest: nil)
        let keyedDir = try folder(manifest: #"{"manifest_version":3,"name":"k","version":"1","key":"abc"}"#)
        let uuidDir = try folder(manifest: #"{"manifest_version":3,"name":"u","version":"1","update_url":"https://clients2.google.com/service/update2/crx"}"#)

        let dbQueue = try DatabaseQueue(configuration: Configuration())
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v16")
        try dbQueue.write { db in
            for (id, dir) in [(storeID, storeDir), (selfHostedID, selfHostedDir), (goneID, goneDir),
                              (keyedUnpackedID, keyedDir), (uuidID, uuidDir)] {
                try db.execute(sql: """
                    INSERT INTO "extension" (id, name, version, manifestJSON, basePath, isEnabled, installedAt)
                    VALUES (?, 'Ext', '1.0', x'7b7d', ?, 1, 0)
                    """, arguments: [id, dir.path])
            }
        }

        let db = try AppDatabase(dbQueue: dbQueue)
        let rows = Dictionary(uniqueKeysWithValues: db.loadExtensions().map { ($0.id, $0) })
        XCTAssertEqual(rows.count, 5)

        XCTAssertEqual(rows[storeID]?.source, "webStore")
        XCTAssertEqual(rows[storeID]?.updateURL, "https://clients2.google.com/service/update2/crx")

        XCTAssertEqual(rows[selfHostedID]?.source, "crx")
        XCTAssertEqual(rows[selfHostedID]?.updateURL, "https://updates.example.test/manifest.xml")

        XCTAssertEqual(rows[goneID]?.source, "webStore", "a CRX-shaped id with no folder left can only be a store install")
        XCTAssertEqual(rows[goneID]?.updateURL, ExtensionSource.webStoreUpdateURL.absoluteString)

        XCTAssertEqual(rows[keyedUnpackedID]?.source, "unpacked", "a keyed manifest without update_url was loaded unpacked")
        XCTAssertNil(rows[keyedUnpackedID]?.updateURL)

        XCTAssertEqual(rows[uuidID]?.source, "unpacked", "a UUID id is never a CRX, whatever its manifest says")
        XCTAssertNil(rows[uuidID]?.updateURL)

        for row in rows.values {
            XCTAssertNil(row.sourcePath, "no folder is known for a pre-TASK-113 install")
            XCTAssertNil(row.pendingPermissionApprovalJSON)
        }
    }

    func testNewColumnsRoundTripThroughTheRecord() throws {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        let db = try AppDatabase(dbQueue: dbQueue)
        let pending = try JSONEncoder().encode(ExtensionUpdatePolicy.PendingApproval(
            version: "2.0", delta: .init(permissions: ["tabs"], hostPermissions: [])))
        db.saveExtension(ExtensionRecord(
            id: "ext", name: "E", version: "2.0", manifestJSON: Data("{}".utf8), basePath: "/tmp/ext",
            isEnabled: false, installedAt: 1, source: .crx, updateURL: "https://u.test/x",
            sourcePath: nil, pendingPermissionApprovalJSON: pending))
        let row = try XCTUnwrap(db.loadExtensions().first)
        XCTAssertEqual(row.source, "crx")
        XCTAssertEqual(row.updateURL, "https://u.test/x")
        XCTAssertEqual(row.pendingPermissionApprovalJSON, pending)

        db.setExtensionPendingPermissionApproval(id: "ext", json: nil)
        XCTAssertNil(try XCTUnwrap(db.loadExtensions().first).pendingPermissionApprovalJSON)

        XCTAssertNil(db.extensionUpdateLastCheckAt())
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        db.setExtensionUpdateLastCheckAt(when)
        XCTAssertEqual(db.extensionUpdateLastCheckAt()?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testClassifyCRXFromADownload() {
        let store = ExtensionSource.classifyCRX(
            downloadURL: URL(string: "https://clients2.google.com/service/update2/crx?response=redirect")!,
            manifestUpdateURL: nil)
        XCTAssertEqual(store.source, .webStore)
        XCTAssertEqual(store.updateURL, ExtensionSource.webStoreUpdateURL)

        let storeDeclared = ExtensionSource.classifyCRX(
            downloadURL: URL(string: "https://clients2.googleusercontent.com/crx/blobs/x.crx")!,
            manifestUpdateURL: "https://clients2.google.com/service/update2/crx")
        XCTAssertEqual(storeDeclared.source, .webStore)

        let selfHosted = ExtensionSource.classifyCRX(
            downloadURL: URL(string: "https://example.test/ext.crx")!,
            manifestUpdateURL: "https://example.test/updates.xml")
        XCTAssertEqual(selfHosted.source, .crx)
        XCTAssertEqual(selfHosted.updateURL, URL(string: "https://example.test/updates.xml"))

        let noURL = ExtensionSource.classifyCRX(downloadURL: URL(string: "https://example.test/ext.crx")!, manifestUpdateURL: nil)
        XCTAssertEqual(noURL.source, .crx)
        XCTAssertNil(noURL.updateURL, "no update URL means it never updates")

        let insecure = ExtensionSource.classifyCRX(downloadURL: URL(string: "https://example.test/ext.crx")!,
                                                   manifestUpdateURL: "http://example.test/updates.xml")
        XCTAssertNil(insecure.updateURL, "an http update URL is not polled")
    }
}
