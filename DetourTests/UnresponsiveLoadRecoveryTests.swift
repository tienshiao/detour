import XCTest
import AppKit
import WebKit
@testable import Detour

/// TASK-176: a load the web process never starts. `reload()` only queues a
/// message; a web process whose main thread is blocked never reads it, and
/// WebKit's whole response is one "became unresponsive" report three seconds
/// later.
final class UnresponsiveLoadRecoveryRuleTests: XCTestCase {

    private typealias Recovery = UnresponsiveLoadRecovery
    private let page = URL(string: "https://example.com/")!

    /// Feeds `events` in order and returns the effect of the last one.
    @discardableResult
    private func run(_ recovery: inout Recovery, _ events: Recovery.Event...) -> Recovery.Effect {
        var effect = Recovery.Effect.none
        for event in events { effect = recovery.handle(event) }
        return effect
    }

    private func token(_ effect: Recovery.Effect, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard case .waitForPatience(let token) = effect else {
            XCTFail("expected a patience wait, got \(effect)", file: file, line: line)
            return -1
        }
        return token
    }

    // MARK: - The process is replaced

    func testAReloadStillUnstartedAfterThePatienceReplacesTheProcess() {
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
        XCTAssertNil(recovery.pending, "the load issued in the new process is not tracked: one termination per request")
        XCTAssertFalse(recovery.isUnresponsive)
    }

    func testATypedURLIsIssuedAgainAsThatURL() {
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.url(page)), .becameUnresponsive)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .url(page)))
    }

    func testARequestToAProcessAlreadyKnownUnresponsiveReplacesItAtOnce() {
        var recovery = Recovery()
        XCTAssertEqual(run(&recovery, .becameUnresponsive), .none, "nobody asked for a load yet")
        XCTAssertEqual(recovery.handle(.requested(.reload)), .terminate(thenIssue: .reload))
    }

    func testWebKitsResponsiveReportDoesNotCancelAPendingRequest() {
        // Hiding the view makes WebKit report "responsive" with the process
        // still blocked (seen in TASK-175): the request must still be rescued.
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        recovery.handle(.becameResponsive)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
    }

    func testARepeatedReportDoesNotStartThePatienceOver() {
        // The view was hidden and shown again: WebKit reports "responsive",
        // then "unresponsive" once more. The first deadline stands.
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        XCTAssertEqual(run(&recovery, .becameResponsive, .becameUnresponsive), .none)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
    }

    // MARK: - The process is left alone

    func testAnUnresponsiveProcessNobodyAskedToLoadIsLeftAlone() {
        var recovery = Recovery()
        XCTAssertEqual(run(&recovery, .becameUnresponsive), .none)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: 0)), .none)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: 1)), .none)
    }

    func testALoadThatStartsIsNeverReplaced() {
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        recovery.handle(.answered)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .none)
        XCTAssertFalse(recovery.isUnresponsive, "a process that answered is responsive")
    }

    func testAStopTheProcessAnswersLeavesItAlone() {
        var recovery = Recovery()
        XCTAssertEqual(run(&recovery, .requested(.reload), .stopped, .answered, .becameUnresponsive), .none,
                       "busy later, with nobody asking anything of it")
        XCTAssertFalse(recovery.awaitingStop)
        XCTAssertNil(recovery.pending)
    }

    func testAScriptDialogIsNotAHang() {
        // Reload while the page is busy, then the page puts up an alert: its
        // process now waits on the user for as long as they like.
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        recovery.handle(.waitingOnUser)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .none)
        XCTAssertFalse(recovery.isUnresponsive)
        XCTAssertEqual(recovery.pending, .reload, "the reload is still owed once the dialog is gone")
    }

    // MARK: - Stop

    func testAStopTheProcessNeverReadsEndsInAReloadOfThePage() {
        // Otherwise the web view stays "loading" and the sidebar offers a Stop
        // that does nothing: the dead end of TASK-175.
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .stopped, .becameUnresponsive)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
        XCTAssertFalse(recovery.awaitingStop)
    }

    func testStoppingATypedURLDuringThePatienceReloadsThePageTheTabWasOn() {
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.url(page)), .becameUnresponsive)
        XCTAssertEqual(recovery.handle(.stopped), .none, "the wait already running keeps its deadline")
        XCTAssertNil(recovery.pending, "the URL was withdrawn")
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
    }

    func testAStopOnAProcessAlreadyReportedUnresponsiveStartsTheWaitItself() {
        // WebKit sends no second report for a process it already reported.
        var recovery = Recovery()
        let wait = run(&recovery, .becameUnresponsive, .stopped)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .terminate(thenIssue: .reload))
    }

    func testAResponsiveReportWithNothingPendingClearsTheFlag() {
        var recovery = Recovery()
        run(&recovery, .becameUnresponsive, .becameResponsive)
        XCTAssertEqual(recovery.handle(.requested(.reload)), .none)
        XCTAssertEqual(recovery.pending, .reload)
    }

    func testAnEarlierWaitDoesNotCutANewRequestsPatienceShort() {
        var recovery = Recovery()
        let first = token(run(&recovery, .requested(.reload), .becameUnresponsive))
        // That load started after all; later the user asks again and the
        // process stalls again.
        let second = token(run(&recovery, .answered, .requested(.url(page)), .becameUnresponsive))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: first)), .none, "the first wait is stale")
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: second)), .terminate(thenIssue: .url(page)))
    }

    func testAResetForgetsEverything() {
        var recovery = Recovery()
        let wait = run(&recovery, .requested(.reload), .becameUnresponsive)
        recovery.handle(.reset)
        XCTAssertNil(recovery.pending)
        XCTAssertFalse(recovery.isUnresponsive)
        XCTAssertEqual(recovery.handle(.patienceElapsed(token: token(wait))), .none)
    }
}

