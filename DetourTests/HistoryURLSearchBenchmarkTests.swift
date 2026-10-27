import XCTest
import GRDB
@testable import Detour

/// Timings for `HistoryDatabase.searchURLs`, the query behind
/// `chrome.history.search`, on a large history (TASK-153), and for how long a
/// palette read waits behind one.
///
/// Env-gated like `HistoryBenchmarkTests`, and for the same reason: the
/// fixture is 300,000 visits on disk. Run it with
///
///     env TEST_RUNNER_HISTORY_SEARCH_BENCH=1 xcodebuild -scheme DetourTests \
///         -configuration Debug test -only-testing:DetourTests/HistoryURLSearchBenchmarkTests
///
/// Every number is printed on its own line behind a greppable `BENCH` prefix.
/// The file uses only API that existed before TASK-153 changed the query, so
/// the same file produces the "before" and the "after" column.
///
/// The history is built straight into a temp-file database in batched
/// transactions, and everything about a URL (its home profile, its titles) is
/// derived from its index, so the fixture holds no per-URL or per-visit arrays.
final class HistoryURLSearchBenchmarkTests: XCTestCase {

    // MARK: - Measuring

    private struct Sample {
        var median: Double
        var min: Double
        var max: Double
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private func summary(_ samples: [Double]) -> Sample {
        let sorted = samples.sorted()
        return Sample(median: sorted[sorted.count / 2], min: sorted[0], max: sorted[sorted.count - 1])
    }

    /// Median of five, in milliseconds, with the number of rows the call
    /// returned so a fast number cannot be an empty answer in disguise.
    @discardableResult
    private func measure(_ label: String, runs: Int = 5, _ body: () -> Int) -> Sample {
        var rows = 0
        let sample = summary((0 ..< runs).map { _ in milliseconds { rows = body() } })
        print(String(format: "BENCH %@ %.2f ms (min %.2f, max %.2f) rows %d",
                     label, sample.median, sample.min, sample.max, rows))
        return sample
    }

    /// How long a palette read, made from this thread as the main thread makes
    /// it, takes when it is issued just after `search` started on another
    /// thread. History is one serial `DatabaseQueue`, so the read waits for
    /// the search to finish; what is printed is the read's whole duration,
    /// wait included.
    ///
    /// "Just after" is one millisecond after the other thread reported it is
    /// about to call, so the search has the queue by the time the read asks
    /// for it. A run where the read won the race shows up as the minimum.
    private func measureWait(_ label: String, runs: Int = 5,
                             behind search: @escaping () -> Void, read: () -> Void) {
        var samples: [Double] = []
        for _ in 0 ..< runs {
            let starting = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                starting.signal()
                search()
                finished.signal()
            }
            starting.wait()
            usleep(1_000)
            samples.append(milliseconds(read))
            finished.wait()
        }
        let sample = summary(samples)
        print(String(format: "BENCH %@ %.2f ms (min %.2f, max %.2f)",
                     label, sample.median, sample.min, sample.max))
    }

    // MARK: - Fixture

    /// Three profiles. A is the everyday one and owns most of the history, B
    /// is a second large one, C owns a sliver.
    private static let profileA = ["A1", "A2"]
    private static let profileB = ["B1"]
    private static let profileC = ["C1", "C2"]

    private static let urlCount = 40_000
    private static let visitCount = 300_000
    private static let hostCount = 2_000
    private static let batchSize = 25_000

    /// The newest visit's time. Fixed, so the corpus and the "last 24 hours"
    /// window are the same on every run.
    private static let now = 1_800_000_000.0
    /// Visits are spread evenly over the 90 days history is kept for.
    private static let span = 90.0 * 86_400

    /// Deterministic, so the before/after columns describe the same corpus.
    private struct Rng {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private static let words = [
        "dashboard", "inbox", "project", "review", "notes", "weekly", "report", "summary",
        "design", "build", "release", "issue", "pull", "request", "docs", "guide",
        "tutorial", "reference", "changelog", "roadmap", "meeting", "agenda", "budget",
        "invoice", "analytics", "metrics", "overview", "settings", "profile", "account",
        "search", "results", "archive", "draft", "published", "team", "sprint", "backlog",
        "triage", "status",
    ]

    /// The profile most of a URL's visits come from: 55% A, 35% B, 10% C.
    private static func homeProfile(ofURL index: Int) -> [String] {
        var rng = Rng(seed: UInt64(index) &* 31 &+ 7)
        let roll = rng.below(100)
        return roll < 55 ? profileA : (roll < 90 ? profileB : profileC)
    }

