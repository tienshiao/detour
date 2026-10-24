import XCTest
import AppKit
@testable import Detour

/// Which URLs put a tab in dev mode automatically, the host label its sidebar
/// row shows, and how rows and favourite tiles carry the marking (TASK-186.1).
final class DevModeTests: XCTestCase {

    private func isLocal(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let url = URL(string: string) else {
            XCTFail("unparseable test URL \(string)", file: file, line: line)
            return false
        }
        return isLocalDevelopmentURL(url)
    }

    private func assertLocal(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        for string in strings {
            XCTAssertTrue(isLocal(string, file: file, line: line), "\(string) should be local development", file: file, line: line)
        }
    }

    private func assertNotLocal(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        for string in strings {
            XCTAssertFalse(isLocal(string, file: file, line: line), "\(string) should not be local development", file: file, line: line)
        }
    }

    private func label(_ string: String) -> String {
        devModeHostLabel(for: URL(string: string))
    }

    // MARK: - isLocalDevelopmentURL: hosts

    func testLocalhost() {
        assertLocal([
            "http://localhost/",
            "http://localhost:3000/",
            "https://localhost:8443/app?x=1#y",
            "http://LOCALHOST:3000/",
            "http://LocalHost/",
            "http://localhost./",
            "http://user:pass@localhost:4000/",
        ])
    }

    func testLocalhostSubdomains() {
        assertLocal([
            "http://app.localhost/",
            "http://app.localhost:5173/",
            "http://a.b.c.localhost/",
            "http://App.LocalHost:3000/",
            "http://app.localhost./",
        ])
    }

    func testIPv4LoopbackDottedQuads() {
        assertLocal([
            "http://127.0.0.1/",
            "http://127.0.0.1:8080/",
            "https://127.0.0.1:8443/",
            "http://127.0.0.0/",
            "http://127.1.2.3/",
            "http://127.255.255.255/",
            "http://127.0.0.1./",
        ])
    }

    /// The shorthand, hex, octal and single-number forms a browser's URL parser
    /// reads as 127.x.x.x (WHATWG IPv4 parsing). WebKit normalises them to a
    /// dotted quad before the tab sees the URL, but the rule must not depend on that.
    func testIPv4LoopbackNonCanonicalForms() {
        assertLocal([
            "http://127.1/",            // 127.0.0.1
            "http://127.0.1/",          // 127.0.0.1
            "http://2130706433/",       // 127.0.0.1 as one number
            "http://0x7f000001/",       // hex
            "http://0X7F000001:3000/",
            "http://0x7f.1/",           // hex first part, shorthand
            "http://0177.0.0.1/",       // octal first part
            "http://0177.1/",
            "http://127.0x0.0.01/",     // mixed
            "http://0000000000000177.0.0.1/",   // any number of leading zeros
            "http://0x00000000000007f000001/",
        ])
    }

    func testIPv4NonLoopback() {
        assertNotLocal([
            "http://126.255.255.255/",
            "http://128.0.0.1/",
            "http://192.168.1.10:3000/",   // LAN: excluded by decision
            "http://10.0.0.5:8080/",
            "http://172.16.0.1/",
            "http://1.2.3.4/",
            "http://255.255.255.255/",
            "http://0x80000001/",          // 128.0.0.1
            "http://0200.0.0.1/",          // octal 128
        ])
    }

    /// Strings that look like IPv4 but are not valid addresses are not loopback.
    func testMalformedIPv4IsNotLocal() {
        assertNotLocal([
            "http://127.0.0.256/",
            "http://127.0.0.1.5/",
            "http://127.0.0.08/",          // 08 is not octal
            "http://127..0.1/",
            "http://4294967296/",          // past 32 bits
        ])
    }

    func testIPv6Loopback() {
        assertLocal([
            "http://[::1]/",
            "http://[::1]:3000/",
            "https://[::1]:8443/",
            "http://[0:0:0:0:0:0:0:1]/",
            "http://[0000::0001]:8080/",
        ])
    }

