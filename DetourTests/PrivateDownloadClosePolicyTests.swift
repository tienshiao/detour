import XCTest
@testable import Detour

/// The rule for a Private window's downloads that are still running when the
/// window goes away (TASK-156): which are cancelled, and whether to ask.
final class PrivateDownloadClosePolicyTests: XCTestCase {

    private let windowA = DownloadScope.incognito(spaceID: UUID())
    private let windowB = DownloadScope.incognito(spaceID: UUID())

    // MARK: - Which downloads a close cancels

    func testClosingAPrivateWindowCancelsItsOwnDownloadsInFlight() {
        XCTAssertTrue(PrivateDownloadClosePolicy.cancels(downloadIn: windowA, isInFlight: true,
                                                         closing: .window(windowA)))
    }

    func testADownloadThatHasEndedIsNotCancelled() {
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: windowA, isInFlight: false,
                                                          closing: .window(windowA)))
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: windowA, isInFlight: false,
                                                          closing: .allWindows))
    }

    func testAnotherPrivateWindowsDownloadsAreLeftAlone() {
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: windowB, isInFlight: true,
                                                          closing: .window(windowA)))
    }

    /// Normal windows share one list: the download is still listed in the
    /// others, and closing the last one does not end it either.
    func testClosingANormalWindowCancelsNothing() {
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: .normal, isInFlight: true,
                                                          closing: .window(.normal)))
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: windowA, isInFlight: true,
                                                          closing: .window(.normal)))
    }

    func testClosingAPrivateWindowLeavesNormalDownloadsAlone() {
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: .normal, isInFlight: true,
                                                          closing: .window(windowA)))
    }

    func testQuittingCancelsEveryPrivateWindowsDownloadsInFlight() {
        XCTAssertTrue(PrivateDownloadClosePolicy.cancels(downloadIn: windowA, isInFlight: true, closing: .allWindows))
        XCTAssertTrue(PrivateDownloadClosePolicy.cancels(downloadIn: windowB, isInFlight: true, closing: .allWindows))
        XCTAssertFalse(PrivateDownloadClosePolicy.cancels(downloadIn: .normal, isInFlight: true, closing: .allWindows))
    }

    // MARK: - Whether to ask

    func testNothingInFlightClosesWithoutAsking() {
        XCTAssertEqual(PrivateDownloadClosePolicy.decision(inFlightCount: 0), .close)
    }

    func testOneDownloadInFlightAsks() throws {
        guard case .confirm(let prompt) = PrivateDownloadClosePolicy.decision(inFlightCount: 1) else {
            return XCTFail("expected a question")
        }
        XCTAssertEqual(prompt.messageText, "Close this Private window?")
        XCTAssertEqual(prompt.informativeText, "1 download is in progress. Closing this Private window cancels it.")
        XCTAssertEqual(prompt.closeButtonTitle, "Close Window")
        XCTAssertEqual(prompt.keepButtonTitle, "Continue Downloading")
    }

    func testSeveralDownloadsInFlightAskInThePlural() throws {
        guard case .confirm(let prompt) = PrivateDownloadClosePolicy.decision(inFlightCount: 3) else {
            return XCTFail("expected a question")
        }
        XCTAssertEqual(prompt.informativeText,
                       "3 downloads are in progress. Closing this Private window cancels them.")
    }

    // MARK: - Quit

    func testTheQuitConfirmationNamesPrivateDownloadsInFlight() {
        XCTAssertNil(PrivateDownloadClosePolicy.quitWarning(inFlightCount: 0))
        XCTAssertEqual(PrivateDownloadClosePolicy.quitWarning(inFlightCount: 1),
                       "1 download in a Private window is in progress and will be cancelled.")
        XCTAssertEqual(PrivateDownloadClosePolicy.quitWarning(inFlightCount: 2),
                       "2 downloads in Private windows are in progress and will be cancelled.")
    }
}

