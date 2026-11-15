import Synchronization
import XCTest
@testable import Detour

/// TASK-329 AC #2: the AdGuard URL Tracking filter's download path
/// (`TrackingParameterList`): first download, the cached copy at launch, a
/// conditional refresh, and every failure falling back quietly (the rules in
/// use stay; none at first, so Copy URL uses the built-in names alone).
/// A stub URLProtocol serves `tracking-list.test`; each test has its own
/// cache folder and defaults suite.
nonisolated final class TrackingParameterListTests: XCTestCase {

    private var cacheDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var installed: [TrackingParameterFilter?] = []
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let listURL = URL(string: "https://tracking-list.test/17.txt")!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackingParameterListTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        suiteName = "DetourTests.TrackingParameterList.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        installed = []
        TrackingListStubProtocol.reset()
    }

    @MainActor override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        TrackingListStubProtocol.reset()
        try await super.tearDown()
    }

    @MainActor private func makeList() -> TrackingParameterList {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackingListStubProtocol.self]
        return TrackingParameterList(url: Self.listURL, cacheDirectory: cacheDirectory, defaults: defaults,
                                     session: URLSession(configuration: configuration),
                                     now: { [unowned self] in now },
                                     install: { [unowned self] in installed.append($0) })
    }

    private var cacheFile: URL { cacheDirectory.appendingPathComponent("adguard-url-tracking.txt") }
    private static let fixture = Data(TrackingParameterFilterFixture.text.utf8)

    // MARK: - Launch

    @MainActor func testTheFirstLaunchDownloadsInstallsAndCachesTheList() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.last??.counts.supported, 30)
        XCTAssertEqual(list.counts?.supported, 30)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
        XCTAssertEqual(defaults.string(forKey: "ContentBlocker.adguard-url-tracking.etag"), "\"v1\"")
        XCTAssertEqual(defaults.object(forKey: "ContentBlocker.adguard-url-tracking.lastFetch") as? Date, now)
        XCTAssertEqual(defaults.integer(forKey: "ContentBlocker.adguard-url-tracking.ruleCount"), 30)
        let request = try XCTUnwrap(TrackingListStubProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"), "no cache: the list is fetched in full")
    }

    @MainActor func testALaunchWithACachedListNotDueUsesItWithoutFetching() async throws {
        try Self.fixture.write(to: cacheFile)
        defaults.set(now.addingTimeInterval(-3600), forKey: "ContentBlocker.adguard-url-tracking.lastFetch")
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.last??.counts.supported, 30)
        XCTAssertTrue(TrackingListStubProtocol.requests.isEmpty)
    }

    @MainActor func testALaunchWithACachedListDueRefreshesConditionally() async throws {
        try Self.fixture.write(to: cacheFile)
        defaults.set("\"v1\"", forKey: "ContentBlocker.adguard-url-tracking.etag")
        defaults.set(now.addingTimeInterval(-2 * 86400), forKey: "ContentBlocker.adguard-url-tracking.lastFetch")
        TrackingListStubProtocol.respond(status: 304, body: Data(), etag: "\"v1\"")
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertEqual(installed.count, 1, "the cached rules, and nothing new from the 304")
        XCTAssertEqual(TrackingListStubProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(defaults.object(forKey: "ContentBlocker.adguard-url-tracking.lastFetch") as? Date, now)
        XCTAssertFalse(list.isDue)
    }

    // MARK: - Falling back

    @MainActor func testOfflineAtTheFirstLaunchInstallsNothing() async throws {
        TrackingListStubProtocol.fail(with: URLError(.notConnectedToInternet))
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertTrue(installed.isEmpty, "Copy URL keeps the built-in names alone")
        XCTAssertNil(list.counts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertNil(defaults.object(forKey: "ContentBlocker.adguard-url-tracking.lastFetch"),
                     "a failed fetch is retried at the next launch")
    }

    @MainActor func testAnErrorResponseKeepsTheRulesInUse() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()

        TrackingListStubProtocol.respond(status: 503, body: Data("busy".utf8), etag: nil)
        let outcome = await list.refresh()

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(list.counts?.supported, 30)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
    }

    /// A 200 that is no list (a captive portal's page): no rules, so neither
    /// the rules in use nor the cached text are replaced.
    @MainActor func testATextWithoutRulesKeepsTheRulesInUseAndTheCache() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()

        TrackingListStubProtocol.respond(status: 200, body: Data("<html><body>Sign in to Wi-Fi</body></html>".utf8),
                                         etag: "\"portal\"")
        let outcome = await list.refresh(conditional: false)

        XCTAssertEqual(outcome, .empty)
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
        XCTAssertEqual(defaults.string(forKey: "ContentBlocker.adguard-url-tracking.etag"), "\"v1\"")
    }

    @MainActor func testAnUnreadableCacheIsReplacedByADownload() async throws {
        try Data("garbage\n".utf8).write(to: cacheFile)
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: nil)
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
    }

    // MARK: - Clear Cache & Redownload

    @MainActor func testClearingDropsTheRulesAndDownloadsInFull() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()

        TrackingListStubProtocol.fail(with: URLError(.timedOut))
        await list.clearCacheAndRedownload()

        XCTAssertEqual(installed.count, 2)
        XCTAssertNil(installed.last ?? nil, "the built-in names alone until the download parses")
        XCTAssertNil(list.counts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertNil(defaults.string(forKey: "ContentBlocker.adguard-url-tracking.etag"))
        XCTAssertNil(TrackingListStubProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"))

        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v2\"")
        let outcome = await list.refresh()
        XCTAssertEqual(outcome, .installed)
        XCTAssertNotNil(installed.last ?? nil)
    }

    // MARK: - The Settings switch (TASK-337)

    @MainActor func testTheListIsOnByDefaultAndTheSettingIsStoredInItsDefaults() {
        XCTAssertTrue(makeList().isEnabled)
        makeList().setEnabled(false)
        XCTAssertEqual(defaults.object(forKey: TrackingParameterList.enabledKey) as? Bool, false)
        XCTAssertEqual(TrackingParameterList.enabledKey, "ContentBlocker.adguard-url-tracking.enabled")
        XCTAssertFalse(makeList().isEnabled, "a list on the same data directory's defaults reads it")
    }

    /// Off at launch: no request, and the cached rules are not used, even
    /// with a refresh due; the cache stays for when it is turned on.
    @MainActor func testOffAtLaunchNothingIsFetchedOrUsed() async throws {
        try Self.fixture.write(to: cacheFile)
        defaults.set(now.addingTimeInterval(-2 * 86400), forKey: "ContentBlocker.adguard-url-tracking.lastFetch")
        defaults.set(false, forKey: TrackingParameterList.enabledKey)
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()

        await list.loadAtLaunch()

        XCTAssertTrue(TrackingListStubProtocol.requests.isEmpty)
        XCTAssertTrue(installed.isEmpty, "Copy URL keeps the built-in names alone")
        XCTAssertNil(list.counts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    /// Update Now while off: no request.
    @MainActor func testARefreshWhileOffMakesNoRequest() async {
        defaults.set(false, forKey: TrackingParameterList.enabledKey)
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()

        let conditional = await list.refresh()
        let full = await list.refresh(conditional: false)

        XCTAssertEqual(conditional, .off)
        XCTAssertEqual(full, .off)
        XCTAssertTrue(TrackingListStubProtocol.requests.isEmpty)
        XCTAssertTrue(installed.isEmpty)
    }

    /// Clear Cache & Redownload while off clears the list like the others
    /// but downloads nothing (PROVISIONAL, TASK-337).
    @MainActor func testClearingWhileOffDeletesTheCacheWithoutARequest() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()
        list.setEnabled(false)
        TrackingListStubProtocol.reset()
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v2\"")

        await list.clearCacheAndRedownload()

        XCTAssertTrue(TrackingListStubProtocol.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertNil(defaults.string(forKey: "ContentBlocker.adguard-url-tracking.etag"))
        XCTAssertNil(installed.last ?? nil)
        XCTAssertFalse(list.isEnabled, "clearing leaves the setting alone")
    }

    /// Turning it off stops using the list at once; the cached text and its
    /// bookkeeping stay, so turning it on again works offline.
    @MainActor func testTurningOffStopsUsingTheListAndKeepsItsCache() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()
        XCTAssertNotNil(installed.last ?? nil)

        list.setEnabled(false)

        XCTAssertEqual(installed.count, 2)
        XCTAssertNil(installed.last ?? nil, "the built-in names alone")
        XCTAssertNil(list.counts)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
        XCTAssertEqual(defaults.string(forKey: "ContentBlocker.adguard-url-tracking.etag"), "\"v1\"")
    }

    /// A download already in flight when the list is turned off is neither
    /// used nor cached.
    @MainActor func testAResponseInFlightWhenTurnedOffIsDropped() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        TrackingListStubProtocol.holdReplies()
        let list = makeList()
        let refresh = Task { await list.refresh(conditional: false) }
        for _ in 0..<200 where TrackingListStubProtocol.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(TrackingListStubProtocol.requests.count, 1, "the request is in flight")

        list.setEnabled(false)
        TrackingListStubProtocol.releaseReplies()
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(installed.count, 1)
        XCTAssertNil(installed.last ?? nil, "only turning it off installed anything: nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertNil(defaults.object(forKey: "ContentBlocker.adguard-url-tracking.lastFetch"))
    }

    /// Turned on again offline: the cached rules are back in use, and a
    /// fetch (conditional on the cached text) was tried.
    @MainActor func testTurningOnUsesTheCacheOfflineAndFetches() async throws {
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v1\"")
        let list = makeList()
        await list.loadAtLaunch()
        list.setEnabled(false)
        TrackingListStubProtocol.fail(with: URLError(.notConnectedToInternet))

        list.setEnabled(true)
        await list.turnedOn()

        XCTAssertEqual(installed.last??.counts.supported, 30)
        XCTAssertEqual(list.counts?.supported, 30)
        XCTAssertEqual(TrackingListStubProtocol.requests.count, 2, "launch, then turning it on")
        XCTAssertEqual(TrackingListStubProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
    }

    /// Turned on with no cache (cleared while off): downloaded in full.
    @MainActor func testTurningOnWithoutACacheDownloadsInFull() async throws {
        defaults.set(false, forKey: TrackingParameterList.enabledKey)
        defaults.set("\"stale\"", forKey: "ContentBlocker.adguard-url-tracking.etag")
        TrackingListStubProtocol.respond(status: 200, body: Self.fixture, etag: "\"v2\"")
        let list = makeList()

        list.setEnabled(true)
        await list.turnedOn()

        XCTAssertEqual(TrackingListStubProtocol.requests.count, 1)
        XCTAssertNil(TrackingListStubProtocol.requests.first?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(installed.last??.counts.supported, 30)
        XCTAssertEqual(try Data(contentsOf: cacheFile), Self.fixture)
    }

    /// The pane's status line under the switch.
    @MainActor func testTheSettingsStatusLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        typealias Pane = ContentBlockerSettingsViewController
        XCTAssertEqual(Pane.trackingListStatus(isEnabled: false, ruleCount: 2665, lastFetch: now, now: now),
                       "Off: not downloaded or used")
        XCTAssertEqual(Pane.trackingListStatus(isEnabled: true, ruleCount: nil, lastFetch: nil, now: now),
                       "Not downloaded yet")
        XCTAssertEqual(Pane.trackingListStatus(isEnabled: true, ruleCount: 2665, lastFetch: nil, now: now),
                       "2,665 rules")
        let status = Pane.trackingListStatus(isEnabled: true, ruleCount: 2665,
                                             lastFetch: now.addingTimeInterval(-3 * 3600), now: now)
        XCTAssertTrue(status.hasPrefix("2,665 rules, updated "), status)
        XCTAssertTrue(status.contains("3"), status)
        let justNow = Pane.trackingListStatus(isEnabled: true, ruleCount: 1, lastFetch: now.addingTimeInterval(0.5),
                                              now: now)
        XCTAssertFalse(justNow.contains("in "), "a fetch a moment ahead of the clock is not in the future: \(justNow)")
    }

    // MARK: - The list's address

    @MainActor func testTheListURLAndItsDebugOverride() {
        XCTAssertEqual(TrackingParameterList.listURL(environment: [:]), TrackingParameterList.defaultURL)
        XCTAssertEqual(TrackingParameterList.defaultURL.absoluteString,
                       "https://filters.adtidy.org/extension/ublock/filters/17.txt")
        #if DEBUG
        XCTAssertEqual(TrackingParameterList.listURL(environment: ["DETOUR_TRACKING_FILTER_URL": "http://127.0.0.1:8123/17.txt"]),
                       URL(string: "http://127.0.0.1:8123/17.txt"))
        #endif
        XCTAssertEqual(TrackingParameterList.listURL(environment: ["DETOUR_TRACKING_FILTER_URL": ""]),
                       TrackingParameterList.defaultURL)
    }

    /// The test host never fetches the live list into the shared rules.
    @MainActor func testTheTestHostHasNoDownloadedRules() {
        XCTAssertTrue(AppDelegate.isRunningUnitTests)
        XCTAssertNil(ContentBlockerManager.shared.trackingParameterList.counts)
    }
}