    func testIPv6NonLoopback() {
        assertNotLocal([
            "http://[::]/",
            "http://[::2]/",
            "http://[fe80::1]/",
            "http://[2001:db8::1]:3000/",
            // IPv4-mapped loopback: only ::1 counts (decision, TASK-186.1).
            "http://[::ffff:127.0.0.1]/",
        ])
    }

    func testUnspecifiedAddress() {
        assertLocal([
            "http://0.0.0.0/",
            "http://0.0.0.0:3000/",
            "https://0.0.0.0:8443/",
            "http://0/",                   // WHATWG: 0.0.0.0
            "http://0x0/",
        ])
    }

    func testDotTestDomains() {
        assertLocal([
            "http://myapp.test/",
            "http://myapp.test:8080/",
            "https://api.myapp.test/",
            "http://MyApp.TEST/",
            "http://myapp.test./",
        ])
    }

    func testLookAlikesAreNotLocal() {
        assertNotLocal([
            "http://localhost.example.com/",
            "http://localhost.com/",
            "http://localhostx/",
            "http://mylocalhost/",
            "http://notlocalhost:3000/",
            "http://127.0.0.1.nip.io/",
            "http://127.0.0.1.example.com:3000/",
            "http://test/",                // the bare TLD is not *.test
            "http://test.com/",
            "http://mytest/",
            "http://mytest:3000/",
            "http://foo.test.com/",
            "http://footest/",
            "http://example.com/",
            "https://www.apple.com/",
        ])
    }

    /// `.local` (mDNS) is excluded by decision; any site can be put in dev
    /// mode by hand instead (TASK-186.5).
    func testDotLocalIsNotLocalDevelopment() {
        assertNotLocal([
            "http://printer.local/",
            "http://my-mac.local:3000/",
        ])
    }

    // MARK: - isLocalDevelopmentURL: schemes

    func testOnlyHTTPAndHTTPSCount() {
        assertNotLocal([
            "ws://localhost:3000/",
            "wss://localhost:3000/",
            "ftp://localhost/",
            "file:///Users/me/index.html",
            "file://localhost/Users/me/index.html",
            "view-source:http://localhost:3000/",
            "blob:http://localhost:3000/1234",
            "about:blank",
            "data:text/html,hi",
            "detour://history",
            "chrome-extension://abc/page.html",
        ])
        XCTAssertTrue(isLocal("HTTP://localhost:3000/"))
        XCTAssertTrue(isLocal("HTTPS://localhost:3000/"))
    }

    func testNilAndHostlessURLs() {
        XCTAssertFalse(isLocalDevelopmentURL(nil))
        XCTAssertFalse(isLocalDevelopmentURL(URL(string: "http:///path")))
        XCTAssertFalse(isLocalDevelopmentURL(URL(string: "localhost:3000")))  // no scheme
    }

    // MARK: - devModeHostLabel

    func testLabelOmitsDefaultPorts() {
        XCTAssertEqual(label("http://localhost/"), "localhost")
        XCTAssertEqual(label("http://localhost:80/"), "localhost")
        XCTAssertEqual(label("https://localhost/"), "localhost")
        XCTAssertEqual(label("https://localhost:443/"), "localhost")
        XCTAssertEqual(label("http://myapp.test/path?q=1"), "myapp.test")
    }

    func testLabelKeepsNonStandardPorts() {
        XCTAssertEqual(label("http://localhost:4000/"), "localhost:4000")
        XCTAssertEqual(label("http://localhost:443/"), "localhost:443")
        XCTAssertEqual(label("https://localhost:80/"), "localhost:80")
        XCTAssertEqual(label("http://127.0.0.1:8080/x"), "127.0.0.1:8080")
        XCTAssertEqual(label("http://app.localhost:5173/"), "app.localhost:5173")
        XCTAssertEqual(label("http://0.0.0.0:3000/"), "0.0.0.0:3000")
    }