    /// How many titles a URL goes by: mostly one, some two or three.
    private static func titleVariants(ofURL index: Int) -> Int {
        var rng = Rng(seed: UInt64(index) &* 131 &+ 3)
        return rng.below(10) < 6 ? 1 : (rng.below(10) < 7 ? 3 : 2)
    }

    private static func title(ofURL index: Int, variant: Int) -> String {
        var rng = Rng(seed: UInt64(index) &* 8 &+ UInt64(variant))
        return (0 ..< (3 + rng.below(4))).map { _ in words[rng.below(words.count)] }
            .joined(separator: " ")
    }

    private struct Fixture {
        let db: HistoryDatabase
        let directory: URL
    }

    /// 300,000 visits of 40,000 URLs, oldest first.
    ///
    /// - The first 40,000 visits are one per URL, so no URL is without one;
    ///   the rest are skewed towards 5,000 hot URLs, the way browsing is.
    /// - 88% of a URL's visits come from its home profile, the rest are
    ///   another profile looking at the same page — what makes the shared
    ///   `historyURL` row differ from a profile's own view of it.
    /// - URL 0 is the page a profile lives in (a mail inbox): 2% of all
    ///   visits, all from `A1`, under forty titles.
    /// - The oldest fifth of the visits has no title of its own, as visits
    ///   recorded before per-visit titles existed (TASK-91) do; that is the
    ///   case that costs the extension title rule a probe per visit.
    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-search-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("history.db").path,
                                      configuration: config)
        let db = try HistoryDatabase(dbQueue: queue)

        var done = 0
        while done < Self.urlCount {
            let end = min(done + Self.batchSize, Self.urlCount)
            try queue.write { conn in
                let insertURL = try conn.makeStatement(sql: """
                    INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                    VALUES (?, ?, NULL, 1, 0)
                    """)
                for i in done ..< end {
                    let url = i == 0 ? "https://mail.example/inbox"
                        : "https://site\(i % Self.hostCount).example/page\(i)"
                    try insertURL.execute(arguments: [url, Self.title(ofURL: i, variant: 0)])
                }
            }
            done = end
        }

        let all = Self.profileA + Self.profileB + Self.profileC
        let step = Self.span / Double(Self.visitCount)
        let legacyCount = Self.visitCount / 5
        var rng = Rng(seed: 0x153)
        done = 0
        while done < Self.visitCount {
            let end = min(done + Self.batchSize, Self.visitCount)
            try queue.write { conn in
                let insertVisit = try conn.makeStatement(sql: """
                    INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title)
                    VALUES (?, ?, ?, ?, ?)
                    """)
                for n in done ..< end {
                    let time = Self.now - Self.span + Double(n + 1) * step
                    let index: Int
                    if n < Self.urlCount {
                        index = n
                    } else if rng.below(100) < 2 {
                        index = 0
                    } else {
                        index = rng.below(100) < 70 ? rng.below(5_000) : rng.below(Self.urlCount)
                    }
                    let space: String
                    let title: String?
                    if index == 0 {
                        space = "A1"
                        title = n < legacyCount ? nil : "Inbox (\(rng.below(40))) - me@home"
                    } else {
                        let home = Self.homeProfile(ofURL: index)
                        if rng.below(100) < 88 {
                            space = home[rng.below(10) < 7 ? 0 : home.count - 1]
                        } else {
                            let others = all.filter { !home.contains($0) }
                            space = others[rng.below(others.count)]
                        }
                        let variant = rng.below(Self.titleVariants(ofURL: index))
                        title = n < legacyCount ? nil : Self.title(ofURL: index, variant: variant)
                    }
                    try insertVisit.execute(arguments: [Int64(index + 1), space, time,
                                                        rng.below(10) == 0, title])
                }
            }
            done = end
        }

