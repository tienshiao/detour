import XCTest
import Network
@testable import Detour

/// The automation endpoint over a real loopback socket (TASK-228.1, AC #9,
/// #14): the authorisation refusals as a client sees them, a whole session on
/// one keep-alive connection, and a request split across TCP segments.
nonisolated final class AutomationEndpointTests: XCTestCase {

    private let token = "test-token-0123456789abcdef0123456789abcdef"
    private var endpoint: AutomationEndpoint?

    @MainActor override func tearDown() async throws {
        endpoint?.stop()
        endpoint = nil
        try await super.tearDown()
    }

    @MainActor private func start() async throws -> (URL, MCPServer) {
        let tool = MCPTool(
            name: "echo", title: "Echo", description: "Returns its text.",
            inputSchema: MCPSchema.input([("text", .string("Text"))], required: ["text"]),
            outputSchema: MCPSchema.output(["text": MCPSchema.stringType]), annotations: ["readOnlyHint": true],
            handler: { ["text": .string(try $0.requiredString("text"))] })
        let server = MCPServer(tools: [tool], serverVersion: "test", instructions: "")
        let endpoint = try AutomationEndpoint(port: 0, token: token) { request in
            await server.handle(request)
        }
        self.endpoint = endpoint
        let port = try await endpoint.start()
        XCTAssertNotEqual(port, 0)
        return (try XCTUnwrap(URL(string: AutomationCredentials.endpointURL(port: port))), server)
    }

    private func request(_ url: URL, method: String = "POST", body: JSONValue? = nil,
                         headers: [String: String] = [:], authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body?.serialized()
        return request
    }

    private func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    private let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "socket test", "version": "1"]],
    ]

    @MainActor func testWithoutTheTokenTheClientGetsA401WithNoOAuthDiscovery() async throws {
        let (url, server) = try await start()
        let (response, _) = try await send(request(url, body: initialize, authorized: false))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(response.value(forHTTPHeaderField: "WWW-Authenticate"), "Bearer realm=\"Detour\"")
        let (wrong, _) = try await send(request(url, body: initialize, headers: ["Authorization": "Bearer wrong"],
                                                authorized: false))
        XCTAssertEqual(wrong.statusCode, 401)
        XCTAssertTrue(server.sessions.sessions.isEmpty, "a refused request never reaches the server")
    }

    @MainActor func testAWebPagesOriginIsRefusedEvenWithTheToken() async throws {
        let (url, server) = try await start()
        let (response, _) = try await send(request(url, body: initialize, headers: ["Origin": "https://evil.example"]))
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertTrue(server.sessions.sessions.isEmpty)
    }

    @MainActor func testAWholeSessionOverTheSocket() async throws {
        let (url, server) = try await start()
        let (initialized, initBody) = try await send(request(url, body: initialize))
        XCTAssertEqual(initialized.statusCode, 200)
        let session = try XCTUnwrap(initialized.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(try JSONValue.parse(initBody)["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(server.sessions.sessions[session]?.clientName, "socket test")

        let sessionHeaders = ["Mcp-Session-Id": session, "MCP-Protocol-Version": "2025-06-18"]
        let (notified, _) = try await send(request(url, body: ["jsonrpc": "2.0", "method": "notifications/initialized"],
                                                   headers: sessionHeaders))
        XCTAssertEqual(notified.statusCode, 202)

        let call: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                               "params": ["name": "echo", "arguments": ["text": "över the wire"]]]
        let (called, callBody) = try await send(request(url, body: call, headers: sessionHeaders))
        XCTAssertEqual(called.statusCode, 200)
        XCTAssertEqual(try JSONValue.parse(callBody)["result"]?["structuredContent"], ["text": "över the wire"])

        let (deleted, _) = try await send(request(url, method: "DELETE", headers: sessionHeaders))
        XCTAssertEqual(deleted.statusCode, 204)
        XCTAssertTrue(server.sessions.sessions.isEmpty)
        let (after, _) = try await send(request(url, body: call, headers: sessionHeaders))
        XCTAssertEqual(after.statusCode, 404)
    }

    /// Raw TCP: the head and the body arrive in separate segments, and two
    /// requests share the connection.
    @MainActor func testARequestSplitAcrossSegmentsAndAKeptAliveConnection() async throws {
        let (url, _) = try await start()
        let port = try XCTUnwrap(url.port)
        let body = initialize.jsonString
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let ping = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let queue = DispatchQueue(label: "automation-endpoint-test")
        connection.start(queue: queue)
        defer { connection.cancel() }
        func write(_ text: String) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        try await write(head)
        try await Task.sleep(for: .milliseconds(100))
        try await write(body)
        try await write(ping)

        // Read until the server closes (the second request asked it to).
        var received = Data()
        while true {
            let (data, done): (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, isComplete)) }
                }
            }
            if let data { received.append(data) }
            if done || data == nil || data?.isEmpty == true { break }
        }
        let text = String(decoding: received, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK"), text)
        XCTAssertTrue(text.contains("Mcp-Session-Id: "), "the first request initialized a session")
        XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count - 1, 2, "both requests were answered: \(text)")
        XCTAssertTrue(text.contains("HTTP/1.1 400 Bad Request"), "the second has no session")
        XCTAssertTrue(text.contains("Connection: close"))
    }
}
