import XCTest
import WebKit
@testable import Detour

/// TASK-46: `loadExtensionsIntoProfile` resolves a profile's enabled set with
/// one `AppDatabase.enabledExtensionIDs(for:)` query instead of one
/// `isExtensionEnabled` read per installed extension — a per-extension read on
/// the main thread for every profile at launch, and again for every profile
/// added mid-session.
///
/// The counts come from `AppDatabase`'s DEBUG read counters, keyed by the
/// `performRead` label, so the per-extension reads cannot creep back unnoticed.
/// The suite also pins the decisions themselves: the precomputed set must load
/// exactly what the per-extension rule would have (enabled, disabled for the
/// profile, globally disabled).
///
/// The set is then cached per profile (`ExtensionManager.enabledIDsCache`), so a
/// UI read that follows the load does not repeat the query; every measured load
/// below starts from a cold cache (a brand-new profile) or an explicitly
/// invalidated one.
@MainActor
final class ExtensionStartupEnabledReadsTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        // Launch's own loadInstalledExtensions runs in the test host too; until it
        // has reached its per-profile loop, `profileWasAdded` is a no-op.
        try await waitUntil("the host app's installed extensions to load") {
            ExtensionManager.shared.hasLoadedInstalledExtensions
        }
    }

    override func tearDown() async throws {
        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = false
        for id in registeredExtensionIDs {
            // A globally enabled extension reaches every profile in the store,
            // including the host app's own, so unload from all of them.
            for profile in TabStore.shared.profiles {
                profile.unloadExtension(id: id)
            }
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            // Takes the onInstalled ledger rows with it, and the per-profile rows
            // cascade off the `extension` row.
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        createdProfiles.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        AppDatabase.resetReadCounts()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A minimal MV3 extension with an options page and no background content,
    /// registered in ExtensionManager and saved as globally enabled — what an
    /// installed extension looks like at launch.
    private func installExtension(named name: String) async throws -> WebExtension {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "startup-reads-\(name)",
                                                         name: "Startup Reads Test \(name)")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: try testExtensionManifestData(ext))
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        return profile
    }

    private func isLoaded(_ ext: WebExtension, in profile: Profile) -> Bool {
        profile.extensionContexts[ext.id] != nil
    }

    private var enabledSetReads: Int {
        AppDatabase.readCount(AppDatabase.enabledExtensionIDsReadLabel)
    }

    private var perExtensionReads: Int {
        AppDatabase.readCount(AppDatabase.isExtensionEnabledReadLabel)
    }

    // MARK: - AC #1 / #4: one enabled-state query per profile

    func testLoadIntoProfileIssuesOneEnabledStateQueryForAnyNumberOfExtensions() async throws {
        let a = try await installExtension(named: "one-a")
        let b = try await installExtension(named: "one-b")
        let c = try await installExtension(named: "one-c")
        let profile = makeProfile("Startup Reads One")

        AppDatabase.resetReadCounts()
        ExtensionManager.shared.loadExtensionsIntoProfile(profile)

        XCTAssertEqual(enabledSetReads, 1,
                       "the profile's enabled set must be read exactly once, not once per extension")
        XCTAssertEqual(perExtensionReads, 0,
                       "no per-extension isExtensionEnabled read may happen while loading a profile")
        for ext in [a, b, c] {
            XCTAssertTrue(isLoaded(ext, in: profile),
                          "an extension with no per-profile row must still load at launch")
        }
    }

    /// The count must not grow with the number of profiles either: each profile
    /// resolves its own set in one query.
    func testEachProfileCostsOneEnabledStateQuery() async throws {
        _ = try await installExtension(named: "per-profile-a")
        _ = try await installExtension(named: "per-profile-b")
        _ = try await installExtension(named: "per-profile-c")
        let first = makeProfile("Startup Reads Per Profile 1")
        let second = makeProfile("Startup Reads Per Profile 2")

        AppDatabase.resetReadCounts()
        ExtensionManager.shared.loadExtensionsIntoProfile(first)
        ExtensionManager.shared.loadExtensionsIntoProfile(second)

        XCTAssertEqual(enabledSetReads, 2, "one enabled-set read per profile, and no more")
        XCTAssertEqual(perExtensionReads, 0, "no per-extension reads for either profile")
    }

    // MARK: - AC #2: the precomputed decision matches the per-extension rule

    func testPrecomputedSetLoadsExactlyWhatThePerExtensionRuleWould() async throws {
        let enabled = try await installExtension(named: "mixed-enabled")
        let offForProfile = try await installExtension(named: "mixed-profile-off")
        let offGlobally = try await installExtension(named: "mixed-global-off")
        let profile = makeProfile("Startup Reads Mixed")

        // The two ways an extension is not enabled in a profile, written the way
        // the real toggles write them (only the flag each one owns).
        AppDatabase.shared.setProfileExtensionEnabled(extensionID: offForProfile.id,
                                                      profileID: profile.id.uuidString,
                                                      enabled: false)
        offGlobally.isEnabled = false
        AppDatabase.shared.setEnabled(id: offGlobally.id, enabled: false)
        ExtensionManager.shared.invalidateEnabledExtensionsCache()

        AppDatabase.resetReadCounts()
        ExtensionManager.shared.loadExtensionsIntoProfile(profile)

        XCTAssertEqual(enabledSetReads, 1, "still one read with mixed enabled state")
        XCTAssertEqual(perExtensionReads, 0, "still no per-extension reads with mixed enabled state")

        XCTAssertTrue(isLoaded(enabled, in: profile), "an enabled extension must load")
        XCTAssertFalse(isLoaded(offForProfile, in: profile),
                       "an extension the profile turned off must not load")
        XCTAssertFalse(isLoaded(offGlobally, in: profile),
                       "a globally disabled extension must not load")

        // The one rule, read per extension, must agree with the set that decided.
        for ext in [enabled, offForProfile, offGlobally] {
            XCTAssertEqual(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id),
                           isLoaded(ext, in: profile),
                           "isEnabled must agree with what the precomputed set loaded (\(ext.id))")
        }
    }

    /// A stale context left over from a disable is still unloaded: the reconcile
    /// is a two-way convergence, not a load-only pass.
    func testAContextDisabledForTheProfileIsUnloadedOnReload() async throws {
        let ext = try await installExtension(named: "unload")
        let profile = makeProfile("Startup Reads Unload")
        ExtensionManager.shared.loadExtensionsIntoProfile(profile)
        XCTAssertTrue(isLoaded(ext, in: profile), "precondition: it loads with no per-profile row")

        AppDatabase.shared.setProfileExtensionEnabled(extensionID: ext.id,
                                                      profileID: profile.id.uuidString,
                                                      enabled: false)
        ExtensionManager.shared.invalidateEnabledExtensionsCache()

        AppDatabase.resetReadCounts()
        ExtensionManager.shared.loadExtensionsIntoProfile(profile)

        XCTAssertEqual(enabledSetReads, 1, "the reload reads the set once")
        XCTAssertEqual(perExtensionReads, 0, "the reload makes no per-extension reads")
        XCTAssertFalse(isLoaded(ext, in: profile),
                       "a reload must unload a context the profile has since turned off")
    }

    // MARK: - AC #1: the mid-session path (profileWasAdded)

    func testProfileAddedMidSessionMakesNoPerExtensionReads() async throws {
        let a = try await installExtension(named: "added-a")
        let b = try await installExtension(named: "added-b")
        let c = try await installExtension(named: "added-c")

        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = true
        AppDatabase.resetReadCounts()
        let profile = makeProfile("Startup Reads Added")

        // `addProfile` also notifies the store's observers, so the enabled-set
        // read count here is not just the load's; the per-extension count is the
        // one this path must keep at zero.
        XCTAssertEqual(perExtensionReads, 0,
                       "adding a profile must not read enabled state once per extension")
        XCTAssertGreaterThanOrEqual(enabledSetReads, 1,
                                    "the added profile's enabled set is read")
        for ext in [a, b, c] {
            XCTAssertTrue(isLoaded(ext, in: profile),
                          "a profile added mid-session gets its enabled extensions loaded")
        }
    }
}
