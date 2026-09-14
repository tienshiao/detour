import Foundation
import WebKit

/// The per-profile set of hosts the user turned content blocking off for.
///
/// Purely a persisted host set: the switch itself is enforced per navigation by
/// disabling WebKit's content rule lists on the main frame's
/// `WKWebpagePreferences` (see `ContentBlockerManager.configure`), not by a
/// compiled `ignore-previous-rules` list. WebKit evaluates every content rule
/// list independently and merges their Block results, so an
/// `ignore-previous-rules` rule in a *separate* list never cancels a block from
/// the filter lists — the old whitelist list was a no-op (TASK-69).
class ContentBlockerWhitelist {
    private let database: AppDatabase
    private var whitelistedHosts: [UUID: Set<String>] = [:]  // profileID -> hosts

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func loadFromDatabase() {
        let records = database.loadContentBlockerWhitelist()
        whitelistedHosts.removeAll()
        for record in records {
            guard let profileID = UUID(uuidString: record.profileID) else { continue }
            whitelistedHosts[profileID, default: []].insert(record.host)
        }
    }

    /// Whether `host` is covered by `whitelistedHosts`: an exact match, or a
    /// subdomain of a stored host. Case-insensitive; an empty host matches
    /// nothing. The production decision, kept pure so tests exercise exactly it.
    static func covers(host: String, whitelistedHosts: Set<String>) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        return whitelistedHosts.contains { stored in
            let stored = stored.lowercased()
            guard !stored.isEmpty else { return false }
            return host == stored || host.hasSuffix("." + stored)
        }
    }

    /// Every stored entry that covers `host` — the exact host and any parent
    /// domain entry it sits under.
    static func entriesCovering(host: String, whitelistedHosts: Set<String>) -> Set<String> {
        let host = host.lowercased()
        guard !host.isEmpty else { return [] }
        return whitelistedHosts.filter { stored in
            let lowered = stored.lowercased()
            guard !lowered.isEmpty else { return false }
            return host == lowered || host.hasSuffix("." + lowered)
        }
    }

    func isWhitelisted(host: String, profileID: UUID) -> Bool {
        Self.covers(host: host, whitelistedHosts: hostsForProfile(profileID))
    }

    /// Turns blocking off for `host` (stores the exact host), or back on by
    /// removing every entry that covers it — a parent domain entry left behind
    /// would keep the site whitelisted and the switch would not take.
    func toggleHost(_ host: String, profileID: UUID) {
        let hosts = hostsForProfile(profileID)
        let covering = Self.entriesCovering(host: host, whitelistedHosts: hosts)
        if covering.isEmpty {
            whitelistedHosts[profileID, default: []].insert(host)
            database.saveContentBlockerWhitelistEntry(
                ContentBlockerWhitelistRecord(profileID: profileID.uuidString, host: host))
        } else {
            whitelistedHosts[profileID]?.subtract(covering)
            for entry in covering {
                database.deleteContentBlockerWhitelistEntry(profileID: profileID.uuidString, host: entry)
            }
        }
    }

    func hostsForProfile(_ profileID: UUID) -> Set<String> {
        whitelistedHosts[profileID] ?? []
    }
}
