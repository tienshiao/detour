import XCTest
import Network
import Synchronization
@testable import Detour

/// Reads a raw connection until the server closes it.
///
/// `Sendable`: what it saw is behind a `Mutex`; Network.framework calls it on
/// its own queue.
nonisolated final class ConnectionWatch: Sendable {
    private let state = Mutex((received: Data(), closed: false))

    var received: String { state.withLock { String(decoding: $0.received, as: UTF8.self) } }
    var closed: Bool { state.withLock { $0.closed } }

    func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data { state.withLock { $0.received.append(data) } }
            if isComplete || error != nil {
                state.withLock { $0.closed = true }
                return
            }
            read(connection)
        }
    }
}

/// Stands in for the approval panel: records each prompt and answers it when
/// the test says (or at once, with `autoAnswer`).
final class FakeApprovalPrompter: AutomationApprovalPrompter {

    final class Prompt: AutomationApprovalPrompt {
        let request: AutomationApprovalRequest
        private var answer: ((AutomationApprovalAnswer) -> Void)?
        private(set) var dismissed = false

        init(request: AutomationApprovalRequest, answer: @escaping (AutomationApprovalAnswer) -> Void) {
            self.request = request
            self.answer = answer
        }

        func respond(_ value: AutomationApprovalAnswer) {
            let answer = self.answer
            self.answer = nil
            answer?(value)
        }

        func dismiss() {
            dismissed = true
            answer = nil
        }
    }

    var prompts: [Prompt] = []
    var autoAnswer: AutomationApprovalAnswer?

    var open: [Prompt] { prompts.filter { !$0.dismissed } }

    func present(_ request: AutomationApprovalRequest,
                 answer: @escaping (AutomationApprovalAnswer) -> Void) -> AutomationApprovalPrompt {
        let prompt = Prompt(request: request, answer: answer)
        prompts.append(prompt)
        if let autoAnswer { prompt.respond(autoAnswer) }
        return prompt
    }
}

