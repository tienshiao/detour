import Foundation

/// Why a dormant tile (a pinned entry, a favourite) refused to become a tab
/// (TASK-37): its page belongs to an extension that cannot show it now.
///
/// A refusal is silent everywhere the store decides on its own (restore, a split
/// partner waking); it is worth a toast only where the user clicked the tile.
enum DormantTileRefusal: Equatable {
    /// The extension is installed but turned off — globally, or for this
    /// profile. Enabling it rehomes the tile and the click works. `name` is nil
    /// until the extension is loaded, when there is no display name to show.
    case extensionDisabled(name: String?)
    /// The extension is gone: uninstalled, or a page saved before Detour
    /// recorded extension ids, which no install will ever claim. Nothing
    /// installed claims the origin, so there is no name to show. The tile stays
    /// where it is; the next restore drops it (TASK-24).
    case extensionUnavailable

    /// What to tell the user, as a toast.
    var message: String {
        switch self {
        case .extensionDisabled(let name?):
            return "“\(name)” is turned off. Turn it on in Settings › Extensions to open this page."
        case .extensionDisabled(nil):
            return "This page belongs to an extension that is turned off. Turn it on in Settings › Extensions to open it."
        case .extensionUnavailable:
            return "This page belongs to an extension that is no longer installed."
        }
    }
}