/// The rule against a real web process whose page blocks its main thread.
@MainActor
final class UnresponsiveLoadRecoveryTests: XCTestCase {

    /// A web process can take this long to come up in a full run: the suites
    /// before this one leave some fifty web processes still launching, and on
    /// a busy machine a ten-second wait for the first page ran out.
    private static let slowLaunch: TimeInterval = 60

    private var tabs: [BrowserTab] = []
    private var defaultPatience: TimeInterval = 0
    private let scheme = CountingSchemeHandler()
    private let pageURL = URL(string: "hang://hang.test/page")!

    override func setUp() {
        super.setUp()
        defaultPatience = BrowserTab.unresponsiveLoadPatience
        BrowserTab.unresponsiveLoadPatience = 0.2
    }

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        BrowserTab.unresponsiveLoadPatience = defaultPatience
        super.tearDown()
    }

    private func webProcessIdentifier(of tab: BrowserTab) -> pid_t {
        (tab.webView?.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    /// A tab showing a loaded page whose main thread is then blocked for
    /// `seconds` — long enough to outlast the test, short enough that a web
    /// process the test fails to replace does not spin for long.
    private func makeTabWithBlockedPage(seconds: Int = 20) async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "hang")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        tab.load(pageURL)
        try await waitUntil("the first load to finish", timeout: Self.slowLaunch) {
            !tab.isLoading && self.scheme.served == 1
        }
        // The timer lets the call return before the page stops answering.
        _ = try await tab.webView?.evaluateJavaScript(
            "setTimeout(() => { const t = Date.now(); while (Date.now() - t < \(seconds * 1000)) {} }, 0); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        return tab
    }

    func testReloadOnABlockedPageLoadsItInANewWebProcess() async throws {
        let tab = try await makeTabWithBlockedPage()
        let blockedProcess = webProcessIdentifier(of: tab)
        XCTAssertNotEqual(blockedProcess, 0)

        tab.reload()

        // WebKit's report comes three seconds after the request.
        try await waitUntil("the page to be loaded again", timeout: Self.slowLaunch) {
            self.scheme.served == 2 && !tab.isLoading
        }
        XCTAssertNotEqual(webProcessIdentifier(of: tab), blockedProcess, "in a new web process")
        XCTAssertFalse(tab.isTerminatingUnresponsiveProcess)
        XCTAssertEqual(tab.url, pageURL)
        XCTAssertEqual(scheme.served, 2, "loaded once more, not twice")
    }

    func testStopOnABlockedPageDoesNotLeaveTheTabLoadingForever() async throws {
        let tab = try await makeTabWithBlockedPage()
        let blockedProcess = webProcessIdentifier(of: tab)

        tab.reload()
        tab.stopLoading()
        XCTAssertTrue(tab.isLoading, "the stop is queued behind the hang")

        try await waitUntil("the tab to stop loading", timeout: Self.slowLaunch) {
            !tab.isLoading && self.scheme.served == 2
        }
        XCTAssertNotEqual(webProcessIdentifier(of: tab), blockedProcess, "in a new web process")
        XCTAssertEqual(tab.url, pageURL)
    }

    func testStoppingALoadOnAResponsivePageKeepsItsWebProcess() async throws {
        let stalling = StallingSchemeHandler()
        stalling.pages["/page"] = "<html><head><title>Slow</title></head><body><img src=\"/hang.png\"></body></html>"
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(stalling, forURLScheme: "slow")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        tab.load(URL(string: "slow://slow.test/page")!)
        try await waitUntil("the page to commit with its image outstanding", timeout: Self.slowLaunch) {
            tab.isLoading && tab.estimatedProgress > 0.1
        }
        let process = webProcessIdentifier(of: tab)

        tab.stopLoading()

        try await waitUntil("the load to stop") { !tab.isLoading }
        // Longer than the patience: nothing is left waiting to fire.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(webProcessIdentifier(of: tab), process)
        XCTAssertFalse(tab.isLoading)
    }

    func testARequestThatStartsNoProvisionalLoadIsNotReplayedLater() async throws {
        // A jump within the document starts no provisional load — like a load
        // the policy refuses (an external-app link) — and the page's own load,
        // still in flight, keeps `isLoading` true. Only the policy request says
        // the web process read it; otherwise the request stays "unanswered"
        // and the next time the page is merely busy it is replayed in a new
        // process.
        let stalling = StallingSchemeHandler()
        stalling.pages["/page"] = "<html><head><title>Slow</title></head><body><img src=\"/hang.png\"></body></html>"
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(stalling, forURLScheme: "slow")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        tab.load(URL(string: "slow://slow.test/page")!)
        try await waitUntil("the page to commit with its image outstanding", timeout: Self.slowLaunch) {
            tab.isLoading && tab.estimatedProgress > 0.1
        }
        let process = webProcessIdentifier(of: tab)
        XCTAssertNotEqual(process, 0)

        tab.load(URL(string: "slow://slow.test/page#there")!)
        try await waitUntil("the jump within the page") {
            (try await tab.webView?.evaluateJavaScript("location.hash") as? String) == "#there"
        }
        XCTAssertTrue(tab.isLoading, "the page's own load is still in flight")

        // Busy for longer than WebKit's three seconds plus the patience. The
        // stop goes to the web view, not the tab: it starts WebKit's
        // responsiveness timer without being a request of the tab's.
        _ = try await tab.webView?.evaluateJavaScript(
            "setTimeout(() => { const t = Date.now(); while (Date.now() - t < 10000) {} }, 0); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        tab.webView?.stopLoading()
        try await Task.sleep(nanoseconds: 4_500_000_000)

        XCTAssertEqual(webProcessIdentifier(of: tab), process, "busy, with nothing asked of it")
    }

    func testAReloadWhileAScriptDialogIsUpKeepsTheWebProcess() async throws {
        // What the window reports around an alert, confirm or prompt: the
        // process answers nothing until the user does, and WebKit's report in
        // the meantime is not a hang.
        let tab = try await makeTabWithBlockedPage(seconds: 10)
        let blockedProcess = webProcessIdentifier(of: tab)
        XCTAssertNotEqual(blockedProcess, 0)

        tab.scriptDialogDidBegin()
        tab.reload()
        // WebKit's report comes three seconds after the request.
        try await Task.sleep(nanoseconds: 4_500_000_000)

        XCTAssertEqual(webProcessIdentifier(of: tab), blockedProcess)
        XCTAssertEqual(scheme.served, 1, "nothing was loaded again")
        tab.scriptDialogDidEnd()
    }
}

/// Serves the same small page for every request and counts them.
final class CountingSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var served = 0

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        served += 1
        let data = Data("<html><head><title>Page \(served)</title></head><body>page</body></html>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html",
                                             expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
