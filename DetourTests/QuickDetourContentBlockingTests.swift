import XCTest
import WebKit
@testable import Detour

/// An open Quick Detour or quarantine page follows content-blocking changes
/// (TASK-359): on `.contentBlockerRulesDidChange` its window replaces the
/// page's rule lists with what its profile has on now, as a browser window
/// does for its selected panes.
///
/// A real `QuickDetourWindowController` whose `contentRuleStore` is a private
/// temporary store holding tiny lists under the real list identifiers; the
/// page comes from a loopback server and `fetch`es two paths, one per list, so
/// both outcomes (loaded, blocked) are positive signals.
nonisolated final class QuickDetourContentBlockingTests: XCTestCase {

    private var directory: URL!
    private var defaultsSuiteName: String!
    private var ruleStore: ContentRuleStore!
    private var windows: [QuickDetourWindowController] = []
    private var servers: [LoopbackHTTPServer] = []
    private var createdProfiles: [Profile] = []

    /// Released profiles take their process pool down with them, which WebKit
    /// traps on inside an IPC dispatch (`ExtensionPrivateStoreTests`): kept for
    /// the rest of the test process.
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDetourContentBlockingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "QuickDetourContentBlockingTests.\(UUID().uuidString)"
        ruleStore = ContentRuleStore(storage: ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: directory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))))
    }

    @MainActor override func tearDown() async throws {
        for controller in windows { controller.close() }
        windows.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        ruleStore = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The path `easylist` blocks in these tests, and `easyprivacy`'s.
    private static let firstPath = "/task359-first"
    private static let secondPath = "/task359-second"

    @MainActor private func blockRule(_ path: String) -> ContentRule {
        ["trigger": ["url-filter": NSRegularExpression.escapedPattern(for: path)], "action": ["type": "block"]]
    }

    @MainActor private func compile(_ identifier: String, blocking path: String) async {
        let rules = [blockRule(path)]
        let compiled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ruleStore.compile(identifier: identifier, rules: rules) { outcome in
                if case .compiled = outcome { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }
        XCTAssertTrue(compiled, "\(identifier) compiled")
    }

    @MainActor private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Blocking</title></head><body>a page</body></html>",
            Self.firstPath: "first",
            Self.secondPath: "second",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// A window on `profile` (a quarantine when `quarantine`) with the page
    /// loaded, and the page's rule lists those `profile` had on from this
    /// test's store when it opened: what `Space.makeWebViewConfiguration`
    /// gives it from the shared manager's.
    @MainActor private func open(on profile: Profile, quarantine: Bool = false) async throws -> QuickDetourWindowController {
        let url = try await serve()
        let controller = QuickDetourWindowController(
            profile: profile, sourceSpace: nil,
            quarantine: quarantine ? QuarantineSession(originalURL: url) : nil)
        windows.append(controller)
        controller.contentRuleStore = ruleStore
        let page = try XCTUnwrap(controller.tab?.webView)
        ContentBlockerManager.replaceRuleLists(on: page.configuration.userContentController, profile: profile,
                                               from: ruleStore)
        controller.showWindow(nil)
        controller.load(url, typed: false)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the page to load") {
            tab.url == url && !tab.isLoading && tab.title == "Blocking"
        }
        return controller
    }

    private enum Outcome: String { case loaded, blocked }

    /// Fetches both paths from the page; a load a rule list blocks rejects.
    /// Waits until the window has counted every blocked one too.
    @MainActor private func fetchBoth(in controller: QuickDetourWindowController,
                                      file: StaticString = #filePath, line: UInt = #line) async throws
        -> (first: Outcome, second: Outcome) {
        let tab = try XCTUnwrap(controller.tab)
        let page = try XCTUnwrap(tab.webView)
        let countBefore = tab.blockedCount
        let tag = UUID().uuidString
        let js = """
        const outcome = async (path) => {
            try { await fetch(path + '?' + tag, { cache: 'no-store' }); return 'loaded'; }
            catch (e) { return 'blocked'; }
        };
        return JSON.stringify({ first: await outcome(first), second: await outcome(second) });
        """
        let raw = try await page.callAsyncJavaScript(
            js, arguments: ["tag": tag, "first": Self.firstPath, "second": Self.secondPath], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        let first = try XCTUnwrap(result["first"].flatMap(Outcome.init(rawValue:)))
        let second = try XCTUnwrap(result["second"].flatMap(Outcome.init(rawValue:)))
        let blocked = [first, second].filter { $0 == .blocked }.count
        try await waitUntil("the window counts \(blocked) blocked load(s)", timeout: 5) {
            tab.blockedCount == countBefore + blocked
        }
        return (first, second)
    }

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    // MARK: - Tests

    /// A list switched off in Settings > Profiles stops blocking on the open
    /// page; the other list keeps blocking.
    @MainActor func testAListSwitchedOffStopsBlockingOnAnOpenQuickDetour() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let profile = makeProfile("Quick Detour Blocking")
        let controller = try await open(on: profile)
        var outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .blocked, "the lists the page opened with block")
        XCTAssertEqual(outcome.second, .blocked)

        profile.isEasyListEnabled = false
        ContentBlockerManager.shared.reapplyRuleLists()

        outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .loaded, "the list switched off no longer blocks")
        XCTAssertEqual(outcome.second, .blocked, "the list still on still blocks")
    }

    /// A list recompiled with other rules (a refresh, or Clear Cache &
    /// Redownload: every list removed from the store, then compiled again)
    /// blocks with its new rules on the open page, and its old ones are gone.
    @MainActor func testARecompiledListReachesAnOpenQuickDetour() async throws {
        await compile("easylist", blocking: Self.firstPath)
        let profile = makeProfile("Quick Detour Recompile")
        let controller = try await open(on: profile)
        var outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .blocked)
        XCTAssertEqual(outcome.second, .loaded)

        ruleStore.invalidateAll()
        await compile("easylist", blocking: Self.secondPath)
        ContentBlockerManager.shared.reapplyRuleLists()

        outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .loaded, "the old rules are gone")
        XCTAssertEqual(outcome.second, .blocked, "the new rules block")
    }

    /// A quarantine runs on the Private profile: its page follows the Private
    /// profile's switches.
    @MainActor func testAListSwitchedOffInThePrivateProfileStopsBlockingInAQuarantine() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let privateProfile = Profile(name: "Quarantine Blocking Private", isIncognito: true)
        createdProfiles.append(privateProfile)
        let controller = try await open(on: privateProfile, quarantine: true)
        XCTAssertTrue(controller.isQuarantine)
        var outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .blocked)
        XCTAssertEqual(outcome.second, .blocked)

        privateProfile.isEasyPrivacyEnabled = false
        ContentBlockerManager.shared.reapplyRuleLists()

        outcome = try await fetchBoth(in: controller)
        XCTAssertEqual(outcome.first, .blocked)
        XCTAssertEqual(outcome.second, .loaded, "the Private profile's list switched off no longer blocks")
    }
}
