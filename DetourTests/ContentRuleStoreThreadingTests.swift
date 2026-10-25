import XCTest
import WebKit
@testable import Detour

/// Turning parsed rules into the JSON WebKit compiles takes a few hundred
/// milliseconds for EasyList, and the bad-rule search re-encodes every probe:
/// both run on the store's work queue, never on the main queue. Only the
/// `WKContentRuleListStore` calls, which WebKit requires on main, and the
/// bookkeeping run there (TASK-200).
///
/// Compiles of one list run one at a time in call order, so a compile that
/// is still searching for bad rules cannot record its list over a later one.
@MainActor
final class ContentRuleStoreThreadingTests: XCTestCase {

    // MARK: - Fixture

    private var directory: URL!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentRuleStoreThreadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "ContentRuleStoreThreadingTests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A storage of its own under this test's directory.
    private func makeStorage(_ name: String) throws -> ContentBlockerStorage {
        let ruleListDirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: ruleListDirectory, withIntermediateDirectories: true)
        return ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: ruleListDirectory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName)))
    }

    private func block(_ host: String) -> [String: Any] {
        ["trigger": ["url-filter": "\(host)\\.example"], "action": ["type": "block"]]
    }

    /// WebKit refuses the whole list over this rule: its URL filters have no
    /// disjunction.
    private let badRule: [String: Any] = ["trigger": ["url-filter": "bad|rule"], "action": ["type": "block"]]

    private func compile(_ store: ContentRuleStore, _ identifier: String, _ rules: [[String: Any]]) async -> [WKContentRuleList] {
        await withCheckedContinuation { continuation in
            store.compile(identifier: identifier, rules: rules) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Off the main queue

    func testRuleSerialisationRunsOffTheMainQueue() async throws {
        let spy = EncoderSpy()
        let store = ContentRuleStore(storage: try makeStorage("store"), maxRulesPerList: 2, encode: spy.encode)

        let lists = await compile(store, "easylist", ["a", "b", "c", "d", "e"].map(block))

        XCTAssertEqual(lists.count, 3, "five rules at a cap of two are three chunks")
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 5)
        XCTAssertEqual(spy.calls.count, 3, "one encoding per chunk")
        XCTAssertEqual(spy.calls.filter(\.onMain).count, 0, "no chunk is encoded on the main queue")
    }

    func testTheBadRuleSearchRunsOffTheMainQueue() async throws {
        let spy = EncoderSpy()
        let store = ContentRuleStore(storage: try makeStorage("store"), encode: spy.encode)

        let lists = await compile(store, "easylist-cookie", [block("a"), badRule, block("b"), block("c")])

        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist-cookie"), 3, "the bad rule is stripped")
        XCTAssertGreaterThan(spy.calls.count, 2, "the search encodes its probes and the cleaned list")
        XCTAssertEqual(spy.calls.filter(\.onMain).count, 0, "no probe or cleaned list is encoded on the main queue")
    }

    func testTheDefaultEncodingIsTheJSONWebKitWasGivenBefore() async throws {
        let rules = EasyListParser().parse(text: Self.sampleList).rules
        XCTAssertGreaterThan(rules.count, 8)
        let reference = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)
        let encoded = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: ContentRuleStore.encodedRuleList(rules)) }
        }
        XCTAssertNotNil(encoded)
        XCTAssertEqual(encoded, reference)
    }

    /// The compiled file a list leaves in WebKit's store is byte for byte
    /// the one compiled from the JSON the store encoded on main before.
    func testTheCompiledListIsByteIdenticalToBefore() async throws {
        let rules = EasyListParser().parse(text: Self.sampleList).rules
        let storeStorage = try makeStorage("store")
        let store = ContentRuleStore(storage: storeStorage)
        let lists = await compile(store, "easylist", rules)
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), rules.count, "no rule was stripped")

        let referenceJSON = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8))
        let referenceStorage = try makeStorage("reference")
        let referenceError: Error? = await withCheckedContinuation { continuation in
            referenceStorage.ruleListStore.compileContentRuleList(
                forIdentifier: "easylist", encodedContentRuleList: referenceJSON) { _, error in
                continuation.resume(returning: error)
            }
        }
        XCTAssertNil(referenceError)

        let compiled = try Data(contentsOf: directory.appendingPathComponent("store/ContentRuleList-easylist"))
        let reference = try Data(contentsOf: directory.appendingPathComponent("reference/ContentRuleList-easylist"))
        XCTAssertGreaterThan(compiled.count, 0)
        XCTAssertEqual(compiled, reference)
    }

    // MARK: - One compile of a list at a time

    /// The first compile hits a bad rule and searches for it; the second,
    /// issued at once, waits for it, so the list left attached is the
    /// second's.
    func testASecondCompileOfAListWaitsForTheFirstsBadRuleSearch() async throws {
        let spy = EncoderSpy()
        let store = ContentRuleStore(storage: try makeStorage("store"), encode: spy.encode)
        let first = [block("a"), badRule, block("b")]
        let second = ["c", "d", "e", "f"].map(block)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            store.compile(identifier: "easylist", rules: first) { _ in
                spy.record("first done")
                group.leave()
            }
            store.compile(identifier: "easylist", rules: second) { _ in
                spy.record("second done")
                group.leave()
            }
            group.notify(queue: .main) { continuation.resume() }
        }

        XCTAssertEqual(spy.events.filter { $0.hasSuffix("done") }, ["first done", "second done"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 4, "the second compile's list is the one kept")
        let firstDone = try XCTUnwrap(spy.events.firstIndex(of: "first done"))
        let secondEncoded = try XCTUnwrap(spy.events.firstIndex(of: "encode 4"))
        XCTAssertGreaterThan(secondEncoded, firstDone, "the second compile starts once the first is done")
    }

    func testCompilesOfDifferentListsDoNotWaitForEachOther() async throws {
        let spy = EncoderSpy()
        let store = ContentRuleStore(storage: try makeStorage("store"), encode: spy.encode)
        var cookieLists: [WKContentRuleList] = []
        var privacyLists: [WKContentRuleList] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            store.compile(identifier: "easylist-cookie", rules: [block("a"), badRule, block("b")]) {
                cookieLists = $0
                spy.record("cookie done")
                group.leave()
            }
            store.compile(identifier: "easyprivacy", rules: [block("c")]) {
                privacyLists = $0
                spy.record("privacy done")
                group.leave()
            }
            group.notify(queue: .main) { continuation.resume() }
        }
        XCTAssertEqual(spy.events.filter { $0.hasSuffix("done") }, ["privacy done", "cookie done"],
                       "the second list does not wait for the first list's bad-rule search")
        XCTAssertEqual(cookieLists.count, 1)
        XCTAssertEqual(privacyLists.count, 1)
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist-cookie"), 2)
        XCTAssertEqual(store.compiledRuleCount(forList: "easyprivacy"), 1)
    }

    // MARK: - Older text never replaces newer text

    func testACompileOfOlderTextDoesNotStartAfterOneOfNewerText() {
        var order = FilterListCompileOrder()
        let cache = order.takeTicket()
        let download = order.takeTicket()
        XCTAssertTrue(order.shouldStartCompile(ticket: download, for: "easylist"))
        XCTAssertFalse(order.shouldStartCompile(ticket: cache, for: "easylist"),
                       "the cached text was read before the download arrived")
    }

    func testCompilesStartingInTicketOrderAllStart() {
        var order = FilterListCompileOrder()
        let cache = order.takeTicket()
        let download = order.takeTicket()
        XCTAssertTrue(order.shouldStartCompile(ticket: cache, for: "easylist"))
        XCTAssertTrue(order.shouldStartCompile(ticket: download, for: "easylist"))
    }

    func testEachListIsOrderedOnItsOwn() {
        var order = FilterListCompileOrder()
        let easylist = order.takeTicket()
        let privacy = order.takeTicket()
        XCTAssertTrue(order.shouldStartCompile(ticket: privacy, for: "easyprivacy"))
        XCTAssertTrue(order.shouldStartCompile(ticket: easylist, for: "easylist"))
        XCTAssertGreaterThan(order.takeTicket(), easylist)
    }

    // MARK: - Sample

    /// Every section the parser emits: generic and specific hiding, both
    /// cosmetic exceptions, block rules with options, a network exception,
    /// a `$document` allowlist and an `$important` rule.
    static let sampleList = """
    [Adblock Plus 2.0]
    ! sample
    ##.generic-ad
    ##div[id^="banner-"]
    example.com,other.example##.specific-ad
    @@||allowed-hiding.example^$generichide
    @@||site.example^$elemhide
    /jquery.popunder.js
    ||ads.example^$script,third-party
    ||tracker.example/pixel.gif$image,domain=a.example|b.example
    ||cdn.example^$third-party,domain=~c.example|~d.example
    /banner/*/img^
    @@||ads.example/ok.js$script
    @@||allowed.example^$document
    ||evil.example^$important
    """
}

/// Encodes like the store and records where it ran: from the store's work
/// queue, so every access takes the lock.
private final class EncoderSpy: @unchecked Sendable {
    struct Call {
        let ruleCount: Int
        let onMain: Bool
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _events: [String] = []

    var calls: [Call] { lock.withLock { _calls } }
    var events: [String] { lock.withLock { _events } }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    var encode: ContentRuleStore.RuleListEncoder {
        { [self] rules in
            lock.withLock {
                _calls.append(Call(ruleCount: rules.count, onMain: Thread.isMainThread))
                _events.append("encode \(rules.count)")
            }
            guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}
