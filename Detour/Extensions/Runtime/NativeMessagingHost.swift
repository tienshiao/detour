import Foundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "native-messaging")

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
    static let searchDirectories: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts",
            "\(home)/Library/Application Support/Chromium/NativeMessagingHosts",
            "\(home)/Library/Application Support/Detour/NativeMessagingHosts",
            "/Library/Google/Chrome/NativeMessagingHosts",
        ]
    }()

    static let maxMessageSize = 1_048_576 // 1 MB

    private let hostName: String
    let extensionID: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let readQueue = DispatchQueue(label: "com.detour.native-messaging.read")

    /// Called on the main queue when a message is received from the native host.
    var onMessage: (([String: Any]) -> Void)?
    /// Called on the main queue when the native host disconnects (process exit or error).
    var onDisconnect: ((String?) -> Void)?

    private var isConnected = false

    init(hostName: String, extensionID: String) {
        self.hostName = hostName
        self.extensionID = extensionID
    }

    deinit {
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
            log.error("Native host binary not found at \(hostPath) for \(self.hostName, privacy: .public)")
            throw NativeMessagingError.hostNotFound(hostPath)
        }

        // Spawn the process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hostPath)
        // Chrome passes the extension origin as the first argument
        proc.arguments = [expectedOrigin]

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        // Discard stderr to avoid pipe buffer deadlocks
        proc.standardError = FileHandle.nullDevice

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.process = proc

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.isConnected else { return }
                self.isConnected = false
                let msg = process.terminationStatus == 0 ? nil : "Native host exited with status \(process.terminationStatus)"
                self.onDisconnect?(msg)
            }
        }

        try proc.run()
        isConnected = true
        log.info("Connected to native host \(self.hostName, privacy: .public) at \(hostPath) for extension \(self.extensionID, privacy: .public)")

        // Start reading stdout on a background queue
        startReadLoop()
    }

    /// Send a JSON message to the native host using the length-prefixed protocol.
    func sendMessage(_ message: [String: Any]) throws {
        guard isConnected, let stdinPipe else {
            throw NativeMessagingError.notConnected
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw NativeMessagingError.invalidMessage
        }

        guard data.count <= Self.maxMessageSize else {
            log.warning("Message size \(data.count) exceeds 1MB limit for native host \(self.hostName, privacy: .public)")
            throw NativeMessagingError.messageTooLarge(data.count)
        }

        // Write 4-byte little-endian length prefix + message data
        var length = UInt32(data.count).littleEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)

        stdinPipe.fileHandleForWriting.write(packet)
    }

    /// Disconnect the native host (terminates the process).
    func disconnect() {
        guard isConnected else { return }
        log.info("Disconnecting native host \(self.hostName, privacy: .public) for extension \(self.extensionID, privacy: .public)")
        isConnected = false

        stdinPipe?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    // MARK: - Private

    private func discoverManifest() throws -> NativeHostManifest {
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

    private func startReadLoop() {
        guard let stdout = stdoutPipe?.fileHandleForReading else { return }

        readQueue.async { [weak self] in
            while let self, self.isConnected {
                // Read 4-byte length prefix
                let lengthData = stdout.readData(ofLength: 4)
                guard lengthData.count == 4 else {
                    // EOF or error — native host disconnected
                    DispatchQueue.main.async {
                        guard self.isConnected else { return }
                        self.isConnected = false
                        self.onDisconnect?(nil)
                    }
                    return
                }

                let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
                guard length > 0, length <= Self.maxMessageSize else {
                    DispatchQueue.main.async {
                        self.isConnected = false
                        self.onDisconnect?("Invalid message length: \(length)")
                    }
                    return
                }

                // Read the message body
                let messageData = stdout.readData(ofLength: Int(length))
                guard messageData.count == Int(length) else {
                    DispatchQueue.main.async {
                        self.isConnected = false
                        self.onDisconnect?("Incomplete message read")
                    }
                    return
                }

                // Parse JSON and deliver
                if let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                    DispatchQueue.main.async {
                        self.onMessage?(json)
                    }
                }
            }
        }
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

    /// Encode a message into Chrome's length-prefixed format (for testing).
    static func encodeMessage(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        return packet
    }

    /// Decode a length-prefixed message. Returns (message data, bytes consumed) or nil.
    static func decodeMessage(from data: Data) -> (Data, Int)? {
        guard data.count >= 4 else { return nil }
        let length = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let totalLength = 4 + Int(length)
        guard data.count >= totalLength else { return nil }
        return (data.subdata(in: 4..<totalLength), totalLength)
    }
}
