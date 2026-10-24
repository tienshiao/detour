import Foundation

/// A per-site preference with a stored override (TASK-187). A site with no
/// row uses the setting's default, which the setting's consumer owns.
enum SiteSetting: String, CaseIterable {
    /// `false` turns content blocking off for the site (`ContentBlockerWhitelist`).
    case contentBlocking
    /// `false` keeps the site's playing video out of the picture in picture
    /// Detour enters on a tab switch (`AutomaticPictureInPicture`, TASK-188).
    case pictureInPicture
    /// Dev mode for the site (TASK-186.5): `true` turns it on for any site,
    /// `false` turns it off for a local development URL (`DevMode`).
    case devMode

    /// Whether a value set in the Private profile is written to disk. One that
    /// is not lives in memory until the Private session ends
    /// (`SiteSettingsStore.discardPrivateSession`), so the sites a Private
    /// window visited are not left in the database. Content blocking has
    /// always saved them, and does until it is moved over.
    var persistsInPrivate: Bool {
        switch self {
        case .contentBlocking: return true
        case .pictureInPicture, .devMode: return false
        }
    }

    /// Whether an override stored for `site` applies to a page whose site is
    /// `key`. The key's form is the setting's: the page's host for content
    /// blocking and picture in picture, its host plus a non-default port
    /// (`devModeSiteKey`) for dev mode. Both are compared lowercased; an empty
    /// key or site matches nothing.
    func site(_ site: String, covers key: String) -> Bool {
        let site = site.lowercased()
        let key = key.lowercased()
        guard !site.isEmpty, !key.isEmpty else { return false }
        switch self {
        case .contentBlocking, .pictureInPicture:
            // The host or any parent host, as the whitelist always matched.
            return key == site || key.hasSuffix("." + site)
        case .devMode:
            // Exact: a site key names one app, and a port is not a subdomain.
            return key == site
        }
    }
}

/// The session database's `siteSetting` table, cached per profile. Sites are
/// stored lowercased. Loaded once at creation; every change is written
/// through, except the Private profile's values of a setting that does not
/// persist in Private.
final class SiteSettingsStore {
    /// Posted (object: the store) when a stored value changes or is removed, with
    /// the `SiteSetting` under `settingKey` and the profile's UUID under
    /// `profileIDKey`, so a view showing a site's state can follow at once.
    static let didChangeNotification = Notification.Name("SiteSettingsStoreDidChange")
    static let settingKey = "setting"
    static let profileIDKey = "profileID"

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

    /// The stored value that applies to a page whose site is `key` (in the
    /// setting's form, `SiteSetting.site(_:covers:)`): of the sites covering
    /// it, the most specific (longest). Nil when none does.
    func override(_ setting: SiteSetting, forSite key: String, profileID: UUID) -> Bool? {
        overrides(setting, profileID: profileID)
            .filter { setting.site($0.key, covers: key) }
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
        let changed = values[profileID]?[setting]?[site] != value
        values[profileID, default: [:]][setting, default: [:]][site] = value
        if writesThrough(setting, profileID: profileID) {
            database.saveSiteSetting(SiteSettingRecord(profileID: profileID.uuidString, site: site,
                                                       setting: setting.rawValue, value: value))
        }
        if changed { postChange(setting, profileID: profileID) }
    }

    /// Removes the stored values for `sites`, so they fall back to the default.
    func clear(_ setting: SiteSetting, sites: Set<String>, profileID: UUID) {
        let sites = Set(sites.map { $0.lowercased() })
        var removed = false
        for site in sites {
            removed = values[profileID]?[setting]?.removeValue(forKey: site) != nil || removed
        }
        if writesThrough(setting, profileID: profileID) {
            database.deleteSiteSettings(profileID: profileID.uuidString, setting: setting.rawValue, sites: sites)
        }
        if removed { postChange(setting, profileID: profileID) }
    }

    /// Puts the site `key` back on the default by removing every stored value
    /// that covers it: a parent site's row left behind would still apply.
    func resetToDefault(_ setting: SiteSetting, forSite key: String, profileID: UUID) {
        let covering = overrides(setting, profileID: profileID).keys.filter { setting.site($0, covers: key) }
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

    private func postChange(_ setting: SiteSetting, profileID: UUID) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                                        userInfo: [Self.settingKey: setting, Self.profileIDKey: profileID])
    }

    /// Whether `setting`'s values for `profileID` are in the database: all but
    /// the Private profile's values of a setting kept in memory there.
    private func writesThrough(_ setting: SiteSetting, profileID: UUID) -> Bool {
        profileID != TabStore.incognitoProfileID || setting.persistsInPrivate
    }
}
