import XCTest
import GRDB
@testable import Detour

/// TASK-293.2: carrying an Arc import plan out in a real TabStore — what lands
/// where, that it survives a relaunch, that importing again adds nothing, and
/// the history write.
nonisolated final class ArcImportTabStoreTests: XCTestCase {

    private struct Fixture {
        let appDB: AppDatabase
        let historyDB: HistoryDatabase
        let store: TabStore
        let home: Space
    }

    @MainActor private func makeFixture() throws -> Fixture {
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: appDB, historyDB: historyDB)
        let profile = store.addProfile(name: "Default")
        let home = store.addSpace(name: "Home", emoji: "🏠", colorHex: "007AFF", profileID: profile.id)
        return Fixture(appDB: appDB, historyDB: historyDB, store: store, home: home)
    }

    private static func tab(_ key: String, _ url: String) -> ArcTab {
        ArcTab(sourceKey: key, url: URL(string: url)!, title: key)
    }

    private static func snapshot(historyFile: URL? = nil) -> ArcImportSnapshot {
        ArcImportSnapshot(
            source: .installation(URL(filePath: "/arc")),
            profiles: [ArcProfile(id: .default, name: "Default", favorites: [tab("fav", "https://mail.invalid/")],
                                  historyFile: historyFile)],
            spaces: [ArcSpace(
                sourceKey: "space:W", title: "Work", emoji: "💼", colorHex: "112233", profileID: .default,
                pinned: [
                    .tab(tab("top", "https://docs.invalid/")),
                    .folder(ArcFolder(sourceKey: "F", title: "Projects", children: [
                        .tab(tab("inner", "https://a.invalid/")),
                        .folder(ArcFolder(sourceKey: "G", title: "Deep", children: [.tab(tab("deep", "https://b.invalid/"))])),
                    ])),
                    .split(ArcSplit(sourceKey: "S", tabs: [tab("left", "https://left.invalid/"),
                                                           tab("right", "https://right.invalid/")],
                                    leadingFraction: 0.4)),
                ],
                unpinned: [
                    .tab(tab("today", "https://news.invalid/")),
                    .split(ArcSplit(sourceKey: "S2", tabs: [tab("x", "https://x.invalid/"), tab("y", "https://y.invalid/")],
                                    leadingFraction: 0.6)),
                ])],
            skipped: [])
    }

    @MainActor private func importAll(_ fixture: Fixture, _ snapshot: ArcImportSnapshot = snapshot()) throws -> ArcImportPlan {
        let plan = ArcImportPlanner.plan(snapshot, options: .everything(in: snapshot),
                                         existing: fixture.store.arcImportExistingState())
        let outcome = try fixture.store.applyArcImport(plan)
        XCTAssertEqual(outcome, .saved)
        return plan
    }

    // MARK: - Apply

    @MainActor func testAnImportAddsAProfileASpaceItsTreeTabsAndFavouritesWithoutWebViews() throws {
        let fixture = try makeFixture()
        _ = try importAll(fixture)
        let store = fixture.store

        let profile = try XCTUnwrap(store.profiles.first { $0.name == "Default (Arc)" },
                                    "a new profile, its name kept apart from the existing Default")
        let work = try XCTUnwrap(store.spaces.first { $0.name == "Work" })
        XCTAssertEqual(work.profileID, profile.id)
        XCTAssertTrue(work.profile === profile)
        XCTAssertEqual(work.emoji, "💼")
        XCTAssertEqual(work.colorHex, "112233")

        let flattened = flattenPinnedTree(entries: work.pinnedEntries, folders: work.pinnedFolders,
                                          collapsedFolderIDs: [], selectedTabID: nil)
        let rows: [String] = flattened.map { item in
            switch item {
            case .entry(let entry, let depth): "\(depth):\(entry.pinnedTitle)"
            case .folder(let folder, let depth): "\(depth):[\(folder.name)]"
            case .split(_, let entries, let depth): "\(depth):split(\(entries.map(\.pinnedTitle).joined(separator: ",")))"
            }
        }
        XCTAssertEqual(rows, ["0:top", "0:[Projects]", "1:inner", "1:[Deep]", "2:deep", "0:split(left,right)"])
        XCTAssertTrue(work.pinnedEntries.allSatisfy { !$0.isLive }, "pinned entries are dormant")
        XCTAssertEqual(work.pinnedEntries.first { $0.pinnedTitle == "left" }?.splitFraction, 0.4)

        XCTAssertEqual(work.tabs.map(\.title), ["today", "x", "y"])
        XCTAssertTrue(work.tabs.allSatisfy { $0.isSleeping && $0.webView == nil }, "Today tabs come in asleep")
        XCTAssertNotNil(work.tabs[1].splitGroupID)
        XCTAssertEqual(work.tabs[1].splitGroupID, work.tabs[2].splitGroupID)
        XCTAssertEqual(work.tabs[1].splitFraction, 0.6, "a Today split keeps Arc's width share")
        XCTAssertNotNil(work.tabs[0].lastDeselectedAt, "the archive clock starts at the import")

        XCTAssertEqual(profile.favorites.map(\.title), ["fav"])
        XCTAssertFalse(profile.favorites[0].isLive)
        XCTAssertEqual(fixture.home.pinnedEntries.count, 0, "the existing space is untouched")
    }

    @MainActor func testTheImportSurvivesARelaunch() throws {
        let fixture = try makeFixture()
        _ = try importAll(fixture)

        let relaunched = TabStore(appDB: fixture.appDB, historyDB: fixture.historyDB)
        _ = relaunched.restoreSession()
        let work = try XCTUnwrap(relaunched.spaces.first { $0.name == "Work" })
        XCTAssertEqual(work.pinnedEntries.count, 5)
        XCTAssertEqual(work.pinnedFolders.map(\.name).sorted(), ["Deep", "Projects"])
        XCTAssertEqual(work.tabs.map(\.title), ["today", "x", "y"])
        let leftAndRight = work.pinnedEntries.filter { $0.splitGroupID != nil }
        XCTAssertEqual(leftAndRight.map(\.pinnedTitle).sorted(), ["left", "right"], "the pinned split survives")
        XCTAssertEqual(relaunched.profile(withID: work.profileID)?.favorites.map(\.title), ["fav"])
    }

    @MainActor func testImportingTheSameDataAgainAddsNothing() throws {
        let fixture = try makeFixture()
        _ = try importAll(fixture)
        let snapshot = Self.snapshot()
        let again = ArcImportPlanner.plan(snapshot, options: .everything(in: snapshot),
                                          existing: fixture.store.arcImportExistingState())
        XCTAssertTrue(again.profiles.isEmpty && again.spaces.isEmpty && again.folders.isEmpty
                      && again.pinnedEntries.isEmpty && again.tabs.isEmpty && again.favorites.isEmpty,
                      "everything is already there: \(again)")
        XCTAssertEqual(again.alreadyPresent, 9, "5 pinned, 3 Today tabs, 1 favourite")
    }

    @MainActor func testARenamedSpaceIsReusedAndADeletedEntryComesBack() throws {
        let fixture = try makeFixture()
        _ = try importAll(fixture)
        let work = try XCTUnwrap(fixture.store.spaces.first { $0.name == "Work" })
        let originalProfile = work.profileID
        fixture.store.updateSpace(id: work.id, name: "Day job", emoji: work.emoji, colorHex: work.colorHex,
                                  profileID: work.profileID)
        work.pinnedEntries.removeAll { $0.pinnedTitle == "top" }

        let snapshot = Self.snapshot()
        let again = ArcImportPlanner.plan(snapshot, options: .everything(in: snapshot),
                                          existing: fixture.store.arcImportExistingState())
        XCTAssertEqual(again.spaces, [], "the link takes the import back to the renamed space")
        XCTAssertEqual(again.profiles, [], "and to the profile it made the first time")
        XCTAssertEqual(again.pinnedEntries.map(\.title), ["top"], "the deleted entry comes back (user, 2026-11-12)")
        try fixture.store.applyArcImport(again)
        XCTAssertEqual(work.profileID, originalProfile)
        XCTAssertTrue(work.pinnedEntries.contains { $0.pinnedTitle == "top" })
    }

    @MainActor func testAPlanThatNoLongerFitsChangesNothing() throws {
        let fixture = try makeFixture()
        let snapshot = Self.snapshot()
        var options = ArcImportOptions.everything(in: snapshot)
        options.profileTargets[.default] = .existing(fixture.home.profileID)
        let plan = ArcImportPlanner.plan(snapshot, options: options,
                                         existing: fixture.store.arcImportExistingState())
        var stale = plan
        stale.pinnedEntries[0].folderID = UUID()
        let before = (fixture.store.spaces.count, fixture.store.profiles.count)
        XCTAssertThrowsError(try fixture.store.applyArcImport(stale)) { error in
            XCTAssertEqual(error as? TabStore.ArcImportApplyError, .staleTarget)
        }
        XCTAssertEqual(fixture.store.spaces.count, before.0)
        XCTAssertEqual(fixture.store.profiles.count, before.1)
        XCTAssertEqual(fixture.appDB.loadImportLinks(source: TabStore.arcImportSource), [:])
    }

    @MainActor func testAnEntryInAFolderOfAnotherSpaceIsRefused() throws {
        let fixture = try makeFixture()
        let homeFolder = PinnedFolder(name: "Elsewhere")
        fixture.home.pinnedFolders.append(homeFolder)
        let snapshot = Self.snapshot()
        var plan = ArcImportPlanner.plan(snapshot, options: .everything(in: snapshot),
                                         existing: fixture.store.arcImportExistingState())
        plan.pinnedEntries[0].folderID = homeFolder.id
        XCTAssertThrowsError(try fixture.store.applyArcImport(plan)) { error in
            XCTAssertEqual(error as? TabStore.ArcImportApplyError, .staleTarget)
        }
        XCTAssertFalse(fixture.store.spaces.contains { $0.name == "Work" })
    }

    @MainActor func testLinksAreRecordedAfterTheSave() throws {
        let fixture = try makeFixture()
        let plan = try importAll(fixture)
        let links = fixture.appDB.loadImportLinks(source: TabStore.arcImportSource)
        XCTAssertEqual(links["space:W"], plan.spaces.first?.id)
        XCTAssertEqual(links["profile:default"], plan.profiles.first?.id)
    }

    // MARK: - History

    @MainActor func testHistoryIsImportedUnderTheSpaceOnceAndFeedsTheReaders() async throws {
        let fixture = try makeFixture()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ArcImportTabStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let historyFile = folder.appending(path: "History")
        let now = Date().timeIntervalSince1970
        let queue = try DatabaseQueue(path: historyFile.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                    last_visit_time INTEGER NOT NULL DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL);
                CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL,
                    transition INTEGER DEFAULT 0 NOT NULL);
                INSERT INTO urls (id, url, title) VALUES (1, 'https://recipes.invalid/soup', 'Tomato soup');
                INSERT INTO urls (id, url, title) VALUES (2, 'https://ancient.invalid/', 'Old');
                """)
            for (url, daysAgo) in [(1, 1.0), (1, 2.0), (2, 400.0)] {
                try db.execute(sql: "INSERT INTO visits (url, visit_time) VALUES (?, ?)",
                               arguments: [url, ArcHistoryReader.chromiumMicroseconds(unixTime: now - daysAgo * 86_400)])
            }
        }
        try queue.close()

        let plan = try importAll(fixture, Self.snapshot(historyFile: historyFile))
        let work = try XCTUnwrap(plan.spaces.first?.id)
        XCTAssertEqual(plan.history.map(\.spaceID), [work])

        let results = await fixture.store.importArcHistory(plan.history)
        XCTAssertEqual(results.map(\.added), [2], "the visit older than Detour's retention is left out")
        let again = await fixture.store.importArcHistory(plan.history)
        XCTAssertEqual(again.map(\.added), [0], "the same visits are not added twice")

        let visits = fixture.historyDB.visits(spaceIDs: [work.uuidString], limit: 10)
        XCTAssertEqual(visits.map(\.title), ["Tomato soup", "Tomato soup"])
        XCTAssertEqual(fixture.historyDB.searchHistory(query: "tomato", spaceIDs: [work.uuidString]).map(\.url),
                       ["https://recipes.invalid/soup"], "the palette's history search finds it")
        XCTAssertEqual(fixture.historyDB.visits(spaceIDs: [fixture.home.id.uuidString], limit: 10), [],
                       "other spaces' history is untouched")
    }

    @MainActor func testImportedVisitsNeverRenameAPageDetourSawSince() async throws {
        let fixture = try makeFixture()
        let space = fixture.home.id.uuidString
        let now = Date().timeIntervalSince1970
        await withCheckedContinuation { continuation in
            fixture.historyDB.recordVisit(url: "https://page.invalid/", title: "Current title", faviconURL: nil,
                                          spaceID: space) { _ in continuation.resume() }
        }
        let added = await withCheckedContinuation { continuation in
            fixture.historyDB.importVisits([.init(url: "https://page.invalid/", title: "Old title",
                                                  visitTime: now - 86_400, isTyped: false)],
                                           spaceID: space) { continuation.resume(returning: try? $0.get()) }
        }
        XCTAssertEqual(added, 1)
        let url = fixture.historyDB.searchHistory(query: "page", spaceIDs: [space]).first
        XCTAssertEqual(url?.title, "Current title")
        XCTAssertEqual(url?.visitCount, 2)
    }
}
