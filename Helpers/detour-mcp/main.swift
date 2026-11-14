// detour-mcp: Detour's MCP server for clients that launch a local command
// and talk to it over stdin and stdout (Claude Desktop, and any other MCP
// client) (TASK-228.1, AC #15).
//
// It relays MCP's stdio transport (one JSON-RPC message per line) to the
// automation endpoint inside the running Detour (Streamable HTTP on
// 127.0.0.1), and finds that endpoint itself in the data directory's
// mcp-endpoint.json, so the client is configured with this command alone and
// never sees the token:
//   ~/Library/Application Support/<DETOUR_DATA_DIR or "Detour">/mcp-endpoint.json
// DETOUR_MCP_ENDPOINT_FILE names the file directly (tests).
//
// When Detour restarted, the token was reset or the session ended, it reads
// the file again, replays the client's initialize and retries once. When
// Detour is not running with automation on, each request gets a JSON-RPC
// error saying so. At the end of stdin it ends its session.
//
// Tokens (TASK-228.5). A test run's endpoint file carries its shared token,
// which the helper uses as it is. The user's endpoint file carries none:
// each client has a token of its own, which the user approves in Detour.
// On the client's initialize, the helper looks for the token it saved
// under the client's name (clientInfo.name):
//   <data directory>/mcp-clients/<SHA-256 of the name>.token  (0600, in a 0700 folder)
// With none, it asks Detour for one (POST /mcp/authorize with the name,
// title and version); Detour shows its Allow / Deny prompt and holds the
// request until the user answers, then the helper saves the token. A
// denial, or a 401 later on (the user disconnected or revoked the client:
// the token file is deleted), is answered with a JSON-RPC error for the
// rest of the run, with no new prompt; the next start of the client asks
// again.

import CryptoKit
import Foundation

struct Endpoint {
    let url: URL
    /// A test run's shared token; nil for the user's endpoint, where each
    /// client has its own.
    let sharedToken: String?
    /// The data directory, where the per-client tokens are kept.
    let directory: URL
}

enum RelayError: Error {
    /// Nothing reached Detour: no endpoint, or nothing listening.
    case notRunning(String)
    /// The request was sent but no answer came (a timeout, a dropped
    /// connection): Detour may have acted on it.
    case noAnswer(String)
    case refused(Int, String)
    /// The client has no token and cannot get one in this run (denied,
    /// revoked, no answer): every request gets this message.
    case unauthorized(String)
}

let protocolVersionHeader = "MCP-Protocol-Version"
let sessionHeader = "Mcp-Session-Id"

func endpointFileURL() -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["DETOUR_MCP_ENDPOINT_FILE"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    let name = environment["DETOUR_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "Detour"
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return support.appendingPathComponent(name, isDirectory: true).appendingPathComponent("mcp-endpoint.json")
}

func readEndpoint() throws -> Endpoint {
    let file = endpointFileURL()
    guard let data = try? Data(contentsOf: file),
          let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let urlString = fields["url"] as? String, let url = URL(string: urlString) else {
        throw RelayError.notRunning("Detour is not running with automation turned on "
            + "(no endpoint at \(file.path)). Turn it on in Detour's Settings > General > Automation.")
    }
    if let pid = fields["pid"] as? Int, kill(pid_t(pid), 0) != 0, errno == ESRCH {
        throw RelayError.notRunning("Detour is not running (its endpoint file is left from process \(pid)).")
    }
    return Endpoint(url: url, sharedToken: fields["token"] as? String, directory: file.deletingLastPathComponent())
}

// MARK: Per-client tokens

/// Where the token approved for the client called `name` is kept.
func clientTokenFile(name: String, in directory: URL) -> URL {
    let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("mcp-clients", isDirectory: true).appendingPathComponent("\(hash).token")
}

/// The saved token, or nil. Never follows a symbolic link.
func readClientToken(_ file: URL) -> String? {
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: 512)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return nil }
    let token = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

/// Saves `token` 0600 in a 0700 folder, by a new file renamed over the old,
/// so it is never readable by others, even for a moment.
func saveClientToken(_ token: String, to file: URL) throws {
    let folder = file.deletingLastPathComponent()
    if mkdir(folder.path, 0o700) != 0 && errno != EEXIST {
        throw RelayError.notRunning("cannot create \(folder.path): errno \(errno)")
    }
    var info = stat()
    guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
        throw RelayError.notRunning("\(folder.path) is not a folder of this user's")
    }
    if info.st_mode & 0o777 != 0o700 { chmod(folder.path, 0o700) }
    let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw RelayError.notRunning("cannot create \(temporary.path): errno \(errno)") }
    let data = Array((token + "\n").utf8)
    let written = Darwin.write(fd, data, data.count)
    close(fd)
    guard written == data.count, rename(temporary.path, file.path) == 0 else {
        unlink(temporary.path)
        throw RelayError.notRunning("cannot save the token in \(folder.path)")
    }
}

