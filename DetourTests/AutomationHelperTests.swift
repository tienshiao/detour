import XCTest
@testable import Detour

/// The bundled stdio helper, detour-mcp (TASK-228.1, AC #15), run from the
/// test host's own bundle against an endpoint of the test's: it relays
/// stdin's JSON-RPC lines and finds the endpoint and token by itself; it
/// starts a new session when the old one ended; it answers with an error
/// when Detour is not running; it ends its session when stdin closes. And
/// the setup Settings copies for clients.
nonisolated final class AutomationHelperTests: XCTestCase {

    private var endpoint: AutomationEndpoint?
    private var processes: [Process] = []
    private var directories: [URL] = []

    @MainActor override func tearDown() async throws {
        for process in processes where process.isRunning { process.terminate() }
        processes.removeAll()
        endpoint?.stop()
        endpoint = nil
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    private final class Helper {
        let process: Process
        let input: FileHandle
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

        init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.lines = output.bytes.lines.makeAsyncIterator()
        }

        func send(_ message: JSONValue) {
            input.write(message.serialized() + Data("\n".utf8))
        }

        func receive() async throws -> JSONValue {
            guard let line = try await lines.next() else { throw CocoaError(.fileReadUnknown) }
            return try JSONValue.parse(Data(line.utf8))
        }
    }

    @MainActor private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    /// An endpoint with one echo tool and its endpoint file.
    @MainActor private func startEndpoint(in directory: URL) async throws -> MCPServer {
        let tool = MCPTool(
            name: "echo", title: "Echo", description: "Returns its text.",
            inputSchema: MCPSchema.input([("text", .string("Text"))], required: ["text"]),
            outputSchema: MCPSchema.output(["text": MCPSchema.stringType]), annotations: ["readOnlyHint": true],
            handler: { ["text": .string(try $0.requiredString("text"))] })
        let server = MCPServer(tools: [tool], serverVersion: "test", instructions: "")
        let token = try AutomationCredentials.makeToken()
        let endpoint = try AutomationEndpoint(port: 0, token: token) { request in await server.handle(request) }
        self.endpoint = endpoint
        let port = try await endpoint.start()
        try AutomationCredentials.writeEndpointFile(port: port, token: token,
                                                    pid: ProcessInfo.processInfo.processIdentifier,
                                                    testRun: true, in: directory)
        return server
    }

    @MainActor private func launchHelper(endpointFile: URL) throws -> Helper {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/detour-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path.path), "the helper ships in the app")
        let process = Process()
        process.executableURL = path
        process.environment = ["DETOUR_MCP_ENDPOINT_FILE": endpointFile.path, "HOME": NSHomeDirectory()]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        processes.append(process)
        return Helper(process: process, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
    }

    private let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                   "clientInfo": ["name": "claude-desktop", "title": "Claude Desktop", "version": "1"]],
    ]

    @MainActor func testTheHelperRelaysASessionAndEndsItWhenStdinCloses() async throws {
        let directory = try temporaryDirectory()
        let server = try await startEndpoint(in: directory)
        let helper = try launchHelper(endpointFile: directory.appendingPathComponent(AutomationCredentials.endpointFileName))

        helper.send(initialize)
        let initialized = try await helper.receive()
        XCTAssertEqual(initialized["id"], 1)
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], "detour")
        XCTAssertEqual(server.sessions.orderedSessions.map(\.clientName), ["Claude Desktop"], "the client's own name")
        helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        helper.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]]])
        let called = try await helper.receive()
        XCTAssertEqual(called["id"], 2, "a notification gets no line; the next line answers the call")
        XCTAssertEqual(called["result"]?["structuredContent"], ["text": "hi"])

        // The session ended on Detour's side (idle, or Reset Token): the helper starts another.
        server.sessions.endAll()
        helper.send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "again"]]])
        let again = try await helper.receive()
        XCTAssertEqual(again["result"]?["structuredContent"], ["text": "again"])
        XCTAssertEqual(server.sessions.orderedSessions.map(\.clientName), ["Claude Desktop"])

        try helper.input.close()
        try await waitUntil("the helper to end its session", timeout: 5) { server.sessions.sessions.isEmpty }
        try await waitUntil("the helper to exit", timeout: 5) { !helper.process.isRunning }
        XCTAssertEqual(helper.process.terminationStatus, 0)
    }

    @MainActor func testWithoutDetourEachRequestGetsAnErrorSayingSo() async throws {
        let directory = try temporaryDirectory()
        let helper = try launchHelper(endpointFile: directory.appendingPathComponent("missing.json"))
        helper.send(initialize)
        let reply = try await helper.receive()
        XCTAssertEqual(reply["id"], 1)
        XCTAssertEqual(reply["error"]?["code"], -32000)
        XCTAssertTrue(reply["error"]?["message"]?.stringValue?.contains("not running") == true,
                      reply.jsonString)
        try helper.input.close()
    }

    // MARK: Per-client tokens (TASK-228.5)

    /// The user's endpoint: approved clients' tokens only, the prompt faked,
    /// and an endpoint file with no token.
    @MainActor private func startUserEndpoint(in directory: URL, prompter: FakeApprovalPrompter)
        async throws -> (MCPServer, AutomationClientStore) {
        let tool = MCPTool(
            name: "echo", title: "Echo", description: "Returns its text.",
            inputSchema: MCPSchema.input([("text", .string("Text"))], required: ["text"]),
            outputSchema: MCPSchema.output(["text": MCPSchema.stringType]), annotations: ["readOnlyHint": true],
            handler: { ["text": .string(try $0.requiredString("text"))] })
        let server = MCPServer(tools: [tool], serverVersion: "test", instructions: "")
        let store = AutomationClientStore(directory: directory)
        server.isClientApproved = { store.contains(clientID: $0) }
        let approvals = AutomationApprovals(store: store, prompter: prompter)
        let endpoint = try AutomationEndpoint(port: 0, credentials: .perClient(store),
                                              handler: { await server.handle($0) },
                                              authorizer: { await approvals.handle($0, cancellation: $1) })
        self.endpoint = endpoint
        let port = try await endpoint.start()
        try AutomationCredentials.writeEndpointFile(port: port, token: nil,
                                                    pid: ProcessInfo.processInfo.processIdentifier,
                                                    testRun: false, in: directory)
        return (server, store)
    }

    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private func call(_ id: Int, _ text: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": "echo", "arguments": ["text": .string(text)]]]
    }

    @MainActor func testTheHelperAsksForATokenSavesItPrivatelyAndReusesIt() async throws {
        let directory = try temporaryDirectory()
        let prompter = FakeApprovalPrompter()
        let (server, store) = try await startUserEndpoint(in: directory, prompter: prompter)
        let endpointFile = directory.appendingPathComponent(AutomationCredentials.endpointFileName)
        let helper = try launchHelper(endpointFile: endpointFile)

        helper.send(initialize)
        try await waitUntil("Detour's prompt") { prompter.prompts.count == 1 }
        XCTAssertEqual(prompter.prompts[0].request,
                       AutomationApprovalRequest(name: "claude-desktop", title: "Claude Desktop", version: "1"),
                       "the helper sends the client's name, title and version")
        prompter.prompts[0].respond(.allow)
        let initialized = try await helper.receive()
        XCTAssertEqual(initialized["id"], 1)
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], "detour")
        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(server.sessions.orderedSessions.map(\.clientID), [record.clientID])
        XCTAssertEqual(server.sessions.orderedSessions.map(\.clientName), ["Claude Desktop"])
        helper.send(call(2, "hi"))
        let called = try await helper.receive()
        XCTAssertEqual(called["result"]?["structuredContent"], ["text": "hi"])

        // Saved 0600 in a 0700 folder under the data directory, named by the
        // name's hash; the token itself matches the approval.
        let folder = directory.appendingPathComponent("mcp-clients")
        XCTAssertEqual(try permissions(folder.path), 0o700)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files, [AutomationClientStore.hash("claude-desktop") + ".token"])
        let tokenPath = folder.appendingPathComponent(files[0]).path
        XCTAssertEqual(try permissions(tokenPath), 0o600)
        let saved = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(store.client(presenting: saved)?.clientID, record.clientID)
        try helper.input.close()
        try await waitUntil("the helper to exit", timeout: 5) { !helper.process.isRunning }

        // The next run uses the saved token: no prompt.
        let next = try launchHelper(endpointFile: endpointFile)
        next.send(initialize)
        let again = try await next.receive()
        XCTAssertEqual(again["result"]?["serverInfo"]?["name"], "detour")
        XCTAssertEqual(prompter.prompts.count, 1)
        try next.input.close()
    }

    @MainActor func testARevokedClientIsToldSoItsTokenDeletedAndNotPromptedAgain() async throws {
        let directory = try temporaryDirectory()
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .allow
        let (server, store) = try await startUserEndpoint(in: directory, prompter: prompter)
        let helper = try launchHelper(endpointFile: directory.appendingPathComponent(AutomationCredentials.endpointFileName))
        helper.send(initialize)
        _ = try await helper.receive()
        let record = try XCTUnwrap(store.records.first)
        let tokenFile = directory.appendingPathComponent("mcp-clients/\(AutomationClientStore.hash("claude-desktop")).token")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFile.path))

        // Disconnect / Revoke in Detour.
        store.revoke(clientID: record.clientID)
        server.sessions.endAll(clientID: record.clientID)
        helper.send(call(2, "after"))
        let refused = try await helper.receive()
        XCTAssertEqual(refused["id"], 2)
        XCTAssertTrue(refused["error"]?["message"]?.stringValue?.contains("revoked") == true, refused.jsonString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path), "the token file is deleted")
        helper.send(call(3, "still"))
        let still = try await helper.receive()
        XCTAssertTrue(still["error"]?["message"]?.stringValue?.contains("restart the client") == true, still.jsonString)
        XCTAssertEqual(prompter.prompts.count, 1, "no prompt loop")
        XCTAssertTrue(store.records.isEmpty)
        try helper.input.close()
    }

    @MainActor func testADeniedClientGetsAnErrorAndNoSecondPromptInTheRun() async throws {
        let directory = try temporaryDirectory()
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .deny
        let (server, store) = try await startUserEndpoint(in: directory, prompter: prompter)
        let helper = try launchHelper(endpointFile: directory.appendingPathComponent(AutomationCredentials.endpointFileName))
        helper.send(initialize)
        let denied = try await helper.receive()
        XCTAssertEqual(denied["id"], 1)
        XCTAssertTrue(denied["error"]?["message"]?.stringValue?.contains("403") == true, denied.jsonString)
        helper.send(call(2, "x"))
        let again = try await helper.receive()
        XCTAssertNotNil(again["error"])
        XCTAssertEqual(prompter.prompts.count, 1)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(server.sessions.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mcp-clients").path))
        try helper.input.close()
    }

    // MARK: What Settings copies

    @MainActor func testTheSetupCommandsRunTheHelper() {
        let path = "/Applications/Detour.app/Contents/MacOS/detour-mcp"
        XCTAssertEqual(GeneralSettingsViewController.claudeCodeCommand(helperPath: path, environment: [:]),
                       "claude mcp add detour -- '\(path)'")
        XCTAssertEqual(GeneralSettingsViewController.claudeCodeCommand(helperPath: path,
                                                                       environment: ["DETOUR_DATA_DIR": "DetourVerify"]),
                       "claude mcp add detour -e 'DETOUR_DATA_DIR=DetourVerify' -- '\(path)'")
        // Spaces, `$` and quotes stay literal in the shell.
        XCTAssertEqual(GeneralSettingsViewController.claudeCodeCommand(helperPath: "/Apps/My $Detour's.app/detour-mcp",
                                                                       environment: ["DETOUR_DATA_DIR": "Detour Test"]),
                       #"claude mcp add detour -e 'DETOUR_DATA_DIR=Detour Test' -- '/Apps/My $Detour'\''s.app/detour-mcp'"#)
        XCTAssertEqual(GeneralSettingsViewController.mcpConfig(helperPath: path, environment: [:]),
                       #"{"mcpServers":{"detour":{"command":"/Applications/Detour.app/Contents/MacOS/detour-mcp"}}}"#)
        XCTAssertEqual(GeneralSettingsViewController.helperEnvironment(dataDirectory: "Detour"), [:])
        XCTAssertEqual(GeneralSettingsViewController.helperEnvironment(dataDirectory: "DetourVerify"),
                       ["DETOUR_DATA_DIR": "DetourVerify"])
    }
}
