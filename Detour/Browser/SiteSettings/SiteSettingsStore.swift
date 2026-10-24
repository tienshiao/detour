import Foundation

/// A per-site preference with a stored override (TASK-187). A site with no
/// row uses the setting's default, which the setting's consumer owns.
enum SiteSetting: String, CaseIterable {
    /// `false` turns content blocking off for the site (`ContentBlockerWhitelist`).
    case contentBlocking

    /// Whether an override stored for `site` applies to a page on `host`.
    /// Both are compared lowercased; an empty host or site matches nothing.
    func site(_ site: String, covers host: String) -> Bool {
        let site = site.lowercased()
        let host = host.lowercased()
        guard !site.isEmpty, !host.isEmpty else { return false }
        switch self {
        case .contentBlocking:
            // The host or any parent host, as the whitelist always matched.
            return host == site || host.hasSuffix("." + site)
        }
    }
}

/// The session database's `siteSetting` table, cached per profile. Sites are
/// stored lowercased. Loaded once at creation; every change is written through.
final class SiteSettingsStore {
    static let shared = SiteSettingsStore(database: .shared)

    private let database: AppDatabase
    private var values: [UUID: [SiteSetting: [String: Bool]]] = [:]

    init(database: AppDatabase) {
        self.database = database
        for record in database.loadSiteSettings() {
            // A setting this build does not know (written by a newer one) is
            // left in the table and ignored.
            guard let profileID = UUID(uuidString: record.profileID),
                  let setting = SiteSetting(rawValue: record.setting) else { continue }
            values[profileID, default: [:]][setting, default: [:]][record.site.lowercased()] = record.value
        }
    }

    /// The stored value that applies to `host`: of the sites covering it, the
    /// most specific (longest). Nil when none does.
    func override(_ setting: SiteSetting, forHost host: String, profileID: UUID) -> Bool? {
        overrides(setting, profileID: profileID)
            .filter { setting.site($0.key, covers: host) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    /// Every site with a stored value for `setting` in `profileID`.
    func overrides(_ setting: SiteSetting, profileID: UUID) -> [String: Bool] {
        values[profileID]?[setting] ?? [:]
    }

    func set(_ setting: SiteSetting, site: String, to value: Bool, profileID: UUID) {
        let site = site.lowercased()
        guard !site.isEmpty else { return }
        values[profileID, default: [:]][setting, default: [:]][site] = value
        database.saveSiteSetting(SiteSettingRecord(profileID: profileID.uuidString, site: site,
                                                   setting: setting.rawValue, value: value))
    }

    /// Removes the stored values for `sites`, so they fall back to the default.
    func clear(_ setting: SiteSetting, sites: Set<String>, profileID: UUID) {
        let sites = Set(sites.map { $0.lowercased() })
        for site in sites {
            values[profileID]?[setting]?[site] = nil
        }
        database.deleteSiteSettings(profileID: profileID.uuidString, setting: setting.rawValue, sites: sites)
    }
}
