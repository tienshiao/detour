import Foundation

/// `chrome.runtime.onInstalled` as Detour emits it (TASK-22, TASK-29).
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
/// So the polyfill keeps WebKit's event from reaching the extension — in the
/// worker and in its pages — and the worker asks Detour instead, once per worker
/// start. Detour answers from a ledger of the version each (profile, extension)
/// last had the event delivered for, which is what makes the Chrome rules below
/// hold: per profile, exactly once per install, reinstall or version change, never
/// for a reload, relaunch or re-enable, and never `chrome_update` (Detour has no
/// browser-update notion to report). A profile where the extension was disabled
/// during an update gets the `update` when it next runs there, the way Chrome
/// defers a pending dispatch. The Private profile never gets the event.
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

    /// What the ledger holds for one (profile, extension).
    struct LedgerEntry: Equatable {
        /// The version the event was last delivered for.
        let deliveredVersion: String
        /// The user reinstalled the extension (`ExtensionManager.install` over an
        /// installed one) since that delivery.
        let reinstallPending: Bool
    }

    /// The event a context running `currentVersion` still owes its listeners, given
    /// what the ledger holds for that profile (nil when the event was never
    /// delivered there). Nil when nothing is owed.
    ///
    /// - No entry → `install`.
    /// - A different version → `update` from the delivered version.
    /// - A reinstall since the delivery → `update` from the delivered version, which
    ///   for a same-version reinstall is the current one. Chrome reports `update` for
    ///   reloading an unpacked extension; Detour's nearest equivalent is the user
    ///   installing the same extension again. Only an explicit install sets the flag,
    ///   so a background-recovery reload, a relaunch or a disable → enable — all of
    ///   which load the delivered version again — still owe nothing.
    /// - The Private profile → nothing, ever. Chrome's default "spanning" incognito
    ///   mode runs the extension once, in the regular profile, and the incognito side
    ///   never gets its own `onInstalled`; delivering it in Detour's Private profile
    ///   would also rerun first-run setup (1Password's welcome page) in Private
    ///   windows, whose extension storage does not survive a relaunch.
    static func pending(ledger: LedgerEntry?, currentVersion: String, isPrivateProfile: Bool) -> Details? {
        guard !isPrivateProfile else { return nil }
        guard let ledger else {
            return Details(reason: .install, previousVersion: nil)
        }
        guard ledger.reinstallPending || ledger.deliveredVersion != currentVersion else { return nil }
        return Details(reason: .update, previousVersion: ledger.deliveredVersion)
    }
}