/// Per-client approval of the user's automation endpoint (TASK-228.5): the
/// client store and its hashed tokens, authorisation with per-client
/// credentials, the authorize request and its limits, the approval flow
/// with a fake prompt (allow, deny, timeout, the rate limits, one name at a
/// time, a client that goes away, turning off), sessions bound to their
/// client, and the same over a real socket (the held connection and the
/// deadline, revocation on the next request).
nonisolated final class AutomationClientApprovalTests: XCTestCase {

    private var directories: [URL] = []
    private var endpoints: [AutomationEndpoint] = []

    @MainActor override func tearDown() async throws {
        for endpoint in endpoints { endpoint.stop() }
        endpoints.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    @MainActor private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clients-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private static func authorizeRequest(_ body: JSONValue) -> AutomationHTTP.Request {
        AutomationHTTP.Request(method: "POST", path: AutomationAuthorization.authorizePath,
                               headers: ["content-type": "application/json"], body: body.serialized())
    }

    private static let claude: JSONValue = ["client_name": "claude-code", "client_title": "Claude Code",
                                            "client_version": "2.1"]

    // MARK: The store

    @MainActor func testTheStoreKeepsOnlyHashesInAPrivateFileAndReloadsThem() throws {
        let directory = try temporaryDirectory()
        let store = AutomationClientStore(directory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (token, record) = try store.add(name: "claude-code", title: "Claude Code", version: "2.1", now: now)
        XCTAssertEqual(token.count, 43)
        XCTAssertEqual(record.tokenSHA256, AutomationClientStore.hash(token))
        XCTAssertEqual(record.displayName, "Claude Code")

        let file = directory.appendingPathComponent(AutomationClientStore.fileName)
        XCTAssertEqual(try permissions(file), 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(token), "the token itself is never written")
        XCTAssertTrue(text.contains(record.tokenSHA256))
        XCTAssertTrue(text.contains("\"client_id\""))

        XCTAssertEqual(store.client(presenting: token)?.clientID, record.clientID)
        XCTAssertNil(store.client(presenting: token + "x"))
        XCTAssertNil(store.client(presenting: String(token.dropLast())))
        XCTAssertNil(store.client(presenting: record.tokenSHA256), "the hash is not the token")

        let reloaded = AutomationClientStore(directory: directory)
        XCTAssertEqual(reloaded.records, [record])
        XCTAssertEqual(reloaded.client(presenting: token)?.clientID, record.clientID)
    }

    @MainActor func testRevokingRefusesTheTokenAtOnceAndOnDiskAndALateLastUsedDoesNotBringItBack() throws {
        let directory = try temporaryDirectory()
        let store = AutomationClientStore(directory: directory)
        let now = Date()
        let (first, one) = try store.add(name: "one", title: nil, version: nil, now: now)
        let (second, two) = try store.add(name: "two", title: nil, version: nil, now: now)
        XCTAssertEqual(store.revoke(clientID: one.clientID)?.clientID, one.clientID)
        XCTAssertNil(store.client(presenting: first))
        XCTAssertEqual(store.client(presenting: second)?.clientID, two.clientID, "others keep working")
        XCTAssertNil(store.revoke(clientID: one.clientID))
        store.noteUsed(clientID: one.clientID, now: now + 120)
        store.noteUsed(clientID: two.clientID, now: now + 120)
        let reloaded = AutomationClientStore(directory: directory)
        XCTAssertEqual(reloaded.records.map(\.clientID), [two.clientID])
        XCTAssertNil(reloaded.client(presenting: first))
    }

    @MainActor func testLastUsedIsWrittenAtMostOnceAMinute() throws {
        let directory = try temporaryDirectory()
        let store = AutomationClientStore(directory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (_, record) = try store.add(name: "one", title: nil, version: nil, now: now)
        store.noteUsed(clientID: record.clientID, now: now + 1)
        store.noteUsed(clientID: record.clientID, now: now + 30)
        XCTAssertEqual(store.record(id: record.clientID)?.lastUsed, now + 30, "in memory every time")
        XCTAssertEqual(AutomationClientStore(directory: directory).records.first?.lastUsed, now + 1)
        store.noteUsed(clientID: record.clientID, now: now + 90)
        XCTAssertEqual(AutomationClientStore(directory: directory).records.first?.lastUsed, now + 90)
    }

    @MainActor func testAMalformedFileApprovesNoClient() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent(AutomationClientStore.fileName)
        try Data("{not json".utf8).write(to: file)
        XCTAssertTrue(AutomationClientStore(directory: directory).records.isEmpty)
        let shortHash: JSONValue = ["version": 1, "clients": [["client_id": .string(UUID().uuidString), "name": "x",
                                                               "created": "2026-11-14T00:00:00Z",
                                                               "token_sha256": "abc"]]]
        try shortHash.serialized().write(to: file)
        XCTAssertTrue(AutomationClientStore(directory: directory).records.isEmpty, "a hash that could not match")
    }

    // MARK: Authorisation with per-client credentials

    @MainActor func testOnlyApprovedTokensAreAcceptedAndTheSharedTokenNever() throws {
        let store = AutomationClientStore(directory: nil)
        let (token, record) = try store.add(name: "claude-code", title: "Claude Code", version: nil, now: Date())
        let shared = try AutomationCredentials.makeToken()
        func decide(_ path: String, _ headers: [String: String]) -> AutomationAuthorization.Decision {
            AutomationAuthorization.decide(path: path, headers: headers, credentials: .perClient(store), port: 4000)
        }
        let host = ["host": "127.0.0.1:4000"]
        XCTAssertEqual(decide("/mcp", host.merging(["authorization": "Bearer \(token)"]) { $1 }),
                       .allowedClient(AutomationClientIdentity(id: record.clientID, name: "Claude Code")))
        for authorization in [nil, "Bearer \(shared)", "Bearer \(record.tokenSHA256)", "Basic \(token)"] {
            var headers = host
            headers["authorization"] = authorization
            guard case .refused(401, _) = decide("/mcp", headers) else {
                return XCTFail("\(authorization ?? "no header") was not refused")
            }
        }
        store.revoke(clientID: record.clientID)
        guard case .refused(401, _) = decide("/mcp", host.merging(["authorization": "Bearer \(token)"]) { $1 }) else {
            return XCTFail("a revoked token was accepted")
        }

        // The one route without a token, and only after Host and Origin.
        XCTAssertEqual(decide("/mcp/authorize", host), .authorizationRequest)
        guard case .refused(403, _) = decide("/mcp/authorize", ["host": "evil.example:4000"]),
              case .refused(403, _) = decide("/mcp/authorize", host.merging(["origin": "https://evil.example"]) { $1 })
        else { return XCTFail("authorize skipped the Host or Origin check") }
        for path in ["/mcp/authorize/", "/MCP/authorize", "/mcp/authorizex", "/mcp"] {
            guard case .refused(401, _) = decide(path, host) else { return XCTFail("\(path) needed no token") }
        }
        // A test run has no authorize route: the shared token is needed everywhere.
        guard case .refused(401, _) = AutomationAuthorization.decide(
            path: "/mcp/authorize", headers: host, credentials: .shared(token: shared), port: 4000) else {
            return XCTFail("a test run answered authorize without its token")
        }
        guard case .refused(401, _) = AutomationAuthorization.decide(
            path: "/mcp", headers: host.merging(["authorization": "Bearer \(token)"]) { $1 },
            credentials: .shared(token: shared), port: 4000) else {
            return XCTFail("a test run accepted a client token")
        }
    }

    func testAnAuthorizeRequestIsCheckedOnItsHead() {
        func head(_ headers: [String: String], method: String = "POST") -> AutomationHTTP.Request {
            AutomationHTTP.Request(method: method, path: "/mcp/authorize", headers: headers, body: Data())
        }
        let json = ["content-type": "application/json", "content-length": "40"]
        XCTAssertNil(AutomationAuthorization.authorizationHeadRefusal(head(json)))
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(head(json, method: "GET"))?.status, 405)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(head(["content-length": "40"]))?.status, 415)
        XCTAssertNil(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "Application/JSON; charset=utf-8", "content-length": "40"])))
        // A type a web page may send without a preflight, naming JSON only in
        // a parameter: refused.
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "text/plain;x=application/json", "content-length": "40"]))?.status, 415)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "application/jsonx", "content-length": "40"]))?.status, 415)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(head(["content-type": "application/json"]))?.status, 411)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "application/json", "transfer-encoding": "chunked"]))?.status, 411)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "application/json", "content-length": "4097"]))?.status, 413)
        XCTAssertEqual(AutomationAuthorization.authorizationHeadRefusal(
            head(["content-type": "application/json", "content-length": "-1"]))?.status, 411)
    }

    func testTheClientsNameIsCleanedBeforeItIsShown() throws {
        let request = try AutomationApprovalRequest.parse(
            JSONValue.object(["client_name": "  Claude\u{202E}edoC\n\tCode\u{0007} ", "client_title": "Claude\u{200B} Code",
                              "client_version": "1.0\u{2028}"]).serialized())
        XCTAssertEqual(request.name, "ClaudeedoC Code", "no bidi override, control or line break")
        XCTAssertEqual(request.title, "Claude Code")
        XCTAssertEqual(request.version, "1.0")
        XCTAssertEqual(try AutomationApprovalRequest.parse(JSONValue.object(["client_name": .string(String(repeating: "a", count: 500))])
                                                            .serialized()).name.count, 64)
        let same = try AutomationApprovalRequest.parse(JSONValue.object(["client_name": "x", "client_title": "x"]).serialized())
        XCTAssertNil(same.title)
        for body in [#"{}"#, #"{"client_name":"  \u0007 "}"#, #"{"client_name":1}"#, #"{"client_name":"x","client_title":2}"#,
                     #"["client_name"]"#, "not json"] {
            XCTAssertThrowsError(try AutomationApprovalRequest.parse(Data(body.utf8)), body)
        }
        XCTAssertThrowsError(try AutomationApprovalRequest.parse(Data(repeating: 0x20, count: 4097)))
    }

    // MARK: The approval flow

    @MainActor private func approvals(_ prompter: FakeApprovalPrompter, store: AutomationClientStore? = nil,
                                      now: @escaping () -> Date = Date.init) -> (AutomationApprovals, AutomationClientStore) {
        let store = store ?? AutomationClientStore(directory: nil)
        return (AutomationApprovals(store: store, prompter: prompter, now: now), store)
    }

    @MainActor func testAllowGivesTheClientATokenOfItsOwn() async throws {
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .allow
        let (approvals, store) = approvals(prompter)
        var approved = 0
        approvals.onApproval = { approved += 1 }
        let outcome = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(outcome.response.status, 200)
        XCTAssertEqual(prompter.prompts.first?.request,
                       AutomationApprovalRequest(name: "claude-code", title: "Claude Code", version: "2.1"))
        XCTAssertTrue(prompter.prompts.allSatisfy(\.dismissed))
        let body = try JSONValue.parse(outcome.response.body)
        let token = try XCTUnwrap(body["token"]?.stringValue)
        let record = try XCTUnwrap(store.client(presenting: token))
        XCTAssertEqual(body["client_id"]?.stringValue, record.clientID.uuidString)
        XCTAssertEqual(body["name"], "Claude Code")
        XCTAssertEqual(approved, 1)

        // A response that never reached the client revokes the approval.
        outcome.undo?()
        XCTAssertNil(store.client(presenting: token))
    }

    @MainActor func testDenyRefusesAndTheNameIsNotAskedAboutAgainForTenMinutes() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .deny
        let (approvals, store) = approvals(prompter, now: { now })
        let denied = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(denied.response.status, 403)
        XCTAssertNil(denied.undo)
        XCTAssertTrue(store.records.isEmpty)

        now += 9 * 60
        let again = await approvals.handle(Self.authorizeRequest(["client_name": "Claude-Code"]), cancellation: .init())
        XCTAssertEqual(again.response.status, 403, "refused without a prompt, whatever the case")
        XCTAssertNotNil(again.response.header("Retry-After"))
        XCTAssertEqual(prompter.prompts.count, 1)

        let other = await approvals.handle(Self.authorizeRequest(["client_name": "cursor"]), cancellation: .init())
        XCTAssertEqual(other.response.status, 403, "another name is asked about (and denied here)")
        XCTAssertEqual(prompter.prompts.count, 2)

        now += 61
        prompter.autoAnswer = .allow
        let later = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(later.response.status, 200, "after ten minutes it may ask again")
        XCTAssertEqual(prompter.prompts.count, 3)
    }

    @MainActor func testNoAnswerInTimeIsADenial() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, store) = approvals(prompter)
        approvals.promptTimeout = .milliseconds(200)
        let outcome = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(outcome.response.status, 403)
        XCTAssertTrue(prompter.prompts[0].dismissed, "the panel closes")
        prompter.prompts[0].respond(.allow)
        XCTAssertTrue(store.records.isEmpty, "a late Allow approves nothing")
        let again = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(again.response.status, 403)
        XCTAssertEqual(prompter.prompts.count, 1, "counted as a denial")
    }

    @MainActor func testOnePromptPerNameAtATimeEachWithItsOwnAnswer() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, store) = approvals(prompter)
        let first = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("the first prompt") { prompter.prompts.count == 1 }
        let second = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("the second request to wait") { approvals.heldCount == 2 }
        XCTAssertEqual(prompter.prompts.count, 1, "the second waits; no second prompt while the first is up")
        let third = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(third.response.status, 429, "one waiter per name")

        prompter.prompts[0].respond(.allow)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome.response.status, 200)
        try await waitUntil("the second request's own prompt") { prompter.prompts.count == 2 }
        XCTAssertEqual(store.records.count, 1, "the second did not ride on the first answer")
        prompter.prompts[1].respond(.deny)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome.response.status, 403)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(approvals.heldCount, 0)
    }

    @MainActor func testAWaiterIsRefusedWhenThePromptAheadOfItIsDenied() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, _) = approvals(prompter)
        let first = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("the first prompt") { prompter.prompts.count == 1 }
        let second = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("the second request to wait") { approvals.heldCount == 2 }
        prompter.prompts[0].respond(.deny)
        let firstStatus = await first.value.response.status
        let secondStatus = await second.value.response.status
        XCTAssertEqual(firstStatus, 403)
        XCTAssertEqual(secondStatus, 403)
        XCTAssertEqual(prompter.prompts.count, 1)
    }

    @MainActor func testAtMostThreeNamesAreAskedAboutAtOnce() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, _) = approvals(prompter)
        var tasks: [Task<AutomationAuthorizeOutcome, Never>] = []
        for name in ["a", "b", "c"] {
            tasks.append(Task { await approvals.handle(Self.authorizeRequest(["client_name": .string(name)]),
                                                       cancellation: .init()) })
        }
        try await waitUntil("three prompts") { prompter.prompts.count == 3 }
        let fourth = await approvals.handle(Self.authorizeRequest(["client_name": "d"]), cancellation: .init())
        XCTAssertEqual(fourth.response.status, 429)
        XCTAssertEqual(prompter.prompts.count, 3)
        prompter.prompts[0].respond(.allow)
        _ = await tasks[0].value
        let fifth = Task { await approvals.handle(Self.authorizeRequest(["client_name": "d"]), cancellation: .init()) }
        try await waitUntil("a prompt for d once a place is free") { prompter.prompts.count == 4 }
        approvals.stop()
        for task in tasks.dropFirst() + [fifth] {
            let status = await task.value.response.status
            XCTAssertEqual(status, 503)
        }
    }

    @MainActor func testAClientThatGoesAwayWithdrawsItsRequestAndThePromptCloses() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, store) = approvals(prompter)
        let cancellation = AutomationRequestCancellation()
        let task = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: cancellation) }
        try await waitUntil("the prompt") { prompter.prompts.count == 1 }
        cancellation.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome.response.status, 400)
        XCTAssertTrue(prompter.prompts[0].dismissed)
        prompter.prompts[0].respond(.allow)
        XCTAssertTrue(store.records.isEmpty)
        // Not a denial the first time: the name may ask again at once.
        prompter.autoAnswer = .allow
        let again = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(again.response.status, 200)
    }

    @MainActor func testHangingUpOnAShownPromptTwiceCountsAsADenial() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, _) = approvals(prompter)
        for round in 1...2 {
            let cancellation = AutomationRequestCancellation()
            let task = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: cancellation) }
            try await waitUntil("prompt \(round)") { prompter.prompts.count == round }
            cancellation.cancel()
            let status = await task.value.response.status
            XCTAssertEqual(status, 400)
        }
        let third = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(third.response.status, 403, "closing and reconnecting cannot keep the panel flashing")
        XCTAssertEqual(prompter.prompts.count, 2)
    }

    @MainActor func testADenialHoldsForTheTitleThePromptShowedUnderAnotherName() async throws {
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .deny
        let (approvals, _) = approvals(prompter)
        let denied = await approvals.handle(Self.authorizeRequest(["client_name": "x1", "client_title": "Claude Code"]),
                                            cancellation: .init())
        XCTAssertEqual(denied.response.status, 403)
        let renamed = await approvals.handle(Self.authorizeRequest(["client_name": "x2", "client_title": "claude code"]),
                                             cancellation: .init())
        XCTAssertEqual(renamed.response.status, 403, "a fresh name with the same title is refused without a prompt")
        let asName = await approvals.handle(Self.authorizeRequest(["client_name": "Claude Code"]), cancellation: .init())
        XCTAssertEqual(asName.response.status, 403, "and so is the title used as the name")
        XCTAssertEqual(prompter.prompts.count, 1)
    }

    @MainActor func testAtMostFivePromptsAreShownInTenMinutesWhateverTheNames() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .deny
        let (approvals, _) = approvals(prompter, now: { now })
        for index in 1...AutomationApprovals.maximumPromptsPerWindow {
            let outcome = await approvals.handle(
                Self.authorizeRequest(["client_name": .string("n\(index)"), "client_title": .string("T\(index)")]),
                cancellation: .init())
            XCTAssertEqual(outcome.response.status, 403)
            now += 60
        }
        let over = await approvals.handle(Self.authorizeRequest(["client_name": "fresh", "client_title": "Fresh"]),
                                          cancellation: .init())
        XCTAssertEqual(over.response.status, 429, "rotating name and title does not buy more prompts")
        XCTAssertNotNil(over.response.header("Retry-After"))
        XCTAssertEqual(prompter.prompts.count, AutomationApprovals.maximumPromptsPerWindow)

        now += 6 * 60  // the first prompt is now more than ten minutes old
        prompter.autoAnswer = .allow
        let later = await approvals.handle(Self.authorizeRequest(["client_name": "fresh", "client_title": "Fresh"]),
                                           cancellation: .init())
        XCTAssertEqual(later.response.status, 200)
    }

    @MainActor func testTurningOffClosesEveryPromptAndAnswersEveryHeldRequest() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, store) = approvals(prompter)
        let held = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("the prompt") { prompter.prompts.count == 1 }
        let waiting = Task { await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init()) }
        try await waitUntil("a waiter") { approvals.heldCount == 2 }
        approvals.stop()
        let heldStatus = await held.value.response.status
        let waitingStatus = await waiting.value.response.status
        XCTAssertEqual(heldStatus, 503)
        XCTAssertEqual(waitingStatus, 503)
        XCTAssertTrue(prompter.prompts.allSatisfy(\.dismissed))
        prompter.prompts[0].respond(.allow)
        XCTAssertTrue(store.records.isEmpty)
        let after = await approvals.handle(Self.authorizeRequest(Self.claude), cancellation: .init())
        XCTAssertEqual(after.response.status, 503)
        XCTAssertEqual(prompter.prompts.count, 1)
    }

    @MainActor func testABadBodyIsRefusedWithoutAPrompt() async throws {
        let prompter = FakeApprovalPrompter()
        let (approvals, _) = approvals(prompter)
        let outcome = await approvals.handle(Self.authorizeRequest(["client_title": "No Name"]), cancellation: .init())
        XCTAssertEqual(outcome.response.status, 400)
        XCTAssertTrue(prompter.prompts.isEmpty)
    }

    // MARK: Sessions belong to their client

    @MainActor private func initialize(_ server: MCPServer, client: AutomationClientIdentity?,
                                       clientInfoName: String = "whatever") async -> AutomationHTTP.Response {
        let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                  "params": ["protocolVersion": "2025-06-18",
                                             "clientInfo": ["name": .string(clientInfoName)]]]
        var request = AutomationHTTP.Request(method: "POST", path: "/mcp", headers: ["content-type": "application/json"],
                                             body: message.serialized())
        request.client = client
        return await server.handle(request)
    }

    private static let pingMessage: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "ping"]

    @MainActor private func ping(_ server: MCPServer, session: String, client: AutomationClientIdentity?,
                                 method: String = "POST") async -> AutomationHTTP.Response {
        var request = AutomationHTTP.Request(
            method: method, path: "/mcp",
            headers: ["content-type": "application/json", "mcp-session-id": session],
            body: method == "POST" ? Self.pingMessage.serialized() : Data())
        request.client = client
        return await server.handle(request)
    }

    @MainActor func testASessionIsNamedAfterItsApprovalAndReachedOnlyWithItsClientsToken() async throws {
        let server = MCPServer(tools: [], serverVersion: "1", instructions: "")
        var approved: Set<UUID> = []
        server.isClientApproved = { approved.contains($0) }
        let one = AutomationClientIdentity(id: UUID(), name: "Claude Code")
        let two = AutomationClientIdentity(id: UUID(), name: "Cursor")
        approved = [one.id, two.id]
        server.sessions.block("Claude Code")  // a test run's blocking does not apply to approved clients
        let started = await initialize(server, client: one, clientInfoName: "Something Else")
        XCTAssertEqual(started.status, 200)
        let session = try XCTUnwrap(started.header(MCPServer.sessionHeader))
        XCTAssertEqual(server.sessions.sessions[session]?.clientName, "Claude Code", "the approved name, not clientInfo")
        XCTAssertEqual(server.sessions.sessions[session]?.clientID, one.id)

        let mine = await ping(server, session: session, client: one)
        XCTAssertEqual(mine.status, 200)
        let theirs = await ping(server, session: session, client: two)
        XCTAssertEqual(theirs.status, 404, "another client's token does not reach the session")
        let shared = await ping(server, session: session, client: nil)
        XCTAssertEqual(shared.status, 404)
        let deleteByOther = await ping(server, session: session, client: two, method: "DELETE")
        XCTAssertEqual(deleteByOther.status, 404)
        XCTAssertNotNil(server.sessions.sessions[session])

        // Revoked between the endpoint's check and the main actor: refused.
        approved.remove(one.id)
        let revoked = await ping(server, session: session, client: one)
        XCTAssertEqual(revoked.status, 401)
        XCTAssertEqual(revoked.header("WWW-Authenticate"), "Bearer realm=\"Detour\"")

        _ = await initialize(server, client: two)
        server.sessions.endAll(clientID: one.id)
        XCTAssertEqual(server.sessions.orderedSessions.map(\.clientName), ["Cursor"])
    }

    /// A tool that revokes its caller, for the batch test.
    @MainActor private final class RevokingTool {
        var approved: Set<UUID> = []
        weak var server: MCPServer?
        var runs = 0
    }

    @MainActor func testARevocationDuringABatchRefusesTheBatchsLaterMessages() async throws {
        let one = AutomationClientIdentity(id: UUID(), name: "Claude Code")
        let state = RevokingTool()
        state.approved = [one.id]
        let tool = MCPTool(
            name: "revoke_me", title: "Revoke me", description: "Revokes the caller, as the user would meanwhile.",
            inputSchema: MCPSchema.input([]), outputSchema: MCPSchema.output([:]), annotations: [:],
            handler: { _ in
                state.runs += 1
                state.approved.remove(one.id)
                state.server?.sessions.endAll(clientID: one.id)
                return [:]
            })
        let server = MCPServer(tools: [tool], serverVersion: "1", instructions: "")
        state.server = server
        server.isClientApproved = { state.approved.contains($0) }
        let started = await initialize(server, client: one)
        let session = try XCTUnwrap(started.header(MCPServer.sessionHeader))

        let call: JSONValue = ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                               "params": ["name": "revoke_me", "arguments": [:]]]
        let batch: JSONValue = .array([call, call, Self.pingMessage])
        var request = AutomationHTTP.Request(
            method: "POST", path: "/mcp",
            headers: ["content-type": "application/json", "mcp-session-id": session], body: batch.serialized())
        request.client = one
        let response = await server.handle(request)
        XCTAssertEqual(response.status, 200)
        let answers = try XCTUnwrap(try JSONValue.parse(response.body).arrayValue)
        XCTAssertEqual(answers.count, 3)
        XCTAssertNotNil(answers[0]["result"], "the first call ran")
        XCTAssertEqual(answers[1]["error"]?["code"]?.intValue, -32001, "refused once its client was revoked")
        XCTAssertEqual(answers[2]["error"]?["code"]?.intValue, -32001)
        XCTAssertEqual(state.runs, 1, "the second call never ran")
    }

    @MainActor func testAClientAtTheSessionLimitEndsItsOwnOldestSessionNotAnothers() throws {
        let store = MCPSessionStore()
        let mine = UUID(), theirs = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let other = store.start(clientName: "Cursor", clientVersion: nil, protocolVersion: "2025-06-18", now: start,
                                clientID: theirs)
        var first: MCPSessionStore.Session?
        for index in 1..<MCPSessionStore.maximumSessions {
            let session = store.start(clientName: "Claude Code", clientVersion: nil, protocolVersion: "2025-06-18",
                                      now: start + Double(index), clientID: mine)
            if first == nil { first = session }
        }
        XCTAssertEqual(store.sessions.count, MCPSessionStore.maximumSessions)
        _ = store.start(clientName: "Claude Code", clientVersion: nil, protocolVersion: "2025-06-18",
                        now: start + 100, clientID: mine)
        XCTAssertEqual(store.sessions.count, MCPSessionStore.maximumSessions)
        XCTAssertNotNil(store.sessions[other.id], "another client's least recent session is kept")
        XCTAssertNil(store.sessions[try XCTUnwrap(first).id], "the client's own least recent one went")
    }

    // MARK: Over the socket

    @MainActor private func startEndpoint(store: AutomationClientStore, prompter: FakeApprovalPrompter,
                                          headTimeout: TimeInterval = 10, maximumHeld: Int = 8)
        async throws -> (URL, MCPServer, AutomationApprovals) {
        let server = MCPServer(tools: [], serverVersion: "test", instructions: "")
        server.isClientApproved = { store.contains(clientID: $0) }
        let approvals = AutomationApprovals(store: store, prompter: prompter)
        let endpoint = try AutomationEndpoint(port: 0, credentials: .perClient(store), headTimeout: headTimeout,
                                              maximumHeldAuthorizations: maximumHeld,
                                              handler: { await server.handle($0) },
                                              authorizer: { await approvals.handle($0, cancellation: $1) })
        endpoints.append(endpoint)
        let port = try await endpoint.start()
        return (try XCTUnwrap(URL(string: AutomationCredentials.endpointURL(port: port))), server, approvals)
    }

    private func post(_ url: URL, _ body: JSONValue, token: String? = nil, session: String? = nil,
                      method: String = "POST") async throws -> (Int, Data, String?) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = method == "POST" ? body.serialized() : nil
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data, http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    private let initializeMessage: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code"]],
    ]

    @MainActor func testOverTheSocketAnApprovedTokenWorksUntilRevokedAndThenTheNextRequestIs401() async throws {
        let store = AutomationClientStore(directory: try temporaryDirectory())
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .allow
        let (url, server, _) = try await startEndpoint(store: store, prompter: prompter)
        let authorize = url.appendingPathComponent("authorize")

        let (unauthorized, _, _) = try await post(url, initializeMessage)
        XCTAssertEqual(unauthorized, 401)
        let (granted, grantBody, _) = try await post(authorize, Self.claude)
        XCTAssertEqual(granted, 200)
        let token = try XCTUnwrap(try JSONValue.parse(grantBody)["token"]?.stringValue)
        let (otherStatus, otherBody, _) = try await post(authorize, ["client_name": "other"])
        XCTAssertEqual(otherStatus, 200)
        let other = try XCTUnwrap(try JSONValue.parse(otherBody)["token"]?.stringValue)

        let (initialized, _, sessionID) = try await post(url, initializeMessage, token: token)
        XCTAssertEqual(initialized, 200)
        let session = try XCTUnwrap(sessionID)
        XCTAssertEqual(server.sessions.sessions[session]?.clientName, "Claude Code")
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "ping"]
        let (pinged, _, _) = try await post(url, ping, token: token, session: session)
        XCTAssertEqual(pinged, 200)
        XCTAssertNotNil(store.records.first?.lastUsed, "last used is noted")

        let id = try XCTUnwrap(store.client(presenting: token)?.clientID)
        store.revoke(clientID: id)
        server.sessions.endAll(clientID: id)
        let (after, _, _) = try await post(url, ping, token: token, session: session)
        XCTAssertEqual(after, 401, "the very next request")
        let (otherInit, _, _) = try await post(url, initializeMessage, token: other)
        XCTAssertEqual(otherInit, 200, "other clients keep working")
    }

    @MainActor func testOverTheSocketTheAuthorizeRouteRefusesBadHeadsBeforeReadingTheBody() async throws {
        let store = AutomationClientStore(directory: nil)
        let prompter = FakeApprovalPrompter()
        let (url, _, _) = try await startEndpoint(store: store, prompter: prompter)
        let authorize = url.appendingPathComponent("authorize")
        let (get, _, _) = try await post(authorize, [:], method: "GET")
        XCTAssertEqual(get, 405)
        var big = URLRequest(url: authorize)
        big.httpMethod = "POST"
        big.setValue("application/json", forHTTPHeaderField: "Content-Type")
        big.httpBody = Data(repeating: 0x20, count: 5000)
        let (_, response) = try await URLSession.shared.data(for: big)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)
        var origin = URLRequest(url: authorize)
        origin.httpMethod = "POST"
        origin.setValue("application/json", forHTTPHeaderField: "Content-Type")
        origin.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        origin.httpBody = Self.claude.serialized()
        let (_, refused) = try await URLSession.shared.data(for: origin)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertTrue(prompter.prompts.isEmpty, "no prompt for any of them")
    }

    /// A held authorize request outlives the deadline for unauthorised
    /// connections; an idle connection still does not; and only so many are
    /// held at once.
    @MainActor func testOverTheSocketAHeldAuthorizeRequestOutlivesTheDeadlineAndIsBounded() async throws {
        let store = AutomationClientStore(directory: nil)
        let prompter = FakeApprovalPrompter()
        let (url, _, _) = try await startEndpoint(store: store, prompter: prompter, headTimeout: 0.3, maximumHeld: 1)
        let authorize = url.appendingPathComponent("authorize")
        let held = Task { try await self.post(authorize, Self.claude) }
        try await waitUntil("the prompt") { prompter.prompts.count == 1 }

        let (beyond, _, _) = try await post(authorize, ["client_name": "second"])
        XCTAssertEqual(beyond, 429, "beyond the endpoint's held limit")

        // An idle connection is still closed at the deadline meanwhile.
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
        idle.start(queue: DispatchQueue(label: "automation-held-test"))
        let idleClosed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            idle.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                continuation.resume(returning: error != nil || isComplete || data == nil)
            }
        }
        idle.cancel()
        XCTAssertTrue(idleClosed, "the server closed the idle connection")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(prompter.open.count, 1, "the held request is still waiting, past the deadline")

        prompter.prompts[0].respond(.allow)
        let (status, body, _) = try await held.value
        XCTAssertEqual(status, 200, "answered after the 0.3 s deadline")
        XCTAssertNotNil(try JSONValue.parse(body)["token"]?.stringValue)
    }

    /// A revoked client's open connections close: authorised ones are spared
    /// by the deadline, so they would otherwise hold their places for good.
    @MainActor func testOverTheSocketRevokingAClientClosesItsOpenConnections() async throws {
        let store = AutomationClientStore(directory: nil)
        let (url, _, _) = try await startEndpoint(store: store, prompter: FakeApprovalPrompter())
        let endpoint = try XCTUnwrap(endpoints.last)
        let (token, record) = try store.add(name: "claude-code", title: nil, version: nil, now: Date())
        let port = try XCTUnwrap(url.port)
        let body = initializeMessage.jsonString
        let request = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
            + "Accept: application/json, text/event-stream\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "automation-revoke-test"))
        defer { connection.cancel() }
        let watch = ConnectionWatch()
        watch.read(connection)
        connection.send(content: Data(request.utf8), completion: .idempotent)
        try await waitUntil("the answer") { watch.received.contains("\r\n\r\n") }
        XCTAssertTrue(watch.received.hasPrefix("HTTP/1.1 200"), watch.received)
        XCTAssertFalse(watch.closed, "an authorised connection stays open for the next request")

        endpoint.closeConnections(clientID: record.clientID)
        try await waitUntil("the connection to close") { watch.closed }
    }

    @MainActor func testOverTheSocketAClientThatHangsUpWithdrawsItsRequest() async throws {
        let store = AutomationClientStore(directory: nil)
        let prompter = FakeApprovalPrompter()
        let (url, _, approvals) = try await startEndpoint(store: store, prompter: prompter)
        let port = try XCTUnwrap(url.port)
        let body = Self.claude.jsonString
        let request = "POST /mcp/authorize HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "automation-hangup-test"))
        connection.send(content: Data(request.utf8), completion: .idempotent)
        try await waitUntil("the prompt") { prompter.prompts.count == 1 }
        connection.cancel()
        try await waitUntil("the prompt to close") { prompter.prompts[0].dismissed }
        try await waitUntil("nothing to be held") { approvals.heldCount == 0 }
        XCTAssertTrue(store.records.isEmpty)
    }
}
