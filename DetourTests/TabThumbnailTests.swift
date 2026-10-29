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

    func testATabNoRowListsOrHostsHasNoKey() throws {
        let (store, space) = try makeStore()
        XCTAssertNil(store.thumbnailKey(for: makeTab(in: space)))
    }

    // MARK: - Peeks (TASK-230)

    private let articleURL = URL(string: "https://news.example/story")!
    private let otherURL = URL(string: "https://news.example/other")!

    private func peek(_ url: URL?) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Article", url: url, faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
    }

    func testAPeekKeyIsDerivedFromItsHostsKeyAndItsURL() {
        let host = UUID(), other = UUID()
        let key = TabStore.peekThumbnailKey(hostKey: host, peekURL: articleURL)
        XCTAssertEqual(key, TabStore.peekThumbnailKey(hostKey: host, peekURL: articleURL), "the same on every launch")
        XCTAssertNotEqual(key, host)
        XCTAssertNotEqual(key, TabStore.peekThumbnailKey(hostKey: host, peekURL: otherURL),
                          "another Peek on the same host never gets this picture")
        XCTAssertNotEqual(key, TabStore.peekThumbnailKey(hostKey: other, peekURL: articleURL))
    }

    /// Keyed by the URL the session saves for the Peek (`peekURL`), not the
    /// Peek tab's own `url`, which can differ (an error page keeps the
    /// failed URL): otherwise a picture written while the app runs would be
    /// looked up, and swept, under another key after a relaunch.
    func testANormalTabsPeekIsKeyedByTheTabAndTheURLTheSessionSaves() throws {
        let (store, space) = try makeStore()
        let host = makeTab(in: space)
        space.tabs.append(host)
        let live = peek(articleURL)
        host.peekTab = live
        host.peekURL = otherURL

        let key = TabStore.peekThumbnailKey(hostKey: host.id, peekURL: otherURL)
        XCTAssertEqual(store.thumbnailKey(for: live), key)
        XCTAssertTrue(store.liveThumbnailKeys.contains(key))
    }

    func testAPinnedOrFavouriteHostsPeekIsKeyedByTheTile() throws {
        let (store, space) = try makeStore()
        let profileID = try XCTUnwrap(space.profile?.id)
        let pinned = makeTab(in: space)
        space.tabs.append(pinned)
        store.pinTab(id: pinned.id, in: space)
        let entry = try XCTUnwrap(space.pinnedEntries.first)
        let pinnedPeek = peek(articleURL)
        pinned.peekTab = pinnedPeek
        pinned.peekURL = articleURL

        let favoured = makeTab(in: space)
        store.addFavorite(from: favoured, profileID: profileID)
        let favorite = try XCTUnwrap(space.profile?.favorites.first)
        let favouritePeek = peek(otherURL)
        favoured.peekTab = favouritePeek
        favoured.peekURL = otherURL

        XCTAssertEqual(store.thumbnailKey(for: pinnedPeek), TabStore.peekThumbnailKey(hostKey: entry.id, peekURL: articleURL))
        XCTAssertEqual(store.thumbnailKey(for: favouritePeek), TabStore.peekThumbnailKey(hostKey: favorite.id, peekURL: otherURL))
        XCTAssertTrue(store.liveThumbnailKeys.isSuperset(of: [
            TabStore.peekThumbnailKey(hostKey: entry.id, peekURL: articleURL),
            TabStore.peekThumbnailKey(hostKey: favorite.id, peekURL: otherURL),
        ]))
    }

    func testAParkedPeekWithoutAURLIsKeyedByTheURLItsHostSaved() throws {
        let (store, space) = try makeStore()
        let host = makeTab(in: space)
        space.tabs.append(host)
        let parked = peek(nil)
        host.peekTab = parked
        host.peekURL = articleURL

        XCTAssertEqual(store.thumbnailKey(for: parked), TabStore.peekThumbnailKey(hostKey: host.id, peekURL: articleURL))
    }

    func testARestoredPeeksKeyStaysLive() throws {
        // After a relaunch the host has only its saved peek columns.
        let (store, space) = try makeStore()
        let host = makeTab(in: space)
        space.tabs.append(host)
        host.peekURL = articleURL

        XCTAssertTrue(store.liveThumbnailKeys.contains(TabStore.peekThumbnailKey(hostKey: host.id, peekURL: articleURL)))
    }

    func testAClosedOrNavigatedPeeksPictureIsNoLongerLive() throws {
        let (store, space) = try makeStore()
        let host = makeTab(in: space)
        space.tabs.append(host)
        host.peekURL = articleURL
        let first = TabStore.peekThumbnailKey(hostKey: host.id, peekURL: articleURL)

        host.peekURL = otherURL
        XCTAssertFalse(store.liveThumbnailKeys.contains(first), "the Peek navigated away")

        host.clearPeekState()
        XCTAssertFalse(store.liveThumbnailKeys.contains(TabStore.peekThumbnailKey(hostKey: host.id, peekURL: otherURL)),
                       "the Peek was closed")
    }

    func testAPrivateHostsPeekHasNoKey() throws {
        let (store, _) = try makeStore()
        let privateSpace = store.addIncognitoSpace()
        let host = makeTab(in: privateSpace)
        privateSpace.tabs.append(host)
        let live = peek(articleURL)
        host.peekTab = live
        host.peekURL = articleURL

        XCTAssertNil(store.thumbnailKey(for: live), "never written for Private")
    }

    func testAClosedTabsKeyIsNoLongerLive() throws {
        let (store, space) = try makeStore()
        let tab = makeTab(in: space)
        space.tabs.append(tab)
        store.closeTab(id: tab.id, in: space)

        XCTAssertFalse(store.liveThumbnailKeys.contains(tab.id))
    }
}
