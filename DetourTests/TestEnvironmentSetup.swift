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

/// The production defaults keys a test run must leave alone (TASK-41), and how
/// to read them. `UserDefaults.standard` in the test host *is* the production
/// domain — the host is Detour.app — so these are the keys the real app
/// restores its window and sidebar from, plus Sparkle's state. Shared by the
/// bundle-wide net below and by `ProductionDefaultsIsolationTests`.
enum ProductionDefaultsWatch {

    /// The unscoped autosave keys: what the default data directory writes.
    static let autosaveKeys = [
        "NSWindow Frame BrowserWindow",
        "NSSplitView Subview Frames BrowserSplitView",
    ]
    static let sparkleKeyPrefix = "SU"

    /// The autosave keys this process writes — the production keys in the
    /// default data directory, suffixed ones anywhere else (`UserDefaultsScope`).
    static var scopedAutosaveKeys: [String] {
        [
            "NSWindow Frame \(BrowserWindowController.frameAutosaveName)",
            "NSSplitView Subview Frames \(BrowserWindowController.splitViewAutosaveName)",
        ]
    }

    /// Every production key to watch: the two autosave keys plus every `SU*`
    /// key the app domain currently holds. The app domain's own keys are
    /// enumerated rather than the merged representation, which would also pull
    /// in unrelated global-domain keys.
    static func keys() -> [String] {
        let defaults = UserDefaults.standard
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.detourbrowser.mac"
        // A domain that cannot be read would leave the SU keys unwatched, so
        // fall back to the merged representation (a few unrelated keys there
        // never matter: a key that did not change is never written back).
        let keys = defaults.persistentDomain(forName: bundleIdentifier)?.keys.map { $0 }
            ?? defaults.dictionaryRepresentation().keys.map { $0 }
        let sparkleKeys = keys.filter { $0.hasPrefix(sparkleKeyPrefix) }
        return autosaveKeys + sparkleKeys.sorted()
    }

    /// The current value of every watched key that has one.
    static func snapshot() -> [String: NSObject] {
        let defaults = UserDefaults.standard
        var values: [String: NSObject] = [:]
        for key in keys() {
            if let value = defaults.object(forKey: key) as? NSObject {
                values[key] = value
            }
        }
        return values
    }

    static func valuesEqual(_ lhs: NSObject?, _ rhs: NSObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?): return left.isEqual(right)
        default: return false
        }
    }
}

private final class TestObserver: NSObject, XCTestObservation {

    private var cleaned = false

    /// The production defaults values at bundle start (TASK-41). `nil` until
    /// snapshotted, and in the default data directory, where the run owns the
    /// domain.
    private var productionDefaults: [String: NSObject]?

    /// The watched keys this process itself changed since the snapshot, with the
    /// value each change left (`nil`: removed), and the values last seen. Fed by
    /// `UserDefaults.didChangeNotification`, which a process receives only for
    /// its *own* writes — a production Detour writing the same domain during the
    /// run never posts it here — so the restore can tell the run's writes from
    /// someone else's. The notification arrives on the writing thread, hence
    /// the lock.
    private var changesMadeHere: [String: NSObject?] = [:]
    private var lastSeen: [String: NSObject] = [:]
    private let changesLock = NSLock()
    private var defaultsObservation: NSObjectProtocol?

    func testBundleWillStart(_ testBundle: Bundle) {
        snapshotProductionDefaults()
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
        restoreProductionDefaults()
        guard !WebKitStorageScope.currentIsDefaultDataDirectory else { return }
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

    // MARK: - Production defaults safety net (TASK-41)

    /// The autosave names are scoped to the data directory (`UserDefaultsScope`)
    /// and Sparkle does not start in the test host (`AppDelegate.startsUpdater`),
    /// so nothing should write the production keys any more; the snapshot and
    /// restore below are the net under those two fixes. Only this process's own
    /// writes are undone (see `changesMadeHere`): a difference nobody here made
    /// is the real app's, and is left alone.
    ///
    /// The net starts when the bundle does, after the host finished launching,
    /// so a write made *during* launch is already in the baseline. The names
    /// themselves are pinned instead: `UserDefaultsScopeTests` checks they are
    /// scoped, and `ProductionDefaultsIsolationTests` that the launch window
    /// uses them.
    private func snapshotProductionDefaults() {
        guard !WebKitStorageScope.currentIsDefaultDataDirectory, productionDefaults == nil else { return }
        let snapshot = ProductionDefaultsWatch.snapshot()
        productionDefaults = snapshot
        lastSeen = snapshot
        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { [weak self] _ in
            self?.recordOwnChanges()
        }
    }

    /// One of this process's writes went through: attribute whatever watched
    /// key differs from the last look to this run.
    private func recordOwnChanges() {
        let current = ProductionDefaultsWatch.snapshot()
        changesLock.lock()
        defer { changesLock.unlock() }
        for key in Set(current.keys).union(lastSeen.keys)
        where !ProductionDefaultsWatch.valuesEqual(current[key], lastSeen[key]) {
            changesMadeHere[key] = .some(current[key])
        }
        lastSeen = current
    }

    /// Reports and undoes the changes this run made to the watched production
    /// keys, including keys it created (they are removed again). A key another
    /// process wrote after this run did is left as that process left it. Also
    /// drops the data-directory-scoped autosave keys the run wrote, so no
    /// test's window geometry carries into the next run.
    private func restoreProductionDefaults() {
        guard let snapshot = productionDefaults else { return }
        productionDefaults = nil
        if let observation = defaultsObservation {
            NotificationCenter.default.removeObserver(observation)
            defaultsObservation = nil
        }
        changesLock.lock()
        let changes = changesMadeHere
        changesLock.unlock()

        let defaults = UserDefaults.standard
        var restored: [String] = []
        var leftAlone: [String] = []
        for (key, valueLeftHere) in changes {
            let current = defaults.object(forKey: key) as? NSObject
            let original = snapshot[key]
            // Back where it started, whoever wrote in between.
            guard !ProductionDefaultsWatch.valuesEqual(current, original) else { continue }
            // Not the value this run left: someone else wrote since.
            guard ProductionDefaultsWatch.valuesEqual(current, valueLeftHere) else {
                leftAlone.append(key)
                continue
            }
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            restored.append(key)
        }

        // Never the production keys: outside the default data directory the
        // names are suffixed, and the guard above established that.
        for key in ProductionDefaultsWatch.scopedAutosaveKeys {
            defaults.removeObject(forKey: key)
        }

        if !restored.isEmpty {
            print("⚠️  The test run changed production defaults keys, restored: \(restored.sorted().joined(separator: ", "))")
        }
        if !leftAlone.isEmpty {
            print("⚠️  Production defaults keys this run changed were then written by another process, left alone: \(leftAlone.sorted().joined(separator: ", "))")
        }
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
