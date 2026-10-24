import Foundation

/// The per-profile set of hosts the user turned content blocking off for:
/// the `contentBlocking = false` rows of `SiteSettingsStore` (TASK-187; its own
/// `contentBlockerWhitelist` table until then).
///
/// Purely a persisted host set: the switch itself is enforced per navigation by
/// disabling WebKit's content rule lists on the main frame's
/// `WKWebpagePreferences` (see `ContentBlockerManager.configure`), not by a
/// compiled `ignore-previous-rules` list. WebKit evaluates every content rule
/// list independently and merges their Block results, so an
/// `ignore-previous-rules` rule in a *separate* list never cancels a block from
/// the filter lists — the old whitelist list was a no-op (TASK-69).
class ContentBlockerWhitelist {
    private let store: SiteSettingsStore

    init(store: SiteSettingsStore = .shared) {
        self.store = store
    }

    /// Whether `host` is covered by `whitelistedHosts`: an exact match, or a
    /// subdomain of a stored host. Case-insensitive; an empty host matches
    /// nothing. The production decision, kept pure so tests exercise exactly it
    /// — defined via `entriesCovering` so there is one predicate, not two.
    static func covers(host: String, whitelistedHosts: Set<String>) -> Bool {
        !entriesCovering(host: host, whitelistedHosts: whitelistedHosts).isEmpty
    }

    /// Every stored entry that covers `host` — the exact host and any parent
    /// domain entry it sits under, in their stored spelling (`toggleHost`
    /// clears them from the store by value). Entries are lowercased on
    /// the way in, but this stays correct for a set that was not normalised.
    static func entriesCovering(host: String, whitelistedHosts: Set<String>) -> Set<String> {
        whitelistedHosts.filter { SiteSetting.contentBlocking.site($0, covers: host) }
    }

    func isWhitelisted(host: String, profileID: UUID) -> Bool {
        store.override(.contentBlocking, forSite: host, profileID: profileID) == false
    }

    /// Turns blocking off for `host` (stores that host, lowercased), or back on by
    /// removing every entry that covers it — a parent domain entry left behind
    /// would keep the site whitelisted and the switch would not take. The
    /// direction follows `isWhitelisted` (the store's most specific override),
    /// so a more specific `contentBlocking = true` row under a whitelisted
    /// parent makes the switch turn blocking off rather than clear the parent.
    func toggleHost(_ host: String, profileID: UUID) {
        if isWhitelisted(host: host, profileID: profileID) {
            let covering = Self.entriesCovering(host: host, whitelistedHosts: hostsForProfile(profileID))
            store.clear(.contentBlocking, sites: covering, profileID: profileID)
        } else {
            store.set(.contentBlocking, site: host, to: false, profileID: profileID)
        }
    }

    /// The hosts content blocking is off for in `profileID`.
    func hostsForProfile(_ profileID: UUID) -> Set<String> {
        Set(store.overrides(.contentBlocking, profileID: profileID).filter { !$0.value }.keys)
    }
}
