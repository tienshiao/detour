import Foundation
import GRDB

struct DownloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "download"

    var id: String
    var filename: String
    var sourceURL: String?
    var destinationURL: String
    var totalBytes: Int64
    var bytesWritten: Int64
    var state: String
    var createdAt: Date
    var completedAt: Date?
}
