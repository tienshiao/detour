import Foundation

/// The stable, machine-readable codes a failed tool call carries in
/// `structuredContent.error.code` (TASK-228.1, AC #12). Scripts and tests
/// assert on these, so a code is never renamed; new ones are added.
nonisolated enum AutomationErrorCode: String, Sendable, CaseIterable {
    case invalidArguments = "invalid_arguments"
    case unknownWindow = "unknown_window"
    case unknownSpace = "unknown_space"
    case unknownTab = "unknown_tab"
    case unknownContext = "unknown_context"
    case privateUnreachable = "private_unreachable"
    case dormantRefused = "dormant_refused"
    case unknownMenuItem = "unknown_menu_item"
    case menuItemDisabled = "menu_item_disabled"
    case noOpenMenu = "no_open_menu"
    case selectorNoMatch = "selector_no_match"
    case timeout = "timeout"
    case gateClosed = "gate_closed"
    case internalError = "internal_error"
}

/// A tool call that failed in a way the caller can act on.
nonisolated struct AutomationToolError: Error, Equatable, Sendable {
    var code: AutomationErrorCode
    var message: String

    init(_ code: AutomationErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// One tool of the endpoint: its MCP description and what it does.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue
    /// MCP tool annotations (`readOnlyHint`, `destructiveHint`, ...).
    let annotations: JSONValue
    let handler: @MainActor (ToolArguments) async throws -> JSONValue

    /// The tool as `tools/list` describes it.
    var listing: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "outputSchema": outputSchema,
            "annotations": annotations,
        ]
    }
}

/// A tool's arguments, checked against its input schema's property names, so
/// a misspelt argument in a script fails instead of being ignored.
struct ToolArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue], allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AutomationToolError(.invalidArguments, "Unknown argument(s): \(unknown.sorted().joined(separator: ", "))")
        }
        // Clients send null for an omitted optional argument; treat it so.
        self.values = values.filter { !$0.value.isNull }
    }

    func has(_ name: String) -> Bool { values[name] != nil }

    func string(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        guard let string = value.stringValue else { throw typeError(name, "a string") }
        return string
    }

    func requiredString(_ name: String) throws -> String {
        guard let value = try string(name) else { throw missing(name) }
        return value
    }

    func int(_ name: String) throws -> Int? {
        guard let value = values[name] else { return nil }
        // Some clients send integers as strings; accept a plain decimal one.
        if let string = value.stringValue, let parsed = Int(string) { return parsed }
        guard let int = value.intValue else { throw typeError(name, "an integer") }
        return int
    }

    func requiredInt(_ name: String) throws -> Int {
        guard let value = try int(name) else { throw missing(name) }
        return value
    }

    func bool(_ name: String) throws -> Bool? {
        guard let value = values[name] else { return nil }
        if let string = value.stringValue, let parsed = Bool(string) { return parsed }
        guard let bool = value.boolValue else { throw typeError(name, "a boolean") }
        return bool
    }

    func stringArray(_ name: String) throws -> [String]? {
        guard let value = values[name] else { return nil }
        guard let array = value.arrayValue else { throw typeError(name, "an array of strings") }
        return try array.map { element in
            guard let string = element.stringValue else { throw typeError(name, "an array of strings") }
            return string
        }
    }

    func uuid(_ name: String) throws -> UUID? {
        guard let string = try string(name) else { return nil }
        guard let uuid = UUID(uuidString: string) else { throw typeError(name, "a UUID") }
        return uuid
    }

    func requiredUUID(_ name: String) throws -> UUID {
        guard let value = try uuid(name) else { throw missing(name) }
        return value
    }

    private func missing(_ name: String) -> AutomationToolError {
        AutomationToolError(.invalidArguments, "Missing required argument \(name)")
    }

    private func typeError(_ name: String, _ expected: String) -> AutomationToolError {
        AutomationToolError(.invalidArguments, "Argument \(name) must be \(expected)")
    }
}

/// Builds the JSON Schemas tools declare. Input schemas stay flat on purpose
/// (AC #16): one object of string, integer, number, boolean or string-array
/// properties, with no `$ref`, `oneOf`, `anyOf`, `allOf` or formats, which
/// OpenAI and Gemini models reject. `MCPServerTests` walks every tool's
/// schema to hold that.
nonisolated enum MCPSchema {

    enum Property: Sendable {
        case string(String)
        case integer(String)
        case number(String)
        case boolean(String)
        case stringArray(String)
        case enumeration([String], String)

        var schema: JSONValue {
            switch self {
            case .string(let description): ["type": "string", "description": .string(description)]
            case .integer(let description): ["type": "integer", "description": .string(description)]
            case .number(let description): ["type": "number", "description": .string(description)]
            case .boolean(let description): ["type": "boolean", "description": .string(description)]
            case .stringArray(let description):
                ["type": "array", "items": ["type": "string"], "description": .string(description)]
            case .enumeration(let values, let description):
                ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
            }
        }
    }

    static func input(_ properties: [(String, Property)], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map { ($0.0, $0.1.schema) })),
            "additionalProperties": false,
        ]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    /// An output schema. It lists no required fields: a failed call returns
    /// `{error: {code, message}}` as its structured content, and clients that
    /// validate structured content against the schema must accept that too.
    static func output(_ properties: [String: JSONValue]) -> JSONValue {
        var all = properties
        all["error"] = [
            "type": "object",
            "description": "Present only when the call failed (isError is true).",
            "properties": ["code": ["type": "string"], "message": ["type": "string"]],
        ]
        return ["type": "object", "properties": .object(all)]
    }

    static let stringType: JSONValue = ["type": "string"]
    static let integerType: JSONValue = ["type": "integer"]
    static let booleanType: JSONValue = ["type": "boolean"]
    static let objectType: JSONValue = ["type": "object"]
    static let nullableString: JSONValue = ["type": ["string", "null"]]
    static func arrayOfObjects(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "object"], "description": .string(description)]
    }
}

