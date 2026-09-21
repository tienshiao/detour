import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "EXT-ITP")

/// The private `-[WKWebsiteDataStore _logUserInteraction:completionHandler:]`
/// (WKWebsiteDataStorePrivate.h, macOS 10.15.4+), reached through an `@objc`
/// protocol rather than a raw `perform` so the URL and the completion block are
/// bridged by the compiler.
@objc private protocol WKWebsiteDataStoreInteractionShim {
    @objc(_logUserInteraction:completionHandler:)
    func logUserInteraction(_ url: URL, completionHandler: @escaping () -> Void)
}

/// Keeps a profile's loaded extension origins inside WebKit's tracking
/// prevention (ITP) user-interaction window, so the launch-time processing pass
/// stops deleting their script-written storage (TASK-70).
///
/// The mechanism, from `ResourceLoadStatisticsStore.cpp`: with the default
/// `FirstPartyWebsiteDataRemovalMode::AllButCookies`, `shouldRemoveAllButCookiesFor()`
/// schedules *every* observed domain whose record has no unexpired user
/// interaction for script-written-storage removal — service worker
/// registrations, IndexedDB and localStorage. A record with
/// `hadUserInteraction == false` qualifies immediately. An extension origin
/// (`webkit-extension://<uuid>/`) enters the statistics table as soon as a page
/// loads one of the extension's cross-host resources (a content-script iframe or
/// fetch), and `RegistrableDomain` for such a URL is the uuid host — the very
/// key the storage manager deletes by. Observed with 1Password: the pass logged
/// `deleteAndRestrictWebsiteDataForRegistrableDomains ... 706
/// domainsToDeleteAllScriptWrittenStorageFor`, immediately followed by
/// `SWServerRegistration::clear` for the extension, and the worker was gone.
///
/// Popup clicks do log an interaction for the extension origin — but WebKit
/// mints a fresh base URL at every context load, so each launch's origin is
/// brand new: the extension's own pages put it in the statistics table (a
/// fingerprinting-API access or a third-party script load is enough), the
/// merge that inserts it runs a processing pass synchronously, and the
/// registration is cleared within milliseconds — long before any popup click.
/// Detour therefore logs the interaction itself, at context load before the
/// background content starts, and once a day for as long as the app runs —
/// the interaction window counts "operating days" (days the browser ran), 7 or
/// 30, so a re-log a day keeps the origin unexpired however long the process
/// lives.
///
/// Non-persistent stores are skipped: they have no ITP database and nothing to
/// preserve. That is a property of the store the extension's pages run in, not
/// of the profile (`keptDataStore`, TASK-90) — which since TASK-73 is what
/// takes the Private profile out: its extension pages run in its own ephemeral
/// store, where no purge can reach them.
///
/// Known hole: only *loaded* contexts are covered. WebKit carries an
/// extension's IndexedDB and localStorage onto each new origin from its
/// persisted `LastSeenBaseURL`, so an extension left disabled for longer than
/// the window (7 or 30 operating days) has that origin purged in the meantime
/// and the rename at its next load finds nothing to move. Closing it means
/// persisting the last base URL of every installed extension and re-logging
/// those too.
final class ExtensionOriginInteractionKeeper {

    /// How often the loaded origins are re-logged. The interaction window is
    /// measured in operating days, so once a day is enough and never late.
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Generous slack: this timer has no deadline worth waking the CPU for.
    static let refreshTolerance: TimeInterval = 60 * 60

    /// Test seam: every interaction that reaches WebKit is announced here
    /// first, so a test can count the calls the production path makes without
    /// reading the unified log. Skipped calls (non-persistent store, missing
    /// selector) do not fire it.
    static var interactionLogHookForTesting: ((URL, WKWebsiteDataStore) -> Void)?

    private static let logInteractionSelector =
        NSSelectorFromString("_logUserInteraction:completionHandler:")
    /// The missing-selector complaint is worth exactly one line per process: it
    /// would otherwise repeat for every context of every profile.
    private static var loggedMissingSelector = false

    /// Weak: the keeper is owned by the profile, and a profile that is gone has
    /// no origins left to keep.
    private weak var profile: Profile?
    private var timer: Timer?

    init(profile: Profile) {
        self.profile = profile
    }

