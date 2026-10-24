import XCTest
import GRDB
@testable import Detour

/// TASK-190: tab thumbnails for the sidebar hover card, cached on disk so they
/// survive a relaunch. Keyed by the row the user hovers: a pinned entry's or
/// favourite's own id (stable while the tile is dormant), else the tab id.
final class TabThumbnailTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabThumbnailTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeImage(width: Int = 480, height: Int = 300) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: width / 2, height: height / 2))
        image.addRepresentation(rep)
        return image
    }

    private func loadedImage(_ cache: TabThumbnailCache, _ key: UUID) -> NSImage? {
        let loaded = expectation(description: "image loaded")
        var result: NSImage?
        cache.image(for: key) { image in
            result = image
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        return result
    }

    // MARK: - Cache

    func testAStoredThumbnailIsReadBackFromDisk() throws {
        let key = UUID()
        let writer = TabThumbnailCache(directory: directory)
        writer.store(makeImage(), for: key)
        writer.flush()
        // A new cache over the same folder: what a relaunch reads.
        let cache = TabThumbnailCache(directory: directory)

        let image = try XCTUnwrap(loadedImage(cache, key))
        XCTAssertEqual(image.representations.first?.pixelsWide, 480, "stored at the capture's pixel width")
    }

    func testAKeyWithNoFileReadsNil() {
        XCTAssertNil(loadedImage(TabThumbnailCache(directory: directory), UUID()))
    }

    func testTheSweepRemovesOrphansAndKeepsLiveKeys() throws {
        let cache = TabThumbnailCache(directory: directory)
        let live = UUID(), orphan = UUID()
        cache.store(makeImage(), for: live)
        cache.store(makeImage(), for: orphan)
        cache.flush()

        cache.sweep(keeping: [live], olderThan: Date().addingTimeInterval(1))
        cache.flush()

        XCTAssertNotNil(loadedImage(cache, live))
        XCTAssertNil(loadedImage(cache, orphan))
    }

    func testTheOrphanRule() {
        let live = UUID(), orphan = UUID(), fresh = UUID()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let files: [String: Date] = [
            "\(live.uuidString).jpg": Date(timeIntervalSince1970: 10),
            "\(orphan.uuidString).jpg": Date(timeIntervalSince1970: 10),
            "\(fresh.uuidString).jpg": Date(timeIntervalSince1970: 2_000),
            "notes.txt": Date(timeIntervalSince1970: 10),
        ]
        XCTAssertEqual(TabThumbnailCache.orphans(in: files, keeping: [live], olderThan: cutoff),
                       ["\(orphan.uuidString).jpg"],
                       "a file written after the sweep started may belong to a tab the live set missed; "
                       + "files that are not thumbnails are left alone")
    }

    // MARK: - Keys

    private func makeStore() throws -> (TabStore, Space) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: DatabaseQueue()))
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, space)
    }

    private func makeTab(in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab", url: URL(string: "https://example.com/"), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    func testANormalTabIsKeyedByItsID() throws {
        let (store, space) = try makeStore()
        let tab = makeTab(in: space)
        space.tabs.append(tab)

        XCTAssertEqual(store.thumbnailKey(for: tab), tab.id)
        XCTAssertTrue(store.liveThumbnailKeys.contains(tab.id))
    }

    func testAPinnedTabIsKeyedByItsEntryAndStaysLiveWhileDormant() throws {
        let (store, space) = try makeStore()
        let tab = makeTab(in: space)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entry = try XCTUnwrap(space.pinnedEntries.first)

        XCTAssertEqual(store.thumbnailKey(for: tab), entry.id)
        XCTAssertEqual(entry.id, tab.id, "pinning keeps the tab's id, so the picture survives the pin")

        entry.tab = nil  // dormant
        XCTAssertTrue(store.liveThumbnailKeys.contains(entry.id), "a dormant tile keeps its picture")
    }

    func testAFavouriteTabIsKeyedByTheFavourite() throws {
        let (store, space) = try makeStore()
        let profileID = try XCTUnwrap(space.profile?.id)
        let tab = makeTab(in: space)
        store.addFavorite(from: tab, profileID: profileID)
        let favorite = try XCTUnwrap(space.profile?.favorites.first)

        XCTAssertEqual(store.thumbnailKey(for: tab), favorite.id)
        XCTAssertTrue(store.liveThumbnailKeys.contains(favorite.id))
    }

    func testAPrivateTabHasNoKey() throws {
        let (store, _) = try makeStore()
        let privateSpace = store.addIncognitoSpace()
        let tab = makeTab(in: privateSpace)
        privateSpace.tabs.append(tab)

        XCTAssertNil(store.thumbnailKey(for: tab), "never written for Private")
    }

    func testATabNoRowListsHasNoKey() throws {
        let (store, space) = try makeStore()
        XCTAssertNil(store.thumbnailKey(for: makeTab(in: space)), "a Peek, for one, is not a sidebar row")
    }

    func testAClosedTabsKeyIsNoLongerLive() throws {
        let (store, space) = try makeStore()
        let tab = makeTab(in: space)
        space.tabs.append(tab)
        store.closeTab(id: tab.id, in: space)

        XCTAssertFalse(store.liveThumbnailKeys.contains(tab.id))
    }
}
