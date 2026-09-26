import XCTest
@testable import Detour

/// TASK-123: the staged copy on disk.
final class StagedExtensionUpdateTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-staged-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dataDir)
        super.tearDown()
    }

    private func unpacked(version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-unpacked-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"S","version":"\#(version)"}"#
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return dir
    }

    func testStageMovesTheFilesAndLoadsBack() throws {
        let src = try unpacked(version: "2.0")
        let key = Data([1, 2, 3])
        let staged = try StagedExtensionUpdate.stage(unpackedDirectory: src, publicKey: key, version: "2.0",
                                                     for: "abc", in: dataDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "moved, not copied")
        XCTAssertEqual(staged.directory, StagedExtensionUpdate.directory(for: "abc", in: dataDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.directory.appendingPathComponent("manifest.json").path))

        let loaded = try XCTUnwrap(StagedExtensionUpdate.load(for: "abc", in: dataDir))
        XCTAssertEqual(loaded.version, "2.0")
        XCTAssertEqual(loaded.publicKey, key)
        XCTAssertEqual(loaded.extensionID, "abc")
        XCTAssertEqual(StagedExtensionUpdate.all(in: dataDir).map(\.extensionID), ["abc"])

        // A newer stage replaces the old copy.
        let newer = try StagedExtensionUpdate.stage(unpackedDirectory: try unpacked(version: "3.0"), publicKey: key,
                                                    version: "3.0", for: "abc", in: dataDir)
        XCTAssertEqual(StagedExtensionUpdate.load(for: "abc", in: dataDir)?.version, "3.0")
        XCTAssertEqual(newer.directory, staged.directory)

        newer.discard()
        XCTAssertNil(StagedExtensionUpdate.load(for: "abc", in: dataDir))
        XCTAssertTrue(StagedExtensionUpdate.all(in: dataDir).isEmpty)
    }

    func testAnUnreadableStagedCopyIsDroppedNotReturned() throws {
        let dir = StagedExtensionUpdate.directory(for: "bad", in: dataDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(StagedExtensionUpdate.manifestFilename))
        XCTAssertNil(StagedExtensionUpdate.load(for: "bad", in: dataDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "removed so it can never be tried again")
        XCTAssertNil(StagedExtensionUpdate.load(for: "missing", in: dataDir))
        XCTAssertTrue(StagedExtensionUpdate.all(in: dataDir).isEmpty)
    }

    func testAStagedCopyUnderTheWrongNameIsRejected() throws {
        // A manifest that names another extension: never applied to this id.
        let src = try unpacked(version: "2.0")
        _ = try StagedExtensionUpdate.stage(unpackedDirectory: src, publicKey: Data([9]), version: "2.0", for: "one", in: dataDir)
        let wrong = StagedExtensionUpdate.directory(for: "two", in: dataDir)
        try FileManager.default.moveItem(at: StagedExtensionUpdate.directory(for: "one", in: dataDir), to: wrong)
        XCTAssertNil(StagedExtensionUpdate.load(for: "two", in: dataDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrong.path))
    }
}
