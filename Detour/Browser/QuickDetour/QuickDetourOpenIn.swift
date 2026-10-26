import Foundation

// Open in <Space> (TASK-193.3): where a Quick Detour's page goes when it is
// moved into a space, and what the title bar's button and its dropdown offer.
// Pure: the store builds the snapshots, the window carries the move out.

/// Where Open in sends a Quick Detour's page.
enum QuickDetourOpenInTarget: Equatable {
    /// A new tab of this normal space: the page itself when the space is the
    /// window's profile's, its address opened again when it is another's.
    case space(UUID)
    /// A new tab of the most recent Private window, else of a new one: a
    /// Private Quick Detour's only destination.
    case privateWindow
}

/// One space, as the Open in rules see it.
struct QuickDetourSpaceSnapshot: Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var profileID: UUID
    var isPrivate: Bool
}

/// One profile, as the Open in rules see it.
struct QuickDetourProfileSnapshot: Equatable {
    var id: UUID
    var name: String
    var isPrivate: Bool
    var isDeleted: Bool
}

/// The Open in button and its dropdown, for one Quick Detour window.
struct QuickDetourOpenInMenu: Equatable {
    struct Item: Equatable {
        var spaceID: UUID
        var emoji: String
        var name: String
        /// Another profile's space: the web view cannot move into it (another
        /// data store), so the page's address is opened there instead — that
        /// profile's cookies and sign-ins, and no back/forward history.
        var reloads: Bool
        /// The button's target, and Cmd+O's.
        var isDefault: Bool
    }

    struct Section: Equatable {
        var profileID: UUID
        /// The profile's name, the section's header.
        var title: String
        var items: [Item]
    }

    /// What the button and Cmd+O do; nil when there is nowhere to go (no
    /// normal space at all).
    var defaultTarget: QuickDetourOpenInTarget?
    /// What the button names after "Open in": the space's emoji and name, or
    /// "Private Window".
    var destinationName: String?
    /// The default target is another profile's space (the window's profile
    /// has none), so the button reloads rather than moves.
    var defaultReloads: Bool
    /// The dropdown, one section per profile with spaces, the window's own
    /// first. Empty for a Private Quick Detour, which has no dropdown.
    var sections: [Section]

    /// Headers only say something when there is more than one profile to
    /// tell apart.
    var showsSectionHeaders: Bool { sections.count > 1 }
    var hasDropdown: Bool { !sections.isEmpty }

    static let none = QuickDetourOpenInMenu(defaultTarget: nil, destinationName: nil, defaultReloads: false,
                                            sections: [])
}

extension QuickDetour {
    /// The button's label for a Private Quick Detour.
    static let privateWindowDestinationName = "Private Window"

    /// `profileID`'s most recently used space (TASK-193.3, decision 1): the
    /// first of `useOrder` that is a normal space of that profile, else the
    /// profile's first normal space in sidebar order; nil when it has none.
    static func mostRecentlyUsedSpace(ofProfile profileID: UUID, spaces: [QuickDetourSpaceSnapshot],
                                      useOrder: [UUID]) -> UUID? {
        let candidates = spaces.filter { $0.profileID == profileID && !$0.isPrivate }
        let ids = Set(candidates.map(\.id))
        return useOrder.first(where: ids.contains) ?? candidates.first?.id
    }

    /// The space Open in names for a Quick Detour of `profileID` opened from
    /// `sourceSpaceID` (decision 1): that space, when it is still there and
    /// the same profile's; otherwise the profile's most recently used space.
    /// Nil when the profile has no normal space.
    static func openInDefaultSpace(profileID: UUID, sourceSpaceID: UUID?, spaces: [QuickDetourSpaceSnapshot],
                                   useOrder: [UUID]) -> UUID? {
        if let sourceSpaceID,
           spaces.contains(where: { $0.id == sourceSpaceID && $0.profileID == profileID && !$0.isPrivate }) {
            return sourceSpaceID
        }
        return mostRecentlyUsedSpace(ofProfile: profileID, spaces: spaces, useOrder: useOrder)
    }

    /// The button and the dropdown for a Quick Detour on `windowProfile`.
    ///
    /// - Private: the page moves to a Private window; no dropdown, since no
    ///   normal space may take a Private page (decision 3).
    /// - Otherwise the dropdown lists every normal space of a live profile,
    ///   one section per profile, the window's own first and the rest in
    ///   `profiles` order, spaces in sidebar order (decision 2). The button
    ///   names `openInDefaultSpace`; a profile with no space of its own falls
    ///   back to the most recently used space of any profile, which reloads.
    static func openInMenu(windowProfile: QuickDetourProfileSnapshot, sourceSpaceID: UUID?,
                           spaces: [QuickDetourSpaceSnapshot], profiles: [QuickDetourProfileSnapshot],
                           useOrder: [UUID]) -> QuickDetourOpenInMenu {
        if windowProfile.isPrivate {
            return QuickDetourOpenInMenu(defaultTarget: .privateWindow, destinationName: privateWindowDestinationName,
                                         defaultReloads: false, sections: [])
        }
        let liveProfiles = profiles.filter { !$0.isPrivate && !$0.isDeleted }
        let liveProfileIDs = Set(liveProfiles.map(\.id))
        let listed = spaces.filter { !$0.isPrivate && liveProfileIDs.contains($0.profileID) }

        let defaultID = openInDefaultSpace(profileID: windowProfile.id, sourceSpaceID: sourceSpaceID,
                                           spaces: listed, useOrder: useOrder)
            ?? useOrder.first { id in listed.contains { $0.id == id } }
            ?? listed.first?.id
        let ordered = liveProfiles.filter { $0.id == windowProfile.id } + liveProfiles.filter { $0.id != windowProfile.id }
        let sections: [QuickDetourOpenInMenu.Section] = ordered.compactMap { profile in
            let items = listed.filter { $0.profileID == profile.id }.map { space in
                QuickDetourOpenInMenu.Item(spaceID: space.id, emoji: space.emoji, name: space.name,
                                           reloads: space.profileID != windowProfile.id,
                                           isDefault: space.id == defaultID)
            }
            return items.isEmpty ? nil : QuickDetourOpenInMenu.Section(profileID: profile.id, title: profile.name,
                                                                       items: items)
        }
        guard let defaultID, let target = listed.first(where: { $0.id == defaultID }) else {
            return QuickDetourOpenInMenu(defaultTarget: nil, destinationName: nil, defaultReloads: false,
                                         sections: sections)
        }
        return QuickDetourOpenInMenu(defaultTarget: .space(target.id), destinationName: "\(target.emoji) \(target.name)",
                                     defaultReloads: target.profileID != windowProfile.id, sections: sections)
    }
}