    func testLabelBracketsIPv6() {
        XCTAssertEqual(label("http://[::1]/"), "[::1]")
        XCTAssertEqual(label("http://[::1]:3000/"), "[::1]:3000")
        XCTAssertEqual(label("https://[::1]:443/"), "[::1]")
    }

    /// The rule matches a fully-qualified `localhost.`; the label names the
    /// same host without the trailing dot.
    func testLabelDropsTrailingDot() {
        XCTAssertEqual(label("http://localhost.:3000/"), "localhost:3000")
        XCTAssertEqual(label("http://myapp.test./"), "myapp.test")
    }

    func testLabelIsLowercasedAndDropsUserInfo() {
        XCTAssertEqual(label("http://LOCALHOST:3000/"), "localhost:3000")
        XCTAssertEqual(label("http://user:pass@localhost:4000/"), "localhost:4000")
    }

    func testLabelOfHostlessURLIsEmpty() {
        XCTAssertEqual(devModeHostLabel(for: nil), "")
        XCTAssertEqual(label("about:blank"), "")
    }

    // MARK: - Effective state and row marking

    func testRowMarking() {
        XCTAssertEqual(DevMode.rowMarking(for: URL(string: "http://localhost:4000/"), profileID: nil),
                       .tab(hostLabel: "localhost:4000"))
        XCTAssertEqual(DevMode.rowMarking(for: URL(string: "https://example.com/"), profileID: nil), DevModeRowMarking.none)
        XCTAssertEqual(DevMode.rowMarking(for: nil, profileID: nil), DevModeRowMarking.none)
    }

    /// A split row marks the local pane's half only and never shows a host line.
    func testSplitRowMarking() {
        let local = URL(string: "http://localhost:3000/")
        let remote = URL(string: "https://example.com/")
        XCTAssertEqual(DevMode.splitRowMarking(left: local, right: remote, profileID: nil), .split(left: true, right: false))
        XCTAssertEqual(DevMode.splitRowMarking(left: remote, right: local, profileID: nil), .split(left: false, right: true))
        XCTAssertEqual(DevMode.splitRowMarking(left: local, right: local, profileID: nil), .split(left: true, right: true))
        XCTAssertEqual(DevMode.splitRowMarking(left: remote, right: remote, profileID: nil), DevModeRowMarking.none)
        XCTAssertEqual(DevMode.splitRowMarking(left: nil, right: nil, profileID: nil), DevModeRowMarking.none)
    }

