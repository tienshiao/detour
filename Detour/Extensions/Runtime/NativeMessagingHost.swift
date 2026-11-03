import Foundation
import os
import Synchronization

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "native-messaging")

/// Represents a native messaging host manifest (e.g. `com.1password.1password.json`).
struct NativeHostManifest: Codable {
    let name: String
    let description: String?
    let path: String
    let type: String?
    let allowedOrigins: [String]?

    enum CodingKeys: String, CodingKey {
        case name, description, path, type
        case allowedOrigins = "allowed_origins"
    }
}

/// Manages a single native messaging host process, implementing Chrome's native messaging protocol.
///
/// Protocol: 4-byte little-endian uint32 length prefix + UTF-8 JSON message body.
/// Max message size: 1 MB (Chrome's limit).
class NativeMessagingHost {

    /// Search directories for native messaging host manifests (Chrome-compatible locations).
    ///
    /// Debug builds additionally honor `DETOUR_NATIVE_MESSAGING_HOSTS_DIR`, searched
    /// first, so an isolated test profile can point a host name at a stand-in binary
    /// (e.g. a fake host that keeps the port open) without touching the real manifests.
    /// Read on every lookup rather than once, so a test can point it at a fake
    /// host directory in-process (TASK-25).
    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "\(home)/Library/Application Support/Chromium/NativeMessagingHosts",
            "\(home)/Library/Application Support/Detour/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
        ]
        #if DEBUG
        // `ProcessInfo` rather than `getenv`: it reads the live environment
        // too (a `setenv` is seen by the next call), without handing out a
        // C string pointer.
        if let override = ProcessInfo.processInfo.environment["DETOUR_NATIVE_MESSAGING_HOSTS_DIR"], !override.isEmpty {
            directories.insert(override, at: 0)
        }
        #endif
        return directories
    }

    nonisolated static let maxMessageSize = 1_048_576 // 1 MB

    private let hostName: String
    let extensionID: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Called on the main queue when a message is received from the native host.
    var onMessage: (([String: Any]) -> Void)?
    /// Called on the main queue when the native host disconnects (process exit or error),
    /// after every message it wrote before going away.
    var onDisconnect: ((String?) -> Void)?

    /// One spawned host process's connection, shared by the main actor, the
    /// read loop and the termination handler, so its state is behind mutexes.
    /// One per `connect()`: a loop or handler left over from an earlier
    /// connection only ever touches its own.
    nonisolated private final class Connection: Sendable {
        /// Cleared on the main actor, by `disconnect()` or by the reported
        /// end; read by the loop and by message delivery.
        private let open = Mutex(true)
        /// The join of the end of stream and the process exit (TASK-232).
        private let ending: Mutex<NativeHostEnding>

        init(timing: NativeHostEnding.Timing) {
            ending = Mutex(NativeHostEnding(timing: timing))
        }

        var isOpen: Bool { open.withLock { $0 } }

        /// Marks the connection closed. True for the call that closed it.
        func close() -> Bool {
            open.withLock { isOpen in
                defer { isOpen = false }
                return isOpen
            }
        }

        func handle(_ event: NativeHostEnding.Event) -> NativeHostEnding.Action {
            ending.withLock { $0.handle(event) }
        }
    }

    private let endTiming: NativeHostEnding.Timing
    private var connection: Connection?

    var isConnected: Bool { connection?.isOpen ?? false }

    /// `endTiming` is for tests; see `NativeHostEnding.Timing`.
    init(hostName: String, extensionID: String, endTiming: NativeHostEnding.Timing = .init()) {
        self.hostName = hostName
        self.extensionID = extensionID
        self.endTiming = endTiming
    }

    /// Isolated: the process and pipes are main-actor state. The read loop
    /// holds a strong reference for each iteration, including while it is
    /// blocked reading, so while the host process is alive and quiet this does
    /// not run when the owner lets go: it runs once the loop's next read
    /// returns (a message, EOF or an error). The loop's reference is then
    /// usually the last one, released on the read queue, and the teardown hops
    /// to the main actor. Owners that need the process gone call `disconnect()`.
    isolated deinit {
        disconnect()
    }

    /// Discover and validate the native host manifest, then spawn the host process.
    func connect() throws {
        guard !isConnected else { return }

        let manifest = try discoverManifest()

        // Validate origin
        let expectedOrigin = "chrome-extension://\(extensionID)/"
        if let allowedOrigins = manifest.allowedOrigins {
            guard allowedOrigins.contains(expectedOrigin) else {
                log.error("Origin validation failed: extension \(self.extensionID, privacy: .public) not in allowed_origins for \(self.hostName, privacy: .public)")
                throw NativeMessagingError.originNotAllowed(extensionID)
            }
        }

        // Validate the host binary exists
        let hostPath = manifest.path
        guard FileManager.default.isExecutableFile(atPath: hostPath) else {
            log.error("Native host binary not found at \(hostPath, privacy: .public) for \(self.hostName, privacy: .public)")
            throw NativeMessagingError.hostNotFound(hostPath)
        }

        // Spawn the process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hostPath)
        // Chrome passes the extension origin as the first argument
        proc.arguments = [expectedOrigin]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let stderrHostName = hostName
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: Foundation keeps re-firing the handler with empty data
                // until it is cleared, spinning a core if the host closes its
                // stderr but stays alive.
                handle.readabilityHandler = nil
                return
            }
            // Host stderr is host-controlled text and may contain diagnostics
            // with tokens, so it is kept out of the persisted log store: debug
            // level (not persisted) and private (redacted unless private
            // logging is enabled or a debugger is attached). The decode lives
            // inside the interpolation so it is skipped when debug is off, and
            // is lossy so a chunk split mid-character still logs its size.
            // 1Password keeps its own BrowserSupport logs under
            // ~/Library/Group Containers/2BUA8C4S2C.com.1password/…/Data/logs/BrowserSupport/.
            log.debug("[1PW-DEBUG] NM STDERR [\(stderrHostName, privacy: .public)] (\(data.count) bytes): \(String(decoding: data, as: UTF8.self), privacy: .private)")
        }

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        let connection = Connection(timing: endTiming)
        let hostNameCopy = hostName
        // The exit is not the disconnect: it is joined with the read loop's
        // end of stream, so a reply still in the pipe is delivered first.
        proc.terminationHandler = { [weak self] process in
            log.notice("[1PW-DEBUG] NM EXIT [\(hostNameCopy, privacy: .public)] status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)")
            stderr.fileHandleForReading.readabilityHandler = nil
            Self.record(.processExited(status: process.terminationStatus), on: connection,
                        hostName: hostNameCopy, reportingTo: self)
        }

        try proc.run()
        self.connection = connection
        log.info("Connected to native host \(self.hostName, privacy: .public) at \(hostPath, privacy: .public) for extension \(self.extensionID, privacy: .public)")

        // Start reading stdout on a background queue
        startReadLoop(on: connection)
    }

    /// Send a JSON message to the native host using the length-prefixed protocol.
    ///
    /// NEVER log message payloads (or any part of them, including keys) here or
    /// in the read loop: native hosts such as 1Password exchange account secrets,
    /// vault items and session tokens over this channel, and the unified log is
    /// readable by anything on the machine. Byte counts and the host name only.
    func sendMessage(_ message: [String: Any]) throws {
        guard let connection, connection.isOpen, let stdinPipe, process?.isRunning == true else {
            throw NativeMessagingError.notConnected
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw NativeMessagingError.invalidMessage
        }

        guard data.count <= Self.maxMessageSize else {
            log.warning("Message size \(data.count) exceeds 1MB limit for native host \(self.hostName, privacy: .public)")
            throw NativeMessagingError.messageTooLarge(data.count)
        }

        // Payload contents are deliberately never logged (see doc comment above).
        log.notice("[1PW-DEBUG] → NM SEND [\(self.hostName, privacy: .public)] (\(data.count) bytes)")

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Self.encodeMessage(data))
        } catch {
            // Read end closed (native host exited): treat as a disconnect rather
            // than crashing. SIGPIPE is ignored process-wide, so this surfaces as
            // an EPIPE error here instead of terminating the app. The failure
            // is recorded first, so the exit the teardown causes cannot report
            // a reason of their own; it is joined with the end of stream like
            // an exit, since a reply the host wrote before going away may
            // still be in the pipe. Then the teardown runs eagerly, so the
            // caller sees closed pipes as soon as it catches notConnected
            // (`connectionEnded` repeats it, harmlessly).
            log.notice("[1PW-DEBUG] NM WRITE FAILED [\(self.hostName, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            Self.record(.writeFailed("Native host write failed: \(error.localizedDescription)"), on: connection,
                        hostName: hostName, reportingTo: self)
            teardownProcess()
            throw NativeMessagingError.notConnected
        }
    }

    /// Disconnect the native host (terminates the process). Deliberately does
    /// NOT fire onDisconnect: this is the port telling the host to go away,
    /// not the host going away.
    func disconnect() {
        guard let connection, connection.close() else { return }
        log.info("Disconnecting native host \(self.hostName, privacy: .public) for extension \(self.extensionID, privacy: .public)")
        teardownProcess()
    }

    /// Releases the host process and pipes. Every disconnect path must reach
    /// this exactly once or the host process outlives the port; the nil-outs
    /// make a second call harmless.
    private func teardownProcess() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Feeds one end-of-connection signal into `connection`'s join and acts
    /// on the answer. Callable from any thread: the read loop, the
    /// termination handler, a wait expiring, or the main actor.
    ///
    /// The report is a main-actor task, as the read loop's message deliveries
    /// are, and tasks reach the main actor in the order they are made. The
    /// join only reports once the loop has reached the end of stream (or a
    /// framing error, which the loop itself reports), and the loop made its
    /// delivery tasks before that, so every message it read comes first. A
    /// report after `endOfStreamWait` without the end of stream comes after
    /// whatever the loop had read by then; anything it reads later finds the
    /// connection closed.
    nonisolated private static func record(
        _ event: NativeHostEnding.Event, on connection: Connection,
        hostName: String, reportingTo host: NativeMessagingHost?
    ) {
        switch connection.handle(event) {
        case .none:
            break
        case .report(let reason):
            if event == .waitExpired {
                log.notice("[1PW-DEBUG] NM END [\(hostName, privacy: .public)] after waiting: the host exited with stdout still open, or closed stdout and kept running")
            }
            Task { @MainActor [weak host] in
                host?.connectionEnded(connection, reason: reason)
            }
        case .wait(let seconds):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak host] in
                Self.record(.waitExpired, on: connection, hostName: hostName, reportingTo: host)
            }
        }
    }

    /// The host went away: tears down the host process, closes the
    /// connection and notifies, exactly once. Not after `disconnect()`, which
    /// closed it already. Paths that already tore down (a write failure) are
    /// fine: teardownProcess is idempotent.
    private func connectionEnded(_ ended: Connection, reason: String?) {
        guard ended === connection, ended.close() else { return }
        teardownProcess()
        onDisconnect?(reason)
    }

    /// A message the read loop read, unless the connection it came from has
    /// been closed since: an owner that called `disconnect()`, or saw
    /// `onDisconnect`, hears nothing more.
    private func deliver(_ message: [String: Any], from source: Connection) {
        guard source === connection, source.isOpen else { return }
        onMessage?(message)
    }

    // MARK: - Private

    /// Chrome native-messaging host names are restricted to lowercase
    /// alphanumerics, dots and underscores, with no leading/trailing/double
    /// dots. Enforcing this rejects attacker-supplied names like "../../evil"
    /// that would otherwise traverse out of the search directories when joined
    /// via `appendingPathComponent`.
    static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if name.hasPrefix(".") || name.hasSuffix(".") || name.contains("..") { return false }
        return true
    }

    private func discoverManifest() throws -> NativeHostManifest {
        guard Self.isValidHostName(hostName) else {
            log.error("Rejecting native host name with illegal characters: \(self.hostName, privacy: .public)")
            throw NativeMessagingError.manifestNotFound(hostName)
        }
        let filename = "\(hostName).json"

        for dir in Self.searchDirectories {
            let path = (dir as NSString).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: path) else { continue }

            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let manifest = try JSONDecoder().decode(NativeHostManifest.self, from: data)

            guard manifest.name == hostName else { continue }
            return manifest
        }

        throw NativeMessagingError.manifestNotFound(hostName)
    }

    private func startReadLoop(on connection: Connection) {
        guard let stdout = stdoutPipe?.fileHandleForReading else { return }
        let hostName = hostName
        // A queue per connection: a loop left blocked on an earlier
        // connection's stdout (a child of that host holding it open) must not
        // hold up the next connection's.
        let readQueue = DispatchQueue(label: "com.detour.native-messaging.read")

        readQueue.async { [weak self] in
            while let self, connection.isOpen {
                // Read 4-byte length prefix
                let lengthData = stdout.readData(ofLength: 4)
                guard let length = lengthData.littleEndianUInt32() else {
                    // EOF or error — native host disconnected
                    log.notice("[1PW-DEBUG] ← NM EOF [\(hostName, privacy: .public)] (read \(lengthData.count) bytes instead of 4)")
                    Self.record(.endOfStream, on: connection, hostName: hostName, reportingTo: self)
                    return
                }

                guard length > 0, length <= Self.maxMessageSize else {
                    Self.record(.failed("Invalid message length: \(length)"), on: connection,
                                hostName: hostName, reportingTo: self)
                    return
                }

                // Read the message body
                let messageData = stdout.readData(ofLength: Int(length))
                guard messageData.count == Int(length) else {
                    Self.record(.failed("Incomplete message read"), on: connection,
                                hostName: hostName, reportingTo: self)
                    return
                }

                // Parse JSON and deliver
                if let json = Self.parsedMessage(messageData) {
                    // Payload contents are deliberately never logged: native hosts
                    // send secrets over this channel. Byte count only.
                    log.notice("[1PW-DEBUG] ← NM RECV [\(hostName, privacy: .public)] (\(messageData.count) bytes)")
                    // A task rather than a dispatch block: `json` is a fresh
                    // value nothing here touches again, so it can be sent to
                    // the main actor; tasks reach it in the order they are
                    // made, as `record`'s reports do.
                    Task { @MainActor in
                        self.deliver(json, from: connection)
                    }
                } else {
                    log.error("[1PW-DEBUG] ← NM RECV [\(hostName, privacy: .public)] (\(messageData.count) bytes): failed to parse as JSON")
                }
            }
        }
    }

    /// A message body parsed as a JSON object, or nil. `sending`: the result
    /// is a fresh object graph nothing else refers to, so the read loop can
    /// hand it to the main actor.
    nonisolated private static func parsedMessage(_ data: Data) -> sending [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Errors

    enum NativeMessagingError: LocalizedError {
        case manifestNotFound(String)
        case hostNotFound(String)
        case originNotAllowed(String)
        case notConnected
        case invalidMessage
        case messageTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .manifestNotFound(let name): return "Native messaging host \"\(name)\" not found"
            case .hostNotFound(let path): return "Native messaging host binary not found at \(path)"
            case .originNotAllowed(let id): return "Extension \(id) is not in the native host's allowed_origins"
            case .notConnected: return "Not connected to native messaging host"
            case .invalidMessage: return "Failed to serialize message as JSON"
            case .messageTooLarge(let size): return "Message size \(size) exceeds 1MB limit"
            }
        }
    }

    // MARK: - Encoding/Decoding Helpers

    /// Encode a message into Chrome's length-prefixed format: the body's
    /// byte count as a little-endian UInt32, then the body. `sendMessage`
    /// caps the body at `maxMessageSize` before calling this, so the count
    /// fits.
    static func encodeMessage(_ data: Data) -> Data {
        var packet = Data(littleEndianBytesOf: UInt32(data.count))
        packet.append(data)
        return packet
    }

    /// Decode a length-prefixed message (for testing; the read loop reads
    /// the prefix and the body straight off the pipe). Returns (message data,
    /// bytes consumed), or nil when the prefix is short or claims more bytes
    /// than `data` holds. Offsets count from `startIndex`.
    static func decodeMessage(from data: Data) -> (Data, Int)? {
        guard let length = data.littleEndianUInt32() else { return nil }
        let totalLength = 4 + Int(length)
        guard data.count >= totalLength else { return nil }
        return (data.subdata(in: (data.startIndex + 4)..<(data.startIndex + totalLength)), totalLength)
    }
}
