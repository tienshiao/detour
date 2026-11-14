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

import Foundation

struct Endpoint {
    let url: URL
    let token: String
}

enum RelayError: Error {
    case notRunning(String)
    case refused(Int, String)
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
          let urlString = fields["url"] as? String, let url = URL(string: urlString),
          let token = fields["token"] as? String else {
        throw RelayError.notRunning("Detour is not running with automation turned on "
            + "(no endpoint at \(file.path)). Turn it on in Detour's Settings > General > Automation.")
    }
    if let pid = fields["pid"] as? Int, kill(pid_t(pid), 0) != 0, errno == ESRCH {
        throw RelayError.notRunning("Detour is not running (its endpoint file is left from process \(pid)).")
    }
    return Endpoint(url: url, token: token)
}

/// The relay's state: the endpoint, the session, and the client's initialize
/// to replay when a session has to be started again.
@MainActor final class Relay {
    private var endpoint: Endpoint?
    private var session: String?
    private var protocolVersion: String?
    private var initializeParams: Any?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private func post(_ body: Data, includeSession: Bool = true) async throws -> (Int, Data, String?) {
        if endpoint == nil { endpoint = try readEndpoint() }
        guard let endpoint else { throw RelayError.notRunning("Detour is not running") }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if includeSession, let session { request.setValue(session, forHTTPHeaderField: sessionHeader) }
        if includeSession, let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader) }
        do {
            let (data, response) = try await urlSession.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, data, http.value(forHTTPHeaderField: sessionHeader))
        } catch {
            self.endpoint = nil
            throw RelayError.notRunning("Detour did not answer at \(endpoint.url.absoluteString) "
                + "(\(error.localizedDescription)). Is it still running with automation on?")
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
        if isInitialize {
            initializeParams = object?["params"]
            session = nil
        }
        do {
            var status: Int, data: Data, newSession: String?
            do {
                (status, data, newSession) = try await post(line, includeSession: !isInitialize)
            } catch RelayError.notRunning {
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
        } catch RelayError.refused(let status, let body) {
            return errorLine(id: id, message: "Detour refused the request (HTTP \(status)): "
                + body.trimmingCharacters(in: .whitespacesAndNewlines))
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
        guard let session, let endpoint else { return }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
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
