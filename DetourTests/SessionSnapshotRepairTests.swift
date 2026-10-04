import XCTest
@testable import Detour

/// `SessionSnapshot.repairingInvalidRows()` (TASK-154): the pinned rows the
/// database would refuse are moved to the root of their space, and nothing
/// else changes. `SessionSaveFailureTests` saves and reloads the same cases
/// through `TabStore`.
final class SessionSnapshotRepairTests: XCTestCase {

    private func folder(_ id: String, parent: String? = nil, order: Int, space: String = "S") -> PinnedFolderRecord {
        PinnedFolderRecord(id: id, spaceID: space, parentFolderID: parent, name: id, isCollapsed: false, sortOrder: order)
    }

    private func entry(_ id: String, folder: String? = nil, order: Int, space: String = "S") -> PinnedTabRecord {
        PinnedTabRecord(id: id, spaceID: space, pinnedURL: "https://example.com/\(id)", pinnedTitle: id, faviconURL: nil,
                        sortOrder: order, folderID: folder, tabID: nil, splitGroupID: nil, splitFraction: nil)
    }

    private func snapshot(_ pinnedItems: [AppDatabase.SessionSnapshot.PinnedItems]) -> AppDatabase.SessionSnapshot {
        AppDatabase.SessionSnapshot(spaces: [], lastActiveSpaceID: nil, profiles: [], pinnedItems: pinnedItems, favorites: [])
    }

    private func snapshot(folders: [PinnedFolderRecord], tabs: [PinnedTabRecord] = []) -> AppDatabase.SessionSnapshot {
        snapshot([.init(spaceID: "S", folders: folders, tabs: tabs)])
    }

    /// `id parent order` of each folder, in the order given.
    private func shape(_ folders: [PinnedFolderRecord]) -> [String] {
        folders.map { "\($0.id) \($0.parentFolderID ?? "-") \($0.sortOrder)" }
    }

    /// `id folder order` of each entry, in the order given.
    private func shape(_ tabs: [PinnedTabRecord]) -> [String] {
        tabs.map { "\($0.id) \($0.folderID ?? "-") \($0.sortOrder)" }
    }

    func testAValidTreeIsLeftAsItIs() {
        // A child ahead of its parent is valid: the write orders the rows.
        let folders = [folder("child", parent: "A", order: 0), folder("A", order: 0),
                       folder("grandchild", parent: "child", order: 1), folder("B", order: 2)]
        let tabs = [entry("e1", folder: "grandchild", order: 0), entry("e2", order: 1)]

        let result = snapshot(folders: folders, tabs: tabs).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), shape(folders))
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].tabs), shape(tabs))
    }

    func testAFolderWhoseParentIsMissingMovesToTheRootAfterEverythingElse() {
        let folders = [folder("A", order: 0), folder("orphan", parent: "gone", order: 0)]
        let tabs = [entry("e1", order: 4)]

        let result = snapshot(folders: folders, tabs: tabs).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderWithMissingParent(folderID: "orphan", spaceID: "S", parentFolderID: "gone")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["A - 0", "orphan - 5"])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].tabs), shape(tabs))
    }

    func testAParentInAnotherSpaceCountsAsMissing() {
        let result = snapshot([
            .init(spaceID: "S1", folders: [folder("A", order: 0, space: "S1")], tabs: []),
            .init(spaceID: "S2", folders: [folder("B", parent: "A", order: 0, space: "S2")], tabs: []),
        ]).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderWithMissingParent(folderID: "B", spaceID: "S2", parentFolderID: "A")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["A - 0"])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[1].folders), ["B - 1"])
    }

    func testOneFolderOfACycleMovesToTheRootAndTheRestKeepTheirParent() {
        let folders = [folder("A", parent: "B", order: 0), folder("B", parent: "A", order: 0),
                       folder("C", parent: "A", order: 1)]

        let result = snapshot(folders: folders).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderInParentCycle(folderID: "A", spaceID: "S", parentFolderID: "B")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["A - 2", "B A 0", "C A 1"])
    }

    func testAFolderBelowACycleIsNotTheOneMoved() {
        // C hangs off the cycle A <-> B and comes first in the store's order.
        let folders = [folder("C", parent: "A", order: 0), folder("A", parent: "B", order: 0),
                       folder("B", parent: "A", order: 1)]

        let result = snapshot(folders: folders).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderInParentCycle(folderID: "A", spaceID: "S", parentFolderID: "B")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["C A 0", "A - 2", "B A 1"])
    }

    func testAFolderThatIsItsOwnParentMovesToTheRoot() {
        let result = snapshot(folders: [folder("A", parent: "A", order: 3)]).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderInParentCycle(folderID: "A", spaceID: "S", parentFolderID: "A")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["A - 4"])
    }

    func testEachCycleIsOpenedOnce() {
        let folders = [folder("A", parent: "B", order: 0), folder("B", parent: "C", order: 0),
                       folder("C", parent: "A", order: 0), folder("X", parent: "Y", order: 1),
                       folder("Y", parent: "X", order: 0)]

        let result = snapshot(folders: folders).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.folderInParentCycle(folderID: "A", spaceID: "S", parentFolderID: "B"),
                                        .folderInParentCycle(folderID: "X", spaceID: "S", parentFolderID: "Y")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["A - 2", "B C 0", "C A 0", "X - 3", "Y X 0"])
    }

    func testAnEntryWhoseFolderIsMissingMovesToTheRootAfterEverythingElse() {
        let folders = [folder("A", order: 2)]
        let tabs = [entry("e1", folder: "gone", order: 0), entry("e2", folder: "A", order: 0)]

        let result = snapshot(folders: folders, tabs: tabs).repairingInvalidRows()

        XCTAssertEqual(result.repairs, [.entryWithMissingFolder(entryID: "e1", spaceID: "S", folderID: "gone")])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].tabs), ["e1 - 3", "e2 A 0"])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), shape(folders))
    }

    func testSeveralRepairsTakeSuccessiveRootOrders() {
        let folders = [folder("orphan", parent: "gone", order: 0), folder("A", parent: "A", order: 7)]
        let tabs = [entry("e1", folder: "gone", order: 0)]

        let result = snapshot(folders: folders, tabs: tabs).repairingInvalidRows()

        XCTAssertEqual(result.repairs.count, 3)
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].folders), ["orphan - 8", "A - 9"])
        XCTAssertEqual(shape(result.snapshot.pinnedItems[0].tabs), ["e1 - 10"])
    }

    func testTheRestOfTheSnapshotIsUntouched() {
        var input = snapshot(folders: [folder("orphan", parent: "gone", order: 0)])
        input.lastActiveSpaceID = "S"
        input.spaces = [(SpaceRecord(id: "S", name: "Space", emoji: "S", colorHex: "000000", sortOrder: 0,
                                     selectedTabID: nil, profileID: "P"), [])]

        let result = input.repairingInvalidRows()

        XCTAssertEqual(result.snapshot.lastActiveSpaceID, "S")
        XCTAssertEqual(result.snapshot.spaces.map(\.0.id), ["S"])
        XCTAssertEqual(result.snapshot.pinnedItems.map(\.spaceID), ["S"])
    }
}
