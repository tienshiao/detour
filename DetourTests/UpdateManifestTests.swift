import XCTest
@testable import Detour

/// TASK-113: the update2 request and response as the Chrome Web Store speaks them.
final class UpdateManifestTests: XCTestCase {

    private let storeResponse = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">
      <daystart elapsed_days="6300" elapsed_seconds="51000"/>
      <app appid="aeblfdkhhhdcdjpifhhbdiojplfjncoa" cohort="1::" cohortname="" status="ok">
        <updatecheck _esbAllowlist="false" codebase="https://clients2.googleusercontent.com/crx/blobs/AcXo/aeblfdkhhhdcdjpifhhbdiojplfjncoa_8_10_50_28_0.crx" fp="1.abcdef" hash_sha256="0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0" protected="0" size="1024" status="ok" version="8.10.50.28"/>
      </app>
      <app appid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" status="ok">
        <updatecheck status="noupdate"/>
      </app>
      <app appid="cccccccccccccccccccccccccccccccc" status="error-invalidAppId"/>
    </gupdate>
    """

    func testParsesAStoreResponse() throws {
        let entries = try UpdateManifest.parse(Data(storeResponse.utf8))
        XCTAssertEqual(entries.count, 3)

        let update = entries[0]
        XCTAssertEqual(update.appID, "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        XCTAssertEqual(update.appStatus, "ok")
        XCTAssertEqual(update.updateStatus, "ok")
        XCTAssertEqual(update.version, "8.10.50.28")
        XCTAssertEqual(update.codebase?.host, "clients2.googleusercontent.com")
        XCTAssertEqual(update.sha256?.count, 32)
        XCTAssertEqual(update.sha256?.first, 0x0F)
        XCTAssertEqual(update.sha256?.last, 0xF0)

        let current = entries[1]
        XCTAssertEqual(current.updateStatus, "noupdate")
        XCTAssertNil(current.version)
        XCTAssertNil(current.codebase)

        let unknown = entries[2]
        XCTAssertEqual(unknown.appStatus, "error-invalidAppId")
        XCTAssertNil(unknown.updateStatus)
    }

    /// A self-hosted update manifest (the Chromium autoupdate doc's shape): no
    /// namespace prefix games, no hash, single quotes.
    func testParsesASelfHostedManifest() throws {
        let xml = """
        <?xml version='1.0' encoding='UTF-8'?>
        <gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
          <app appid='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'>
            <updatecheck codebase='https://example.test/ext.crx' version='2.0' />
          </app>
        </gupdate>
        """
        let entries = try UpdateManifest.parse(Data(xml.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].appStatus)
        XCTAssertEqual(entries[0].version, "2.0")
        XCTAssertEqual(entries[0].codebase, URL(string: "https://example.test/ext.crx"))
        XCTAssertNil(entries[0].sha256)
    }

    func testNamespacePrefixedElementsStillParse() throws {
        let xml = """
        <g:gupdate xmlns:g="http://www.google.com/update2/response" protocol="2.0">
          <g:app appid="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" status="ok">
            <g:updatecheck status="ok" codebase="https://example.test/e.crx" version="3.1"/>
          </g:app>
        </g:gupdate>
        """
        let entries = try UpdateManifest.parse(Data(xml.utf8))
        XCTAssertEqual(entries.map(\.version), ["3.1"])
    }

    func testNotXMLThrows() {
        XCTAssertThrowsError(try UpdateManifest.parse(Data("<html><body>nope".utf8)))
    }

    func testAnOddLengthHashIsDropped() throws {
        let xml = """
        <gupdate><app appid="a"><updatecheck status="ok" version="1" hash_sha256="abc"/></app></gupdate>
        """
        XCTAssertNil(try UpdateManifest.parse(Data(xml.utf8))[0].sha256)
    }

    // MARK: - Request URL

    func testRequestURLEncodesTheXParameterTheWayTheStoreExpects() throws {
        let url = try XCTUnwrap(UpdateManifest.requestURL(
            updateURL: ExtensionSource.webStoreUpdateURL, extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
            version: "8.10.40.0", prodVersion: "131.0.0.0"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "clients2.google.com")
        XCTAssertEqual(url.path, "/service/update2/crx")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("response=updatecheck"), query)
        XCTAssertTrue(query.contains("acceptformat=crx3"), query)
        XCTAssertTrue(query.contains("prodversion=131.0.0.0"), query)
        XCTAssertTrue(query.contains("x=id%3Daeblfdkhhhdcdjpifhhbdiojplfjncoa%26v%3D8.10.40.0%26uc"), query)
        XCTAssertFalse(query.contains("x=id="), "the inner '=' and '&' must be percent-encoded")
    }

    func testRequestURLKeepsExistingQueryItems() throws {
        let base = try XCTUnwrap(URL(string: "https://updates.example.test/manifest.xml?channel=beta"))
        let url = try XCTUnwrap(UpdateManifest.requestURL(updateURL: base, extensionID: "abc", version: "1", prodVersion: "131.0.0.0"))
        XCTAssertTrue(url.query?.hasPrefix("channel=beta&response=updatecheck") == true, url.absoluteString)
    }

    func testChromeProductVersionComesFromTheUserAgent() {
        XCTAssertEqual(ExtensionUpdater.chromeProductVersion(fromUserAgent: UserAgentMode.chromeUserAgent), "131.0.0.0")
        XCTAssertEqual(ExtensionUpdater.chromeProductVersion(fromUserAgent: "Mozilla/5.0 Chrome/140.0.7339.80 Safari/537.36"), "140.0.7339.80")
        XCTAssertEqual(ExtensionUpdater.chromeProductVersion(fromUserAgent: "Detour/1"), "131.0.0.0", "fallback")
    }
}