    /// Log a user interaction for `baseURL`'s registrable domain in
    /// `dataStore`'s ITP database. `WebsiteDataStore::logUserInteraction` only
    /// rejects about:/empty URLs, so an extension base URL is accepted and sets
    /// `hadUserInteraction` / `mostRecentUserInteractionTime` for its domain.
    static func logInteraction(for baseURL: URL, on dataStore: WKWebsiteDataStore,
                               extensionID: String, completion: (() -> Void)? = nil) {
        guard dataStore.isPersistent else {
            // A non-persistent store keeps no statistics and loses its storage
            // at teardown anyway.
            completion?()
            return
        }
        guard dataStore.responds(to: logInteractionSelector) else {
            if !loggedMissingSelector {
                loggedMissingSelector = true
                log.error("ITP: -[WKWebsiteDataStore _logUserInteraction:completionHandler:] is unavailable; extension origins will fall out of the interaction window and tracking prevention will purge their storage")
            }
            completion?()
            return
        }
        interactionLogHookForTesting?(baseURL, dataStore)
        let host = baseURL.host ?? baseURL.absoluteString
        unsafeBitCast(dataStore, to: WKWebsiteDataStoreInteractionShim.self)
            .logUserInteraction(baseURL) {
                // Deliberately at .notice, not .info: this line is how a
                // production run is verified against the Networking log's
                // `deleteAndRestrictWebsiteDataForRegistrableDomains`.
                log.notice("ITP: logged user interaction for \(extensionID, privacy: .public) origin \(host, privacy: .public)")
                completion?()
            }
    }

    /// Called by `Profile.loadExtensionContext` once a context is loaded: the
    /// origin WebKit just minted is observed from this moment on, so the
    /// interaction has to be logged now rather than at the next daily refresh.
    /// Also covers the TASK-68 background recovery, which reloads the context
    /// through the same method and so gets a fresh origin logged with it.
    func contextDidLoad(_ context: WKWebExtensionContext, extensionID: String) {
        guard let store = keptDataStore() else { return }
        Self.logInteraction(for: context.baseURL, on: store, extensionID: extensionID)
        startTimerIfNeeded()
    }

    /// Re-log every context currently loaded in the profile. The daily timer's
    /// work, exposed so a test can drive it without waiting a day.
    func refreshNow() {
        guard let profile, let store = keptDataStore() else {
            stop()
            return
        }
        // Snapshot: logging is asynchronous in WebKit but the dictionary is
        // read here, and a context reload during the walk must not mutate it
        // under us.
        for (extensionID, context) in Array(profile.extensionContexts) {
            Self.logInteraction(for: context.baseURL, on: store, extensionID: extensionID)
        }
    }

    /// Stop the daily refresh. Called when the profile unloads everything —
    /// `unloadAllExtensions`, which `TabStore.deleteProfile` runs before the
    /// profile leaves the store.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    /// The persistent store the profile's extension pages run in, or nil when
    /// there is nothing to keep: a deleted profile (its storage is being
    /// removed), a released one, or pages that really do run in a
    /// non-persistent store.
    ///
    /// Decided by the store, never by `isIncognito` (TASK-90). That rule is
    /// what keeps this correct across TASK-73: while the Private profile's
    /// extension pages were on WebKit's default store — persistent, and ITP
    /// session 1 — skipping them *because the profile is incognito* left
    /// 1Password's Private-profile origin outside the interaction window, and
    /// within a minute of every worker start the purge deleted its IndexedDB
    /// files under the running worker, every transaction aborted, and the
    /// extension's backend re-initialised in a loop that logged 20 errors a
    /// second and pinned the Networking process (production, 2026-09-18 and
    /// -19). Those pages now run in the profile's own ephemeral store
    /// (TASK-73), so `isPersistent` below drops them by itself — no ITP
    /// database, no purge, nothing to keep. What is logged for a persistent
    /// profile is the extension's `webkit-extension://<uuid>/` origin only —
    /// nothing about what was browsed.
    private func keptDataStore() -> WKWebsiteDataStore? {
        guard let profile, !profile.isDeleted else { return nil }
        // The store the extension's pages actually run in — the controller's
        // web view configuration, which `Profile` points at the profile store.
        // Logging into any other store is a no-op for the purge, which runs in
        // the session that holds the registration (production, 2026-09-13).
        let store = profile.extensionController.configuration.webViewConfiguration.websiteDataStore
        return store.isPersistent ? store : nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // The run loop owns the timer and the block holds the keeper weakly, so
        // a timer that outlives its profile would otherwise fire forever: it
        // invalidates itself the first time it finds nothing there.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                         repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.refreshNow()
        }
        timer.tolerance = Self.refreshTolerance
        self.timer = timer
    }
}