/// The window's side of the rule: `windowShouldClose` asks through an injected
/// confirmation, so no test shows an alert (TASK-156). The downloads are manual
/// items on `DownloadManager.shared`; a real one is in
/// `PrivateDownloadTransferTests`.
@MainActor
final class PrivateDownloadCloseWindowTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var items: [DownloadItem] = []

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        // Normal items stay listed after their window closes.
        for item in items { DownloadManager.shared.removeDownload(item) }
        items.removeAll()
        super.tearDown()
    }

    /// A window whose answer to the question is `answer`, and the prompts it
    /// was asked.
    private final class Asked {
        var prompts: [PrivateDownloadClosePolicy.Prompt] = []
    }

    private func makeWindow(incognito: Bool, answering answer: Bool) -> (BrowserWindowController, Asked) {
        let wc = BrowserWindowController(incognito: incognito)
        controllers.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        let asked = Asked()
        wc.confirmClosingWithPrivateDownloads = { prompt in
            asked.prompts.append(prompt)
            return answer
        }
        return (wc, asked)
    }

    private func addItem(_ name: String, scope: DownloadScope) -> DownloadItem {
        let item = DownloadManager.shared.addManualItem(filename: name, sourceURL: nil, scope: scope)
        items.append(item)
        return item
    }

    private func shouldClose(_ wc: BrowserWindowController) throws -> Bool {
        wc.windowShouldClose(try XCTUnwrap(wc.window))
    }

    func testAPrivateWindowWithNothingInFlightClosesWithoutAsking() throws {
        let (wc, asked) = makeWindow(incognito: true, answering: false)
        let ended = addItem("done.zip", scope: wc.downloadScope)
        DownloadManager.shared.downloadDidEnd(ended)

        XCTAssertTrue(try shouldClose(wc))
        XCTAssertTrue(asked.prompts.isEmpty)
    }

    func testDecliningKeepsTheWindowOpenAndTheDownloadRunning() throws {
        let (wc, asked) = makeWindow(incognito: true, answering: false)
        let running = addItem("private.iso", scope: wc.downloadScope)

        XCTAssertFalse(try shouldClose(wc))

        XCTAssertEqual(asked.prompts.map(\.informativeText),
                       ["1 download is in progress. Closing this Private window cancels it."])
        XCTAssertEqual(running.state, .downloading)
        XCTAssertTrue(DownloadManager.shared.items(in: wc.downloadScope).contains { $0 === running })
        XCTAssertNotNil(wc.activeSpace, "the window keeps its space")
    }

    func testGoingAheadCancelsTheWindowsDownloadsInFlight() throws {
        let (wc, asked) = makeWindow(incognito: true, answering: true)
        let first = addItem("first.iso", scope: wc.downloadScope)
        let second = addItem("second.iso", scope: wc.downloadScope)
        let ended = addItem("done.zip", scope: wc.downloadScope)
        DownloadManager.shared.downloadDidEnd(ended)

        XCTAssertTrue(try shouldClose(wc))

        XCTAssertEqual(asked.prompts.map(\.informativeText),
                       ["2 downloads are in progress. Closing this Private window cancels them."])
        XCTAssertEqual(first.state, .cancelled)
        XCTAssertEqual(second.state, .cancelled)
        XCTAssertEqual(ended.state, .completed)
        XCTAssertFalse(DownloadManager.shared.hasActiveDownloads(in: wc.downloadScope))

        wc.window?.close()
        XCTAssertTrue(DownloadManager.shared.items(in: wc.downloadScope).isEmpty)
    }

    func testAnotherPrivateWindowsDownloadIsNeitherCountedNorCancelled() throws {
        let (closing, asked) = makeWindow(incognito: true, answering: true)
        let (other, _) = makeWindow(incognito: true, answering: true)
        let mine = addItem("mine.iso", scope: closing.downloadScope)
        let theirs = addItem("theirs.iso", scope: other.downloadScope)
        let normal = addItem("normal.iso", scope: .normal)

        XCTAssertTrue(try shouldClose(closing))

        XCTAssertEqual(asked.prompts.count, 1)
        XCTAssertEqual(asked.prompts.first?.informativeText,
                       "1 download is in progress. Closing this Private window cancels it.")
        XCTAssertEqual(mine.state, .cancelled)
        XCTAssertEqual(theirs.state, .downloading)
        XCTAssertEqual(normal.state, .downloading)
    }

    /// Normal windows share the list, so the download is still reachable from
    /// the others and from the next window opened.
    func testANormalWindowClosesWithoutAskingAndCancelsNothing() throws {
        let (wc, asked) = makeWindow(incognito: false, answering: false)
        let running = addItem("normal.iso", scope: .normal)

        XCTAssertTrue(try shouldClose(wc))

        XCTAssertTrue(asked.prompts.isEmpty)
        XCTAssertEqual(running.state, .downloading)
    }
}
