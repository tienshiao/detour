import XCTest
@testable import Detour

final class ExtensionPermissionCheckerTests: XCTestCase {

    // MARK: - Helpers

    private func makeManifest(permissions: [String]? = nil, hostPermissions: [String]? = nil) -> ExtensionManifest {
        // Build a minimal manifest JSON and decode it
        var dict: [String: Any] = [
            "manifest_version": 3,
            "name": "Test Extension",
            "version": "1.0"
        ]
        if let permissions { dict["permissions"] = permissions }
        if let hostPermissions { dict["host_permissions"] = hostPermissions }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    private func makeExtension(permissions: [String]? = nil, hostPermissions: [String]? = nil) -> WebExtension {
        let manifest = makeManifest(permissions: permissions, hostPermissions: hostPermissions)
        return WebExtension(id: "test-ext", manifest: manifest, basePath: URL(fileURLWithPath: "/tmp"))
    }

    // MARK: - hasPermission

    func testHasPermissionReturnsTrueWhenDeclared() {
        let ext = makeExtension(permissions: ["tabs", "storage"])
        XCTAssertTrue(ExtensionPermissionChecker.hasPermission("tabs", extension: ext))
        XCTAssertTrue(ExtensionPermissionChecker.hasPermission("storage", extension: ext))
    }

    func testHasPermissionReturnsFalseWhenNotDeclared() {
        let ext = makeExtension(permissions: ["storage"])
        XCTAssertFalse(ExtensionPermissionChecker.hasPermission("tabs", extension: ext))
        XCTAssertFalse(ExtensionPermissionChecker.hasPermission("scripting", extension: ext))
    }

    func testHasPermissionReturnsFalseWhenNilPermissions() {
        let ext = makeExtension(permissions: nil)
        XCTAssertFalse(ExtensionPermissionChecker.hasPermission("tabs", extension: ext))
    }

    func testHasPermissionReturnsFalseWhenEmptyPermissions() {
        let ext = makeExtension(permissions: [])
        XCTAssertFalse(ExtensionPermissionChecker.hasPermission("storage", extension: ext))
    }

    // MARK: - hasHostPermission

    func testHostPermissionAllURLsMatchesAnyHTTPS() {
        let ext = makeExtension(hostPermissions: ["<all_urls>"])
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://example.com/page")!, extension: ext))
    }

    func testHostPermissionAllURLsMatchesHTTP() {
        let ext = makeExtension(hostPermissions: ["<all_urls>"])
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "http://example.com/")!, extension: ext))
    }

    func testHostPermissionExactDomainMatches() {
        let ext = makeExtension(hostPermissions: ["https://example.com/*"])
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://example.com/page")!, extension: ext))
    }

    func testHostPermissionExactDomainRejectsOther() {
        let ext = makeExtension(hostPermissions: ["https://example.com/*"])
        XCTAssertFalse(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://other.com/page")!, extension: ext))
    }

    func testHostPermissionWildcardSubdomain() {
        let ext = makeExtension(hostPermissions: ["https://*.example.com/*"])
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://sub.example.com/")!, extension: ext))
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://example.com/")!, extension: ext))
        XCTAssertFalse(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://other.com/")!, extension: ext))
    }

    func testHostPermissionReturnsFalseWhenNilHostPermissions() {
        let ext = makeExtension(hostPermissions: nil)
        XCTAssertFalse(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://example.com/")!, extension: ext))
    }

    func testHostPermissionReturnsFalseWhenEmpty() {
        let ext = makeExtension(hostPermissions: [])
        XCTAssertFalse(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://example.com/")!, extension: ext))
    }

    func testHostPermissionMultiplePatterns() {
        let ext = makeExtension(hostPermissions: ["https://a.com/*", "https://b.com/*"])
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://a.com/")!, extension: ext))
        XCTAssertTrue(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://b.com/")!, extension: ext))
        XCTAssertFalse(ExtensionPermissionChecker.hasHostPermission(
            for: URL(string: "https://c.com/")!, extension: ext))
    }

    // MARK: - requiredPermission

    func testTabsDoesNotRequirePermission() {
        // Chrome does not require the "tabs" permission for tabs APIs.
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.query"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.create"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.update"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.remove"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.get"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "tabs.sendMessage"))
    }

    func testRequiredPermissionForStorage() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "storage.get"), "storage")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "storage.set"), "storage")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "storage.remove"), "storage")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "storage.clear"), "storage")
    }

    func testRequiredPermissionForScripting() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "scripting.executeScript"), "scripting")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "scripting.insertCSS"), "scripting")
    }

    func testRequiredPermissionForWebNavigation() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "webNavigation.onCompleted"), "webNavigation")
    }

    func testRequiredPermissionForWebRequest() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "webRequest.onBeforeRequest"), "webRequest")
    }

    func testRequiredPermissionForRuntimeIsNil() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "runtime.sendMessage"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "runtime.sendResponse"))
    }

    func testRequiredPermissionForUnknownIsNil() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "unknown.something"))
    }

    // MARK: - Error messages

    func testAPIPermissionErrorFormat() {
        let msg = ExtensionPermissionChecker.apiPermissionError(permission: "tabs", api: "tabs.query")
        XCTAssertTrue(msg.contains("tabs.query"))
        XCTAssertTrue(msg.contains("\"tabs\""))
    }

    func testHostPermissionErrorFormat() {
        let url = URL(string: "https://example.com/page")!
        let msg = ExtensionPermissionChecker.hostPermissionError(url: url)
        XCTAssertTrue(msg.contains("https://example.com/page"))
    }

    // MARK: - permissionSummary

    func testPermissionSummaryIncludesKnownPermissions() {
        let manifest = makeManifest(permissions: ["tabs", "storage", "scripting"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 3)
        XCTAssertTrue(summary.contains("Access your tabs"))
        XCTAssertTrue(summary.contains("Store data locally"))
        XCTAssertTrue(summary.contains("Inject scripts into web pages"))
    }

    func testPermissionSummaryIncludesHostPermissions() {
        let manifest = makeManifest(hostPermissions: ["<all_urls>"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Access all websites"))
    }

    func testPermissionSummaryWildcardSubdomain() {
        let manifest = makeManifest(hostPermissions: ["https://*.example.com/*"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 1)
        XCTAssertTrue(summary[0].contains("example.com"))
    }

    func testPermissionSummaryExactHost() {
        let manifest = makeManifest(hostPermissions: ["https://example.com/*"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 1)
        XCTAssertTrue(summary[0].contains("example.com"))
    }

    func testPermissionSummaryWildcardHostShowsAllWebsites() {
        let manifest = makeManifest(hostPermissions: ["https://*/*"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Access all websites"))
    }

    func testPermissionSummaryUnknownPermission() {
        let manifest = makeManifest(permissions: ["customAPI"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 1)
        XCTAssertTrue(summary[0].contains("customAPI"))
    }

    func testPermissionSummaryEmptyManifest() {
        let manifest = makeManifest()
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.isEmpty)
    }

    func testPermissionSummaryCombinesPermissionsAndHosts() {
        let manifest = makeManifest(
            permissions: ["tabs", "storage"],
            hostPermissions: ["https://example.com/*"]
        )
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 3)
        XCTAssertTrue(summary.contains("Access your tabs"))
        XCTAssertTrue(summary.contains("Store data locally"))
        XCTAssertTrue(summary.contains { $0.contains("example.com") })
    }

    func testPermissionSummaryWebNavigationAndWebRequest() {
        let manifest = makeManifest(permissions: ["webNavigation", "webRequest", "bookmarks"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Monitor your browsing navigation"))
        XCTAssertTrue(summary.contains("Monitor your web requests"))
        XCTAssertTrue(summary.contains("Access your bookmarks"))
    }

    // MARK: - New permission types (alarms, fontSettings)

    func testRequiredPermissionForAlarms() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "alarms.create"), "alarms")
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "alarms.clear"), "alarms")
    }

    func testRequiredPermissionForFontSettings() {
        XCTAssertEqual(ExtensionPermissionChecker.requiredPermission(for: "fontSettings.getFontList"), "fontSettings")
    }

    func testActionDoesNotRequirePermission() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "action.setBadgeText"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "action.setIcon"))
    }

    func testCommandsDoesNotRequirePermission() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "commands.getAll"))
    }

    func testWindowsDoesNotRequirePermission() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "windows.getAll"))
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "windows.getCurrent"))
    }

    func testPermissionsDoesNotRequirePermission() {
        XCTAssertNil(ExtensionPermissionChecker.requiredPermission(for: "permissions.contains"))
    }

    func testPermissionSummaryAlarms() {
        let manifest = makeManifest(permissions: ["alarms"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Schedule periodic tasks"))
    }

    func testPermissionSummaryFontSettings() {
        let manifest = makeManifest(permissions: ["fontSettings"])
        let summary = ExtensionPermissionChecker.permissionSummary(for: manifest)
        XCTAssertTrue(summary.contains("Access font settings"))
    }
}
