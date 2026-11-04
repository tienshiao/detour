import Foundation
import GRDB

/// One per-site override (TASK-187): `value` for `setting` on `site` in a
/// profile. A missing row means the setting's default.
struct SiteSettingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "siteSetting"

    var profileID: String
    var site: String
    var setting: String
    var value: Bool
}
