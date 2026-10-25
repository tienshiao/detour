import XCTest
import AppKit
import WebKit
@testable import Detour

/// TASK-192: the tab side of the now-playing bar — the Media Session bridge in
/// a real web view (handlers and metadata reported, a stored handler run from
/// native, the handler out of the page's reach), page mute, the playback run
/// and the picture in picture bookkeeping.
@MainActor
final class NowPlayingTabTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private let scheme = StallingSchemeHandler()
    private let pageURL = URL(string: "stall://media.test/page")!
    private let otherURL = URL(string: "stall://media.test/other")!

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        super.tearDown()
    }

    private func makeTab() -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "stall")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        return tab
    }

    private static let sessionPage = """
        <html><head><title>Session page</title></head><body><script>
        window.__log = [];
        navigator.mediaSession.metadata = new MediaMetadata({ title: 'Song', artist: 'Band', album: 'Record',
          artwork: [{ src: 'https://cdn.test/a.png', sizes: '96x96' }] });
        navigator.mediaSession.setActionHandler('nexttrack', (details) => __log.push('next:' + details.action));
        navigator.mediaSession.setActionHandler('seekto', () => {});
        </script></body></html>
        """

    private func loadSessionPage(in tab: BrowserTab) async throws {
        scheme.pages[pageURL.path] = Self.sessionPage
        tab.load(pageURL)
        try await waitUntil("the page's Media Session to reach the tab") { tab.mediaSession?.title == "Song" }
    }

    private func pageLog(_ tab: BrowserTab) async throws -> String {
        try await tab.webView?.evaluateJavaScript("__log.join(',')") as? String ?? ""
    }

    // MARK: - Media Session bridge

    func testThePageSessionReachesTheTab() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        XCTAssertEqual(tab.mediaSession, MediaSessionReport(actions: [.nexttrack], title: "Song", artist: "Band",
                                                            album: "Record",
                                                            artworkURL: URL(string: "https://cdn.test/a.png")),
                       "seekto is not a bar action")
        XCTAssertTrue(tab.canPerformMediaSessionAction(.nexttrack))
        XCTAssertFalse(tab.canPerformMediaSessionAction(.previoustrack), "no handler, no button")
    }

    func testNextRunsThePagesOwnHandler() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        tab.performMediaSessionAction(.nexttrack)
        try await waitUntil("the page's nexttrack handler to run") { try await self.pageLog(tab) == "next:nexttrack" }
    }

    func testMetadataChangesAndRemovedHandlersAreReported() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        _ = try await tab.webView?.evaluateJavaScript("navigator.mediaSession.metadata.title = 'Other'; 1")
        try await waitUntil("the new title") { tab.mediaSession?.title == "Other" }
        _ = try await tab.webView?.evaluateJavaScript("navigator.mediaSession.setActionHandler('nexttrack', null); 1")
        try await waitUntil("the removed handler") { tab.mediaSession?.actions.isEmpty == true }
        XCTAssertFalse(tab.canPerformMediaSessionAction(.nexttrack))
    }

    func testANewDocumentForgetsTheOldSession() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        scheme.pages[otherURL.path] = "<html><body>plain</body></html>"
        tab.load(otherURL)
        try await waitUntil("the session to clear") { tab.mediaSession == nil }
    }

    /// A document no user script runs in (a PDF, a plugin document) never
    /// posts 'document': the native commit has to forget the old session.
    func testACommittedNavigationForgetsTheOldSessionAtOnce() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        tab.isPlayingAudio = true
        let run = try XCTUnwrap(tab.playbackSession)
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "a", active: true))
        let webView = try XCTUnwrap(tab.webView)

        tab.webView(webView, didCommit: nil)

        XCTAssertNil(tab.mediaSession, "no stale title or enabled Next")
        XCTAssertFalse(tab.isInPictureInPicture, "the old document's videos are gone")
        XCTAssertEqual(tab.playbackSession, run, "the run follows _isPlayingAudio, not the commit")
    }

    /// The new page's reports arrive after the commit, so clearing on commit
    /// never wipes them.
    func testTheNextPagesSessionSurvivesItsCommit() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        scheme.pages[otherURL.path] = Self.sessionPage.replacingOccurrences(of: "title: 'Song'", with: "title: 'Second'")
        tab.load(otherURL)
        try await waitUntil("the next page's session") { tab.mediaSession?.title == "Second" }
        try await waitUntil("the load to finish") { !tab.isLoading }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(tab.mediaSession?.title, "Second")
    }

    func testThePageCannotSeeTheMessageHandler() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        let type = try await tab.webView?.evaluateJavaScript(
            "typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(MediaSessionBridge.handlerName))") as? String
        XCTAssertEqual(type, "undefined", "the handler lives in the isolated world only")
    }

    func testAPageCanOnlyMisreportItsOwnSessionWithKnownActions() async throws {
        let tab = makeTab()
        try await loadSessionPage(in: tab)
        _ = try await tab.webView?.evaluateJavaScript("""
            document.dispatchEvent(new CustomEvent('\(MediaSessionBridge.changedEvent)',
              { detail: 'previoustrack,evil,<img src=x>' })); 1
            """)
        try await waitUntil("the forged report") { tab.mediaSession?.actions == [.previoustrack] }
    }

    func testAReportPostsANowPlayingChange() async throws {
        let tab = makeTab()
        let posted = expectation(forNotification: BrowserTab.nowPlayingDidChangeNotification, object: tab) { _ in
            tab.mediaSession?.title == "Song"
        }
        try await loadSessionPage(in: tab)
        await fulfillment(of: [posted], timeout: 5)
    }

    // MARK: - Mute

    func testMuteMutesThePageAndUnmuteRestoresIt() throws {
        let tab = makeTab()
        let webView = try XCTUnwrap(tab.webView)
        tab.toggleMute()
        XCTAssertTrue(tab.isMuted)
        XCTAssertTrue(PageMediaControl(webView: webView).isPageAudioMuted, "every frame and Web Audio, not element.muted")
        tab.toggleMute()
        XCTAssertFalse(tab.isMuted)
        XCTAssertFalse(PageMediaControl(webView: webView).isPageAudioMuted)
    }

    // MARK: - Playback run

    func testAudibleStateDrivesThePlaybackRun() throws {
        let tab = makeTab()
        XCTAssertNil(tab.playbackSession)
        tab.isPlayingAudio = true
        let start = try XCTUnwrap(tab.playbackSession?.startedAt)
        XCTAssertNil(tab.playbackSession?.stoppedAt)
        tab.isPlayingAudio = false
        XCTAssertEqual(tab.playbackSession?.startedAt, start)
        XCTAssertNotNil(tab.playbackSession?.stoppedAt, "quiet, in its grace")
    }

    func testClosingATabTakesItOffTheBarAtOnce() {
        let tab = makeTab()
        tab.isPlayingAudio = true
        tab.teardown()
        XCTAssertNil(tab.playbackSession, "no grace for a closed or sleeping tab")
        XCTAssertNil(tab.nowPlayingCandidate(isPrivate: false).session)
    }

    func testLiftingTheBarSuspensionKeepsThePauseHeld() {
        let tab = makeTab()
        tab.isPlayingAudio = true
        tab.togglePlayPauseFromBar()
        XCTAssertTrue(tab.isMediaSuspendedFromBar, "no page handlers: the bar suspends the page")
        XCTAssertTrue(tab.isPausedFromBar)

        // Another window shows the tab.
        tab.liftMediaSuspensionFromBar()
        XCTAssertFalse(tab.isMediaSuspendedFromBar, "a page on screen must be able to play again")
        XCTAssertTrue(tab.isPausedFromBar, "the pausing window's bar still holds it")
    }

    func testAStaleAudioChangeDoesNotReachASleptTab() async throws {
        let tab = makeTab()
        let webView = try XCTUnwrap(tab.webView)
        // What KVO queues just before `releaseWebView` removes the observer.
        tab.observeValue(forKeyPath: "_isPlayingAudio", of: webView, change: [.newKey: true], context: nil)
        tab.sleep()
        // Queued behind the KVO change, so it has run by the time this fires.
        let drained = expectation(description: "the queued change ran")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertFalse(tab.isPlayingAudio)
        XCTAssertNil(tab.playbackSession, "a sleeping tab must not land on the bar")
    }

    func testDismissingNamesTheCurrentRun() {
        let tab = makeTab()
        tab.isPlayingAudio = true
        tab.dismissFromNowPlaying()
        XCTAssertEqual(tab.nowPlayingDismissedSessionStart, tab.playbackSession?.startedAt)
        XCTAssertEqual(NowPlayingRule.tabToShow([tab.nowPlayingCandidate(isPrivate: false)], visibleTabIDs: [],
                                                windowIsPrivate: false, now: Date()), nil)
    }

    // MARK: - Picture in picture

    func testAFrameInPiPKeepsTheTabInPiPUntilItLeaves() {
        let tab = makeTab()
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "a", active: true))
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "b", active: true))
        XCTAssertTrue(tab.isInPictureInPicture)
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "a", active: false))
        XCTAssertTrue(tab.isInPictureInPicture, "frame b is still in PiP")
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "b", active: false))
        XCTAssertFalse(tab.isInPictureInPicture, "the PiP window closed")
    }

    func testANewDocumentLeavesPiP() {
        let tab = makeTab()
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "a", active: true))
        tab.mediaBridgeDidReport(.document)
        XCTAssertFalse(tab.isInPictureInPicture)
    }

    func testARequestedPiPCountsUntilTheFrameReports() {
        let tab = makeTab()
        tab.pictureInPictureEntryWillStart()
        XCTAssertTrue(tab.isInPictureInPicture, "no bar flashes up while the video is on its way into PiP")
        tab.mediaBridgeDidReport(.pictureInPicture(frame: "a", active: true))
        XCTAssertTrue(tab.isInPictureInPicture)
        XCTAssertFalse(tab.isAwaitingPictureInPicture)
    }

    func testAPageWithNoPiPVideoIsNotInPiP() {
        let tab = makeTab()
        tab.pictureInPictureEntryWillStart()
        tab.pictureInPictureEntryDidFinish(requested: false)
        XCTAssertFalse(tab.isInPictureInPicture, "an audio-only page gets the bar")
    }

    func testARequestThatNeverLandsTimesOut() async throws {
        let saved = BrowserTab.pictureInPictureEntryTimeout
        BrowserTab.pictureInPictureEntryTimeout = 0.1
        defer { BrowserTab.pictureInPictureEntryTimeout = saved }
        let tab = makeTab()
        tab.pictureInPictureEntryWillStart()
        tab.pictureInPictureEntryDidFinish(requested: true)
        try await waitUntil("the entry to time out", timeout: 2) { !tab.isInPictureInPicture }
    }
}