/// The relay's state: the endpoint, the session, and the client's initialize
/// to replay when a session has to be started again.
@MainActor final class Relay {
    private var endpoint: Endpoint?
    private var session: String?
    private var protocolVersion: String?
    private var initializeParams: Any?
    /// The token this client was approved with (the user's endpoint).
    private var clientToken: String?
    /// Why this run can no longer reach Detour (denied, revoked): sticky,
    /// so a client that retries never prompts the user again.
    private var unauthorized: String?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
    /// For the authorize request, which Detour holds while its prompt is up
    /// (up to 5 minutes): longer than that.
    private let authorizeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 340
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// The client's name, title and version from its initialize.
    private var clientInfo: (name: String, title: String?, version: String?) {
        let info = (initializeParams as? [String: Any])?["clientInfo"] as? [String: Any]
        let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "MCP client"
        return (name, info?["title"] as? String, info?["version"] as? String)
    }

    /// The bearer token for `endpoint`: the test run's shared one, else this
    /// client's own, read from its file or asked for (the prompt).
    private func bearer(for endpoint: Endpoint) async throws -> String {
        if let shared = endpoint.sharedToken { return shared }
        if let unauthorized { throw RelayError.unauthorized(unauthorized) }
        if let clientToken { return clientToken }
        guard initializeParams != nil else {
            throw RelayError.unauthorized("detour-mcp: the client must send initialize first")
        }
        let file = clientTokenFile(name: clientInfo.name, in: endpoint.directory)
        if let saved = readClientToken(file) {
            clientToken = saved
            return saved
        }
        let token = try await requestToken(from: endpoint)
        do {
            try saveClientToken(token, to: file)
        } catch {
            // Used for this run all the same; the next run asks again.
            FileHandle.standardError.write(Data("detour-mcp: the token was not saved: \(error)\n".utf8))
        }
        clientToken = token
        return token
    }

    /// Asks Detour for a token under the client's name: Detour shows its
    /// prompt and answers when the user does.
    private func requestToken(from endpoint: Endpoint) async throws -> String {
        let info = clientInfo
        var fields: [String: Any] = ["client_name": info.name]
        if let title = info.title { fields["client_title"] = title }
        if let version = info.version { fields["client_version"] = version }
        var url = endpoint.url
        url.append(path: "authorize")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 330
        let data: Data, status: Int
        do {
            let (body, response) = try await authorizeSession.data(for: request)
            data = body
            status = (response as! HTTPURLResponse).statusCode
        } catch {
            self.endpoint = nil
            if (error as? URLError)?.code == .cannotConnectToHost {
                throw RelayError.notRunning("Detour is not running with automation on at \(endpoint.url.absoluteString).")
            }
            let reason = "Detour did not answer the request for access (\(error.localizedDescription)). "
                + "Restart the client to ask again."
            unauthorized = reason
            throw RelayError.unauthorized(reason)
        }
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 200, let token = answer?["token"] as? String, !token.isEmpty {
            return token
        }
        let message = answer?["error"] as? String ?? String(decoding: data, as: UTF8.self)
        let reason = "Detour did not give \(info.name) access (HTTP \(status)): \(message). "
            + "Restart the client to ask again."
        // A denial is final for this run; a refusal for being busy is not.
        if status != 429 && status != 503 { unauthorized = reason }
        throw RelayError.unauthorized(reason)
    }

    /// A 401 with this client's own token: the user disconnected or revoked
    /// it. The token is deleted and the run ends its access, with no prompt.
    private func revoked() -> RelayError {
        if let endpoint {
            try? FileManager.default.removeItem(at: clientTokenFile(name: clientInfo.name, in: endpoint.directory))
        }
        clientToken = nil
        let reason = "Detour revoked this client's access; restart the client to ask again."
        unauthorized = reason
        return RelayError.unauthorized(reason)
    }

