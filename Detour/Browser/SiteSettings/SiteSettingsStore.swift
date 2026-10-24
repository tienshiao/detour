import Foundation

/// A per-site preference with a stored override (TASK-187). A site with no
/// row uses the setting's default, which the setting's consumer owns.
enum SiteSetting: String, CaseIterable {
    /// `false` turns content blocking off for the site (`ContentBlockerWhitelist`).
    case contentBlocking
    /// `false` keeps the site's playing video out of the picture in picture
    /// Detour enters on a tab switch (`AutomaticPictureInPicture`, TASK-188).
    case pictureInPicture

    /// Whether a value set in the Private profile is written to disk. One that
    /// is not lives in memory until the Private session ends
    /// (`SiteSettingsStore.discardPrivateSession`), so the sites a Private
    /// window visited are not left in the database. Content blocking has
    /// always saved them, and does until it is moved over.
    var persistsInPrivate: Bool {
        switch self {
        case .contentBlocking: return true
        case .pictureInPicture: return false
        }
    }

    /// Whether an override stored for `site` applies to a page on `host`.
    /// Both are compared lowercased; an empty host or site matches nothing.
    func site(_ site: String, covers host: String) -> Bool {
        let site = site.lowercased()
        let host = host.lowercased()
        guard !site.isEmpty, !host.isEmpty else { return false }
        switch self {
        case .contentBlocking, .pictureInPicture:
            // The host or any parent host, as the whitelist always matched.
            return host == site || host.hasSuffix("." + site)
        }
    }
}

/// The session database's `siteSetting` table, cached per profile. Sites are
/// stored lowercased. Loaded once at creation; every change is written
/// through, except the Private profile's values of a setting that does not
/// persist in Private.
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
        guard writesThrough(setting, profileID: profileID) else { return }
        database.saveSiteSetting(SiteSettingRecord(profileID: profileID.uuidString, site: site,
                                                   setting: setting.rawValue, value: value))
    }

    /// Removes the stored values for `sites`, so they fall back to the default.
    func clear(_ setting: SiteSetting, sites: Set<String>, profileID: UUID) {
        let sites = Set(sites.map { $0.lowercased() })
        for site in sites {
            values[profileID]?[setting]?[site] = nil
        }
        guard writesThrough(setting, profileID: profileID) else { return }
        database.deleteSiteSettings(profileID: profileID.uuidString, setting: setting.rawValue, sites: sites)
    }

    /// Puts `host` back on the default by removing every stored value that
    /// covers it: a parent site's row left behind would still apply.
    func resetToDefault(_ setting: SiteSetting, forHost host: String, profileID: UUID) {
        let covering = overrides(setting, profileID: profileID).keys.filter { setting.site($0, covers: host) }
        guard !covering.isEmpty else { return }
        clear(setting, sites: Set(covering), profileID: profileID)
    }

    /// The last Private window closed: forgets the Private profile's values of
    /// the settings kept in memory only.
    func discardPrivateSession() {
        for setting in SiteSetting.allCases where !setting.persistsInPrivate {
            values[TabStore.incognitoProfileID]?[setting] = nil
        }
    }

    /// Whether `setting`'s values for `profileID` are in the database: all but
    /// the Private profile's values of a setting kept in memory there.
    private func writesThrough(_ setting: SiteSetting, profileID: UUID) -> Bool {
        profileID != TabStore.incognitoProfileID || setting.persistsInPrivate
    }
}
