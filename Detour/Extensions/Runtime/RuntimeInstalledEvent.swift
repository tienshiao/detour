import Foundation

/// `chrome.runtime.onInstalled` as Detour emits it (TASK-22).
///
/// WebKit's own event cannot be used as is. It decides the reason per context
/// *load* (`WebExtensionContext::determineInstallReasonDuringLoad`): a version
/// different from the one it last saw is an update, otherwise a load into a
/// controller that is no longer "freshly created" (5 s after its first load) is an
/// install, and any other load is none. Measured in the app (see
/// docs/1password-integration-plan.md, "runtime.onInstalled"): the first extension a
/// profile ever loads gets no event at all, while every same-version reload —
/// background-load recovery, disable → enable — gets `install` again. An extension
/// doing first-run setup in `onInstalled` (1Password opens its welcome page) would
/// both miss its real install and repeat it on every recovery.
///
/// So the service-worker polyfill keeps WebKit's event from reaching the extension
/// and asks Detour instead, once per worker start. Detour answers from a ledger of
/// the version each (profile, extension) last had the event delivered for, which is
/// what makes the Chrome rules below hold: per profile, exactly once per install or
/// version change, never for a reload, relaunch or re-enable, and never
/// `chrome_update` (Detour has no browser-update notion to report). A profile where
/// the extension was disabled during an update gets the `update` when it next runs
/// there, the way Chrome defers a pending dispatch.
enum RuntimeInstalledEvent {

    enum Reason: String, Equatable {
        case install
        case update
    }

    struct Details: Equatable {
        let reason: Reason
        /// The version the event was last delivered for; only for `update`.
        let previousVersion: String?

        /// The `details` object `onInstalled` listeners receive: `previousVersion`
        /// is absent (not null) for an install, as in Chrome.
        var dictionary: [String: Any] {
            var result: [String: Any] = ["reason": reason.rawValue]
            if let previousVersion { result["previousVersion"] = previousVersion }
            return result
        }
    }

    /// The event a context running `currentVersion` still owes its listeners, given
    /// the version the ledger last delivered the event for in that profile (nil when
    /// it never has). Nil when nothing is owed.
    ///
    /// Same version → nothing, which is every reload, relaunch and re-enable. A
    /// same-version reinstall is deliberately nothing too: Chrome reports `update`
    /// for reloading an unpacked extension, but a ledger keyed by version cannot
    /// tell that apart from a reload, and a spurious event is the worse error.
    static func pending(deliveredVersion: String?, currentVersion: String) -> Details? {
        guard let deliveredVersion else {
            return Details(reason: .install, previousVersion: nil)
        }
        guard deliveredVersion != currentVersion else { return nil }
        return Details(reason: .update, previousVersion: deliveredVersion)
    }
}
