import Foundation
import WebKit

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

    // MARK: - What a claim records (TASK-134)

    /// What a background context's claim does with the owed event.
    enum ClaimDisposition: Equatable {
        /// Answer the event and record it delivered.
        case deliver
        /// Answer the event and record it delivered, but take the record back if
        /// the claiming context's background content then fails to load.
        case deliverProvisionally
        /// Answer nothing and leave the ledger alone: the event stays owed.
        case withhold
    }

    /// The rule for when an event counts as delivered. The claim is sent by a
    /// timer the polyfill queues before the extension's own script runs, so it
    /// is also sent by a worker whose script then threw — a context nothing will
    /// ever dispatch in. `listenerCount` is how many `onInstalled` listeners the
    /// context had registered when it claimed (nil from a caller that does not
    /// say), `backgroundLoadFailed` whether WebKit has already reported
    /// `backgroundContentFailedToLoad` for it.
    ///
    /// - A listener was there → delivered. The reply can still reach a worker
    ///   that died meanwhile; that loss is the accepted one (see
    ///   `AppDatabase.claimRuntimeInstalledEvent`), and it is what keeps an event
    ///   from ever being delivered twice.
    /// - No listener, and the load has failed → withheld. The next context that
    ///   loads still owes the event.
    /// - No listener, and no failure so far → delivered provisionally. An
    ///   extension that simply does not listen has had its install as far as the
    ///   ledger goes (so a later version is an `update`, and nothing keeps
    ///   waking it for an event it ignores), but the failure report for a script
    ///   that threw arrives a moment after its claim, and takes the record back
    ///   (`ProvisionalInstalledEventClaims`).
    static func claimDisposition(listenerCount: Int?, backgroundLoadFailed: Bool) -> ClaimDisposition {
        guard let listenerCount, listenerCount <= 0 else { return .deliver }
        return backgroundLoadFailed ? .withhold : .deliverProvisionally
    }
}

/// The ledger change one claim made, kept so it can be taken back.
struct RuntimeInstalledEventClaim: Equatable {
    let details: RuntimeInstalledEvent.Details
    /// The row before the claim; nil when there was none.
    let previous: ExtensionInstalledEventRecord?
    /// The row the claim wrote.
    let written: ExtensionInstalledEventRecord
}

/// Claims made by background contexts that had no `onInstalled` listener
/// (TASK-134), until it is known whether their background content loaded. When
/// WebKit reports `backgroundContentFailedToLoad` for the claiming context, the
/// claim is undone: nothing was there to receive the event, so the context that
/// eventually loads still owes it. Kept in memory only: an app that quits
/// between such a claim and its failure report keeps the ledger as claimed.
final class ProvisionalInstalledEventClaims {
    static let shared = ProvisionalInstalledEventClaims()

    private struct Entry {
        weak var context: AnyObject?
        let claim: RuntimeInstalledEventClaim
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private static func key(extensionID: String, profileID: String) -> String { "\(profileID)|\(extensionID)" }

    /// Remember `claim`, made by `context`. A newer claim for the same profile
    /// and extension replaces an older one.
    func record(_ claim: RuntimeInstalledEventClaim, context: AnyObject, extensionID: String, profileID: String) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.context != nil }
        entries[Self.key(extensionID: extensionID, profileID: profileID)] = Entry(context: context, claim: claim)
    }

    /// `context`'s background content failed to load: undo the claim it made, if
    /// it made the one on record. Returns the event that is owed again.
    @discardableResult
    func contextFailedToLoad(_ context: AnyObject, extensionID: String, profileID: String,
                             database: AppDatabase = .shared) -> RuntimeInstalledEvent.Details? {
        let key = Self.key(extensionID: extensionID, profileID: profileID)
        lock.lock()
        guard let entry = entries[key], entry.context === context else {
            lock.unlock()
            return nil
        }
        entries[key] = nil
        lock.unlock()
        return database.undoRuntimeInstalledEventClaim(entry.claim) ? entry.claim.details : nil
    }
}

extension WKWebExtensionContext {
    /// Whether WebKit has reported `backgroundContentFailedToLoad` for this
    /// context and still lists it.
    var hasBackgroundContentLoadFailure: Bool {
        errors.contains {
            let error = $0 as NSError
            return error.domain == WKWebExtensionContext.errorDomain
                && error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
        }
    }
}
