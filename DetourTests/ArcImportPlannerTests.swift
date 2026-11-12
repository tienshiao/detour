import XCTest
@testable import Detour

/// TASK-293.2: the pure rules that turn an Arc snapshot and the user's choices
/// into what an import adds to Detour.
nonisolated final class ArcImportPlannerTests: XCTestCase {

    // MARK: - Fixtures

    private static func tab(_ key: String, _ url: String, _ title: String? = nil) -> ArcTab {
        ArcTab(sourceKey: key, url: URL(string: url)!, title: title ?? key)
    }

    private static func profile(_ id: ArcProfile.ID, _ name: String, favorites: [ArcTab] = [],
                                history: Bool = false) -> ArcProfile {
        ArcProfile(id: id, name: name, favorites: favorites,
                   historyFile: history ? URL(filePath: "/arc/\(name)/History") : nil)
    }

    private static func space(_ key: String, _ title: String, profile: ArcProfile.ID = .default,
                              emoji: String? = "💼", color: String? = "112233",
                              pinned: [ArcSidebarNode] = [], unpinned: [ArcSidebarNode] = []) -> ArcSpace {
        ArcSpace(sourceKey: key, title: title, emoji: emoji, colorHex: color, profileID: profile,
                 pinned: pinned, unpinned: unpinned)
    }

    private static func snapshot(profiles: [ArcProfile], spaces: [ArcSpace]) -> ArcImportSnapshot {
        ArcImportSnapshot(source: .installation(URL(filePath: "/arc")), profiles: profiles, spaces: spaces, skipped: [])
    }

    private static let empty = ArcImportExistingState(profiles: [], spaces: [], links: [:])

    /// Ids 00000000-…-000000000001, …-002, … in creation order.
    nonisolated private final class IDs {
        var next = 0
        func make() -> UUID {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
        }
    }

    @MainActor private func plan(_ snapshot: ArcImportSnapshot, options: ArcImportOptions? = nil,
                                 existing: ArcImportExistingState = empty) -> ArcImportPlan {
        let ids = IDs()
        return ArcImportPlanner.plan(snapshot, options: options ?? .everything(in: snapshot), existing: existing,
                                     presetColors: ["AAAAAA", "BBBBBB"], makeID: { ids.make() })
    }

    /// A work space with a nested folder, a split and Today tabs, on the
    /// default profile; a home space on Profile 1.
    private static func richSnapshot() -> ArcImportSnapshot {
        snapshot(
            profiles: [
                profile(.default, "Default", favorites: [tab("f1", "https://mail.invalid/")], history: true),
                profile(.directory("Profile 1"), "Home", favorites: [tab("f2", "https://music.invalid/")],
                        history: true),
                profile(.directory("Profile 2"), "Empty", history: true),
            ],
            spaces: [
                space("space:W", "Work", pinned: [
                    .tab(tab("t1", "https://docs.invalid/")),
                    .folder(ArcFolder(sourceKey: "F", title: "Projects", children: [
                        .tab(tab("t2", "https://a.invalid/")),
                        .folder(ArcFolder(sourceKey: "G", title: "Deep", children: [.tab(tab("t3", "https://b.invalid/"))])),
                    ])),
                    .split(ArcSplit(sourceKey: "S", tabs: [tab("l", "https://left.invalid/"),
                                                           tab("r", "https://right.invalid/")],
                                    leadingFraction: 0.3)),
                ], unpinned: [
                    .tab(tab("u1", "https://news.invalid/")),
                    .split(ArcSplit(sourceKey: "S2", tabs: [tab("u2", "https://x.invalid/"),
                                                            tab("u3", "https://y.invalid/"),
                                                            tab("u4", "https://z.invalid/")])),
                ]),
                space("space:H", "Home", profile: .directory("Profile 1"), emoji: nil, color: nil),
            ])
    }

    // MARK: - Profiles and spaces

    @MainActor func testEachArcProfileGetsANewProfileNamedAfterItUnlessTaken() {
        let existing = ArcImportExistingState(
            profiles: [.init(id: UUID(), name: "Default", favoriteURLs: [])], spaces: [], links: [:])
        let result = plan(Self.richSnapshot(), existing: existing)
        XCTAssertEqual(result.profiles.map(\.name), ["Default (Arc)", "Home"],
                       "a taken name gets (Arc); a profile bringing nothing (no space, no favourite) is not made")
        XCTAssertEqual(result.historyWithoutSpace, [.directory("Profile 2")])
        XCTAssertEqual(result.links.filter { $0.kind == .profile }.map(\.sourceKey),
                       ["profile:default", "profile:dir:Profile 1"])
    }

    @MainActor func testUniqueProfileNames() {
        XCTAssertEqual(ArcImportPlanner.uniqueProfileName("Work", taken: ["Home"]), "Work")
        XCTAssertEqual(ArcImportPlanner.uniqueProfileName("Work", taken: ["work"]), "Work (Arc)")
        XCTAssertEqual(ArcImportPlanner.uniqueProfileName("Work", taken: ["Work", "Work (Arc)"]), "Work (Arc 2)")
    }

    @MainActor func testSpacesKeepNameEmojiAndColourWithDefaults() {
        let result = plan(Self.richSnapshot())
        XCTAssertEqual(result.spaces.map(\.name), ["Work", "Home"])
        XCTAssertEqual(result.spaces.map(\.emoji), ["💼", ArcImportPlanner.defaultEmoji])
        XCTAssertEqual(result.spaces.map(\.colorHex), ["112233", "BBBBBB"],
                       "no Arc colour takes a preset by the space's position")
        XCTAssertEqual(result.spaces.map(\.profileID), result.profiles.map(\.id))
    }

    @MainActor func testAnExistingTargetProfileIsUsedAndASameNamedSpaceInItIsReused() {
        let target = UUID(), work = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: target, name: "Mine", favoriteURLs: [])],
            spaces: [.init(id: work, name: "work", profileID: target, folders: [], entries: [], tabURLs: [])],
            links: [:])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.profileTargets[.default] = .existing(target)
        let result = plan(Self.richSnapshot(), options: options, existing: existing)
        XCTAssertFalse(result.spaces.contains { $0.name == "Work" }, "the same-named space is reused")
        XCTAssertEqual(result.reusedSpaceIDs, [work])
        XCTAssertTrue(result.pinnedEntries.allSatisfy { $0.spaceID == work })
        XCTAssertEqual(result.profiles.map(\.name), ["Home"])
    }

    @MainActor func testAReImportGoesBackToTheLinkedProfileAndSpaceEvenAfterARename() {
        let profileID = UUID(), spaceID = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: profileID, name: "Renamed profile", favoriteURLs: [])],
            spaces: [.init(id: spaceID, name: "Renamed space", profileID: profileID, folders: [], entries: [],
                           tabURLs: [])],
            links: ["profile:default": profileID, "space:W": spaceID, "space:H": UUID()])
        let result = plan(Self.richSnapshot(), existing: existing)
        XCTAssertEqual(result.reusedSpaceIDs, [spaceID])
        XCTAssertEqual(result.spaces.map(\.name), ["Home"], "a link to a space that is gone is ignored")
        XCTAssertEqual(result.profiles.map(\.name), ["Home"])
        XCTAssertEqual(result.favorites.first?.profileID, profileID)
    }

    @MainActor func testChoosingNewProfileOverridesALink() {
        let profileID = UUID()
        let existing = ArcImportExistingState(profiles: [.init(id: profileID, name: "Old", favoriteURLs: [])],
                                              spaces: [], links: ["profile:default": profileID])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.profileTargets[.default] = .newProfile
        XCTAssertEqual(plan(Self.richSnapshot(), options: options, existing: existing).profiles.map(\.name),
                       ["Default", "Home"])
    }

    @MainActor func testALinkedSpaceInAnotherProfileIsNotReusedWhenTheProfileGoesElsewhere() {
        let oldProfile = UUID(), linkedSpace = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: oldProfile, name: "Old", favoriteURLs: [])],
            spaces: [.init(id: linkedSpace, name: "Work", profileID: oldProfile, folders: [], entries: [],
                           tabURLs: [])],
            links: ["profile:default": oldProfile, "space:W": linkedSpace])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.profileTargets[.default] = .newProfile
        let result = plan(Self.richSnapshot(), options: options, existing: existing)
        let newDefault = result.profiles.first { $0.name == "Default" }?.id
        XCTAssertNotNil(newDefault)
        XCTAssertFalse(result.reusedSpaceIDs.contains(linkedSpace))
        XCTAssertEqual(result.spaces.first { $0.name == "Work" }?.profileID, newDefault)
        XCTAssertFalse(result.pinnedEntries.contains { $0.spaceID == linkedSpace })
    }

    // MARK: - Pinned tree

    @MainActor func testPinnedTreeKeepsOrderNestingAndSplits() {
        let result = plan(Self.richSnapshot())
        let work = result.spaces[0].id
        let projects = result.folders.first { $0.name == "Projects" }!
        let deep = result.folders.first { $0.name == "Deep" }!
        XCTAssertEqual(projects.parentID, nil)
        XCTAssertEqual(deep.parentID, projects.id)
        XCTAssertTrue(result.folders.allSatisfy { $0.spaceID == work })

        let topLevel = result.pinnedEntries.filter { $0.folderID == nil }
        XCTAssertEqual(topLevel.map(\.title), ["t1", "l", "r"])
        XCTAssertEqual(topLevel.map(\.sortOrder), [0, 2, 3], "the folder holds order 1 between them")
        XCTAssertEqual(projects.sortOrder, 1)
        XCTAssertEqual(result.pinnedEntries.filter { $0.folderID == projects.id }.map(\.title), ["t2"])
        XCTAssertEqual(deep.sortOrder, 1, "orders count per level: t2 is 0, Deep 1")
        XCTAssertEqual(result.pinnedEntries.filter { $0.folderID == deep.id }.map(\.title), ["t3"])

        let split = topLevel.filter { $0.splitGroupID != nil }
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(Set(split.map(\.splitGroupID)).count, 1)
        XCTAssertEqual(split.map(\.splitFraction), [0.3, 0.3])
    }

    @MainActor func testASplitOfThreeKeepsTwoAndAddsTheRestPlain() {
        let snapshot = Self.snapshot(profiles: [Self.profile(.default, "D")], spaces: [
            Self.space("space:S", "S", pinned: [.split(ArcSplit(sourceKey: "X", tabs: [
                Self.tab("a", "https://a.invalid/"), Self.tab("b", "https://b.invalid/"),
                Self.tab("c", "https://c.invalid/"),
            ], leadingFraction: 0.33))]),
        ])
        let entries = plan(snapshot).pinnedEntries
        XCTAssertEqual(entries.map(\.title), ["a", "b", "c"])
        XCTAssertNotNil(entries[0].splitGroupID)
        XCTAssertEqual(entries[0].splitGroupID, entries[1].splitGroupID)
        XCTAssertNil(entries[2].splitGroupID)
        XCTAssertNil(entries[0].splitFraction, "a share of three panes says nothing about two")
    }

    @MainActor func testImportingIntoASpaceAppendsAfterItsItemsAndSkipsWhatItHas() {
        let spaceID = UUID(), folderID = UUID(), profileID = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: profileID, name: "Default", favoriteURLs: ["https://mail.invalid/"])],
            spaces: [.init(id: spaceID, name: "Work", profileID: profileID,
                           folders: [.init(id: folderID, name: "Projects", parentID: nil, sortOrder: 4)],
                           entries: [.init(url: "https://docs.invalid/", folderID: nil, sortOrder: 7),
                                     .init(url: "https://a.invalid/", folderID: folderID, sortOrder: 0)],
                           tabURLs: ["https://news.invalid/"])],
            links: ["profile:default": profileID])
        let result = plan(Self.richSnapshot(), existing: existing)
        XCTAssertEqual(result.reusedSpaceIDs, [spaceID])
        XCTAssertFalse(result.folders.contains { $0.name == "Projects" }, "the existing folder is reused")
        let deep = result.folders.first { $0.name == "Deep" }!
        XCTAssertEqual(deep.parentID, folderID)
        XCTAssertEqual(deep.sortOrder, 1, "after the folder's existing entry")
        XCTAssertEqual(result.pinnedEntries.filter { $0.spaceID == spaceID && $0.folderID == nil }.map(\.sortOrder),
                       [8, 9], "the split goes after the top level's highest order")
        XCTAssertFalse(result.pinnedEntries.contains { $0.url.absoluteString == "https://docs.invalid/" })
        XCTAssertFalse(result.favorites.contains { $0.url.absoluteString == "https://mail.invalid/" })
        XCTAssertFalse(result.tabs.contains { $0.url.absoluteString == "https://news.invalid/" })
        XCTAssertEqual(result.alreadyPresent, 4, "docs, a, the mail favourite and the news tab")
    }

    @MainActor func testASplitWithAPaneAlreadyPinnedComesInPlain() {
        let spaceID = UUID(), profileID = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: profileID, name: "D", favoriteURLs: [])],
            spaces: [.init(id: spaceID, name: "Work", profileID: profileID, folders: [],
                           entries: [.init(url: "https://left.invalid/", folderID: nil, sortOrder: 0)], tabURLs: [])],
            links: ["profile:default": profileID, "space:W": spaceID])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.spaces = ["space:W"]
        let result = plan(Self.richSnapshot(), options: options, existing: existing)
        let right = result.pinnedEntries.first { $0.title == "r" }
        XCTAssertNotNil(right)
        XCTAssertNil(right?.splitGroupID)
    }

    // MARK: - Today tabs, favourites, history

    @MainActor func testTodayTabsBecomeTabsWithTheirSplitPair() {
        let tabs = plan(Self.richSnapshot()).tabs
        XCTAssertEqual(tabs.map(\.title), ["u1", "u2", "u3", "u4"])
        XCTAssertNil(tabs[0].splitGroupID)
        XCTAssertNotNil(tabs[1].splitGroupID)
        XCTAssertEqual(tabs[1].splitGroupID, tabs[2].splitGroupID)
        XCTAssertNil(tabs[3].splitGroupID)
    }

    @MainActor func testATodayTabAlreadyPinnedInTheSpaceIsLeftOut() {
        // An export lists top-level pinned tabs among the Today tabs; after a
        // direct import they are already pinned in the space.
        let spaceID = UUID(), profileID = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: profileID, name: "D", favoriteURLs: [])],
            spaces: [.init(id: spaceID, name: "Work", profileID: profileID, folders: [],
                           entries: [.init(url: "https://news.invalid/", folderID: UUID(), sortOrder: 0)],
                           tabURLs: [])],
            links: ["profile:default": profileID, "space:W": spaceID])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.spaces = ["space:W"]
        options.includePinned = false
        let result = plan(Self.richSnapshot(), options: options, existing: existing)
        XCTAssertEqual(result.tabs.map(\.title), ["u2", "u3", "u4"], "news is pinned there, in a folder")
    }

    @MainActor func testATodayTabPinnedInTheSameImportIsDroppedButNotCountedAsPresent() {
        let snapshot = Self.snapshot(profiles: [Self.profile(.default, "D")], spaces: [
            Self.space("space:S", "S", pinned: [.tab(Self.tab("p", "https://both.invalid/"))],
                       unpinned: [.tab(Self.tab("t", "https://both.invalid/")),
                                  .tab(Self.tab("u", "https://only.invalid/"))]),
        ])
        let result = plan(snapshot)
        XCTAssertEqual(result.pinnedEntries.map(\.title), ["p"])
        XCTAssertEqual(result.tabs.map(\.title), ["u"])
        XCTAssertEqual(result.alreadyPresent, 0, "Detour had nothing before this import")
    }

    @MainActor func testFavouritesGoToTheirProfile() {
        let result = plan(Self.richSnapshot())
        XCTAssertEqual(result.favorites.map(\.title), ["f1", "f2"])
        XCTAssertEqual(result.favorites.map(\.profileID), result.profiles.map(\.id))
    }

    @MainActor func testHistoryIsFiledUnderTheFirstImportedSpaceOfItsProfile() {
        let result = plan(Self.richSnapshot())
        XCTAssertEqual(result.history.map(\.arcProfile), [.default, .directory("Profile 1")])
        XCTAssertEqual(result.history.map(\.spaceID), result.spaces.map(\.id))
    }

    @MainActor func testHistoryOfAProfileWithoutAnImportedSpaceUsesItsDetourProfilesSpace() {
        let target = UUID(), other = UUID()
        let existing = ArcImportExistingState(
            profiles: [.init(id: target, name: "Mine", favoriteURLs: [])],
            spaces: [.init(id: other, name: "Elsewhere", profileID: target, folders: [], entries: [], tabURLs: [])],
            links: [:])
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.profileTargets[.directory("Profile 2")] = .existing(target)
        let result = plan(Self.richSnapshot(), options: options, existing: existing)
        XCTAssertEqual(result.history.first { $0.arcProfile == .directory("Profile 2") }?.spaceID, other)
        XCTAssertEqual(result.historyWithoutSpace, [])
    }

    // MARK: - Choices

    @MainActor func testSwitchesAndSelectionsLeaveThingsOut() {
        var options = ArcImportOptions.everything(in: Self.richSnapshot())
        options.includePinned = false
        options.includeTodayTabs = false
        options.includeFavorites = false
        options.includeHistory = false
        options.spaces = ["space:W"]
        let result = plan(Self.richSnapshot(), options: options)
        XCTAssertEqual(result.spaces.map(\.name), ["Work"])
        XCTAssertEqual(result.profiles.map(\.name), ["Default"],
                       "Home brings nothing once its space and favourites are left out")
        XCTAssertEqual(result.pinnedEntries, [])
        XCTAssertEqual(result.folders, [])
        XCTAssertEqual(result.tabs, [])
        XCTAssertEqual(result.favorites, [])
        XCTAssertEqual(result.history, [])

        var noProfile = ArcImportOptions.everything(in: Self.richSnapshot())
        noProfile.profiles = [.directory("Profile 1")]
        XCTAssertEqual(plan(Self.richSnapshot(), options: noProfile).spaces.map(\.name), ["Home"],
                       "a space whose profile is left out is left out")
    }

    @MainActor func testAnEmptySnapshotPlansNothing() {
        XCTAssertTrue(plan(Self.snapshot(profiles: [], spaces: [])).isEmpty)
    }
}
