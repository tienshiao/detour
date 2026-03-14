import Foundation
import GRDB

struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile"

    var id: String
    var name: String
    var userAgentMode: Int       // 0 = detour, 1 = safari, 2 = custom
    var customUserAgent: String?
    var archiveThreshold: Double // seconds; default 43200 (12 hours), 0 = never
}
