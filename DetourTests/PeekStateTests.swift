import XCTest
import WebKit
@testable import Detour

final class PeekStateTests: XCTestCase {

    private func makeSleepingTab() -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Host",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: UUID()
        )
    }

    // MARK: - clearPeekState

    func testClearPeekStateResetsAllFields() {
        let host = makeSleepingTab()
        host.peekTab = BrowserTab(configuration: WKWebViewConfiguration())
        host.peekURL = URL(string: "https://peek.example.com")
        host.peekInteractionState = Data([1, 2, 3])
        host.peekFaviconURL = URL(string: "https://peek.example.com/favicon.ico")
        host.peekFavicon = NSImage()

        host.clearPeekState()

        XCTAssertNil(host.peekTab)
        XCTAssertNil(host.peekURL)
        XCTAssertNil(host.peekInteractionState)
        XCTAssertNil(host.peekFaviconURL)
        XCTAssertNil(host.peekFavicon)
    }

    // MARK: - savePeekStateForPersistence

    func testSaveKeepsExistingStateWhenPeekTabIsNil() {
        let host = makeSleepingTab()
        let url = URL(string: "https://peek.example.com")
        let state = Data([1, 2, 3])
        host.peekURL = url
        host.peekInteractionState = state
        host.peekFaviconURL = URL(string: "https://peek.example.com/favicon.ico")

        host.savePeekStateForPersistence()

        XCTAssertEqual(host.peekURL, url)
        XCTAssertEqual(host.peekInteractionState, state)
        XCTAssertEqual(host.peekFaviconURL, URL(string: "https://peek.example.com/favicon.ico"))
    }

    func testSaveKeepsExistingURLWhenPeekWebViewHasNoURL() {
        let host = makeSleepingTab()
        let originalURL = URL(string: "https://peek.example.com")
        host.peekURL = originalURL
        // Fresh peek webview that hasn't committed a load: webView.url is nil.
        host.peekTab = BrowserTab(configuration: WKWebViewConfiguration())

        host.savePeekStateForPersistence()

        XCTAssertEqual(host.peekURL, originalURL)
    }

    func testSaveKeepsExistingStateWhenPeekIsSleeping() {
        let host = makeSleepingTab()
        let originalURL = URL(string: "https://peek.example.com")
        let state = Data([9, 9])
        host.peekURL = originalURL
        host.peekInteractionState = state
        // A slept peek has no webView; cached interaction state (nil here)
        // must not clobber the persisted one.
        host.peekTab = makeSleepingTab()

        host.savePeekStateForPersistence()

        XCTAssertEqual(host.peekURL, originalURL)
        XCTAssertEqual(host.peekInteractionState, state)
    }

    // MARK: - displayPeekFavicon

    func testDisplayPeekFaviconPrefersLivePeekTabFavicon() {
        let host = makeSleepingTab()
        let live = NSImage()
        let downloaded = NSImage()
        let peek = BrowserTab(configuration: WKWebViewConfiguration())
        peek.favicon = live
        host.peekTab = peek
        host.peekFavicon = downloaded

        XCTAssertTrue(host.displayPeekFavicon === live)
    }

    func testDisplayPeekFaviconFallsBackToDownloadedFavicon() {
        let host = makeSleepingTab()
        let downloaded = NSImage()
        host.peekFavicon = downloaded

        XCTAssertTrue(host.displayPeekFavicon === downloaded)
    }
}
