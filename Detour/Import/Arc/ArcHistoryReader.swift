import Foundation
import GRDB

/// One page visit from an Arc profile's history.
nonisolated struct ArcHistoryVisit: Sendable, Equatable {
    var url: String
    /// Chromium keeps one title per URL, not per visit.
    var title: String?
    /// Seconds since 1970, as `history.db` stores visit times.
    var visitTime: Double
    /// The user typed the address (Chromium's TYPED transition).
    var isTyped: Bool
}

/// Reads an Arc profile's browsing history: the Chromium `History` SQLite
/// database in `User Data/<profile>/` (schema version 70 in Arc 1.172.1).
///
/// The database is copied first and only the copy is opened. Arc may be
/// running and holding the original open, and an import must never write to
/// (or lock) Arc's own files.
nonisolated enum ArcHistoryReader {
    /// Microseconds between 1601-01-01 (Chromium's epoch) and 1970-01-01.
    static let chromiumEpochOffsetMicroseconds: Int64 = 11_644_473_600 * 1_000_000

    /// Chromium page transition core types (`ui::PageTransition`, low byte).
    static let typedTransition = 1
    static let subframeTransitions: Set<Int> = [3, 4] // AUTO_SUBFRAME, MANUAL_SUBFRAME

    static func unixTime(chromiumMicroseconds: Int64) -> Double {
        Double(chromiumMicroseconds - chromiumEpochOffsetMicroseconds) / 1_000_000
    }

    static func chromiumMicroseconds(unixTime: Double) -> Int64 {
        Int64((unixTime * 1_000_000).rounded()) + chromiumEpochOffsetMicroseconds
    }

    /// The visits newer than `cutoff` (seconds since 1970), oldest first.
    /// Subframe loads and hidden URLs are left out, and so is anything that is
    /// not an http(s) page, matching what Detour itself records.
    static func readVisits(historyFile: URL, since cutoff: Double) throws(ArcImportError) -> [ArcHistoryVisit] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyFile.path) else { return [] }
        let workDirectory = fileManager.temporaryDirectory
            .appending(path: "ArcHistoryImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: workDirectory) }
        let copy = workDirectory.appending(path: "History", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: historyFile, to: copy)
            // A WAL beside the file holds committed pages; a hot rollback
            // journal holds the pages to restore over a half-written
            // transaction. Either way SQLite needs it to read a consistent copy.
            for suffix in ["-journal", "-wal"] {
                let sidecar = URL(filePath: historyFile.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try fileManager.copyItem(at: sidecar, to: URL(filePath: copy.path + suffix))
                }
            }
        } catch {
            throw .unreadable(path: historyFile.path, reason: error.localizedDescription)
        }
        do {
            return try readVisits(databaseAt: copy, since: cutoff)
        } catch let error as ArcImportError {
            throw error
        } catch {
            throw .unrecognizedFormat(path: historyFile.path, reason: error.localizedDescription)
        }
    }

    /// Reads visits from a Chromium history database file in place. It must
    /// be a private copy (see `readVisits(historyFile:since:)`): the
    /// connection is read-write so SQLite can roll back a copied hot journal
    /// (a read-only one fails with SQLITE_READONLY_ROLLBACK) and rebuild the
    /// WAL index of a copied WAL.
    static func readVisits(databaseAt file: URL, since cutoff: Double) throws -> [ArcHistoryVisit] {
        var configuration = Configuration()
        configuration.label = "ArcHistoryImport"
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            guard try db.tableExists("urls"), try db.tableExists("visits") else {
                throw ArcImportError.unrecognizedFormat(path: file.path,
                                                        reason: "no urls or visits table")
            }
            let rows = try Row.fetchCursor(db, sql: """
                SELECT urls.url AS url, urls.title AS title,
                       visits.visit_time AS visitTime, visits.transition AS transition
                FROM visits JOIN urls ON urls.id = visits.url
                WHERE visits.visit_time >= ? AND urls.hidden = 0
                ORDER BY visits.visit_time, visits.id
                """, arguments: [chromiumMicroseconds(unixTime: cutoff)])
            var visits: [ArcHistoryVisit] = []
            while let row = try rows.next() {
                let transition = (row["transition"] as Int64?).map { Int($0 & 0xFF) } ?? 0
                guard !subframeTransitions.contains(transition),
                      let urlString = row["url"] as String?,
                      let url = URL(string: urlString),
                      ArcSidebarReader.isImportable(url) else { continue }
                let title = (row["title"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                visits.append(ArcHistoryVisit(
                    url: urlString, title: title,
                    visitTime: unixTime(chromiumMicroseconds: row["visitTime"]),
                    isTyped: transition == typedTransition))
            }
            return visits
        }
    }
}
