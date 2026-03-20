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

    // MARK: - enabledExtensions cache

    private func installTestExtension() -> (WebExtension, Profile) {
        let ext = makeExtension(permissions: ["storage"])
        ExtensionManager.shared.extensions.append(ext)
        let record = ExtensionRecord(
            id: ext.id, name: "CacheTest", version: "1.0",
            manifestJSON: try! ext.manifest.toJSONData(), basePath: tempDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(record)
        let profile = TabStore.shared.addProfile(name: "CacheTestProfile-\(UUID().uuidString)")
        return (ext, profile)
    }

    private func cleanupTestExtension(_ ext: WebExtension, _ profile: Profile) {
        ExtensionManager.shared.extensions.removeAll { $0.id == ext.id }
        AppDatabase.shared.deleteExtension(id: ext.id)
        TabStore.shared.forceRemoveProfile(id: profile.id)
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
    }

    func testEnabledExtensionsCacheReturnsConsistentResults() {
        let (ext, profile) = installTestExtension()
        defer { cleanupTestExtension(ext, profile) }

        let first = ExtensionManager.shared.enabledExtensions(for: profile.id)
        let second = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(first.contains(where: { $0.id == ext.id }))
    }

    func testSetEnabledGlobalInvalidatesCache() {
        let (ext, profile) = installTestExtension()
        defer { cleanupTestExtension(ext, profile) }

        // Populate cache
        let before = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertTrue(before.contains(where: { $0.id == ext.id }))

        // Global disable goes through setEnabled(id:enabled:)
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)

        // Cache should be invalidated; disabled extension excluded from global list
        let after = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertFalse(after.contains(where: { $0.id == ext.id }))

        // Re-enable for cleanup
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
    }

    func testSetEnabledPerProfileInvalidatesCache() {
        let (ext, profile) = installTestExtension()
        defer { cleanupTestExtension(ext, profile) }

        // Populate cache
        let before = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertTrue(before.contains(where: { $0.id == ext.id }))

        // Per-profile disable goes through setEnabled(id:profileID:enabled:)
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)

        // Cache should be invalidated; extension excluded for this profile
        let after = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertFalse(after.contains(where: { $0.id == ext.id }))
    }

    func testUninstallInvalidatesCache() {
        let (ext, profile) = installTestExtension()
        defer {
            // uninstall already removed from extensions array, just clean up profile/db
            AppDatabase.shared.deleteExtension(id: ext.id)
            TabStore.shared.forceRemoveProfile(id: profile.id)
            ExtensionManager.shared.invalidateEnabledExtensionsCache()
        }

        // Populate cache
        let before = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertTrue(before.contains(where: { $0.id == ext.id }))

        // Uninstall goes through uninstall(id:)
        ExtensionManager.shared.uninstall(id: ext.id)

        // Cache should be invalidated; uninstalled extension gone
        let after = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertFalse(after.contains(where: { $0.id == ext.id }))
    }

    func testInstallInvalidatesCache() {
        let profile = TabStore.shared.addProfile(name: "CacheInstallProfile-\(UUID().uuidString)")
        defer { TabStore.shared.forceRemoveProfile(id: profile.id) }

        // Populate cache with no extensions
        let before = ExtensionManager.shared.enabledExtensions(for: profile.id)
        let countBefore = before.count

        // Write a valid extension to a temp directory and install it
        let extDir = tempDir.appendingPathComponent("installable")
        try! FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "InstallCacheTest",
            "version": "1.0",
            "permissions": ["storage"]
        }
        """
        try! manifestJSON.write(to: extDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        let ext = try! ExtensionManager.shared.install(from: extDir)
        defer { ExtensionManager.shared.uninstall(id: ext.id) }

        // Cache should be invalidated; new extension appears
        let after = ExtensionManager.shared.enabledExtensions(for: profile.id)
        XCTAssertEqual(after.count, countBefore + 1)
        XCTAssertTrue(after.contains(where: { $0.id == ext.id }))
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