        // The shared row as the real upsert leaves it: every profile's visits
        // counted, the newest visit's time.
        try queue.write { conn in
            try conn.execute(sql: """
                UPDATE historyURL SET
                    visitCount = (SELECT COUNT(*) FROM historyVisit v WHERE v.urlID = historyURL.id),
                    lastVisitTime = (SELECT MAX(v.visitTime) FROM historyVisit v WHERE v.urlID = historyURL.id)
                """)
        }
        return Fixture(db: db, directory: directory)
    }

    // MARK: - The run

    func testExtensionHistorySearchBenchmarks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HISTORY_SEARCH_BENCH"] == "1",
                          "history search benchmarks are env-gated: TEST_RUNNER_HISTORY_SEARCH_BENCH=1")

        let buildStart = CFAbsoluteTimeGetCurrent()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let db = fixture.db
        print(String(format: "BENCH fixture-build %.0f ms", (CFAbsoluteTimeGetCurrent() - buildStart) * 1000))

        let perSpace = try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT spaceID, COUNT(*) AS visits, COUNT(DISTINCT urlID) AS urls
                FROM historyVisit GROUP BY spaceID ORDER BY spaceID
                """).map { "\($0["spaceID"] as String) \($0["visits"] as Int)/\($0["urls"] as Int)" }
        }
        print("BENCH fixture visits/urls per space: \(perSpace.joined(separator: ", "))")
        let inbox = try db.dbQueue.read { conn in
            try Row.fetchOne(conn, sql: """
                SELECT COUNT(*) AS visits, COUNT(*) - COUNT(title) AS untitled
                FROM historyVisit WHERE urlID = 1
                """).map { "\($0["visits"] as Int) visits, \($0["untitled"] as Int) without a title" }
        }
        print("BENCH fixture inbox URL: \(inbox ?? "missing")")

        let a = Self.profileA
        let b = Self.profileB
        let c = Self.profileC
        let dayAgo = Self.now - 86_400
        let everything = Int(Int32.max)

        // Empty text: what `chrome.history.search({ text: '' })` asks for.
        // "all" is no lower bound (an explicit `startTime: 0`), "24h" is the
        // last day of the history.
        measure("empty/all/limit100/A") { db.searchURLs(query: "", spaceIDs: a, limit: 100).count }
        measure("empty/all/limit100/C-sliver") { db.searchURLs(query: "", spaceIDs: c, limit: 100).count }
        measure("empty/24h/limit100/A") { db.searchURLs(query: "", spaceIDs: a, from: dayAgo, limit: 100).count }
        measure("empty/24h/limit100/C-sliver") {
            db.searchURLs(query: "", spaceIDs: c, from: dayAgo, limit: 100).count
        }
        measure("empty/all/limit1000/A") { db.searchURLs(query: "", spaceIDs: a, limit: 1_000).count }
        measure("empty/all/limit10000/A") { db.searchURLs(query: "", spaceIDs: a, limit: 10_000).count }
        measure("empty/all/unlimited/A", runs: 3) { db.searchURLs(query: "", spaceIDs: a, limit: everything).count }

        // A typed query, same shapes.
        measure("text/url-token/all/A") { db.searchURLs(query: "site137", spaceIDs: a, limit: 100).count }
        measure("text/title-word/all/A") { db.searchURLs(query: "dashboard", spaceIDs: a, limit: 100).count }
        measure("text/title-word/24h/A") {
            db.searchURLs(query: "dashboard", spaceIDs: a, from: dayAgo, limit: 100).count
        }
        measure("text/every-url/all/A") { db.searchURLs(query: "example", spaceIDs: a, limit: 100).count }
        measure("text/every-url/24h/A") {
            db.searchURLs(query: "example", spaceIDs: a, from: dayAgo, limit: 100).count
        }
        measure("text/miss/all/A") { db.searchURLs(query: "qqzzxnothing", spaceIDs: a, limit: 100).count }
        // The same query in the profiles that never visited the inbox URL:
        // what the title rule's probe over that URL's visits costs A.
        measure("text/every-url/all/B") { db.searchURLs(query: "example", spaceIDs: b, limit: 100).count }
        measure("text/every-url/all/C-sliver") { db.searchURLs(query: "example", spaceIDs: c, limit: 100).count }

        // The palette's reads, alone: what Cmd+T and a keystroke cost with
        // nothing else on the queue. Over the whole profile, as the palette
        // reads it since TASK-209.
        measure("palette/recent/alone") { db.recentHistory(spaceIDs: a).count }
        measure("palette/search-a/alone") { db.searchHistory(query: "a", spaceIDs: a).count }

        // The same reads issued while an extension's search holds the queue.
        measureWait("palette/recent/behind-empty-all-limit100") {
            _ = db.searchURLs(query: "", spaceIDs: a, limit: 100)
        } read: { _ = db.recentHistory(spaceIDs: a) }
        measureWait("palette/recent/behind-empty-24h-limit100") {
            _ = db.searchURLs(query: "", spaceIDs: a, from: dayAgo, limit: 100)
        } read: { _ = db.recentHistory(spaceIDs: a) }
        measureWait("palette/recent/behind-empty-all-unlimited", runs: 3) {
            _ = db.searchURLs(query: "", spaceIDs: a, limit: everything)
        } read: { _ = db.recentHistory(spaceIDs: a) }
        measureWait("palette/search-a/behind-empty-all-limit100") {
            _ = db.searchURLs(query: "", spaceIDs: a, limit: 100)
        } read: { _ = db.searchHistory(query: "a", spaceIDs: a) }
        measureWait("palette/recent/behind-text-every-url-all") {
            _ = db.searchURLs(query: "example", spaceIDs: a, limit: 100)
        } read: { _ = db.recentHistory(spaceIDs: a) }
    }
}
