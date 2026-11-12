import XCTest
@testable import Detour

/// TASK-293.3: the import window's words and the one-time offer rule.
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
        XCTAssertEqual(ArcImportText.spaceDetail(space), "2 pinned · 2 folders · 2 Today tabs")
        let empty = ArcSpace(sourceKey: "e", title: "E", emoji: nil, colorHex: nil, profileID: .default,
                             pinned: [], unpinned: [.tab(Self.tab("https://e.invalid/"))])
        XCTAssertEqual(ArcImportText.spaceDetail(empty), "1 Today tab")
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
                       "1 link only Arc can open is left out.")
        XCTAssertEqual(ArcImportText.skippedNote([
            ArcSkippedItem(reason: .unusableURL), ArcSkippedItem(reason: .unusableURL),
            ArcSkippedItem(reason: .unsupportedKind("easel")),
            ArcSkippedItem(reason: .unsupportedKind("arcDocument")),
        ]), "2 links only Arc can open, 1 Easel and 1 Note are left out.")
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
            "Default history: 4312 visits added",
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
        XCTAssertFalse(noArc.takeOffer(isTestHost: false))
        XCTAssertFalse(defaults.bool(forKey: ArcImportOffer.shownKey), "no Arc: the offer is kept for later")

        let withArc = ArcImportOffer(defaults: defaults, arcDataPresent: { true })
        XCTAssertFalse(withArc.takeOffer(isTestHost: true), "never in the test host")
        XCTAssertTrue(withArc.takeOffer(isTestHost: false))
        XCTAssertFalse(withArc.takeOffer(isTestHost: false), "whatever the answer, never again")
    }
}
