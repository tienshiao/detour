import XCTest
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

        cleanTestExtensions()
        resetTabStore()
        assertCleanState()
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
