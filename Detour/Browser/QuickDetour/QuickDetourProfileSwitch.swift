import Foundation

// The profile pill (TASK-193.4): what its menu lists, and what choosing a
// profile there does. Pure: the window builds the snapshots and carries the
// switch out (`QuickDetourWindowController.switchProfile`), the store
// replaces the page (`TabStore.replaceQuickDetourTab`).

/// The profile pill's menu, for one Quick Detour window.
struct QuickDetourProfileMenu: Equatable {
    struct Item: Equatable {
        var profileID: UUID
        var name: String
        var isPrivate: Bool
        /// The window's own profile.
        var isChecked: Bool
    }

    /// The normal profiles in the store's order, then the Private one.
    var items: [Item]

    /// A separator goes before the first Private item, when there are normal
    /// profiles above it.
    var separatorIndex: Int? {
        guard let index = items.firstIndex(where: \.isPrivate), index > 0 else { return nil }
        return index
    }
}

/// What choosing a profile in the pill's menu does.
enum QuickDetourProfileSwitchDecision: Equatable {
    /// Nothing: the window's own profile, or one that is gone.
    case stay
    /// The page reloads on that profile, in a new web view, at once.
    case switchProfile
    /// Leaving Private would cancel Private downloads still running (they
    /// go with the Private page, as when its window closes): ask first, and
    /// switch, cancelling them, only on a yes.
    case confirm(PrivateDownloadClosePolicy.Prompt)
}

extension QuickDetour {

    /// The pill's menu: every live normal profile in `profiles` order, then
    /// the Private profile last, after a separator; the window's own checked.
    /// Deleted profiles are left out.
    static func profileMenu(windowProfileID: UUID, profiles: [QuickDetourProfileSnapshot]) -> QuickDetourProfileMenu {
        let live = profiles.filter { !$0.isDeleted }
        let ordered = live.filter { !$0.isPrivate } + live.filter(\.isPrivate)
        return QuickDetourProfileMenu(items: ordered.map {
            QuickDetourProfileMenu.Item(profileID: $0.id, name: $0.name, isPrivate: $0.isPrivate,
                                        isChecked: $0.id == windowProfileID)
        })
    }

    /// What choosing `target` in the pill's menu of a window on `current`
    /// does, given how many Private downloads the window has in flight
    /// (`DownloadManager.privateDownloadsInFlight(closing:)` for its scope).
    static func profileSwitchDecision(from current: QuickDetourProfileSnapshot, to target: QuickDetourProfileSnapshot?,
                                      privateDownloadsInFlight: Int) -> QuickDetourProfileSwitchDecision {
        guard let target, !target.isDeleted, target.id != current.id else { return .stay }
        // Only a Private page's downloads go with it; a normal one's are
        // listed in every normal window and outlive it.
        guard current.isPrivate, privateDownloadsInFlight > 0 else { return .switchProfile }
        let informativeText = privateDownloadsInFlight == 1
            ? "1 download is in progress. Leaving Private browsing cancels it."
            : "\(privateDownloadsInFlight) downloads are in progress. Leaving Private browsing cancels them."
        return .confirm(PrivateDownloadClosePolicy.Prompt(messageText: "Switch to \(target.name)?",
                                                          informativeText: informativeText,
                                                          closeButtonTitle: "Switch Profile",
                                                          keepButtonTitle: "Continue Downloading"))
    }
}