/// The clients connected to the endpoint (TASK-228.1). A session starts with
/// `initialize` and ends with an HTTP DELETE, a disconnect from Detour's UI,
/// or eviction of the oldest one beyond `maximumSessions`.
final class MCPSessionStore {

    struct Session: Equatable {
        let id: String
        let clientName: String
        let clientVersion: String?
        let protocolVersion: String
        let startedAt: Date
        var lastSeen: Date
        var initialized: Bool
    }

    static let maximumSessions = 32

    private(set) var sessions: [String: Session] = [:]

    /// Called after a session starts or ends (the connected indicator).
    var onChange: (() -> Void)?

    /// Sessions in the order they started.
    var orderedSessions: [Session] { sessions.values.sorted { $0.startedAt < $1.startedAt } }

    func start(clientName: String, clientVersion: String?, protocolVersion: String, now: Date) -> Session {
        if sessions.count >= Self.maximumSessions,
           let oldest = sessions.values.min(by: { $0.lastSeen < $1.lastSeen }) {
            sessions.removeValue(forKey: oldest.id)
        }
        let session = Session(id: UUID().uuidString, clientName: clientName, clientVersion: clientVersion,
                              protocolVersion: protocolVersion, startedAt: now, lastSeen: now, initialized: false)
        sessions[session.id] = session
        onChange?()
        return session
    }

    func touch(_ id: String, now: Date) {
        sessions[id]?.lastSeen = now
    }

    func markInitialized(_ id: String) {
        sessions[id]?.initialized = true
    }

    @discardableResult
    func end(_ id: String) -> Bool {
        guard sessions.removeValue(forKey: id) != nil else { return false }
        onChange?()
        return true
    }

    func endAll() {
        guard !sessions.isEmpty else { return }
        sessions.removeAll()
        onChange?()
    }
}

/// The MCP side of the endpoint (TASK-228.1): Streamable HTTP routing,
/// JSON-RPC, protocol version negotiation, sessions and tool dispatch. Main
/// actor and socket-free, so all of it is unit-tested by handing it parsed
/// requests; `AutomationEndpoint` owns the socket and the authorisation check
/// in front of it.
final class MCPServer {

    /// Newest first. A client asking for one of these gets it; any other
    /// version gets the newest, and the client decides whether to go on.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let path = "/mcp"
    static let sessionHeader = "Mcp-Session-Id"
    static let protocolVersionHeader = "MCP-Protocol-Version"

