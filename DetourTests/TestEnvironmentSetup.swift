import XCTest
import WebKit
@testable import Detour

/// Cleans the test database once before any tests run.
///
/// Registered as `NSPrincipalClass` for the test bundle so it loads automatically.
/// Requires `DETOUR_DATA_DIR=DetourTests` in the test scheme environment
/// (set in project.yml) so test data lives in
/// `~/Library/Application Support/DetourTests/` instead of the real app data.
@objc(TestEnvironmentSetup)
final class TestEnvironmentSetup: NSObject {

    private static let observer = TestObserver()

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(Self.observer)
    }
}

private final class TestObserver: NSObject, XCTestObservation {

    private var cleaned = false

    func testBundleWillStart(_ testBundle: Bundle) {
        guard !cleaned else { return }
        cleaned = true

        let dataDir = ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"]
        if dataDir == nil || dataDir == "Detour" {
            print("⚠️  DETOUR_DATA_DIR not set — tests may pollute production data.")
        } else {
            print("✓ Test data directory: ~/Library/Application Support/\(dataDir!)/")
        }

        // The test host is the app, so ExtensionManager.initialize has run and a
        // profile added to TabStore.shared would load every registered extension
        // (TASK-27). Tests create profiles freely and wire contexts by hand; the
        // new-profile load tests opt back in (NewProfileExtensionLoadTests).
        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = false

        cleanTestExtensions()
        resetTabStore()
        clearPendingProfileDataRemovals()
        // The profiles TabStore.shared restored are live; leave their storage.
        removeRecordedWebKitStorage(phase: "start", excludingProfileIDs: Set(TabStore.shared.profiles.map(\.id)))
        assertCleanState()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        guard !WebKitStorageScope.current.isDefaultDataDirectory else { return }
        // Release what tests left in the shared store, and the persistent WebKit
        // objects of the profiles it keeps (the test data directory's default
        // profile creates a store and controller during the run), so none of
        // that storage is in use any more. Then remove all the WebKit storage
        // this data directory recorded. WebKit refuses a store something still
        // uses; that storage stays recorded and goes at the next run's start.
        for profile in TabStore.shared.profiles {
            profile.unloadAllExtensions()
        }
        // Undo actions capture the spaces (and so the profiles) they act on.
        TabStore.shared.undoManager.removeAllActions()
        resetTabStore()
        for profile in TabStore.shared.profiles where !profile.isIncognito {
            profile.extensionController = WKWebExtensionController(configuration: .nonPersistent())
            profile.dataStore = .nonPersistent()
        }
        removeRecordedWebKitStorage(phase: "end", excludingProfileIDs: [])
    }

    /// Removes the persistent WebKit storage (identifier data stores and
    /// extension controller directories under the production app's
    /// `~/Library/WebKit/<bundle id>/`) that this test data directory recorded
    /// creating (TASK-36), except that of `excludingProfileIDs`.
    /// `WebKitStorageScope.removeRecordedStorage` refuses anything not recorded
    /// here, not derived from this data directory's name, or equal to a
    /// production profile id. Never runs in the default data directory.
    private func removeRecordedWebKitStorage(phase: String, excludingProfileIDs liveProfileIDs: Set<UUID>) {
        let scope = WebKitStorageScope.current
        guard !scope.isDefaultDataDirectory else { return }
        let recorded = scope.registry.recordedWebKitStorageIdentifiers().count
        let started = Date()
        var report: WebKitStorageScope.CleanupReport?
        Task { @MainActor in
            // WebKit reports a store in use for about 0.25 s after its last web
            // view goes; the default retries cover that. A store still in use
            // after them is held by a leaked object and waits for the next run.
            report = await scope.removeRecordedStorage(excludingProfileIDs: liveProfileIDs)
        }
        let deadline = Date().addingTimeInterval(60)
        while report == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let report else {
            print("⚠️  WebKit storage cleanup (\(phase)) did not finish within 60 s")
            return
        }
        print("✓ WebKit storage cleanup (\(phase)): \(recorded) recorded, \(report.removed.count) removed, \(report.kept.count) kept, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for (identifier, reason) in report.kept.sorted(by: { $0.key.uuidString < $1.key.uuidString }).prefix(10) {
            print("    kept \(identifier.uuidString): \(reason)")
        }
    }

    /// Profile data removals recorded by earlier runs (TASK-32) are never retried
    /// in the test host — AppDelegate skips the launch retry there — so drop the
    /// rows rather than let the table grow across runs. Database rows only; the
    /// storage those profiles created is recorded separately and removed by
    /// `removeRecordedWebKitStorage`.
    private func clearPendingProfileDataRemovals() {
        for profileID in AppDatabase.shared.pendingProfileDataRemovals() {
            AppDatabase.shared.clearPendingProfileDataRemoval(profileID: profileID)
        }
    }

    private func cleanTestExtensions() {
        let records = AppDatabase.shared.loadExtensions()
        for record in records {
            AppDatabase.shared.storageClear(extensionID: record.id)
            AppDatabase.shared.deleteExtension(id: record.id)
        }
        ExtensionManager.shared.extensions.removeAll()

        // Clean up any leftover extension files in the test data directory
        let extDir = detourDataDirectory().appendingPathComponent("Extensions")
        try? FileManager.default.removeItem(at: extDir)
    }

    /// Removes all stale spaces and test profiles left over from previous runs,
    /// leaving only the default space and profile that ensureDefaultSpace creates.
    private func resetTabStore() {
        // Remove all spaces except the first non-incognito one
        let store = TabStore.shared
        let nonIncognitoSpaces = store.spaces.filter { !$0.isIncognito }
        for space in nonIncognitoSpaces.dropFirst() {
            store.forceRemoveSpace(id: space.id)
        }

        // Remove all incognito spaces
        for space in store.spaces.filter({ $0.isIncognito }) {
            store.forceRemoveSpace(id: space.id)
        }

        // Remove all tabs from the remaining space (if any)
        if let space = store.spaces.first {
            space.tabs.removeAll()
        }

        // Remove test profiles (keep the default and incognito)
        let defaultProfileID = store.spaces.first?.profileID
        for profile in store.profiles {
            if profile.isIncognito { continue }
            if profile.id == defaultProfileID { continue }
            store.forceRemoveProfile(id: profile.id)
        }

        // Persist the clean state to DB so it doesn't grow across runs
        store.saveNow()
    }

    private func assertCleanState() {
        let store = TabStore.shared
        let nonIncognitoSpaces = store.spaces.filter { !$0.isIncognito }
        let nonIncognitoProfiles = store.profiles.filter { !$0.isIncognito }

        if nonIncognitoSpaces.count != 1 {
            print("⚠️  Expected 1 non-incognito space at test start, found \(nonIncognitoSpaces.count)")
        }
        if nonIncognitoProfiles.count != 1 {
            print("⚠️  Expected 1 non-incognito profile at test start, found \(nonIncognitoProfiles.count)")
        }

        let totalTabs = nonIncognitoSpaces.reduce(0) { $0 + $1.tabs.count }
        if totalTabs != 0 {
            print("⚠️  Expected 0 tabs at test start, found \(totalTabs)")
        }

        assert(nonIncognitoSpaces.count == 1, "Test environment should start with exactly 1 space")
        assert(nonIncognitoProfiles.count == 1, "Test environment should start with exactly 1 profile")
        assert(totalTabs == 0, "Test environment should start with 0 tabs")
    }
}
