import XCTest
@testable import Detour

/// TASK-231.8: Chrome's native-messaging framing — a little-endian UInt32 byte
/// count, then that many bytes of UTF-8 JSON — read and written without raw
/// pointers. The prefix comes from another process, so a prefix that claims
/// more than the host sends must end the connection, never be read past.
///
/// The `connect()` legs run a real host process (`FakeNativeMessagingHost`)
/// and go through the read loop itself, which reads the prefix and the body
/// straight off the pipe; `decodeMessage` is only the in-memory form.
nonisolated final class NativeMessagingFramingTests: XCTestCase {

    private static let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    private var fixture: FakeNativeMessagingHost?
    private var host: NativeMessagingHost?
    private var received: [[String: Any]] = []
    private var disconnects: [String?] = []

    @MainActor override func tearDown() async throws {
        reset()
        try await super.tearDown()
    }

    /// Disconnect and remove the fake host, and forget what it delivered.
    @MainActor private func reset() {
        host?.disconnect()
        host = nil
        fixture?.tearDown()
        fixture = nil
        received.removeAll()
        disconnects.removeAll()
    }

    /// Spawn a fake host with `behavior` and connect to it, recording what
    /// the read loop delivers.
    @MainActor private func connect(_ behavior: FakeNativeMessagingHost.Behavior) throws {
        let fixture = try FakeNativeMessagingHost(allowing: [Self.extensionID], behavior: behavior)
        self.fixture = fixture
        let host = NativeMessagingHost(hostName: fixture.name, extensionID: Self.extensionID)
        host.onMessage = { [weak self] in self?.received.append($0) }
        host.onDisconnect = { [weak self] in self?.disconnects.append($0) }
        self.host = host
        try host.connect()
    }

    @MainActor private func waitForDisconnect() async throws {
        try await waitUntil("the read loop to report the disconnect") { !self.disconnects.isEmpty }
    }

    /// The bytes `sendMessage` would write for `json`.
    @MainActor private func frame(_ json: String) -> Data {
        NativeMessagingHost.encodeMessage(Data(json.utf8))
    }

    // MARK: - Wire format

    @MainActor func testTheLengthPrefixIsTheBodyCountLittleEndian() {
        XCTAssertEqual(NativeMessagingHost.encodeMessage(Data("Hello".utf8)), Data([5, 0, 0, 0]) + Data("Hello".utf8))
        let body = Data(repeating: 0x20, count: 0x0102_03)
        XCTAssertEqual(NativeMessagingHost.encodeMessage(body).prefix(4), Data([0x03, 0x02, 0x01, 0x00]))
        XCTAssertEqual(NativeMessagingHost.encodeMessage(Data()), Data([0, 0, 0, 0]))
    }

    @MainActor func testDecodingAPrefixThatExceedsTheDataReturnsNil() {
        let body = Data("{}".utf8)
        for claimed: UInt32 in [3, 4, 100, 1 << 20, UInt32(Int32.max), .max] {
            XCTAssertNil(NativeMessagingHost.decodeMessage(from: Data(littleEndianBytesOf: claimed) + body),
                         "claimed \(claimed)")
        }
        for short in 0..<4 {
            XCTAssertNil(NativeMessagingHost.decodeMessage(from: Data([2, 0, 0, 0]).prefix(short)), "\(short) bytes")
        }
        // A prefix that claims exactly what follows decodes, and bytes after
        // the frame are left for the next one.
        let decoded = NativeMessagingHost.decodeMessage(from: frame("{}") + Data([9, 9]))
        XCTAssertEqual(decoded?.0, body)
        XCTAssertEqual(decoded?.1, 6)
    }

    /// A frame handed over as a slice of a larger buffer is read from its own
    /// start, not from byte 0 of the buffer.
    @MainActor func testDecodingASliceReadsItsOwnBytes() {
        let buffer = Data([0xEE, 0xEE, 0xEE]) + frame(#"{"a":1}"#) + Data([0xEE])
        let slice = buffer[3...]
        XCTAssertEqual(slice.startIndex, 3)
        let decoded = NativeMessagingHost.decodeMessage(from: slice)
        XCTAssertEqual(decoded?.0, Data(#"{"a":1}"#.utf8))
        XCTAssertEqual(decoded?.1, 11)
    }

    // MARK: - The read loop, against a real host process

    /// The host's prefix says 100 bytes, it writes 8 and closes stdout: the
    /// loop gets a short read, reports it once and delivers nothing.
    @MainActor func testAHostWhosePrefixExceedsWhatItSendsIsDisconnected() async throws {
        try connect(.writesThenClosesStdout(Data(littleEndianBytesOf: 100) + Data(#"{"a":"b"}"#.utf8).prefix(8)))
        try await waitForDisconnect()
        XCTAssertEqual(disconnects, ["Incomplete message read"])
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(host?.isConnected ?? true)
    }

    /// Frames before the truncated one are delivered, in order, before the
    /// disconnect.
    @MainActor func testFramesBeforeATruncatedOneAreDelivered() async throws {
        let output = frame(#"{"n":1}"#) + frame(#"{"n":2}"#) + Data(littleEndianBytesOf: 64) + Data("{".utf8)
        try connect(.writesThenClosesStdout(output))
        try await waitForDisconnect()
        XCTAssertEqual(received.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(disconnects, ["Incomplete message read"])
    }

    /// A prefix above Chrome's 1 MB limit, or of zero, ends the connection
    /// without reading a body.
    @MainActor func testAnOutOfRangePrefixIsRefusedBeforeReadingABody() async throws {
        for claimed: UInt32 in [UInt32(NativeMessagingHost.maxMessageSize) + 1, .max, 0] {
            try connect(.writesThenClosesStdout(Data(littleEndianBytesOf: claimed) + Data("{}".utf8)))
            try await waitForDisconnect()
            XCTAssertEqual(disconnects, ["Invalid message length: \(claimed)"])
            XCTAssertTrue(received.isEmpty)
            reset()
        }
    }

    /// Fewer than four bytes of prefix, then EOF, is the host going away.
    @MainActor func testAShortPrefixThenEOFIsAPlainDisconnect() async throws {
        try connect(.writesThenClosesStdout(Data([7, 0])))
        try await waitForDisconnect()
        XCTAssertEqual(disconnects, [nil])
        XCTAssertTrue(received.isEmpty)
    }

    /// What `sendMessage` writes is what the read loop reads: an echoing host
    /// hands the message back unchanged, including a body over 64 KiB (a pipe
    /// buffer's worth, so the loop's read spans several pipe reads).
    @MainActor func testAnEchoingHostRoundTripsMessages() async throws {
        try connect(.echoes)
        let small: [String: Any] = ["text": "héllo ✓", "n": 1]
        let large: [String: Any] = ["blob": String(repeating: "x", count: 200_000), "n": 2]
        try host?.sendMessage(small)
        try host?.sendMessage(large)
        try await waitUntil("both messages to come back") { self.received.count == 2 }
        XCTAssertEqual(received.first.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: small))
        XCTAssertEqual(received.last.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: large))
        XCTAssertTrue(disconnects.isEmpty)
    }
}
