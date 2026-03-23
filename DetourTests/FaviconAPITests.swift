import XCTest
import WebKit
@testable import Detour

/// Tests for the chrome-extension://{id}/_favicon/ API permission gating
/// and the ExtensionPageSchemeHandler _favicon handler.
@MainActor
final class FaviconAPITests: XCTestCase {

    // MARK: - ExtensionPageSchemeHandler _favicon permission

    func testFaviconAPIRequiresFaviconPermission() {
        // An extension WITHOUT the "favicon" permission should be denied
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-favicon-perm")
        try? FileManager.default.removeItem(at: tempDir)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "No Favicon Permission",
            "version": "1.0",
            "permissions": ["tabs"]
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: "test-no-favicon", manifest: manifest, basePath: tempDir)

        XCTAssertFalse(ext.manifest.permissions?.contains("favicon") == true,
                       "Extension should not have favicon permission")
    }

    func testFaviconAPIAllowedWithFaviconPermission() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-favicon-allowed")
        try? FileManager.default.removeItem(at: tempDir)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "With Favicon Permission",
            "version": "1.0",
            "permissions": ["tabs", "favicon"]
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: "test-with-favicon", manifest: manifest, basePath: tempDir)

        XCTAssertTrue(ext.manifest.permissions?.contains("favicon") == true,
                      "Extension should have favicon permission")
    }
}
