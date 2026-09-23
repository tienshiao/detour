import XCTest
import WebKit
@testable import Detour

/// A tab no window has claimed shows its document's title once the navigation
/// commits, not only once the load ends (TASK-114). Hidden background web views
/// can stay loading until first shown; the page here holds one image request
/// open forever (`StallingSchemeHandler`), so the load never ends.
@MainActor
final class BackgroundTabTitleTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private let scheme = StallingSchemeHandler()
    private let pageURL = URL(string: "stall://title.test/page")!

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        super.tearDown()
    }

    private func makeTab(serving html: String) -> BrowserTab {
        scheme.pages[pageURL.path] = html
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "stall")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        return tab
    }

    func testAnUnclaimedTabShowsTheDocumentTitleWhileStillLoading() async throws {
        let tab = makeTab(serving: "<html><head><title>Stalled Page</title></head><body><img src=\"/hang.png\"></body></html>")
        tab.load(pageURL)
        XCTAssertEqual(tab.title, "stall://title.test/page", "before the commit the tab shows where it is going")

        try await waitUntil("the document title") { tab.title == "Stalled Page" }
        XCTAssertTrue(tab.isLoading, "the load must still be in progress, or the end-of-load path could be the one that set the title")
    }

    /// A title the page sets later, while still loading, follows too.
    func testATitleChangedByScriptWhileLoadingIsShown() async throws {
        let tab = makeTab(serving: """
            <html><head><title>First</title></head><body>
            <script>setTimeout(() => { document.title = 'Second'; }, 200);</script>
            <img src="/hang.png"></body></html>
            """)
        tab.load(pageURL)

        try await waitUntil("the script's title") { tab.title == "Second" }
        XCTAssertTrue(tab.isLoading)
    }
}
