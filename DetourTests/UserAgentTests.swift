import XCTest
@testable import Detour

/// The user agents Detour sends (TASK-216): Safari's own string with the
/// macOS version frozen, in every mode but Custom; the Detour token only in
/// the Detour mode.
nonisolated final class UserAgentTests: XCTestCase {
    private let safari27 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"

    @MainActor func testSafarisStringIsExactlyWhatSafariSends() {
        XCTAssertEqual(UserAgentMode.safariUserAgent(safariVersion: "27.0"), safari27)
        XCTAssertEqual(Quarantine.userAgent(safariVersion: "27.0"), safari27, "a quarantine page sends the same")
    }

    @MainActor func testNoUserAgentCarriesTheRealMacOSVersion() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let real = "\(os.majorVersion)_\(os.minorVersion)"
        for ua in [UserAgentMode.safariUserAgent, UserAgentMode.detourUserAgent, UserAgentMode.chromeUserAgent,
                   Quarantine.userAgent] {
            XCTAssertTrue(ua.contains("Intel Mac OS X 10_15_7)"), ua)
            if real != "10_15" { XCTAssertFalse(ua.contains("OS X \(real)"), ua) }
        }
    }

    @MainActor func testTheSafariModeSendsSafarisStringAndTheDetourModeAddsTheToken() {
        let safari = Profile(name: "S", userAgentMode: .safari)
        XCTAssertEqual(safari.resolvedUserAgent(), UserAgentMode.safariUserAgent)
        XCTAssertFalse(safari.resolvedUserAgent()?.contains("Detour") ?? true)

        let detour = Profile(name: "D", userAgentMode: .detour)
        XCTAssertEqual(detour.resolvedUserAgent(), UserAgentMode.safariUserAgent + " " + UserAgentMode.detourAppName)
        XCTAssertTrue(UserAgentMode.detourAppName.hasPrefix("Detour/"))
        XCTAssertNil(UserAgentMode.detourAppName.dropFirst("Detour/".count).firstIndex(of: "."), "the major version only")

        let custom = Profile(name: "C", userAgentMode: .custom, customUserAgent: "Custom/1")
        XCTAssertEqual(custom.resolvedUserAgent(), "Custom/1")
    }

    @MainActor func testDetoursOwnRequestsSendSafarisUserAgent() {
        let request = URLRequest.withSafariUserAgent(URL(string: "https://a.test/favicon.ico")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), UserAgentMode.safariUserAgent,
                       "shared by every profile, so never the Detour token a Safari-mode profile must not send")
    }
}
