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
        cleanTestProfiles()
    }

    private func cleanTestExtensions() {
        let records = AppDatabase.shared.loadExtensions()
        for record in records {
            AppDatabase.shared.storageClear(extensionID: record.id)
            AppDatabase.shared.deleteExtension(id: record.id)
        }
        ExtensionManager.shared.extensions.removeAll()
        ExtensionManager.shared.backgroundHosts.removeAll()
        ExtensionManager.shared.offscreenHosts.removeAll()
        ExtensionManager.shared.contextMenuItems.removeAll()

        // Clean up any leftover extension files in the test data directory
        let extDir = detourDataDirectory().appendingPathComponent("Extensions")
        try? FileManager.default.removeItem(at: extDir)
    }

    private func cleanTestProfiles() {
        let profiles = TabStore.shared.profiles
        for profile in profiles {
            if profile.isIncognito { continue }
            let spaceCount = TabStore.shared.spaces.filter { $0.profileID == profile.id && !$0.isIncognito }.count
            if spaceCount == 0 && profile.name.contains("Test") {
                TabStore.shared.deleteProfile(id: profile.id)
            }
        }
    }
}
