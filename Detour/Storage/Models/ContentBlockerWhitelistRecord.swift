import Foundation
import GRDB

struct ContentBlockerWhitelistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contentBlockerWhitelist"

    var profileID: String
    var host: String
}
