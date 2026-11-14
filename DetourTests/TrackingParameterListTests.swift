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

    static var requests: [URLRequest] { state.withLock { $0.recorded } }

    static func respond(status: Int, body: Data, etag: String?) {
        state.withLock { $0.reply = .response(status: status, body: body, etag: etag) }
    }

    static func fail(with error: URLError) {
        state.withLock { $0.reply = .error(error) }
    }

    static func reset() {
        state.withLock { $0 = (nil, []) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tracking-list.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let reply = Self.state.withLock { state -> Reply? in
            state.recorded.append(request)
            return state.reply
        }
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