    private func post(_ body: Data, includeSession: Bool = true) async throws -> (Int, Data, String?) {
        if endpoint == nil { endpoint = try readEndpoint() }
        guard let endpoint else { throw RelayError.notRunning("Detour is not running") }
        let token = try await bearer(for: endpoint)
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if includeSession, let session { request.setValue(session, forHTTPHeaderField: sessionHeader) }
        if includeSession, let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader) }
        do {
            let (data, response) = try await urlSession.data(for: request)
            let http = response as! HTTPURLResponse
            if http.statusCode == 401, endpoint.sharedToken == nil { throw revoked() }
            return (http.statusCode, data, http.value(forHTTPHeaderField: sessionHeader))
        } catch let error as RelayError {
            throw error
        } catch {
            self.endpoint = nil
            let reason = "Detour did not answer at \(endpoint.url.absoluteString) "
                + "(\(error.localizedDescription)). Is it still running with automation on?"
            // Refused outright: the request never arrived, so it can be sent again.
            if (error as? URLError)?.code == .cannotConnectToHost { throw RelayError.notRunning(reason) }
            throw RelayError.noAnswer(reason)
        }
    }

    /// Starts a session with the client's own initialize, again.
    private func reinitialize() async throws {
        guard let initializeParams else { return }
        session = nil
        let message: [String: Any] = ["jsonrpc": "2.0", "id": "detour-mcp-reinitialize", "method": "initialize",
                                      "params": initializeParams]
        let (status, data, newSession) = try await post(try JSONSerialization.data(withJSONObject: message),
                                                       includeSession: false)
        guard status == 200, let newSession else {
            throw RelayError.refused(status, String(decoding: data, as: UTF8.self))
        }
        session = newSession
        let initialized = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        _ = try await post(initialized)
    }

    /// Forwards one message; returns the response line to write, if any.
    func forward(_ line: Data) async -> Data? {
        let message = try? JSONSerialization.jsonObject(with: line)
        let object = message as? [String: Any]
        let id = object?["id"]
        let isInitialize = object?["method"] as? String == "initialize"
        // A tool call that went unanswered may have run (a click, typed text):
        // never sent twice. Anything else is safe to send again.
        let isToolCall = object?["method"] as? String == "tools/call"
        if isInitialize {
            initializeParams = object?["params"]
            session = nil
        }
        do {
            var status: Int, data: Data, newSession: String?
            do {
                (status, data, newSession) = try await post(line, includeSession: !isInitialize)
            } catch RelayError.noAnswer(let reason) where isToolCall {
                throw RelayError.noAnswer(reason + " The call was not sent again: it may have run.")
            } catch RelayError.notRunning, RelayError.noAnswer {
                // Detour may have restarted on another port: `post` dropped the
                // endpoint it had, so the file is read again; one more try.
                if !isInitialize { try await reinitialize() }
                (status, data, newSession) = try await post(line, includeSession: !isInitialize)
            }
            // A session that ended, a reset token, or a Detour that restarted:
            // read the file again, start a new session and try once more.
            if !isInitialize, status == 404 || status == 401 {
                endpoint = nil
                try await reinitialize()
                (status, data, newSession) = try await post(line)
            }
            if isInitialize, status == 200, let newSession {
                session = newSession
                if let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let version = (result["result"] as? [String: Any])?["protocolVersion"] as? String {
                    protocolVersion = version
                }
            }
            if status == 202 || data.isEmpty { return nil }
            if (200..<300).contains(status) { return data }
            // A JSON-RPC error body is passed on as it is; anything else becomes one.
            if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return id == nil ? nil : data }
            throw RelayError.refused(status, String(decoding: data, as: UTF8.self))
        } catch RelayError.notRunning(let reason) {
            return errorLine(id: id, message: reason)
        } catch RelayError.noAnswer(let reason) {
            return errorLine(id: id, message: reason)
        } catch RelayError.refused(let status, let body) {
            return errorLine(id: id, message: "Detour refused the request (HTTP \(status)): "
                + body.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch RelayError.unauthorized(let reason) {
            return errorLine(id: id, message: reason)
        } catch {
            return errorLine(id: id, message: "detour-mcp: \(error)")
        }
    }

    private func errorLine(id: Any?, message: String) -> Data? {
        guard let id else { return nil }   // a notification gets no answer
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        return try? JSONSerialization.data(withJSONObject: reply)
    }

    /// Ends the session, so Detour's indicator stops showing this client.
    func close() async {
        guard let session, let endpoint, let token = endpoint.sharedToken ?? clientToken else { return }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: sessionHeader)
        _ = try? await urlSession.data(for: request)
    }
}

func write(_ data: Data) {
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

let relay = Relay()
// Split on LF alone, as MCP's stdio transport does: `bytes.lines` also ends a
// line at CR, NEL, U+2028 and U+2029, which JSON allows unescaped inside a
// string, and would cut such a message in two.
var pendingLine = Data()
@MainActor func relayLine(_ bytes: Data) async {
    let trimmed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let reply = await relay.forward(Data(trimmed.utf8)) { write(reply) }
}
for try await byte in FileHandle.standardInput.bytes {
    if byte == 0x0A {
        await relayLine(pendingLine)
        pendingLine.removeAll(keepingCapacity: true)
    } else {
        pendingLine.append(byte)
    }
}
await relayLine(pendingLine)
await relay.close()
