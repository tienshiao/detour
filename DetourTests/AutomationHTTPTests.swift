import XCTest
@testable import Detour

/// The automation endpoint's HTTP framing, authorisation and gate
/// (TASK-228.1): the pure rules in front of the MCP server.
nonisolated final class AutomationHTTPTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    private func parsed(_ string: String) throws -> (AutomationHTTP.Request, Int) {
        guard case .request(let request, let consumed) = try AutomationHTTP.parse(data(string)) else {
            XCTFail("expected a whole request")
            throw AutomationHTTP.ParseError.malformed("incomplete")
        }
        return (request, consumed)
    }

    // MARK: Parsing

    func testAPostWithContentLengthParsesWithLowercasedHeadersAndNoQuery() throws {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let (request, consumed) = try parsed(raw)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.headers["host"], "127.0.0.1:5")
        XCTAssertEqual(request.body, data("{}"))
        XCTAssertEqual(consumed, raw.utf8.count)
    }

    func testAHeadOrBodyThatHasNotArrivedIsIncomplete() throws {
        XCTAssertEqual(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nHost: a")), .incomplete)
        XCTAssertEqual(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}")), .incomplete)
    }

    func testTwoPipelinedRequestsAreReadOneAtATime() throws {
        let first = "POST /mcp HTTP/1.1\r\nContent-Length: 1\r\n\r\na"
        let second = "DELETE /mcp HTTP/1.1\r\nMcp-Session-Id: s\r\n\r\n"
        let (request, consumed) = try parsed(first + second)
        XCTAssertEqual(request.body, data("a"))
        XCTAssertEqual(consumed, first.utf8.count)
        let rest = Data(data(first + second).dropFirst(consumed))
        guard case .request(let next, _) = try AutomationHTTP.parse(rest) else { return XCTFail("second request") }
        XCTAssertEqual(next.method, "DELETE")
        XCTAssertEqual(next.header("mcp-session-id"), "s")
    }

    func testAChunkedBodyIsDecodedIncludingExtensionsAndTrailers() throws {
        let raw = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3;ext=1\r\n{\"a\r\n4\r\n\":1}\r\n0\r\nX-Trailer: t\r\n\r\n"
        let (request, consumed) = try parsed(raw)
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab")),
                       .incomplete)
    }

    func testMalformedOversizedAndUnsupportedRequestsAreRefused() {
        XCTAssertThrowsError(try AutomationHTTP.parse(data("GARBAGE\r\n\r\n"))) {
            guard case .malformed = $0 as? AutomationHTTP.ParseError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nContent-Length: nope\r\n\r\n")))
        XCTAssertThrowsError(try AutomationHTTP.parse(
            data("POST /mcp HTTP/1.1\r\nContent-Length: \(AutomationHTTP.maximumRequestSize + 1)\r\n\r\n"))) {
            XCTAssertEqual($0 as? AutomationHTTP.ParseError, .tooLarge)
        }
        XCTAssertThrowsError(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"))) {
            XCTAssertEqual($0 as? AutomationHTTP.ParseError, .unsupportedTransferEncoding)
        }
        XCTAssertThrowsError(try AutomationHTTP.parse(Data(repeating: 65, count: AutomationHTTP.maximumHeadSize + 1))) {
            XCTAssertEqual($0 as? AutomationHTTP.ParseError, .tooLarge)
        }
    }

    /// Sizes near Int.max are refused, not added up: an overflow traps, and
    /// it would happen before the request is authorised.
    func testAHugeContentLengthOrChunkSizeIsTooLargeRatherThanAnOverflow() {
        XCTAssertThrowsError(try AutomationHTTP.parse(data("POST /mcp HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n"))) {
            XCTAssertEqual($0 as? AutomationHTTP.ParseError, .tooLarge)
        }
        XCTAssertThrowsError(try AutomationHTTP.parse(
            data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nab"))) {
            XCTAssertEqual($0 as? AutomationHTTP.ParseError, .tooLarge)
        }
    }

    func testTheHeadParsesBeforeTheBodyArrives() throws {
        let head = try XCTUnwrap(try AutomationHTTP.parseHead(
            data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer x\r\nContent-Length: 100\r\n\r\n{")))
        XCTAssertEqual(head.request.header("authorization"), "Bearer x")
        XCTAssertNil(try AutomationHTTP.parseHead(data("POST /mcp HTTP/1.1\r\nHost: a")))
    }

    func testASerializedResponseCarriesItsLengthAndClosesWhenAsked() {
        let response = AutomationHTTP.Response.json(["ok": true], headers: [("Mcp-Session-Id", "s")])
        let text = String(decoding: AutomationHTTP.serialize(response, closing: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Mcp-Session-Id: s\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
        let open = String(decoding: AutomationHTTP.serialize(response, closing: false), as: UTF8.self)
        XCTAssertFalse(open.contains("Connection: close"))
    }

    // MARK: Authorisation (AC #14)

    private let token = "0123456789abcdef0123456789abcdef0123456789a"

    private func decide(_ headers: [String: String], port: UInt16 = 4000) -> AutomationAuthorization.Decision {
        AutomationAuthorization.decide(headers: headers, token: token, port: port)
    }

    func testTheTokenOnTheLoopbackHostIsAllowed() {
        XCTAssertEqual(decide(["host": "127.0.0.1:4000", "authorization": "Bearer \(token)"]), .allowed)
        XCTAssertEqual(decide(["host": "localhost:4000", "authorization": "bearer \(token)"]), .allowed)
        XCTAssertEqual(decide(["host": "[::1]:4000", "authorization": "Bearer \(token)",
                               "origin": "http://localhost:3000"]), .allowed)
    }

    func testAMissingOrWrongTokenIs401() {
        for authorization in [nil, "Bearer nope", "Basic \(token)", "Bearer", "Bearer \(token)x", "Bearer \(token.dropLast())"] {
            var headers = ["host": "127.0.0.1:4000"]
            headers["authorization"] = authorization
            guard case .refused(401, _) = decide(headers) else {
                return XCTFail("\(authorization ?? "no header") was not refused with 401")
            }
        }
    }

    func testAWebPageOriginIs403EvenWithTheToken() {
        for origin in ["https://evil.example", "http://evil.example", "null", "https://127.0.0.1:4000", "file://"] {
            guard case .refused(403, _) = decide(["host": "127.0.0.1:4000", "authorization": "Bearer \(token)",
                                                  "origin": origin]) else {
                return XCTFail("origin \(origin) was not refused")
            }
        }
    }

    func testARebindingHostOrAnotherPortIs403BeforeTheTokenIsLookedAt() {
        for host in [nil, "evil.example:4000", "127.0.0.1:4001", "127.0.0.1", "127.0.0.2:4000", "localhost.evil.example:4000"] {
            var headers = ["authorization": "Bearer \(token)"]
            headers["host"] = host
            guard case .refused(403, _) = decide(headers) else {
                return XCTFail("host \(host ?? "none") was not refused")
            }
        }
    }

    func testTheUnauthorizedResponseOffersNoOAuthDiscovery() {
        let headers = AutomationAuthorization.unauthorizedHeaders
        XCTAssertEqual(headers.map(\.0), ["WWW-Authenticate"])
        XCTAssertFalse(headers[0].1.contains("resource_metadata"))
    }

    func testConstantTimeEqualCompares() {
        XCTAssertTrue(AutomationAuthorization.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(AutomationAuthorization.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(AutomationAuthorization.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(AutomationAuthorization.constantTimeEqual("", "a"))
        XCTAssertTrue(AutomationAuthorization.constantTimeEqual("", ""))
    }

    // MARK: Gate (AC #7)

    private func mode(_ environment: [String: String], setting: Bool = false, port: Int? = nil,
                      tests: Bool = false) -> (AutomationGate.Mode, AutomationGate.Refusal?) {
        let result = AutomationGate.mode(environment: environment, settingEnabled: setting, settingPort: port,
                                         isRunningUnitTests: tests)
        return (result.mode, result.refusal)
    }

    func testTheEndpointIsOffUntilTurnedOn() {
        XCTAssertEqual(mode([:]).0, .off)
        XCTAssertNil(mode([:]).1)
        XCTAssertEqual(mode(["DETOUR_DATA_DIR": "DetourVerify"]).0, .off, "an isolated directory alone does not turn it on")
    }

    func testATestRunNeedsAnIsolatedDataDirectory() {
        XCTAssertEqual(mode(["DETOUR_MCP": "1"]).0, .off)
        XCTAssertEqual(mode(["DETOUR_MCP": "1"]).1, .testRunNeedsIsolatedDataDirectory)
        XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "Detour"]).0, .off)
        XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": ""]).1, .testRunNeedsIsolatedDataDirectory)
        // Other spellings of the production directory (APFS ignores case).
        for name in ["detour", "Detour/", "./Detour", "x/../Detour", "."] {
            XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": name]).1, .testRunNeedsIsolatedDataDirectory, name)
        }
        XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "DetourVerify"]).0, .testRun(port: 0))
        XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "DetourVerify", "DETOUR_MCP_PORT": "5123"]).0,
                       .testRun(port: 5123))
        XCTAssertEqual(mode(["DETOUR_MCP": "true", "DETOUR_DATA_DIR": "DetourVerify"]).0, .off, "only 1 turns it on")
    }

    func testABadTestRunPortIsRefusedNotGuessed() {
        let (result, refusal) = mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "DetourVerify", "DETOUR_MCP_PORT": "99999"])
        XCTAssertEqual(result, .off)
        XCTAssertEqual(refusal, .badPort("99999"))
    }

    func testTheUsersSettingListensOnTheFixedPort() {
        XCTAssertEqual(mode([:], setting: true).0, .userEnabled(port: AutomationGate.defaultPort))
        XCTAssertEqual(mode([:], setting: true, port: 6000).0, .userEnabled(port: 6000))
        XCTAssertEqual(mode([:], setting: true, port: 0).0, .userEnabled(port: AutomationGate.defaultPort))
        XCTAssertEqual(mode([:], setting: true, port: 70000).0, .userEnabled(port: AutomationGate.defaultPort))
        let (result, refusal) = mode(["DETOUR_MCP": "1"], setting: true)
        XCTAssertEqual(result, .userEnabled(port: AutomationGate.defaultPort), "a refused test run leaves the setting")
        XCTAssertEqual(refusal, .testRunNeedsIsolatedDataDirectory)
    }

    func testTheTestHostNeverListens() {
        XCTAssertEqual(mode(["DETOUR_MCP": "1", "DETOUR_DATA_DIR": "DetourTests"], setting: true, tests: true).0, .off)
    }

    // MARK: Credential files

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testTheTokenIsPrivatePersistentAndReplacedOnlyByAReset() throws {
        let directory = try temporaryDirectory()
        let token = try AutomationCredentials.loadOrCreateToken(in: directory)
        XCTAssertEqual(token.count, 43)
        XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "base64url, no padding")
        let file = directory.appendingPathComponent(AutomationCredentials.tokenFileName)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try AutomationCredentials.loadOrCreateToken(in: directory), token, "kept across launches")
        let reset = try AutomationCredentials.resetToken(in: directory)
        XCTAssertNotEqual(reset, token)
        XCTAssertEqual(try AutomationCredentials.loadOrCreateToken(in: directory), reset)
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testTheEndpointFileIsPrivateAndOnlyItsOwnProcessRemovesIt() throws {
        let directory = try temporaryDirectory()
        try AutomationCredentials.writeEndpointFile(port: 5123, token: "t", pid: 42, testRun: true, in: directory)
        let file = directory.appendingPathComponent(AutomationCredentials.endpointFileName)
        XCTAssertEqual(try permissions(file), 0o600)
        let contents = try JSONValue.parse(Data(contentsOf: file))
        XCTAssertEqual(contents["url"], "http://127.0.0.1:5123/mcp")
        XCTAssertEqual(contents["port"], 5123)
        XCTAssertEqual(contents["pid"], 42)
        XCTAssertEqual(contents["token"], "t")
        XCTAssertEqual(contents["test_run"], true)

        AutomationCredentials.removeEndpointFile(in: directory, pid: 43)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "another process's file stays")
        AutomationCredentials.removeEndpointFile(in: directory, pid: 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: JSON

    func testJSONRoundTripsKeepingIntegersAndBooleansApart() throws {
        let value = try JSONValue.parse(data(#"{"a":1,"b":1.5,"c":true,"d":null,"e":["x",{"f":"\n\u0001"}]}"#))
        XCTAssertEqual(value["a"], .int(1))
        XCTAssertEqual(value["b"], .double(1.5))
        XCTAssertEqual(value["c"], .bool(true))
        XCTAssertEqual(value["d"], .null)
        XCTAssertEqual(value.jsonString, #"{"a":1,"b":1.5,"c":true,"d":null,"e":["x",{"f":"\n\u0001"}]}"#)
        XCTAssertEqual(try JSONValue.parse(value.serialized()), value)
    }
}