    private func makeSleepingTab(url: String) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab", url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: UUID())
    }

    /// A tab follows its URL: leaving the local URL drops dev mode, coming back
    /// restores it. A sleeping tab uses its stored URL.
    func testTabFollowsItsURL() {
        let tab = makeSleepingTab(url: "http://localhost:3000/")
        XCTAssertTrue(DevMode.isActive(for: tab))
        tab.url = URL(string: "https://example.com/")
        XCTAssertFalse(DevMode.isActive(for: tab))
        tab.url = URL(string: "http://localhost:3000/other")
        XCTAssertTrue(DevMode.isActive(for: tab))
    }

    func testPinnedEntryUsesLiveURLElsePinnedURL() {
        let entry = PinnedEntry(pinnedURL: URL(string: "http://localhost:3000/")!, pinnedTitle: "App")
        XCTAssertEqual(entry.devModeURL, URL(string: "http://localhost:3000/"))
        entry.tab = makeSleepingTab(url: "https://example.com/")
        XCTAssertEqual(entry.devModeURL, URL(string: "https://example.com/"))
        XCTAssertFalse(DevMode.isActive(for: entry.devModeURL, profileID: nil))
    }

    func testFavoriteUsesLiveURLElseItsURL() {
        let favorite = Favorite(url: URL(string: "https://example.com/")!, title: "Fav")
        XCTAssertEqual(favorite.devModeURL, URL(string: "https://example.com/"))
        favorite.tab = makeSleepingTab(url: "http://127.0.0.1:8000/")
        XCTAssertEqual(favorite.devModeURL, URL(string: "http://127.0.0.1:8000/"))
        XCTAssertTrue(DevMode.isActive(for: favorite.devModeURL, profileID: nil))
    }

    // MARK: - Tab cell

    private func makeCell() -> TabCellView {
        let cell = TabCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        cell.titleLabel.stringValue = "My App"
        return cell
    }

    func testCellShowsHostLineAndBorderForDevModeTab() {
        let cell = makeCell()
        cell.updateDevMode(.tab(hostLabel: "localhost:4000"))
        cell.layoutSubtreeIfNeeded()

        XCTAssertFalse(cell.hostLineLabel.isHidden)
        XCTAssertEqual(cell.hostLineLabel.stringValue, "localhost:4000")
        XCTAssertEqual(cell.devModeBorderFrames.count, 1)
        // Both lines fit inside the row: the row height is unchanged.
        XCTAssertGreaterThanOrEqual(cell.hostLineLabel.frame.minY, 0)
        XCTAssertLessThanOrEqual(cell.titleLabel.frame.maxY, cell.bounds.maxY)
        XCTAssertGreaterThan(cell.titleLabel.frame.minY, cell.hostLineLabel.frame.minY)
    }

    func testCellClearsDevModeWhenTabLeavesLocalURL() {
        let cell = makeCell()
        cell.updateDevMode(.tab(hostLabel: "localhost:4000"))
        cell.updateDevMode(.none)
        cell.layoutSubtreeIfNeeded()

        XCTAssertTrue(cell.hostLineLabel.isHidden)
        XCTAssertEqual(cell.devModeBorderFrames, [])
    }

    func testReusedCellDropsDevMode() {
        let cell = makeCell()
        cell.updateDevMode(.tab(hostLabel: "localhost:4000"))
        cell.prepareForReuse()
        cell.layoutSubtreeIfNeeded()

        XCTAssertTrue(cell.hostLineLabel.isHidden)
        XCTAssertEqual(cell.devModeBorderFrames, [])
    }

    func testSplitCellBordersOnlyTheLocalHalf() throws {
        let cell = makeCell()
        cell.updateSplitPane(favicon: NSImage(size: NSSize(width: 16, height: 16)), title: "Right")

        cell.updateDevMode(.split(left: true, right: false))
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(cell.hostLineLabel.isHidden)
        XCTAssertEqual(cell.devModeBorderFrames.count, 1)
        XCTAssertLessThan(try XCTUnwrap(cell.devModeBorderFrames.first).maxX, cell.bounds.midX)

        cell.updateDevMode(.split(left: false, right: true))
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.devModeBorderFrames.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(cell.devModeBorderFrames.first).minX, cell.bounds.midX)

        cell.updateDevMode(.split(left: true, right: true))
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.devModeBorderFrames.count, 2)
    }

    // MARK: - Favourite tile

    private func spinRunLoop(_ interval: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    func testDormantFavoriteTileUsesItsURL() {
        let local = FavoriteTileView(favorite: Favorite(url: URL(string: "http://localhost:3000/")!, title: "App"), index: 0)
        XCTAssertTrue(local.showsDevModeBorder)
        let remote = FavoriteTileView(favorite: Favorite(url: URL(string: "https://example.com/")!, title: "Ex"), index: 0)
        XCTAssertFalse(remote.showsDevModeBorder)
    }

    func testLiveFavoriteTileFollowsNavigation() {
        let tab = makeSleepingTab(url: "http://localhost:3000/")
        let favorite = Favorite(url: URL(string: "http://localhost:3000/")!, title: "App", tab: tab)
        let tile = FavoriteTileView(favorite: favorite, index: 0)
        XCTAssertTrue(tile.showsDevModeBorder)

        tab.url = URL(string: "https://example.com/")
        spinRunLoop()
        XCTAssertFalse(tile.showsDevModeBorder)

        tab.url = URL(string: "http://localhost:3000/again")
        spinRunLoop()
        XCTAssertTrue(tile.showsDevModeBorder)
    }
}
