import XCTest
import WebKit
@testable import Detour

/// TASK-339: every permission Detour knows reads as words in Settings and
/// the prompts; an unknown one reads as its name made legible, never as the
/// raw manifest string ("privacy", "favicon" did before).
nonisolated final class ExtensionPermissionDescriptionsTests: XCTestCase {

    /// WebKit's own permissions (`WKWebExtension.Permission`: the constants
    /// in the macOS 26 SDK's header, listed by hand, as the SDK has no list),
    /// the ones the polyfill implements or stands in for,
    /// the polyfill-gated ones, and `background`, which has no effect.
    @MainActor private var knownPermissions: Set<String> {
        let webKit: [WKWebExtension.Permission] = [
            .activeTab, .alarms, .clipboardWrite, .contextMenus, .cookies, .declarativeNetRequest,
            .declarativeNetRequestFeedback, .declarativeNetRequestWithHostAccess, .menus, .nativeMessaging,
            .scripting, .storage, .tabs, .unlimitedStorage, .webNavigation, .webRequest,
        ]
        return Set(webKit.map(\.rawValue))
            .union(AutomationCompatReport.polyfillPermissions)
            .union(AutomationCompatReport.stubbedPermissions.keys)
            .union(AutomationCompatReport.ignoredPermissions.keys)
            .union(WebExtension.polyfillGatedPermissions)
    }

    @MainActor func testEveryKnownPermissionHasItsOwnDescription() {
        XCTAssertGreaterThanOrEqual(knownPermissions.count, 27)
        for permission in knownPermissions.sorted() {
            XCTAssertTrue(ExtensionPermissionDescriptions.hasDescription(permission), permission)
            let text = ExtensionPermissionDescriptions.describe(permission)
            XCTAssertNotEqual(text, permission, permission)
            XCTAssertEqual(text.first?.isUppercase, true, "\(permission): \(text)")
        }
    }

    @MainActor func testPrivacyAndFaviconReadAsWords() {
        XCTAssertEqual(ExtensionPermissionDescriptions.describe("privacy"), "Read and change privacy settings")
        XCTAssertEqual(ExtensionPermissionDescriptions.describe("favicon"), "Read the icons of websites")
    }

    /// An unknown permission is its name in words, not the raw string.
    @MainActor func testAnUnknownPermissionReadsAsItsNameInWords() {
        let cases = [
            ("tabGroups", "Tab groups"), ("madeUp", "Made up"), ("system.display", "System display"),
            ("webRequestBlocking", "Web request blocking"), ("tts", "Tts"), ("enterprise.deviceAttributes",
            "Enterprise device attributes"), ("x_y", "X y"), ("", ""), ("readURLs", "Read URLs"),
            ("URLPattern", "URL pattern"), ("ttsEngine", "Tts engine"),
        ]
        for (permission, text) in cases {
            XCTAssertFalse(ExtensionPermissionDescriptions.hasDescription(permission), permission)
            XCTAssertEqual(ExtensionPermissionDescriptions.describe(permission), text, permission)
        }
        XCTAssertTrue(ExtensionPermissionDescriptions.formatForAlert(permissions: ["tabGroups"], hostPermissions: [])
            .contains("Tab groups"))
    }

    /// `management.getPermissionWarningsByManifest` keeps an unknown
    /// permission's manifest name, as it always returned it.
    @MainActor func testTheAPIsWarningsKeepAnUnknownNameAsItWas() {
        XCTAssertEqual(ExtensionPermissionDescriptions.warnings(permissions: ["cookies", "madeUp", "privacy"],
                                                                hostPermissions: ["<all_urls>"]),
                       ["Read and modify cookies", "madeUp", "Read and change privacy settings", "All websites"])
    }
}
