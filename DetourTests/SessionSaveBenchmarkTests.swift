import XCTest
import GRDB
@testable import Detour

/// The cost of one `TabStore.saveNow()` on a large session (TASK-149 AC #2).
///
/// Env-gated, and gated first thing in the one test method: the fixture is an
/// on-disk database rewritten a dozen times, which has no business inside the
/// normal suite. Run it with
///
///     env TEST_RUNNER_SESSION_SAVE_BENCH=1 xcodebuild -scheme DetourTests \
///         -configuration Debug test -only-testing:DetourTests/SessionSaveBenchmarkTests
///
/// (see `HistoryBenchmarkTests` for why the variable needs the `TEST_RUNNER_`
/// prefix). Every number is printed on its own line behind a greppable `BENCH`
/// prefix.
///
/// The session is built and saved through `TabStore` API that existed before
/// TASK-149, so the same file run on the earlier code gives the "before"
/// column. The database is a file, not in memory: what the change removes is
/// one commit (and its sync) per space and per profile, which an in-memory
/// database does not pay for.
final class SessionSaveBenchmarkTests: XCTestCase {

    private static let profileCount = 4
    private static let spacesPerProfile = 5          // 20 spaces
    private static let tabsPerSpace = 100            // 2,000 tabs
    private static let foldersPerSpace = 3           // 60 folders
    private static let pinnedPerSpace = 15           // 300 pinned entries, a third of them live
    private static let favoritesPerProfile = 50      // 200 favourites, a fifth of them live
    private static let interactionStateBytes = 4096

    private final class CommitCounter: TransactionObserver {
        private(set) var commits = 0
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseDidCommit(_ db: GRDB.Database) { commits += 1 }
        func databaseDidRollback(_ db: GRDB.Database) {}
    }

    /// Median of `runs`, in milliseconds — median rather than mean so one
    /// scheduling hiccup does not decide the number.
    private func measure(_ label: String, runs: Int = 9, _ body: () -> Void) {
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

    private func makeSleepingTab(spaceID: UUID, url: String, seed: Int) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab \(seed)", url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: Data(repeating: UInt8(truncatingIfNeeded: seed), count: Self.interactionStateBytes),
                   spaceID: spaceID)
    }

    func testSessionSaveBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SESSION_SAVE_BENCH"] == "1",
                          "session save benchmarks are env-gated: TEST_RUNNER_SESSION_SAVE_BENCH=1")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSaveBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("browser.db").path
        let db = try AppDatabase(dbQueue: DatabaseQueue(path: path))
        let store = TabStore(appDB: db)

        var seed = 0
        var firstTab: BrowserTab?
        for profileIndex in 0 ..< Self.profileCount {
            let profile = store.addProfile(name: "Profile \(profileIndex)")
            var firstSpace: Space?
            for spaceIndex in 0 ..< Self.spacesPerProfile {
                let space = store.addSpace(name: "Space \(profileIndex).\(spaceIndex)", emoji: "S",
                                           colorHex: "007AFF", profileID: profile.id)
                firstSpace = firstSpace ?? space
                for tabIndex in 0 ..< Self.tabsPerSpace {
                    seed += 1
                    let tab = makeSleepingTab(spaceID: space.id,
                                              url: "https://site\(seed).example.com/path/\(tabIndex)", seed: seed)
                    space.tabs.append(tab)
                    firstTab = firstTab ?? tab
                }
                var folders: [PinnedFolder] = []
                for folderIndex in 0 ..< Self.foldersPerSpace {
                    folders.append(store.addPinnedFolder(name: "Folder \(folderIndex)", in: space))
                }
                for pinnedIndex in 0 ..< Self.pinnedPerSpace {
                    seed += 1
                    let url = "https://pinned\(seed).example.com/"
                    if pinnedIndex % 3 == 0 {
                        let tab = makeSleepingTab(spaceID: space.id, url: url, seed: seed)
                        space.tabs.append(tab)
                        store.pinTab(id: tab.id, in: space)
                    } else {
                        store.pinURL(URL(string: url)!, title: "Pinned \(seed)", faviconURL: nil, in: space)
                    }
                    if pinnedIndex % 2 == 0, let entry = space.pinnedEntries.last {
                        store.movePinnedTabToFolder(tabID: entry.id, folderID: folders[pinnedIndex % folders.count].id,
                                                    in: space)
                    }
                }
            }
            let hostSpace = try XCTUnwrap(firstSpace)
            for favoriteIndex in 0 ..< Self.favoritesPerProfile {
                seed += 1
                let url = "https://favorite\(seed).example.com/"
                if favoriteIndex % 5 == 0 {
                    store.addFavorite(from: makeSleepingTab(spaceID: hostSpace.id, url: url, seed: seed),
                                      profileID: profile.id)
                } else {
                    XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: url)!, title: "Favorite \(seed)",
                                                             faviconURL: nil, favicon: nil, profileID: profile.id,
                                                             at: favoriteIndex))
                }
            }
        }
        // Structural mutations register undo actions that capture tabs; none of
        // that is part of a save.
        store.undoManager.removeAllActions()

        let spaces = store.spaces.count
        let tabs = store.spaces.reduce(0) { $0 + $1.tabs.count }
        let pinned = store.spaces.reduce(0) { $0 + $1.pinnedEntries.count }
        let folders = store.spaces.reduce(0) { $0 + $1.pinnedFolders.count }
        let favorites = store.profiles.reduce(0) { $0 + $1.favorites.count }
        print("BENCH session-save/fixture spaces=\(spaces) tabs=\(tabs) pinned=\(pinned) folders=\(folders) "
            + "favorites=\(favorites) profiles=\(store.profiles.count)")

        // The first save fills an empty database; the debounced saves that follow
        // rewrite a full one, which is the case that matters.
        let firstStart = CFAbsoluteTimeGetCurrent()
        store.saveNow()
        print(String(format: "BENCH session-save/first %.2f ms", (CFAbsoluteTimeGetCurrent() - firstStart) * 1000))

        measure("session-save/rewrite") { store.saveNow() }

        // A save after a small change, as the debounce produces while browsing.
        var flip = 0
        let tab = try XCTUnwrap(firstTab)
        measure("session-save/after-title-change") {
            flip += 1
            tab.title = "Title \(flip)"
            store.saveNow()
        }

        let counter = CommitCounter()
        db.dbQueue.add(transactionObserver: counter, extent: .databaseLifetime)
        store.saveNow()
        db.dbQueue.remove(transactionObserver: counter)
        print("BENCH session-save/commits-per-save \(counter.commits)")

        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            bytes += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        print("BENCH session-save/db-bytes \(bytes)")

        let rows = try db.dbQueue.read { conn in
            try ["space", "tab", "pinnedFolder", "pinnedTab", "favorite", "profile"].map { table in
                "\(table)=\(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)"
            }
        }
        print("BENCH session-save/rows \(rows.joined(separator: " "))")
    }
}
