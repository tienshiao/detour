import XCTest
import GRDB
@testable import Detour

/// TASK-305: the archive sweep never closes a tab playing audible media, and
/// once its sound stops the "Archive tabs after" countdown restarts from that
/// moment. Muted or paused media does not hold a tab back.
nonisolated final class ArchiveMediaTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private func makeFixture() throws -> (TabStore, Space, TimeInterval) {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Archive")
        let space = store.addSpace(name: "Archive", emoji: "🗄️", colorHex: "007AFF", profileID: profile.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        let threshold = profile.archiveThreshold
        XCTAssertNotEqual(threshold, .never, "precondition: the profile archives")
        return (store, space, threshold.rawValue)
    }

    @MainActor private func makeTab(_ name: String, in space: Space, deselectedAgo: TimeInterval) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: name, url: URL(string: "https://\(name).example/"),
                             faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
        tab.lastDeselectedAt = now.addingTimeInterval(-deselectedAgo)
        space.tabs.append(tab)
        return tab
    }

    /// The sweep never archives the last tab of a space; a fresh one keeps it
    /// from deciding the outcome of every test here.
    @MainActor private func addKeeper(to space: Space) -> BrowserTab {
        makeTab("keeper", in: space, deselectedAgo: 60)
    }

    @MainActor private func isOpen(_ tab: BrowserTab, in space: Space) -> Bool {
        space.tabs.contains { $0.id == tab.id }
    }

    @MainActor func testAPlayingTabIsNotArchived() throws {
        let (store, space, threshold) = try makeFixture()
        let playing = makeTab("music", in: space, deselectedAgo: threshold + 3600)
        playing.isPlayingAudio = true
        let silent = makeTab("silent", in: space, deselectedAgo: threshold + 3600)
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)

        XCTAssertTrue(isOpen(playing, in: space), "audible playback holds the tab")
        XCTAssertFalse(isOpen(silent, in: space), "an equally stale silent tab goes")
    }

    @MainActor func testAMutedPlayingTabIsArchived() throws {
        let (store, space, threshold) = try makeFixture()
        let muted = makeTab("muted", in: space, deselectedAgo: threshold + 3600)
        // Muted before it ever played audibly: nothing to restart from.
        muted.isMuted = true
        muted.isPlayingAudio = true
        XCTAssertNil(muted.lastAudibleAt)
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)

        XCTAssertFalse(isOpen(muted, in: space), "media the user cannot hear does not block archiving")
    }

    @MainActor func testATabPausedLongAgoIsArchived() throws {
        let (store, space, threshold) = try makeFixture()
        let paused = makeTab("paused", in: space, deselectedAgo: threshold + 7200)
        let pausedAt = now.addingTimeInterval(-threshold - 3600)
        paused.audibilityClock = { pausedAt }
        paused.isPlayingAudio = true
        paused.isPlayingAudio = false // paused before the threshold
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)

        XCTAssertFalse(isOpen(paused, in: space))
    }

    @MainActor func testCountdownRestartsWhenPlaybackStops() throws {
        let (store, space, threshold) = try makeFixture()
        let tab = makeTab("podcast", in: space, deselectedAgo: threshold + 7200)
        let stoppedAt = now.addingTimeInterval(-3600)
        tab.audibilityClock = { stoppedAt }
        tab.isPlayingAudio = true
        tab.isPlayingAudio = false
        XCTAssertEqual(tab.lastAudibleAt, stoppedAt)
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)
        XCTAssertTrue(isOpen(tab, in: space), "stopped an hour ago: the countdown started then")

        store.archiveStaleTabs(now: stoppedAt.addingTimeInterval(threshold - 60))
        XCTAssertTrue(isOpen(tab, in: space), "just short of the threshold after the stop")

        store.archiveStaleTabs(now: stoppedAt.addingTimeInterval(threshold + 60))
        XCTAssertFalse(isOpen(tab, in: space), "the threshold after the stop")
    }

    @MainActor func testMutingAPlayingTabRestartsTheCountdown() throws {
        let (store, space, threshold) = try makeFixture()
        let tab = makeTab("radio", in: space, deselectedAgo: threshold + 7200)
        tab.isPlayingAudio = true
        let mutedAt = now.addingTimeInterval(-600)
        tab.audibilityClock = { mutedAt }
        tab.isMuted = true
        XCTAssertEqual(tab.lastAudibleAt, mutedAt, "muting ends the audible playback")
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)
        XCTAssertTrue(isOpen(tab, in: space))
        store.archiveStaleTabs(now: mutedAt.addingTimeInterval(threshold + 60))
        XCTAssertFalse(isOpen(tab, in: space), "muted, it is archived a threshold after the mute")
    }

    @MainActor func testAStopBeforeTheDeselectionCountsFromTheDeselection() throws {
        let (store, space, threshold) = try makeFixture()
        let tab = makeTab("old", in: space, deselectedAgo: threshold + 60)
        let stoppedAt = now.addingTimeInterval(-threshold - 3600)
        tab.audibilityClock = { stoppedAt }
        tab.isPlayingAudio = true
        tab.isPlayingAudio = false
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)

        XCTAssertFalse(isOpen(tab, in: space), "the later of the two stamps rules")
    }

    @MainActor func testAnAudiblePeekHoldsItsHost() throws {
        let (store, space, threshold) = try makeFixture()
        let host = makeTab("host", in: space, deselectedAgo: threshold + 3600)
        let peek = BrowserTab(id: UUID(), title: "Peek", url: URL(string: "https://peek.example/"),
                              faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
        peek.spaceID = nil // a Peek is in no space
        host.peekTab = peek
        peek.isPlayingAudio = true
        _ = addKeeper(to: space)

        store.archiveStaleTabs(now: now)

        XCTAssertTrue(isOpen(host, in: space), "archiving the host would stop its Peek's sound")
        host.peekTab = nil
    }

    @MainActor func testASplitWithOnePlayingMemberIsNotArchived() throws {
        let (store, space, threshold) = try makeFixture()
        let left = makeTab("left", in: space, deselectedAgo: threshold + 3600)
        let right = makeTab("right", in: space, deselectedAgo: threshold + 3600)
        _ = addKeeper(to: space)
        store.undoManager.beginUndoGrouping()
        store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        store.undoManager.endUndoGrouping()
        XCTAssertNotNil(store.splitGroup(containing: left.id, in: space))
        right.isPlayingAudio = true

        store.archiveStaleTabs(now: now)

        XCTAssertTrue(isOpen(left, in: space), "a split goes only when every member is stale")
        XCTAssertTrue(isOpen(right, in: space))
    }

    // MARK: - Saved clock

    @MainActor func testSavedLastDeselectedAtCarriesTheArchiveClock() throws {
        let (_, space, _) = try makeFixture()
        let deselected = now.addingTimeInterval(-86_400)
        let audible = makeTab("audible", in: space, deselectedAgo: 86_400)
        audible.isPlayingAudio = true
        let stopped = makeTab("stopped", in: space, deselectedAgo: 86_400)
        let stoppedAt = now.addingTimeInterval(-600)
        stopped.audibilityClock = { stoppedAt }
        stopped.isPlayingAudio = true
        stopped.isPlayingAudio = false
        let quiet = makeTab("quiet", in: space, deselectedAgo: 86_400)
        let selected = makeTab("selected", in: space, deselectedAgo: 0)
        selected.lastDeselectedAt = nil

        func saved(_ tab: BrowserTab) -> Double? {
            TabRecord(tab: tab, spaceID: space.id, sortOrder: 0, profile: space.profile, now: now).lastDeselectedAt
        }
        XCTAssertEqual(saved(audible), now.timeIntervalSince1970, "a relaunch stops it: the countdown starts at the save")
        XCTAssertEqual(saved(stopped), stoppedAt.timeIntervalSince1970)
        XCTAssertEqual(saved(quiet), deselected.timeIntervalSince1970)
        XCTAssertNil(saved(selected))
    }

    /// Delete Space's undo rebuilds the space's tabs silent and asleep, as a
    /// relaunch does, so its snapshot carries the archive clock the same way.
    @MainActor func testUndoDeleteSpaceCarriesTheArchiveClock() throws {
        let (store, space, threshold) = try makeFixture()
        let profileID = try XCTUnwrap(space.profile).id
        // Add Space registers an undo, which needs a group here.
        store.undoManager.beginUndoGrouping()
        _ = store.addSpace(name: "Other", emoji: "📁", colorHex: "007AFF", profileID: profileID)
        store.undoManager.endUndoGrouping()
        let audible = makeTab("audible", in: space, deselectedAgo: threshold + 3600)
        audible.lastDeselectedAt = Date().addingTimeInterval(-threshold - 3600)
        audible.isPlayingAudio = true
        let quiet = makeTab("quiet", in: space, deselectedAgo: 0)
        let quietDeselected = Date().addingTimeInterval(-threshold - 3600)
        quiet.lastDeselectedAt = quietDeselected
        store.undoManager.removeAllActions()

        store.undoManager.beginUndoGrouping()
        store.deleteSpace(id: space.id)
        store.undoManager.endUndoGrouping()
        let deletedAt = Date()
        store.undoManager.undo()

        let restored = try XCTUnwrap(store.space(withID: space.id))
        let restoredAudible = try XCTUnwrap(restored.tabs.first { $0.id == audible.id })
        let restoredQuiet = try XCTUnwrap(restored.tabs.first { $0.id == quiet.id })
        XCTAssertEqual(try XCTUnwrap(restoredAudible.lastDeselectedAt).timeIntervalSince1970,
                       deletedAt.timeIntervalSince1970, accuracy: 5,
                       "silenced by the delete: the countdown starts there")
        XCTAssertEqual(restoredQuiet.lastDeselectedAt, quietDeselected)
        for tab in restored.tabs { tab.teardown() }
    }
}
