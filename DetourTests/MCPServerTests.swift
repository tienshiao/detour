import XCTest
@testable import Detour

/// The MCP side of the automation endpoint (TASK-228.1): Streamable HTTP
/// routing, version negotiation, sessions, tool results and error shapes, and
/// the schema rules that keep every client able to use the tools (AC #12,
/// #16). Driven with parsed requests, no socket.
nonisolated final class MCPServerTests: XCTestCase {

    @MainActor private func makeServer(extraTools: [MCPTool] = []) -> MCPServer {
        let echo = MCPTool(
            name: "echo", title: "Echo", description: "Returns its text.",
            inputSchema: MCPSchema.input([("text", .string("Text")), ("count", .integer("Count"))], required: ["text"]),
            outputSchema: MCPSchema.output(["text": MCPSchema.stringType]),
            annotations: ["readOnlyHint": true],
            handler: { arguments in
                ["text": .string(try arguments.requiredString("text")), "count": .int(try arguments.int("count") ?? 0)]
            })
        let fails = MCPTool(
            name: "fails", title: "Fails", description: "Always fails.",
            inputSchema: MCPSchema.input([]), outputSchema: MCPSchema.output([:]), annotations: [:],
            handler: { _ in throw AutomationToolError(.unknownWindow, "No open window 9") })
        return MCPServer(tools: [echo, fails] + extraTools, serverVersion: "1.2.3", instructions: "Hello",
                         now: { Date(timeIntervalSince1970: 1000) })
    }

    private func post(_ body: JSONValue, session: String? = nil, headers: [String: String] = [:]) -> AutomationHTTP.Request {
        var all = ["content-type": "application/json"]
        if let session { all["mcp-session-id"] = session }
        all.merge(headers) { _, new in new }
        return AutomationHTTP.Request(method: "POST", path: "/mcp", headers: all, body: body.serialized())
    }

    private func initializeMessage(version: String = "2025-06-18", name: String = "Test client") -> JSONValue {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": ["protocolVersion": .string(version), "capabilities": [:],
                    "clientInfo": ["name": .string(name), "version": "9"]]]
    }

    @MainActor private func session(_ server: MCPServer) async throws -> String {
        let response = await server.handle(post(initializeMessage()))
        return try XCTUnwrap(response.header(MCPServer.sessionHeader))
    }

    private func body(_ response: AutomationHTTP.Response) throws -> JSONValue {
        try JSONValue.parse(response.body)
    }

    // MARK: Initialize

    @MainActor func testInitializeNegotiatesASupportedVersionAndStartsASession() async throws {
        let server = makeServer()
        for version in MCPServer.supportedProtocolVersions {
            let response = await server.handle(post(initializeMessage(version: version)))
            XCTAssertEqual(response.status, 200)
            let result = try body(response)["result"]
            XCTAssertEqual(result?["protocolVersion"], .string(version))
            XCTAssertEqual(result?["serverInfo"]?["version"], "1.2.3")
            XCTAssertEqual(result?["instructions"], "Hello")
            XCTAssertEqual(result?["capabilities"]?["tools"], ["listChanged": false])
            XCTAssertNotNil(response.header(MCPServer.sessionHeader))
        }
        let unknown = await server.handle(post(initializeMessage(version: "2099-01-01")))
        XCTAssertEqual(try body(unknown)["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]),
                       "an unknown version gets the newest; the client decides")
    }

    @MainActor func testASessionRecordsTheClientsNameForTheIndicator() async throws {
        let server = makeServer()
        let id = try await session(server)
        let recorded = try XCTUnwrap(server.sessions.sessions[id])
        XCTAssertEqual(recorded.clientName, "Test client")
        XCTAssertEqual(recorded.clientVersion, "9")
        XCTAssertFalse(recorded.initialized)
        let notified = await server.handle(post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: id))
        XCTAssertEqual(notified.status, 202)
        XCTAssertTrue(server.sessions.sessions[id]?.initialized ?? false)

        let titled: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": ["protocolVersion": "2025-06-18",
                                            "clientInfo": ["name": "claude-code", "title": "Claude Code", "version": "2"]]]
        let titledResponse = await server.handle(post(titled))
        let other = try XCTUnwrap(titledResponse.header(MCPServer.sessionHeader))
        XCTAssertEqual(server.sessions.sessions[other]?.clientName, "Claude Code", "the title, when there is one")
        XCTAssertEqual(server.sessions.orderedSessions.count, 2)
    }

    @MainActor func testSessionChangesAreReported() async throws {
        let server = makeServer()
        var changes = 0
        server.sessions.onChange = { changes += 1 }
        let id = try await session(server)
        XCTAssertEqual(changes, 1)
        let deleted = await server.handle(AutomationHTTP.Request(method: "DELETE", path: "/mcp",
                                                                 headers: ["mcp-session-id": id], body: Data()))
        XCTAssertEqual(deleted.status, 204)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(server.sessions.sessions.isEmpty)
    }

    // MARK: Sessions and routing

    @MainActor func testRequestsNeedAKnownSession() async throws {
        let server = makeServer()
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 5, "method": "ping"]
        let missing = await server.handle(post(ping))
        XCTAssertEqual(missing.status, 400)
        XCTAssertEqual(try body(missing)["id"], 5)
        let unknown = await server.handle(post(ping, session: "nope"))
        XCTAssertEqual(unknown.status, 404, "404 tells the client to start a new session")

        let id = try await session(server)
        let ok = await server.handle(post(ping, session: id))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try body(ok), ["jsonrpc": "2.0", "id": 5, "result": [:]])

        _ = await server.handle(AutomationHTTP.Request(method: "DELETE", path: "/mcp",
                                                       headers: ["mcp-session-id": id], body: Data()))
        let ended = await server.handle(post(ping, session: id))
        XCTAssertEqual(ended.status, 404)
        let deleteAgain = await server.handle(AutomationHTTP.Request(method: "DELETE", path: "/mcp",
                                                                     headers: ["mcp-session-id": id], body: Data()))
        XCTAssertEqual(deleteAgain.status, 404)
    }

    @MainActor func testTheOldestIdleSessionMakesRoomBeyondTheLimit() async throws {
        var tick = 0.0
        let server = MCPServer(tools: [], serverVersion: "1", instructions: "", now: {
            tick += 1
            return Date(timeIntervalSince1970: tick)
        })
        let first = try await session(server)
        let second = try await session(server)
        for _ in 2..<MCPSessionStore.maximumSessions { _ = try await session(server) }
        // Seen again, so no longer the oldest.
        _ = await server.handle(post(["jsonrpc": "2.0", "id": 1, "method": "ping"], session: first))
        let latest = try await session(server)
        XCTAssertEqual(server.sessions.sessions.count, MCPSessionStore.maximumSessions)
        XCTAssertNotNil(server.sessions.sessions[latest])
        XCTAssertNotNil(server.sessions.sessions[first], "a session in use stays")
        XCTAssertNil(server.sessions.sessions[second], "the least recently seen one goes")
    }

    @MainActor func testRoutingAndTransportErrors() async throws {
        let server = makeServer()
        let get = await server.handle(AutomationHTTP.Request(method: "GET", path: "/mcp", headers: [:], body: Data()))
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.header("Allow"), "POST, DELETE")
        let other = await server.handle(AutomationHTTP.Request(method: "POST", path: "/", headers: [:], body: Data()))
        XCTAssertEqual(other.status, 404)
        let text = await server.handle(AutomationHTTP.Request(method: "POST", path: "/mcp",
                                                              headers: ["content-type": "text/plain"], body: Data("{}".utf8)))
        XCTAssertEqual(text.status, 415)
        let garbage = await server.handle(AutomationHTTP.Request(method: "POST", path: "/mcp",
                                                                 headers: ["content-type": "application/json"],
                                                                 body: Data("{nope".utf8)))
        XCTAssertEqual(garbage.status, 400)
        XCTAssertEqual(try body(garbage)["error"]?["code"], -32700)
        let version = await server.handle(post(initializeMessage(), headers: ["mcp-protocol-version": "1999-01-01"]))
        XCTAssertEqual(version.status, 400)
        let batchedInit = await server.handle(post(.array([initializeMessage()])))
        XCTAssertEqual(batchedInit.status, 400)
    }

    @MainActor func testABatchGetsOneResponsePerRequestAndNoneForNotifications() async throws {
        let server = makeServer()
        let id = try await session(server)
        let batch: JSONValue = [
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]],
            ["jsonrpc": "2.0", "id": "two", "method": "nope"],
        ]
        let response = await server.handle(post(batch, session: id))
        let replies = try XCTUnwrap(try body(response).arrayValue)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0]["id"], 1)
        XCTAssertEqual(replies[1]["id"], "two")
        XCTAssertEqual(replies[1]["error"]?["code"], -32601)
    }

    // MARK: Tools

    @MainActor private func callTool(_ server: MCPServer, _ name: String, _ arguments: JSONValue?) async throws -> JSONValue {
        let id = try await session(server)
        var params: [String: JSONValue] = ["name": .string(name)]
        if let arguments { params["arguments"] = arguments }
        let response = await server.handle(post(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": .object(params)],
                                                session: id))
        XCTAssertEqual(response.status, 200)
        return try body(response)
    }

    @MainActor func testAToolResultCarriesStructuredContentAndTheSameJSONAsText() async throws {
        let reply = try await callTool(makeServer(), "echo", ["text": "hi", "count": 2])
        let result = try XCTUnwrap(reply["result"])
        XCTAssertEqual(result["isError"], false)
        XCTAssertEqual(result["structuredContent"], ["text": "hi", "count": 2])
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), result["structuredContent"])
        XCTAssertEqual(result["content"]?.arrayValue?.first?["type"], "text")
    }

    @MainActor func testAFailedToolCarriesAStableErrorCode() async throws {
        let reply = try await callTool(makeServer(), "fails", nil)
        let result = try XCTUnwrap(reply["result"])
        XCTAssertEqual(result["isError"], true)
        XCTAssertEqual(result["structuredContent"]?["error"]?["code"], "unknown_window")
        XCTAssertEqual(result["structuredContent"]?["error"]?["message"], "No open window 9")
    }

    @MainActor func testArgumentsAreCheckedAgainstTheSchema() async throws {
        let server = makeServer()
        for (arguments, expected) in [
            (["text": "hi", "txet": "typo"] as JSONValue, "invalid_arguments"),
            ([:] as JSONValue, "invalid_arguments"),
            (["text": 5] as JSONValue, "invalid_arguments"),
            ("not an object" as JSONValue, "invalid_arguments"),
        ] {
            let result = try await callTool(server, "echo", arguments)["result"]
            XCTAssertEqual(result?["isError"], true, "\(arguments.jsonString)")
            XCTAssertEqual(result?["structuredContent"]?["error"]?["code"], .string(expected), "\(arguments.jsonString)")
        }
        let lenient = try await callTool(server, "echo", ["text": "hi", "count": "3"])["result"]
        XCTAssertEqual(lenient?["structuredContent"]?["count"], 3, "an integer sent as a string is accepted")
        let nulls = try await callTool(server, "echo", ["text": "hi", "count": nil])["result"]
        XCTAssertEqual(nulls?["structuredContent"]?["count"], 0, "null means omitted")
    }

    @MainActor func testAnUnknownToolIsAProtocolError() async throws {
        let reply = try await callTool(makeServer(), "nope", [:])
        XCTAssertEqual(reply["error"]?["code"], -32602)
    }

    // MARK: Schemas every client accepts (AC #16)

    @MainActor func testEveryToolsInputSchemaIsFlatAndEveryOutputSchemaToleratesAnError() throws {
        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { [] }, mainMenu: { nil },
                                                                       store: .shared)).all
        XCTAssertFalse(tools.isEmpty)
        let forbidden: Set<String> = ["$ref", "$defs", "definitions", "oneOf", "anyOf", "allOf", "not", "format",
                                      "patternProperties", "if", "then", "else"]
        func walk(_ value: JSONValue, _ path: String) {
            if let object = value.objectValue {
                for (key, child) in object {
                    XCTAssertFalse(forbidden.contains(key), "\(path).\(key)")
                    walk(child, "\(path).\(key)")
                }
            } else if let array = value.arrayValue {
                for (index, child) in array.enumerated() { walk(child, "\(path)[\(index)]") }
            }
        }
        var names = Set<String>()
        for tool in tools {
            XCTAssertTrue(names.insert(tool.name).inserted, "duplicate tool \(tool.name)")
            XCTAssertNotNil(tool.name.range(of: "^[a-z][a-z_]*$", options: .regularExpression), tool.name)
            let input = tool.inputSchema
            XCTAssertEqual(input["type"], "object", tool.name)
            walk(input, tool.name)
            for (name, property) in input["properties"]?.objectValue ?? [:] {
                let type = property["type"]?.stringValue
                XCTAssertTrue(["string", "integer", "number", "boolean", "array"].contains(type ?? ""), "\(tool.name).\(name)")
                if type == "array" {
                    XCTAssertEqual(property["items"]?["type"], "string", "\(tool.name).\(name): arrays hold strings")
                }
                XCTAssertNotNil(property["description"]?.stringValue, "\(tool.name).\(name) is described")
            }
            for required in input["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(input["properties"]?[required.stringValue ?? ""], "\(tool.name) requires a declared property")
            }
            XCTAssertEqual(tool.outputSchema["type"], "object", tool.name)
            XCTAssertNil(tool.outputSchema["required"], "\(tool.name): an error result must validate too")
            XCTAssertNotNil(tool.outputSchema["properties"]?["error"], tool.name)
            XCTAssertNotNil(tool.annotations["readOnlyHint"], tool.name)
        }
    }

    func testErrorCodesAreStable() {
        XCTAssertEqual(AutomationErrorCode.allCases.map(\.rawValue), [
            "invalid_arguments", "unknown_window", "unknown_space", "unknown_tab", "unknown_context",
            "private_unreachable", "dormant_refused", "unknown_menu_item", "menu_item_disabled", "no_open_menu",
            "selector_no_match", "timeout", "gate_closed", "internal_error",
        ], "codes are part of the contract: add new ones, never rename")
    }

    // MARK: Context identifiers (AC #11)

    func testContextIdentifiersNameATabAndReserveExtensionKinds() throws {
        let id = UUID()
        XCTAssertEqual(try AutomationContextID.parse("tab:\(id.uuidString)"), .tab(id))
        XCTAssertEqual(try AutomationContextID.parse(id.uuidString), .tab(id), "a bare tab_id")
        XCTAssertEqual(AutomationContextID.tab(id).stringValue, "tab:\(id.uuidString)")
        for reserved in ["popup:abc", "options:abc", "sidepanel:abc", "worker:abc"] {
            XCTAssertThrowsError(try AutomationContextID.parse(reserved)) {
                XCTAssertEqual(($0 as? AutomationToolError)?.code, .unknownContext, reserved)
            }
        }
        for bad in ["tab:nope", "window:1", "nothing"] {
            XCTAssertThrowsError(try AutomationContextID.parse(bad)) {
                XCTAssertEqual(($0 as? AutomationToolError)?.code, .invalidArguments, bad)
            }
        }
    }
}
