import XCTest
import GRDB
@testable import Detour

/// Timings for the history database's read and write paths (TASK-96 AC #6).
///
/// Env-gated, and gated *first thing* in the one test method: the fixture is
/// 55,000 visits on disk and building it twice takes seconds, which has no
/// business inside the normal suite. Run it with
///
///     env TEST_RUNNER_HISTORY_BENCH=1 xcodebuild -scheme DetourTests \
///         -configuration Debug test -only-testing:DetourTests/HistoryBenchmarkTests
///
/// `xcodebuild` passes an environment variable through to the *test host* only
/// when it is set **in xcodebuild's own environment** and prefixed
/// `TEST_RUNNER_`, which the runner strips; the same name given as a
/// command-line build setting never arrives. Every number is printed on its own
/// line behind a greppable `BENCH` prefix.
///
/// The fixture deliberately uses only API that existed before TASK-96, so the
/// same file can be run on the pre-index code to produce the "before" column.
final class HistoryBenchmarkTests: XCTestCase {

    /// Median of five, in milliseconds — median rather than mean so one
    /// scheduling hiccup does not decide the number.
    private func measure(_ label: String, runs: Int = 5, _ body: () -> Void) {
        var samples: [Double] = []
        for _ in 0 ..< runs {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        print(String(format: "BENCH %@ %.2f ms (min %.2f, max %.2f)",
                     label, samples[samples.count / 2], samples[0], samples[samples.count - 1]))
    }

    // MARK: - Fixture

    /// One profile is two spaces (`P1`, `P2`); `OTHER` stands for a second
    /// profile sharing the same URLs, which is what makes the cross-space rules
    /// cost anything.
    private static let profileSpaces = ["P1", "P2"]
    private static let otherSpace = "OTHER"

    private struct Fixture {
        let db: HistoryDatabase
        let directory: URL
        let path: String
    }

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

    private static let asciiWords = [
        "dashboard", "inbox", "project", "review", "notes", "weekly", "report", "summary",
        "design", "build", "release", "issue", "pull", "request", "docs", "guide",
        "tutorial", "reference", "changelog", "roadmap", "meeting", "agenda", "budget",
        "invoice", "analytics", "metrics", "overview", "settings", "profile", "account",
        "search", "results", "archive", "draft", "published", "team", "sprint", "backlog",
        "triage", "status",
    ]

    /// Nothing in here folds to ASCII by a plain lowercase, so every title takes
    /// the matcher's slow path — the 220 ms case TASK-93 measured.
    private static let nonASCIIWords = [
        "Résumé", "ÅNGSTRÖM", "Øresund", "Привет", "мир", "Москва", "東京", "日本語",
        "naïve", "café", "Ünicode", "Español", "Français", "Ελλάδα", "Türkçe", "北京",
        "한국어", "Português", "señor", "über",
    ]

    /// The token that appears **only** in a handful of `P1` visits' own titles —
    /// never in a URL and never in the shared `historyURL.title`. Before TASK-96
    /// the palette cannot find it at all; the History page finds it by scanning.
    private static let asciiOwnTitleToken = "zorbulax"
    private static let nonASCIIOwnTitleToken = "Зорбулакс"

    /// The token that appears only in the shared title of the one URL with 5,000
    /// visits, so a query for it makes the pre-TASK-96 palette walk all 5,000.
    private static let heavyToken = "heavyshared"

    private func makeFixture(nonASCII: Bool) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.db").path

        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        let db = try HistoryDatabase(dbQueue: queue)

        let words = nonASCII ? Self.nonASCIIWords : Self.asciiWords
        let ownToken = nonASCII ? Self.nonASCIIOwnTitleToken : Self.asciiOwnTitleToken
        var rng = Rng(seed: nonASCII ? 0xC0FFEE : 0xBEEF)

        func title(_ rng: inout Rng) -> String {
            (0 ..< (3 + rng.below(5))).map { _ in words[rng.below(words.count)] }
                .joined(separator: " ")
        }

        let urlCount = 8_000
        let visitCount = 50_000

        try queue.write { conn in
            let insertURL = try conn.makeStatement(sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, ?, NULL, 1, 0)
                """)
            let insertVisit = try conn.makeStatement(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title)
                VALUES (?, ?, ?, 0, ?)
                """)
            let updateURL = try conn.makeStatement(sql: """
                UPDATE historyURL SET title = ?, visitCount = ?, lastVisitTime = ? WHERE id = ?
                """)

            // 8,000 URLs over 500 hosts, so URL tokens repeat the way real ones
            // do. A page keeps its title across revisits — most URLs have one,
            // some two or three (a dashboard whose counter changes, an SPA) —
            // and most URLs are browsed from a single space. Both matter for the
            // size of `historyTitle`, which is one row per distinct
            // (URL, space, title); giving every visit a title of its own would
            // model a history where no page is ever revisited under the same
            // name, which is the index's worst case rather than its normal one.
            var titles: [[String]] = []
            var homes: [String] = []
            for i in 0 ..< urlCount {
                let count = rng.below(10) < 6 ? 1 : (rng.below(10) < 7 ? 3 : 2)
                titles.append((0 ..< count).map { _ in title(&rng) })
                let roll = rng.below(100)
                homes.append(roll < 45 ? "P1" : (roll < 80 ? "P2" : Self.otherSpace))
                try insertURL.execute(arguments: ["https://site\(i % 500).example/page\(i)",
                                                  titles[i][0]])
            }

            var latestTitle = [String](repeating: "", count: urlCount)
            var counts = [Int](repeating: 0, count: urlCount)
            var time = 1_000_000.0

            func visit(_ index: Int, _ space: String, _ text: String) throws {
                time += 1
                try insertVisit.execute(arguments: [Int64(index + 1), space, time, text])
                latestTitle[index] = text
                counts[index] += 1
            }

            // One visit each first, so no URL is left without one; the rest are
            // skewed towards the first 2,000 URLs the way browsing is.
            for i in 0 ..< urlCount {
                try visit(i, homes[i], titles[i][0])
            }
            for _ in urlCount ..< visitCount {
                let index = rng.below(100) < 70 ? rng.below(2_000) : rng.below(urlCount)
                // A URL is mostly browsed from its home space; 12% of visits are
                // the other profile looking at the same page.
                let space = rng.below(100) < 88
                    ? homes[index]
                    : ["P1", "P2", Self.otherSpace].filter { $0 != homes[index] }[rng.below(2)]
                try visit(index, space, titles[index][rng.below(titles[index].count)])
            }

            // Five URLs whose *own* P1 title holds a token nothing else has. The
            // later visits above already wrote a different shared title, which is
            // exactly the case TASK-96 lifts.
            for i in 0 ..< 5 {
                let index = 37 + i * 211
                time += 1
                try insertVisit.execute(arguments: [Int64(index + 1), "P1", time,
                                                    "\(ownToken) \(title(&rng))"])
                counts[index] += 1
            }

            for i in 0 ..< urlCount {
                try updateURL.execute(arguments: [latestTitle[i], counts[i], time, Int64(i + 1)])
            }

            // The pathological URL: 5,000 P1 visits, none of whose titles holds
            // the token its shared title does.
            let heavyID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES ('https://heavy.example/', ?, NULL, 5000, ?) RETURNING id
                """, arguments: ["\(Self.heavyToken) marker page", time])!
            let heavyTitles = (0 ..< 3).map { _ in title(&rng) }
            for _ in 0 ..< 5_000 {
                time += 1
                try insertVisit.execute(arguments: [heavyID, "P1", time,
                                                    heavyTitles[rng.below(3)]])
            }
        }

        return Fixture(db: db, directory: directory, path: path)
    }

    private func fileSize(_ fixture: Fixture) -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fixture.path + suffix)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    // MARK: - The run

    func testHistoryBenchmarks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HISTORY_BENCH"] == "1",
                          "history benchmarks are env-gated: TEST_RUNNER_HISTORY_BENCH=1")
        try runBenchmarks(nonASCII: false)
        try runBenchmarks(nonASCII: true)
    }

    private func runBenchmarks(nonASCII: Bool) throws {
        let tag = nonASCII ? "nonascii" : "ascii"
        let buildStart = CFAbsoluteTimeGetCurrent()
        let fixture = try makeFixture(nonASCII: nonASCII)
        print(String(format: "BENCH %@/fixture-build %.0f ms", tag,
                     (CFAbsoluteTimeGetCurrent() - buildStart) * 1000))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let db = fixture.db

        let ownToken = nonASCII ? Self.nonASCIIOwnTitleToken : Self.asciiOwnTitleToken
        let titleWord = nonASCII ? "Привет" : "dashboard"

        // Palette: one space, main thread, per keystroke.
        measure("\(tag)/palette/broad-a") { _ = db.searchHistory(query: "a", spaceID: "P1") }
        measure("\(tag)/palette/url-token") { _ = db.searchHistory(query: "site137", spaceID: "P1") }
        measure("\(tag)/palette/title-token") { _ = db.searchHistory(query: titleWord, spaceID: "P1") }
        measure("\(tag)/palette/own-title-token") { _ = db.searchHistory(query: ownToken, spaceID: "P1") }
        measure("\(tag)/palette/miss") { _ = db.searchHistory(query: "qqzzxnothing", spaceID: "P1") }
        measure("\(tag)/palette/heavy-url") { _ = db.searchHistory(query: Self.heavyToken, spaceID: "P1") }

        // History page: a whole profile, first page.
        measure("\(tag)/page/title-token") {
            _ = db.searchVisits(query: titleWord, spaceIDs: Self.profileSpaces, limit: 100)
        }
        measure("\(tag)/page/own-title-token") {
            _ = db.searchVisits(query: ownToken, spaceIDs: Self.profileSpaces, limit: 100)
        }
        measure("\(tag)/page/url-token") {
            _ = db.searchVisits(query: "site137", spaceIDs: Self.profileSpaces, limit: 100)
        }
        measure("\(tag)/page/miss") {
            _ = db.searchVisits(query: "qqzzxnothing", spaceIDs: Self.profileSpaces, limit: 100)
        }

        print("BENCH \(tag)/db-bytes \(fileSize(fixture))")
        // `historyTitle` does not exist before TASK-96, hence the optional read.
        let indexRows: Int? = try? db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyTitle") ?? 0
        }
        print("BENCH \(tag)/historyTitle-rows \(indexRows.map(String.init) ?? "n/a")")

        // Writes. `recordVisit` is fire-and-forget on GRDB's writer queue and
        // the queue is FIFO, so waiting for the last completion waits for all.
        let written = expectation(description: "1000 visits")
        let writeStart = CFAbsoluteTimeGetCurrent()
        for i in 0 ..< 1_000 {
            db.recordVisit(url: "https://fresh\(i).example/", title: "fresh page \(i) notes",
                           faviconURL: nil, spaceID: "P1") { _ in
                if i == 999 { written.fulfill() }
            }
        }
        wait(for: [written], timeout: 120)
        print(String(format: "BENCH %@/record-1000-visits %.0f ms", tag,
                     (CFAbsoluteTimeGetCurrent() - writeStart) * 1000))

        // Clear all history for the profile — the biggest single write there is.
        let cleared = expectation(description: "clear all")
        let clearStart = CFAbsoluteTimeGetCurrent()
        db.deleteVisits(spaceIDs: Self.profileSpaces, since: nil) { _ in cleared.fulfill() }
        wait(for: [cleared], timeout: 300)
        print(String(format: "BENCH %@/clear-all %.0f ms", tag,
                     (CFAbsoluteTimeGetCurrent() - clearStart) * 1000))
    }
}
