import AppKit

/// Which profile a new install turns the extension on in (TASK-312). An
/// extension is on only where a `profileExtension` row says so, and an install
/// writes exactly one: for the profile the user installed it from, as Chrome
/// installs into the profile whose window it was installed from.
///
/// - Chrome Web Store (or any CRX link): the profile of the tab the package
///   was downloaded in.
/// - Extensions › Install Extension… and Settings › Extensions: the profile of
///   the frontmost normal browser window (the one behind Settings, when
///   Settings is in front).
///
/// The built-in Private profile is never the target — Private stays off until
/// the user allows an extension there ("Allow in Private") — and neither is a
/// profile that no longer exists. When no candidate qualifies (a CRX link in a
/// Private window or a Private Quick Detour, only Private windows open, no
/// window at all), the first normal profile in `TabStore` order is the target:
/// the Default profile on a setup that never reordered or deleted it.
enum ExtensionInstallTarget {

    /// The target among `candidates` (profile ids in preference order): the
    /// first one that is a normal profile, else the first of `normalProfiles`
    /// (every non-Private profile, in `TabStore` order). Nil only when there is
    /// no normal profile at all.
    static func resolveProfile(candidates: [UUID?], normalProfiles: [UUID]) -> UUID? {
        let normal = Set(normalProfiles)
        return candidates.lazy.compactMap { $0 }.first { normal.contains($0) } ?? normalProfiles.first
    }

    /// Every non-Private profile, in `TabStore` order.
    @MainActor
    static func normalProfileIDs(in store: TabStore = .shared) -> [UUID] {
        store.profiles.filter { !$0.isIncognito }.map(\.id)
    }

    /// The target for an install the user started from a menu or from Settings:
    /// the frontmost normal browser window's profile, skipping Private windows.
    @MainActor
    static func profileForFrontWindow(in store: TabStore = .shared) -> UUID? {
        resolveProfile(candidates: NSApp.browserWindowControllersFrontToBack.map { $0.activeSpace?.profileID },
                       normalProfiles: normalProfileIDs(in: store))
    }

    /// The target's name for the install alerts; nil when there is no target.
    @MainActor
    static func profileName(_ target: UUID?, in store: TabStore = .shared) -> String? {
        target.flatMap { store.profile(withID: $0)?.name }
    }

    /// The confirmation alert's line naming where the install turns the
    /// extension on, with the paragraph break that follows it; empty without a
    /// target.
    static func confirmationLine(profileName: String?) -> String {
        profileName.map { "It will be turned on in the \"\($0)\" profile.\n\n" } ?? ""
    }

    /// The "Extension Installed" alert's text: where it is on now, and how to
    /// have it elsewhere.
    static func installedMessage(displayName: String, profileName: String?) -> String {
        guard let profileName else { return "\"\(displayName)\" has been installed." }
        return "\"\(displayName)\" has been installed and turned on in the \"\(profileName)\" profile. "
            + "To use it in other profiles, choose Turn On in All Profiles in Settings › Extensions, "
            + "or turn it on per profile in Settings › Profiles."
    }

    /// The target for a package downloaded in a tab or a Quick Detour whose
    /// profile is `sourceProfileID`.
    @MainActor
    static func profileForSource(_ sourceProfileID: UUID?, in store: TabStore = .shared) -> UUID? {
        resolveProfile(candidates: [sourceProfileID], normalProfiles: normalProfileIDs(in: store))
    }
}
