import XCTest
@testable import Detour

/// The user agents Detour sends (TASK-216): Safari's own string with the
/// macOS version frozen, in every mode but Custom; the Detour token only in
/// the Detour mode.
nonisolated final class UserAgentTests: XCTestCase {
    private let safari27 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"

    @MainActor func testSafarisStringIsExactlyWhatSafariSends() {
        XCTAssertEqual(UserAgentMode.safariUserAgent(safariVersion: "27.0"), safari27)
        XCTAssertEqual(Quarantine.userAgent, UserAgentMode.safariUserAgent, "a quarantine page sends the same")
    }

    @MainActor func testNoUserAgentCarriesTheRealMacOSVersion() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let real = "\(os.majorVersion)_\(os.minorVersion)"   // never 10_15: Detour needs macOS 15.4+
        for ua in [UserAgentMode.safariUserAgent, UserAgentMode.detourUserAgent, UserAgentMode.chromeUserAgent,
                   Quarantine.userAgent] {
            XCTAssertTrue(ua.contains("Intel Mac OS X 10_15_7)"), ua)
            XCTAssertFalse(ua.contains("OS X \(real)"), ua)
        }
    }

    @MainActor func testTheSafariModeSendsSafarisStringAndTheDetourModeAddsTheToken() {
        let safari = Profile(name: "S", userAgentMode: .safari)
        XCTAssertEqual(safari.resolvedUserAgent(), UserAgentMode.safariUserAgent)
        XCTAssertFalse(safari.resolvedUserAgent().contains("Detour"))

        let detour = Profile(name: "D", userAgentMode: .detour)
        XCTAssertEqual(detour.resolvedUserAgent(), UserAgentMode.safariUserAgent + " " + UserAgentMode.detourAppName)
        XCTAssertTrue(UserAgentMode.detourAppName.hasPrefix("Detour/"))
        XCTAssertNil(UserAgentMode.detourAppName.dropFirst("Detour/".count).firstIndex(of: "."), "the major version only")

        let custom = Profile(name: "C", userAgentMode: .custom, customUserAgent: "Custom/1")
        XCTAssertEqual(custom.resolvedUserAgent(), "Custom/1")
    }

    @MainActor func testABlankCustomUserAgentIsRefusedAndAStoredOneSendsTheDefault() {
        XCTAssertNil(UserAgentMode.validatedCustomUserAgent(""))
        XCTAssertNil(UserAgentMode.validatedCustomUserAgent("   \t "))
        XCTAssertNil(UserAgentMode.validatedCustomUserAgent("Custom/1\r\nX-Injected: 1"), "one header line only")
        XCTAssertEqual(UserAgentMode.validatedCustomUserAgent("  Custom/1 "), "Custom/1")
        // Saved before Settings refused blanks, or Custom with no string yet:
        // the default mode's user agent, not WebKit's bare default.
        for stored: String? in [nil, "", "  "] {
            let profile = Profile(name: "C", userAgentMode: .custom, customUserAgent: stored)
            XCTAssertEqual(profile.resolvedUserAgent(), UserAgentMode.detourUserAgent, String(describing: stored))
        }
    }

    @MainActor func testAControlCharacterInACustomUserAgentIsRefused() {
        XCTAssertNil(UserAgentMode.validatedCustomUserAgent("Custom/1\u{0}X"))
        XCTAssertNil(UserAgentMode.validatedCustomUserAgent("Custom/1\u{2028}X"), "a Unicode line separator")
        XCTAssertEqual(UserAgentMode.validatedCustomUserAgent("Custom/1\tX"), "Custom/1\tX", "a tab is a valid header character")
    }

    @MainActor func testSwitchingToCustomWithNoValidStringStartsFromThePreviousUserAgent() {
        let safari = Profile(name: "S", userAgentMode: .safari, customUserAgent: "  ")
        safari.selectUserAgentMode(.custom)
        XCTAssertEqual(safari.customUserAgent, UserAgentMode.safariUserAgent)
        XCTAssertEqual(safari.resolvedUserAgent(), UserAgentMode.safariUserAgent)

        let kept = Profile(name: "K", userAgentMode: .detour, customUserAgent: "Custom/1")
        kept.selectUserAgentMode(.custom)
        XCTAssertEqual(kept.customUserAgent, "Custom/1", "a valid saved string is kept")

        let back = Profile(name: "B", userAgentMode: .custom, customUserAgent: "Custom/1")
        back.selectUserAgentMode(.detour)
        XCTAssertEqual(back.customUserAgent, "Custom/1")
        XCTAssertEqual(back.resolvedUserAgent(), UserAgentMode.detourUserAgent)
    }

    @MainActor func testExtensionWebViewsAreNamedSoWebKitBuildsSafarisUserAgent() {
        let webKitBase = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
        XCTAssertEqual(webKitBase + " " + UserAgentMode.safariApplicationName, UserAgentMode.safariUserAgent)
        let profile = Profile(name: "E", userAgentMode: .detour)
        XCTAssertEqual(profile.extensionController.configuration.webViewConfiguration.applicationNameForUserAgent,
                       UserAgentMode.safariApplicationName)
    }

    @MainActor func testDetoursOwnRequestsSendSafarisUserAgent() {
        let request = URLRequest.withSafariUserAgent(URL(string: "https://a.test/favicon.ico")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), UserAgentMode.safariUserAgent,
                       "shared by every profile, so never the Detour token a Safari-mode profile must not send")
    }
}
