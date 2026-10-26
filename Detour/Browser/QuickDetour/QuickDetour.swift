import AppKit

/// The rules of Quick Detour (TASK-193.1): a small window with one web view,
/// for a lookup that should not disturb any space.
///
/// The window's page is a `BrowserTab` in no space list — like a Peek — held
/// by `TabStore.quickDetourTabs` and built from its profile's configuration.
/// What "no space" means for history, for the Private session and for the
/// window's profile is decided here, as pure functions, so the store and the
/// window share one answer.
enum QuickDetour {
    /// The feature's name in the UI: the History page's label, the window
    /// title, the menu item.
    static let displayName = "Quick Detour"

    // MARK: - History

    /// Flipped into a profile's id to make the history scope its Quick Detour
    /// visits are filed under. Any fixed value works; this one is a random
    /// UUID minted for the purpose and must never change, or the visits
    /// already recorded fall out of every scope (and the launch sweep then
    /// deletes them as a deleted space's).
    private static let historyScopeMask: uuid_t = UUID(uuidString: "5D1C6E2A-9B47-4F03-A8D2-71E0C4B39F6E")!.uuid

    /// The `historyVisit.spaceID` a profile's Quick Detour visits carry.
    ///
    /// `historyVisit.spaceID` is `TEXT NOT NULL`, and every reader scopes by
    /// it (`spaceID IN (…)` over the `(spaceID, visitTime)` index), so a
    /// Quick Detour visit is filed under a per-profile id that is no space's:
    /// the profile id XORed with a fixed mask. Deterministic, so it needs no
    /// storage and survives relaunches; derived from the profile, so the
    /// profile's scope (`HistoryPageBridge.scope(forProfile:)`) can name it
    /// and nothing else does — no space's history reads or writes it.
    static func historySpaceID(forProfileID profileID: UUID) -> UUID {
        var bytes = profileID.uuid
        withUnsafeMutableBytes(of: &bytes) { profile in
            withUnsafeBytes(of: historyScopeMask) { mask in
                for index in 0..<profile.count { profile[index] ^= mask[index] }
            }
        }
        return UUID(uuid: bytes)
    }

    /// `historySpaceID(forProfileID:)` as the database stores it.
    static func historySpaceIDString(forProfileID profileID: UUID) -> String {
        historySpaceID(forProfileID: profileID).uuidString
    }

    /// Whether a visit's `spaceID` is `profileID`'s Quick Detour scope — what
    /// the History page labels "Quick Detour". Case-insensitive, as a stored
    /// id may not have been written by `uuidString`.
    static func isHistorySpaceID(_ spaceID: String, ofProfileID profileID: UUID) -> Bool {
        UUID(uuidString: spaceID) == historySpaceID(forProfileID: profileID)
    }

    // MARK: - Which profile a new window uses

    /// The profile a new Quick Detour opens on: the profile of the space the
    /// frontmost browser window shows — the Private profile when that is a
    /// Private window — else the first profile that is neither Private nor
    /// deleted. Nil only when there is no such profile at all.
    ///
    /// The user's decision in TASK-193.4 (2026-10-26): the frontmost window's
    /// profile, a Quick Detour's own included (one switched with its profile
    /// pill opens the next on the profile it switched to); rejected, the
    /// last profile used in a Quick Detour, and a fixed profile setting.
    static func profileForNewWindow(frontmostSpaceProfile: Profile?, profiles: [Profile]) -> Profile? {
        if let frontmostSpaceProfile, !frontmostSpaceProfile.isDeleted { return frontmostSpaceProfile }
        return profiles.first { !$0.isIncognito && !$0.isDeleted }
    }

    // MARK: - The launcher panel

    /// Where the launcher panel goes: centred on the screen's visible frame,
    /// on whole points.
    static func panelFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(x: (visibleFrame.midX - size.width / 2).rounded(),
               y: (visibleFrame.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// The space whose history the window's palette suggests from: the space
    /// the window was opened from, when it is the window's own profile's and
    /// not Private, so the first lookup already has the profile's places to
    /// complete from; otherwise the Quick Detour scope of the profile. Only
    /// read, never written: the visits themselves always go to the Quick
    /// Detour scope.
    static func paletteHistorySpaceID(profile: Profile, sourceSpace: Space?) -> UUID {
        if let sourceSpace, sourceSpace.profileID == profile.id, !profile.isIncognito { return sourceSpace.id }
        return historySpaceID(forProfileID: profile.id)
    }
}
