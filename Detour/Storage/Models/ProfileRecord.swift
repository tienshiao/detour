import Foundation
import GRDB

struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profile"

    var id: String
    var name: String
    var userAgentMode: Int       // 0 = detour, 1 = safari, 2 = custom
    var customUserAgent: String?
    var archiveThreshold: Double // seconds; default 43200 (12 hours), 0 = never
    var sleepThreshold: Double   // seconds; default 3600 (1 hour), 0 = never
    var searchEngine: Int        // 0 = google, 1 = duckduckgo, 2 = bing, 3 = yahoo, 4 = ecosia, 5 = kagi
    var searchSuggestionsEnabled: Bool
    var isPerTabIsolation: Bool
    var isAdBlockingEnabled: Bool
    var isEasyListEnabled: Bool
    var isEasyPrivacyEnabled: Bool
    var isEasyListCookieEnabled: Bool
    var isMalwareFilterEnabled: Bool
}
