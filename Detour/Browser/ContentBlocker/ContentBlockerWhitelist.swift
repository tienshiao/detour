import Foundation
import WebKit

class ContentBlockerWhitelist {
    private let ruleStore: ContentRuleStore
    private var whitelistedHosts: [UUID: Set<String>] = [:]  // profileID -> hosts

    static let whitelistIdentifier = "content-blocker-whitelist"

    init(ruleStore: ContentRuleStore) {
        self.ruleStore = ruleStore
    }

    func loadFromDatabase() {
        let records = AppDatabase.shared.loadContentBlockerWhitelist()
        whitelistedHosts.removeAll()
        for record in records {
            guard let profileID = UUID(uuidString: record.profileID) else { continue }
            whitelistedHosts[profileID, default: []].insert(record.host)
        }
    }

    func isWhitelisted(host: String, profileID: UUID) -> Bool {
        whitelistedHosts[profileID]?.contains(host) ?? false
    }

    func toggleHost(_ host: String, profileID: UUID, completion: @escaping () -> Void) {
        if isWhitelisted(host: host, profileID: profileID) {
            whitelistedHosts[profileID]?.remove(host)
            AppDatabase.shared.deleteContentBlockerWhitelistEntry(profileID: profileID.uuidString, host: host)
        } else {
            whitelistedHosts[profileID, default: []].insert(host)
            let record = ContentBlockerWhitelistRecord(profileID: profileID.uuidString, host: host)
            AppDatabase.shared.saveContentBlockerWhitelistEntry(record)
        }
        recompileWhitelistRules(profileID: profileID, completion: completion)
    }

    func hostsForProfile(_ profileID: UUID) -> Set<String> {
        whitelistedHosts[profileID] ?? []
    }

    func recompileWhitelistRules(profileID: UUID, completion: @escaping () -> Void) {
        let hosts = hostsForProfile(profileID)
        let identifier = "\(Self.whitelistIdentifier)-\(profileID.uuidString)"

        guard !hosts.isEmpty else {
            ruleStore.removeCachedList(identifier: identifier)
            completion()
            return
        }

        let ifDomains = hosts.map { "*\($0)" }
        let rules: [[String: Any]] = [[
            "trigger": [
                "url-filter": ".*",
                "if-domain": ifDomains
            ],
            "action": ["type": "ignore-previous-rules"]
        ]]

        ruleStore.compile(identifier: identifier, rules: rules) { _ in
            completion()
        }
    }

    func getWhitelistRuleList(profileID: UUID) -> WKContentRuleList? {
        let identifier = "\(Self.whitelistIdentifier)-\(profileID.uuidString)"
        return ruleStore.getCachedList(identifier: identifier)
    }
}
