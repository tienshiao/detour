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
