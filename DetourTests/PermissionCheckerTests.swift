import XCTest
@testable import Detour

/// Unit tests for ExtensionPermissionChecker, covering the new permission mappings
/// for contextMenus, offscreen, and activeTab.
final class PermissionCheckerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-permchecker-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    private func makeExtension(permissions: [String], hostPermissions: [String] = []) -> WebExtension {
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "PermTest",
            "version": "1.0",
            "permissions": \(jsonArray(permissions)),
            "host_permissions": \(jsonArray(hostPermissions))
        }
        """
        let url = tempDir.appendingPathComponent("manifest-\(UUID().uuidString).json")
        try! manifestJSON.write(to: url, atomically: true, encoding: .utf8)
        let manifest = try! ExtensionManifest.parse(at: url)
        return WebExtension(id: UUID().uuidString, manifest: manifest, basePath: tempDir)
    }

    private func jsonArray(_ arr: [String]) -> String {
        let items = arr.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[\(items)]"
    }

    // MARK: - requiredPermission mapping

    func testContextMenusRequiresPermission() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "contextMenus.create"), "contextMenus")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "contextMenus.removeAll"), "contextMenus")
    }

    func testOffscreenRequiresPermission() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "offscreen.createDocument"), "offscreen")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "offscreen.hasDocument"), "offscreen")
    }

    func testRuntimeDoesNotRequirePermission() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "runtime.sendMessage"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "runtime.connect"))
    }

    func testExistingMappingsUnchanged() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.query"))
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "storage.get"), "storage")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "scripting.executeScript"), "scripting")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "webNavigation.onCompleted"), "webNavigation")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "webRequest.onBeforeRequest"), "webRequest")
    }

    // MARK: - hasPermission

    func testHasContextMenusPermission() {
        let ext = makeExtension(permissions: ["contextMenus"])
        XCTAssertTrue(ExtensionPermissionChecker.hasPermission("contextMenus", extension: ext))
    }

    func testLacksContextMenusPermission() {
        let ext = makeExtension(permissions: ["storage"])
        XCTAssertFalse(ExtensionPermissionChecker.hasPermission("contextMenus", extension: ext))
    }

    func testHasOffscreenPermission() {
        let ext = makeExtension(permissions: ["offscreen"])
        XCTAssertTrue(ExtensionPermissionChecker.hasPermission("offscreen", extension: ext))
    }

    func testHasActiveTabPermission() {
        let ext = makeExtension(permissions: ["activeTab"])
        XCTAssertTrue(ExtensionPermissionChecker.hasPermission("activeTab", extension: ext))
    }

    // MARK: - permissionSummary

    func testPermissionSummaryContextMenus() {
        let manifest = try! ExtensionManifest.parse(at: writeManifest(permissions: ["contextMenus"]))
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Add items to context menus"))
    }

    func testPermissionSummaryOffscreen() {
        let manifest = try! ExtensionManifest.parse(at: writeManifest(permissions: ["offscreen"]))
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Create offscreen documents"))
    }

    func testPermissionSummaryActiveTab() {
        let manifest = try! ExtensionManifest.parse(at: writeManifest(permissions: ["activeTab"]))
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Access the active tab on click"))
    }

    func testPermissionSummaryMultiple() {
        let manifest = try! ExtensionManifest.parse(at: writeManifest(
            permissions: ["tabs", "storage", "contextMenus", "offscreen", "activeTab"]))
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 5)
        XCTAssertTrue(summary.contains("Access your tabs"))
        XCTAssertTrue(summary.contains("Store data locally"))
        XCTAssertTrue(summary.contains("Add items to context menus"))
        XCTAssertTrue(summary.contains("Create offscreen documents"))
        XCTAssertTrue(summary.contains("Access the active tab on click"))
    }

    // MARK: - apiPermissionError

    func testApiPermissionErrorContextMenus() {
        let error = ExtensionPermissionChecker.apiPermissionError(permission: "contextMenus", api: "contextMenus.create")
        XCTAssertTrue(error.contains("contextMenus"))
    }

    func testApiPermissionErrorOffscreen() {
        let error = ExtensionPermissionChecker.apiPermissionError(permission: "offscreen", api: "offscreen.createDocument")
        XCTAssertTrue(error.contains("offscreen"))
    }

    // MARK: - Helpers

    private func writeManifest(permissions: [String]) -> URL {
        let json = """
        {
            "manifest_version": 3,
            "name": "Test",
            "version": "1.0",
            "permissions": \(jsonArray(permissions))
        }
        """
        let url = tempDir.appendingPathComponent("manifest-\(UUID().uuidString).json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