/// Serves one stubbed response (or error) for `tracking-list.test` and
/// records the requests. Nonisolated: URLSession calls a protocol on its own
/// queues; the state is behind a mutex.
nonisolated private final class TrackingListStubProtocol: URLProtocol {
    private enum Reply { case response(status: Int, body: Data, etag: String?), error(URLError) }
    private static let state = Mutex<(reply: Reply?, recorded: [URLRequest])>((nil, []))
    /// While held, a reply waits for `releaseReplies()` (a response in flight).
    private static let held = Mutex(false)
    private static let release = DispatchSemaphore(value: 0)

    static func holdReplies() { held.withLock { $0 = true } }

    static func releaseReplies() {
        held.withLock { $0 = false }
        release.signal()
    }

    static var requests: [URLRequest] { state.withLock { $0.recorded } }

    static func respond(status: Int, body: Data, etag: String?) {
        state.withLock { $0.reply = .response(status: status, body: body, etag: etag) }
    }

    static func fail(with error: URLError) {
        state.withLock { $0.reply = .error(error) }
    }

    static func reset() {
        state.withLock { $0 = (nil, []) }
        held.withLock { $0 = false }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tracking-list.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let reply = Self.state.withLock { state -> Reply? in
            state.recorded.append(request)
            return state.reply
        }
        // On URLSession's own thread, so waiting here holds only this load.
        // Timed, so a test that fails before releasing cannot hang the loader.
        if Self.held.withLock({ $0 }) { _ = Self.release.wait(timeout: .now() + 10) }
        switch reply {
        case .response(let status, let body, let etag)?:
            var headers = ["Content-Type": "text/plain; charset=utf-8"]
            if let etag { headers["ETag"] = etag }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error)?:
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }
    }

    override func stopLoading() {}
}
