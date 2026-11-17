import GRDB
import XCTest
@testable import Detour

/// TASK-409: the Quick Detour launcher suggests from every normal profile's
/// history, names each row's profile (the profile of its newest visit) while
/// there is more than one, and opens a row in its own profile.
nonisolated final class QuickDetourCrossProfilePaletteTests: XCTestCase {

    @MainActor private final class SpyDelegate: CommandPaletteDelegate {
        var submitted: [String] = []
        func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String) { submitted.append(input) }
        func commandPalette(_ palette: CommandPaletteView, didSubmitSiteSearch url: URL) {}
        func commandPaletteDidDismiss(_ palette: CommandPaletteView) {}
    }

    private let workID = UUID()
    private let homeID = UUID()
    private let workSpace = UUID().uuidString
    private let workQuickDetour = UUID().uuidString
    private let homeSpace = UUID().uuidString

    private var window: NSWindow?
    private var palette: CommandPaletteView?
    private var spy: SpyDelegate?
    private var launcher: QuickDetourLauncher?
    private var opened: [(profile: Profile, sourceSpace: Space?, url: URL)] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaces: [UUID] = []
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
        palette?.dismiss()
        palette = nil
        window?.close()
        window = nil
        launcher?.close()
        launcher = nil
        opened.removeAll()
        for id in createdSpaces { TabStore.shared.forceRemoveSpace(id: id) }
        createdSpaces.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        try await super.tearDown()
    }

    private var bothProfiles: PaletteHistoryProfiles {
        PaletteHistoryProfiles(profiles: [
            .init(id: homeID, name: "Home", spaceIDs: [homeSpace]),
            .init(id: workID, name: "Work", spaceIDs: [workSpace, workQuickDetour]),
        ])
    }

    /// Jira only at Work (in a Quick Detour), news only at Home, and a shared
    /// page visited at Home first and at Work last.
    @MainActor private func makeHistory() throws -> HistoryDatabase {
        let db = try HistoryDatabase(dbQueue: try DatabaseQueue())
        db.recordVisit(url: "https://jira.example.com/browse/DET-1", title: "DET-1", faviconURL: nil,
                       spaceID: workQuickDetour)
        db.recordVisit(url: "https://news.example.org/", title: "News", faviconURL: nil, spaceID: homeSpace)
        db.recordVisit(url: "https://shared.example.net/", title: "Shared", faviconURL: nil, spaceID: homeSpace)
        db.recordVisit(url: "https://shared.example.net/", title: "Shared", faviconURL: nil, spaceID: workSpace)
        return db
    }

    @MainActor private func showPalette(profiles: PaletteHistoryProfiles, db: HistoryDatabase) throws
        -> CommandPaletteView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let palette = CommandPaletteView()
        palette.suggestionProvider = SuggestionProvider(db: db)
        palette.historyProfiles = profiles
        palette.historySpaceIDs = profiles.spaceIDs
        let spy = SpyDelegate()
        self.spy = spy
        palette.delegate = spy
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView))
        return palette
    }

    @MainActor private func wait(until condition: () -> Bool, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func historyURLs(_ items: [SuggestionItem]) -> [String] {
        items.compactMap { if case .historyResult(let url, _, _) = $0 { url } else { nil } }
    }

    // MARK: - The palette

    @MainActor func testEveryRowNamesTheProfileOfItsNewestVisit() throws {
        let palette = try showPalette(profiles: bothProfiles, db: try makeHistory())

        XCTAssertEqual(Set(historyURLs(palette.suggestions)),
                       ["https://jira.example.com/browse/DET-1", "https://news.example.org/",
                        "https://shared.example.net/"], "both profiles' history, a Quick Detour's visits included")
        XCTAssertEqual(palette.historyRowProfileName(for: "https://jira.example.com/browse/DET-1"), "Work")
        XCTAssertEqual(palette.historyRowProfileName(for: "https://news.example.org/"), "Home")
        XCTAssertEqual(palette.historyRowProfileName(for: "https://shared.example.net/"), "Work",
                       "visited by both: the profile that visited it last")
    }

    @MainActor func testTypedRowsAreNamedAndASubmittedRowKnowsItsProfile() throws {
        let palette = try showPalette(profiles: bothProfiles, db: try makeHistory())
        let editor = try XCTUnwrap(window?.firstResponder as? NSTextView)
        for character in "news" { editor.insertText(String(character), replacementRange: editor.selectedRange()) }
        wait(until: { self.historyURLs(palette.suggestions).contains("https://news.example.org/") },
             "the background pass lists the Home page")
        XCTAssertEqual(palette.historyRowProfileName(for: "https://news.example.org/"), "Home")

        XCTAssertEqual(palette.historyProfileID(forSubmittedInput: "https://news.example.org/"), homeID,
                       "a row submits its own address")
        XCTAssertEqual(palette.historyProfileID(forSubmittedInput: "news.example.org"), homeID,
                       "the field completed to the row's address")
        XCTAssertNil(palette.historyProfileID(forSubmittedInput: "something-else.example"))
    }

    @MainActor func testAHostRowWhoseRootWasNeverVisitedTakesItsHostsProfile() throws {
        let db = try makeHistory()
        // Only deep pages at Home: the host row's root is built, never visited.
        db.recordVisit(url: "https://www.deep.example.io/a/b", title: "Deep", faviconURL: nil, spaceID: homeSpace)
        db.recordVisit(url: "https://deepish.example.io/", title: "Other", faviconURL: nil, spaceID: workSpace)
        let owners = db.latestVisitSpaceIDs(forURLs: ["https://www.deep.example.io/", "https://nowhere.example/"],
                                            spaceIDs: bothProfiles.spaceIDs)
        XCTAssertEqual(owners, ["https://www.deep.example.io/": homeSpace],
                       "the host's newest visit, not another host sharing its prefix; an unknown host stays out")
    }

    @MainActor func testAFieldMatchingTwoRowsTakesTheRowOnScreenFirst() throws {
        let palette = try showPalette(profiles: bothProfiles, db: try makeHistory())
        // An http twin of the shared page, seen earlier and owned by Home.
        palette.noteHistoryProfiles(["http://shared.example.net/": homeID])
        XCTAssertEqual(palette.historyProfileID(forSubmittedInput: "shared.example.net"), workID,
                       "the listed https row (Work), whatever order the dictionary keeps")
        XCTAssertNil(palette.historyProfileID(forSubmittedInput: "news.example.org/X"),
                     "a path compares exactly")
    }

    @MainActor func testOneProfileShowsNoLabels() throws {
        let one = PaletteHistoryProfiles(profiles: [.init(id: workID, name: "Work",
                                                          spaceIDs: [workSpace, workQuickDetour])])
        let palette = try showPalette(profiles: one, db: try makeHistory())
        XCTAssertTrue(historyURLs(palette.suggestions).contains("https://jira.example.com/browse/DET-1"))
        XCTAssertFalse(historyURLs(palette.suggestions).contains("https://news.example.org/"),
                       "Home is not among the profiles")
        XCTAssertNil(palette.historyRowProfileName(for: "https://jira.example.com/browse/DET-1"),
                     "nothing to tell apart")
    }

    @MainActor func testAPaletteOfOneProfileNeverAttributes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        self.window = window
        let palette = CommandPaletteView()
        palette.suggestionProvider = SuggestionProvider(db: try makeHistory())
        palette.historySpaceIDs = [homeSpace]
        self.palette = palette
        palette.show(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(historyURLs(palette.suggestions).sorted(),
                       ["https://news.example.org/", "https://shared.example.net/"],
                       "an in-window palette keeps its profile's history only (TASK-209)")
        XCTAssertNil(palette.historyProfileID(forSubmittedInput: "https://news.example.org/"))
        XCTAssertNil(palette.historyRowProfileName(for: "https://news.example.org/"))
    }

    // MARK: - The profiles

    @MainActor func testNormalProfilesLeaveOutPrivateAndDeletedOnes() throws {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let home = store.addProfile(name: "Home")
        let work = store.addProfile(name: "Work")
        let gone = store.addProfile(name: "Gone")
        gone.isDeleted = true
        let privateProfile = store.ensureIncognitoProfile()
        let space = store.addSpace(name: "S", emoji: "S", colorHex: "007AFF", profileID: work.id)

        let profiles = PaletteHistoryProfiles.normalProfiles(in: store)
        let ids = profiles.profiles.map(\.id)
        XCTAssertTrue(ids.contains(home.id) && ids.contains(work.id))
        XCTAssertFalse(ids.contains(gone.id))
        XCTAssertFalse(ids.contains(privateProfile.id))
        XCTAssertEqual(profiles.profileID(forSpaceID: space.id.uuidString), work.id)
        XCTAssertEqual(profiles.profileID(forSpaceID: QuickDetour.historySpaceIDString(forProfileID: home.id)),
                       home.id, "a profile's Quick Detour visits are its own")
        XCTAssertTrue(profiles.labelsRows)
    }

    // MARK: - The launcher

    @MainActor private func makeLauncher() -> QuickDetourLauncher {
        let launcher = QuickDetourLauncher()
        launcher.openWindow = { [unowned self] profile, sourceSpace, url, _ in
            self.opened.append((profile, sourceSpace, url))
        }
        self.launcher = launcher
        return launcher
    }

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: "\(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    @MainActor func testTheLauncherSuggestsFromEveryNormalProfile() throws {
        let home = makeProfile("Home")
        let work = makeProfile("Work")
        let workSpace = TabStore.shared.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: work.id)
        createdSpaces.append(workSpace.id)

        let launcher = makeLauncher()
        launcher.show(profile: home, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)
        let scope = Set(palette.historySpaceIDs)
        XCTAssertTrue(scope.contains(workSpace.id.uuidString), "another profile's space")
        XCTAssertTrue(scope.contains(QuickDetour.historySpaceIDString(forProfileID: home.id)))
        XCTAssertEqual(palette.historyProfiles, PaletteHistoryProfiles.normalProfiles(in: .shared))
        XCTAssertFalse(scope.contains(QuickDetour.historySpaceIDString(forProfileID: TabStore.incognitoProfileID)),
                       "never the Private profile")
    }

    @MainActor func testAPrivateLauncherStillHasNoHistory() throws {
        let launcher = makeLauncher()
        launcher.show(profile: TabStore.shared.ensureIncognitoProfile(), sourceSpace: nil)
        XCTAssertEqual(launcher.palette?.historySpaceIDs, [])
        XCTAssertNil(launcher.palette?.historyProfiles)
    }

    @MainActor func testARowOpensInItsOwnProfileWithoutTheOtherProfilesSpace() throws {
        let home = makeProfile("Home")
        let work = makeProfile("Work")
        let homeSpace = TabStore.shared.addSpace(name: "Home", emoji: "H", colorHex: "007AFF", profileID: home.id)
        createdSpaces.append(homeSpace.id)

        let launcher = makeLauncher()
        launcher.show(profile: home, sourceSpace: homeSpace)
        let palette = try XCTUnwrap(launcher.palette)
        palette.noteHistoryProfiles(["https://jira.example.com/browse/DET-1": work.id])
        launcher.commandPalette(palette, didSubmitInput: "https://jira.example.com/browse/DET-1")

        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.profile === work, "the row's profile, not the frontmost window's")
        XCTAssertNil(opened.first?.sourceSpace, "Home's space names nothing in a Work window")
    }

    @MainActor func testTypedAddressesAndRowsOfTheLaunchersProfileKeepItsSpace() throws {
        let home = makeProfile("Home")
        let homeSpace = TabStore.shared.addSpace(name: "Home", emoji: "H", colorHex: "007AFF", profileID: home.id)
        createdSpaces.append(homeSpace.id)

        let launcher = makeLauncher()
        launcher.show(profile: home, sourceSpace: homeSpace)
        launcher.commandPalette(try XCTUnwrap(launcher.palette), didSubmitInput: "example.com")

        XCTAssertTrue(opened.first?.profile === home)
        XCTAssertTrue(opened.first?.sourceSpace === homeSpace)
    }

    @MainActor func testARowOfAProfileDeletedMeanwhileOpensInTheLaunchersProfile() throws {
        let home = makeProfile("Home")
        let work = makeProfile("Work")

        let launcher = makeLauncher()
        launcher.show(profile: home, sourceSpace: nil)
        let palette = try XCTUnwrap(launcher.palette)
        palette.noteHistoryProfiles(["https://jira.example.com/": work.id])
        work.isDeleted = true
        launcher.commandPalette(palette, didSubmitInput: "https://jira.example.com/")

        XCTAssertTrue(opened.first?.profile === home)
    }
}