    let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]
    let sessions = MCPSessionStore()
    private let serverVersion: String
    private let instructions: String
    private let now: () -> Date

    init(tools: [MCPTool], serverVersion: String, instructions: String, now: @escaping () -> Date = Date.init) {
        self.tools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.now = now
    }

    // MARK: HTTP

    /// Answers one authorised HTTP request.
    func handle(_ request: AutomationHTTP.Request) async -> AutomationHTTP.Response {
        guard request.path == Self.path else {
            return .text("Not found. The MCP endpoint is \(Self.path)", status: 404)
        }
        switch request.method {
        case "POST":
            return await handlePost(request)
        case "DELETE":
            guard let id = request.header(Self.sessionHeader) else {
                return .text("Missing \(Self.sessionHeader)", status: 400)
            }
            return sessions.end(id) ? AutomationHTTP.Response(status: 204) : .text("Unknown session", status: 404)
        case "GET":
            // No server-initiated stream: every answer comes back on its POST.
            return .text("This endpoint sends no event stream; use POST", status: 405,
                         headers: [("Allow", "POST, DELETE")])
        default:
            return .text("Method not allowed", status: 405, headers: [("Allow", "POST, DELETE")])
        }
    }

    private func handlePost(_ request: AutomationHTTP.Request) async -> AutomationHTTP.Response {
        if let contentType = request.header("content-type"), !contentType.lowercased().contains("application/json") {
            return .text("Content-Type must be application/json", status: 415)
        }
        if let version = request.header(Self.protocolVersionHeader),
           !Self.supportedProtocolVersions.contains(version) {
            return .json(Self.errorResponse(id: .null, code: -32600,
                                            message: "Unsupported \(Self.protocolVersionHeader) \(version)"),
                         status: 400)
        }
        let message: JSONValue
        do {
            message = try JSONValue.parse(request.body)
        } catch {
            return .json(Self.errorResponse(id: .null, code: -32700, message: "Parse error"), status: 400)
        }

        let messages: [JSONValue]
        let isBatch: Bool
        switch message {
        case .array(let values):
            guard !values.isEmpty else {
                return .json(Self.errorResponse(id: .null, code: -32600, message: "Empty batch"), status: 400)
            }
            messages = values
            isBatch = true
        case .object:
            messages = [message]
            isBatch = false
        default:
            return .json(Self.errorResponse(id: .null, code: -32600, message: "Invalid request"), status: 400)
        }

        if messages.contains(where: { $0["method"]?.stringValue == "initialize" }) {
            guard !isBatch else {
                return .json(Self.errorResponse(id: .null, code: -32600, message: "initialize cannot be batched"),
                             status: 400)
            }
            return initialize(message)
        }

        guard let sessionID = request.header(Self.sessionHeader) else {
            return .json(Self.errorResponse(id: messages.first?["id"] ?? .null, code: -32600,
                                            message: "Missing \(Self.sessionHeader); send initialize first"),
                         status: 400)
        }
        guard sessions.sessions[sessionID] != nil else {
            // 404 tells a Streamable HTTP client to start a new session.
            return .json(Self.errorResponse(id: messages.first?["id"] ?? .null, code: -32001,
                                            message: "Unknown or ended session"),
                         status: 404)
        }
        sessions.touch(sessionID, now: now())

        var responses: [JSONValue] = []
        for message in messages {
            if let response = await handleMessage(message, sessionID: sessionID) {
                responses.append(response)
            }
        }
        if responses.isEmpty { return AutomationHTTP.Response(status: 202) }
        return .json(isBatch ? .array(responses) : responses[0])
    }

    private func initialize(_ message: JSONValue) -> AutomationHTTP.Response {
        let id = message["id"] ?? .null
        guard message["jsonrpc"]?.stringValue == "2.0", !id.isNull else {
            return .json(Self.errorResponse(id: id, code: -32600, message: "Invalid request"), status: 400)
        }
        let params = message["params"]
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        let clientInfo = params?["clientInfo"]
        let clientName = clientInfo?["title"]?.stringValue ?? clientInfo?["name"]?.stringValue ?? "MCP client"
        let session = sessions.start(clientName: clientName, clientVersion: clientInfo?["version"]?.stringValue,
                                     protocolVersion: version, now: now())
        let result: JSONValue = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "detour", "title": "Detour", "version": .string(serverVersion)],
            "instructions": .string(instructions),
        ]
        return .json(["jsonrpc": "2.0", "id": id, "result": result],
                     headers: [(Self.sessionHeader, session.id)])
    }

    // MARK: JSON-RPC

    /// The response to one message, or nil for a notification (or a response
    /// from the client, which this server never asks for).
    private func handleMessage(_ message: JSONValue, sessionID: String) async -> JSONValue? {
        guard message.objectValue != nil, message["jsonrpc"]?.stringValue == "2.0" else {
            return Self.errorResponse(id: message["id"] ?? .null, code: -32600, message: "Invalid request")
        }
        guard let method = message["method"]?.stringValue else { return nil }
        guard let id = message["id"], !id.isNull else {
            if method == "notifications/initialized" { sessions.markInitialized(sessionID) }
            return nil
        }
        switch method {
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        case "tools/list":
            return ["jsonrpc": "2.0", "id": id, "result": ["tools": .array(tools.map(\.listing))]]
        case "tools/call":
            guard let name = message["params"]?["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "tools/call needs params.name")
            }
            guard let tool = toolsByName[name] else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool \(name)")
            }
            let arguments = message["params"]?["arguments"]
            let result = await call(tool, arguments: arguments)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case "initialize":
            return Self.errorResponse(id: id, code: -32600, message: "Session already initialized")
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Runs `tool` and wraps what it returned (or threw) as a tool result.
    func call(_ tool: MCPTool, arguments: JSONValue?) async -> JSONValue {
        do {
            let fields: [String: JSONValue]
            switch arguments {
            case nil, .null?: fields = [:]
            case .object(let values)?: fields = values
            default: throw AutomationToolError(.invalidArguments, "arguments must be an object")
            }
            let allowed = Set(tool.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let parsed = try ToolArguments(fields, allowed: allowed)
            let structured = try await tool.handler(parsed)
            return Self.toolResult(structured, isError: false)
        } catch let error as AutomationToolError {
            return Self.toolResult(["error": ["code": .string(error.code.rawValue), "message": .string(error.message)]],
                                   isError: true)
        } catch {
            return Self.toolResult(["error": ["code": .string(AutomationErrorCode.internalError.rawValue),
                                              "message": .string(String(describing: error))]],
                                   isError: true)
        }
    }

    /// A tool result: `structuredContent`, and the same JSON as text for
    /// clients that only read text content (AC #12, #16).
    static func toolResult(_ structured: JSONValue, isError: Bool) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(structured.jsonString)]],
            "structuredContent": structured,
            "isError": .bool(isError),
        ]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
