import CryptoKit
import Foundation
import os
import Synchronization

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "automation")

/// A client the user approved for the automation endpoint (TASK-228.5): what
/// the approval prompt named, and the SHA-256 of the token it was given. The
/// token itself is never stored; only the client (through the bundled
/// helper) keeps it.
nonisolated struct AutomationClientRecord: Codable, Equatable, Sendable {
    var clientID: UUID
    /// The name the client sent (`clientInfo.name`): the client's own, not
    /// verified by anything.
    var name: String
    /// Its `clientInfo.title`, when it sent one.
    var title: String?
    var version: String?
    var created: Date
    var lastUsed: Date?
    /// Lowercase hex SHA-256 of the token's UTF-8 bytes.
    var tokenSHA256: String

    /// What Detour shows for the client: its title, else its name.
    var displayName: String { title ?? name }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case name, title, version, created
        case lastUsed = "last_used"
        case tokenSHA256 = "token_sha256"
    }
}

/// Who an authorised request came from, as the endpoint hands it to
/// `MCPServer`: set by the endpoint after the token matched, never read from
/// anything the client sent.
nonisolated struct AutomationClientIdentity: Equatable, Sendable {
    let id: UUID
    let name: String
}

/// The approved clients of the user's endpoint (TASK-228.5), kept in
/// `mcp-clients.json` in the data directory (0600). One store per
/// controller is the single source of truth: the endpoint checks tokens
/// against it on its own queue, Settings and the indicator read and revoke
/// on the main actor.
///
/// - Tokens are kept only as SHA-256 hashes and compared in constant time
///   against every record (the time says how many clients there are, not
///   how much of a guess matched).
/// - Revoking removes the record and writes the file before it returns, so
///   the very next request with that token is refused.
/// - `last_used` is updated in memory on every authorised request and
///   written at most once a minute per client; every write serialises the
///   current records under the lock, so a late write cannot bring back a
///   revoked one.
/// - A missing or malformed file loads as no clients: nothing is approved
///   that the file does not plainly say.
///
/// `Sendable`: the records are behind a `Mutex`; the file URL is constant.
nonisolated final class AutomationClientStore: Sendable {

    static let fileName = "mcp-clients.json"
    /// How often one client's `last_used` reaches the file.
    static let lastUsedWriteInterval: TimeInterval = 60

    private struct State {
        var records: [AutomationClientRecord]
        /// When each client's `last_used` was last written.
        var lastWritten: [UUID: Date] = [:]
    }

    struct FileFormat: Codable {
        var version: Int
        var clients: [AutomationClientRecord]
    }

    /// Nil keeps the records in memory only (tests).
    let fileURL: URL?
    private let state: Mutex<State>

    init(directory: URL?) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        state = Mutex(State(records: fileURL.map(Self.load) ?? []))
    }

    private static func load(_ url: URL) -> [AutomationClientRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let file = try decoder.decode(FileFormat.self, from: data)
            // A record whose hash is not a SHA-256 could never match; one
            // without a name could not be shown. Neither is kept.
            return file.clients.filter { $0.tokenSHA256.count == 64 && !$0.name.isEmpty }
        } catch {
            log.error("Automation: \(url.lastPathComponent, privacy: .public) is unreadable, so no client is approved: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// The records, oldest first.
    var records: [AutomationClientRecord] {
        state.withLock { $0.records }
    }

    func record(id: UUID) -> AutomationClientRecord? {
        state.withLock { $0.records.first { $0.clientID == id } }
    }

    func contains(clientID: UUID) -> Bool {
        state.withLock { $0.records.contains { $0.clientID == clientID } }
    }

    /// The client whose token `presented` is, comparing its hash with every
    /// record's in constant time.
    func client(presenting presented: String) -> AutomationClientRecord? {
        let hash = Self.hash(presented)
        return state.withLock { state in
            var match: AutomationClientRecord?
            for record in state.records {
                // No early exit: every record is compared.
                let equal = AutomationAuthorization.constantTimeEqual(hash, record.tokenSHA256)
                if equal && match == nil { match = record }
            }
            return match
        }
    }

    /// Approves a client: a new random token, whose hash is written to the
    /// file before the token is returned. Throws (and approves nothing) when
    /// the file cannot be written.
    func add(name: String, title: String?, version: String?, now: Date) throws -> (token: String, record: AutomationClientRecord) {
        let token = try AutomationCredentials.makeToken()
        let record = AutomationClientRecord(clientID: UUID(), name: name, title: title, version: version,
                                            created: now, lastUsed: nil, tokenSHA256: Self.hash(token))
        try state.withLock { state in
            var records = state.records
            records.append(record)
            try write(records)
            state.records = records
        }
        return (token, record)
    }

    /// Removes a client: its token is refused from the next request on.
    /// Returns the record, or nil when there was none.
    @discardableResult
    func revoke(clientID: UUID) -> AutomationClientRecord? {
        state.withLock { state in
            guard let index = state.records.firstIndex(where: { $0.clientID == clientID }) else { return nil }
            let removed = state.records.remove(at: index)
            state.lastWritten[clientID] = nil
            do {
                try write(state.records)
            } catch {
                // Revoked in memory all the same: the running endpoint refuses
                // the token. The file still names it until the next write.
                log.error("Automation: revoking \(removed.name, privacy: .public) was not saved: \(String(describing: error), privacy: .public)")
            }
            return removed
        }
    }

    /// Notes an authorised request: `last_used` in memory, and in the file
    /// at most every `lastUsedWriteInterval`.
    func noteUsed(clientID: UUID, now: Date) {
        state.withLock { state in
            guard let index = state.records.firstIndex(where: { $0.clientID == clientID }) else { return }
            state.records[index].lastUsed = now
            if let written = state.lastWritten[clientID], now.timeIntervalSince(written) < Self.lastUsedWriteInterval {
                return
            }
            state.lastWritten[clientID] = now
            try? write(state.records)
        }
    }

    /// Called with the lock held, so writes follow one another in order.
    private func write(_ records: [AutomationClientRecord]) throws {
        guard let fileURL else { return }
        let data = try Self.encoder.encode(FileFormat(version: 1, clients: records))
        try AutomationCredentials.writePrivateFile(data, to: fileURL)
    }

    /// Lowercase hex SHA-256 of `token`'s UTF-8 bytes.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
