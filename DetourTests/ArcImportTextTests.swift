import XCTest
@testable import Detour

/// TASK-293.3: the import window's words and the one-time offer rule;
/// TASK-293.5: the launch offer's words, its rules and its chip rows.
nonisolated final class ArcImportTextTests: XCTestCase {

    private static func tab(_ url: String) -> ArcTab {
        ArcTab(sourceKey: url, url: URL(string: url)!, title: url)
    }

    @MainActor func testSpaceDetailCountsPinnedFoldersAndTodayTabs() {
        let space = ArcSpace(
            sourceKey: "s", title: "Work", emoji: nil, colorHex: nil, profileID: .default,
            pinned: [.tab(Self.tab("https://a.invalid/")),
                     .folder(ArcFolder(sourceKey: "f", title: "F", children: [
                        .tab(Self.tab("https://b.invalid/")),
                        .folder(ArcFolder(sourceKey: "g", title: "G", children: [])),
                     ]))],
            unpinned: [.split(ArcSplit(sourceKey: "x", tabs: [Self.tab("https://c.invalid/"),
                                                              Self.tab("https://d.invalid/")]))])
        XCTAssertEqual(ArcImportText.spaceDetail(space), "2 pinned · 2 folders · 2 unpinned")
        let empty = ArcSpace(sourceKey: "e", title: "E", emoji: nil, colorHex: nil, profileID: .default,
                             pinned: [], unpinned: [.tab(Self.tab("https://e.invalid/"))])
        XCTAssertEqual(ArcImportText.spaceDetail(empty), "1 unpinned")
    }

    @MainActor func testProfileDetail() {
        XCTAssertEqual(ArcImportText.profileDetail(
            ArcProfile(id: .default, name: "D", favorites: [Self.tab("https://a.invalid/")],
                       historyFile: URL(filePath: "/h"))), "1 favorite · history")
        XCTAssertEqual(ArcImportText.profileDetail(ArcProfile(id: .export, name: "Arc", favorites: [], historyFile: nil)),
                       "Nothing but its spaces")
    }

    @MainActor func testSkippedNoteNamesWhatIsLeftOut() {
        XCTAssertNil(ArcImportText.skippedNote([]))
        XCTAssertEqual(ArcImportText.skippedNote([ArcSkippedItem(reason: .unusableURL)]),
                       "1 link isn’t a web page (like arc:// pages), so it’s left out.")
        XCTAssertEqual(ArcImportText.skippedNote([
            ArcSkippedItem(reason: .unusableURL), ArcSkippedItem(reason: .unusableURL),
            ArcSkippedItem(reason: .unsupportedKind("easel")),
            ArcSkippedItem(reason: .unsupportedKind("arcDocument")),
        ]), "2 links aren’t web pages (like arc:// pages), so they’re left out. "
            + "1 Easel and 1 Note are left out.")
        XCTAssertEqual(ArcImportText.skippedNote([ArcSkippedItem(reason: .unsupportedKind("easel"))]),
                       "1 Easel is left out.")
    }

    @MainActor func testSummaryOfAPlan() {
        var plan = ArcImportPlan()
        XCTAssertEqual(ArcImportText.summary(of: plan), ["Nothing new: Detour already has everything you chose."])
        plan.profiles = [.init(id: UUID(), name: "Default (Arc)")]
        plan.spaces = [.init(id: UUID(), name: "Home", emoji: "🏠", colorHex: "000000", profileID: UUID())]
        plan.reusedSpaceIDs = [UUID()]
        plan.pinnedEntries = [.init(id: UUID(), spaceID: UUID(), url: URL(string: "https://a.invalid/")!,
                                    title: "A", folderID: nil, sortOrder: 0)]
        plan.folders = [.init(id: UUID(), spaceID: UUID(), name: "F", parentID: nil, sortOrder: 1)]
        plan.alreadyPresent = 3
        XCTAssertEqual(ArcImportText.summary(of: plan), [
            "1 new profile: Default (Arc)",
            "1 new space: 🏠 Home",
            "Added to 1 existing space",
            "1 pinned tab in 1 new folder",
            "3 tabs and favorites Detour already had were left as they are",
        ])
    }

    @MainActor func testHistoryLines() {
        let names: [ArcProfile.ID: String] = [.default: "Default", .directory("Profile 1"): "Home"]
        XCTAssertEqual(ArcImportText.historyLines([
            .init(arcProfile: .default, added: 4312, failure: nil),
            .init(arcProfile: .directory("Profile 1"), added: nil, failure: "the disk is full"),
        ], names: names), [
            "Default history: \(4312.formatted()) visits added",
            "Home history wasn’t imported: the disk is full",
        ])
        XCTAssertEqual(ArcImportText.historyWithoutSpaceLine([.directory("Profile 1")], names: names),
                       "History of Home wasn’t imported: no space of that profile came over.")
    }

    @MainActor func testImportErrorsReadAsSentences() {
        XCTAssertEqual(ArcImportError.arcNotFound.localizedDescription, "Arc's data wasn't found on this Mac.")
        XCTAssertEqual(ArcImportError.unrecognizedFormat(path: "/x/Arc Data Export.md", reason: "no headings")
            .localizedDescription, "“Arc Data Export.md” isn't in a format Detour understands (no headings).")
    }

    // MARK: - The one-time offer

    @MainActor func testTheOfferIsShownOnceOnlyWithArcDataAndNeverInTheTestHost() throws {
        let suite = "ArcImportTextTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

        let noArc = ArcImportOffer(defaults: defaults, arcDataPresent: { false })
        XCTAssertFalse(noArc.isDue(isTestHost: false))
        XCTAssertFalse(defaults.bool(forKey: ArcImportOffer.shownKey), "no Arc: the offer is kept for later")

        let withArc = ArcImportOffer(defaults: defaults, arcDataPresent: { true })
        XCTAssertFalse(withArc.isDue(isTestHost: true), "never in the test host")
        XCTAssertTrue(withArc.isDue(isTestHost: false))
        XCTAssertTrue(withArc.isDue(isTestHost: false), "checking does not use the offer up")
        withArc.markShown()
        XCTAssertFalse(withArc.isDue(isTestHost: false), "whatever the answer, never again")
    }

    // MARK: - The launch offer (TASK-293.5)

    private static func snapshot(spaces: [ArcSpace], favorites: [ArcTab] = [], history: Bool = false) -> ArcImportSnapshot {
        ArcImportSnapshot(
            source: .installation(URL(filePath: "/Arc")),
            profiles: [ArcProfile(id: .default, name: "Default", favorites: favorites,
                                  historyFile: history ? URL(filePath: "/h") : nil)],
            spaces: spaces, skipped: [])
    }

    private static func space(_ title: String, emoji: String? = nil, pinned: [ArcSidebarNode] = [],
                              unpinned: [ArcSidebarNode] = []) -> ArcSpace {
        ArcSpace(sourceKey: title, title: title, emoji: emoji, colorHex: nil, profileID: .default,
                 pinned: pinned, unpinned: unpinned)
    }

    @MainActor func testOfferTotalsCountSpacesPinnedTabsFavoritesAndHistory() {
        let full = Self.snapshot(
            spaces: [Self.space("Home", pinned: [.tab(Self.tab("https://a.invalid/")),
                                                 .folder(ArcFolder(sourceKey: "f", title: "F", children: [
                                                     .tab(Self.tab("https://b.invalid/"))]))],
                                unpinned: [.tab(Self.tab("https://c.invalid/"))]),
                     Self.space("Work")],
            favorites: [Self.tab("https://d.invalid/")], history: true)
        XCTAssertEqual(ArcImportText.offerTotals(full), "2 spaces · 2 pinned tabs · 1 favorite · 90 days of history",
                       "unpinned tabs are not counted: Arc archives them on its own")
        XCTAssertEqual(ArcImportText.offerTotals(Self.snapshot(spaces: [Self.space("Home")])), "1 space")
    }

    @MainActor func testOfferChipTitleLeadsWithTheEmojiWhenThereIsOne() {
        XCTAssertEqual(ArcImportText.offerChipTitle(Self.space("Home", emoji: "🏠")), "🏠 Home")
        XCTAssertEqual(ArcImportText.offerChipTitle(Self.space("Work")), "Work")
        XCTAssertEqual(ArcImportText.offerMoreChipTitle(3), "+3 more")
    }

    @MainActor func testOfferFinePrintNamesArcsShutdownOnlyBeforeIt() {
        let before = ArcImportText.arcShutdown.addingTimeInterval(-60)
        XCTAssertEqual(ArcImportText.offerFinePrint(now: before),
                       "Logins, passwords and extensions stay in Arc.\nArc stops working on December 22, 2026.")
        XCTAssertEqual(ArcImportText.offerFinePrint(now: ArcImportText.arcShutdown),
                       "Logins, passwords and extensions stay in Arc.")
    }

    @MainActor func testTheOfferNeedsATabOrAFavorite() {
        XCTAssertFalse(ArcImportOffer.isWorthOffering(Self.snapshot(spaces: [Self.space("Personal")], history: true)),
                       "an Arc that was never set up has only its empty Personal space")
        XCTAssertTrue(ArcImportOffer.isWorthOffering(Self.snapshot(
            spaces: [Self.space("Home", unpinned: [.tab(Self.tab("https://a.invalid/"))])])))
        XCTAssertTrue(ArcImportOffer.isWorthOffering(Self.snapshot(
            spaces: [Self.space("Home", pinned: [.tab(Self.tab("https://a.invalid/"))])])))
        XCTAssertTrue(ArcImportOffer.isWorthOffering(Self.snapshot(
            spaces: [Self.space("Personal")], favorites: [Self.tab("https://a.invalid/")])))
    }

    @MainActor func testChipsWrapIntoRowsInOrder() {
        let layout = ArcImportOfferChipLayout.pack(widths: [40, 40, 40, 40], moreWidth: { _ in 30 },
                                                   maxWidth: 100, spacing: 10, maxRows: 2)
        XCTAssertEqual(layout, .init(rows: [[0, 1], [2, 3]], hidden: 0))
    }

    @MainActor func testChipsThatDoNotFitBecomeAMoreChipOnTheLastRow() {
        // Row 2 holds two chips, but "+N more" needs room: the second goes into it.
        let layout = ArcImportOfferChipLayout.pack(widths: [40, 40, 40, 40, 40, 40], moreWidth: { _ in 30 },
                                                   maxWidth: 100, spacing: 10, maxRows: 2)
        XCTAssertEqual(layout, .init(rows: [[0, 1], [2]], hidden: 3))
        // The more chip's width depends on the count it shows.
        var asked: [Int] = []
        let counted = ArcImportOfferChipLayout.pack(
            widths: [40, 40, 40], moreWidth: { asked.append($0); return $0 == 1 ? 45 : 60 },
            maxWidth: 120, spacing: 10, maxRows: 1)
        XCTAssertEqual(counted, .init(rows: [[0]], hidden: 2))
        XCTAssertEqual(asked, [1, 2], "asked for the 1 that did not fit, then for 2 once the row gave a chip up")
    }

    @MainActor func testAnEmptyChipListHasNoRows() {
        XCTAssertEqual(ArcImportOfferChipLayout.pack(widths: [], moreWidth: { _ in 30 }, maxWidth: 100,
                                                     spacing: 10, maxRows: 2),
                       .init(rows: [], hidden: 0))
    }

    @MainActor func testResultLinesAddTheSaveFailureSkippedItemsAndHistoryWithNowhereToGo() {
        var plan = ArcImportPlan()
        plan.favorites = [.init(id: UUID(), profileID: UUID(), url: URL(string: "https://a.invalid/")!, title: "A")]
        plan.historyWithoutSpace = [.default]
        let lines = ArcImportText.resultLines(
            of: plan, saveFailure: "disk full",
            skipped: [ArcSkippedItem(reason: .unsupportedKind("easel"), title: "E", spaceTitle: nil)],
            names: [.default: "Default"])
        XCTAssertEqual(lines, [
            "1 favorite",
            "Detour couldn’t save this yet (disk full); it tries again with the next change.",
            "1 Easel is left out.",
            "History of Default wasn’t imported: no space of that profile came over.",
        ])
        XCTAssertEqual(ArcImportText.resultNotes(
            of: plan, saveFailure: nil, skipped: [], names: [.default: "Default"]),
                       ["History of Default wasn’t imported: no space of that profile came over."],
                       "the notes are the result lines past the summary")
        XCTAssertEqual(ArcImportText.count(1195, "visit"), "\(1195.formatted()) visits", "counts follow the locale")
    }
}
