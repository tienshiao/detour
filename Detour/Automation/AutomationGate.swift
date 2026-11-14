import Foundation
import Security

/// Whether the automation endpoint listens, and on which port (TASK-228.1,
/// AC #7). Pure: AppDelegate asks once at launch.
///
/// The endpoint reads pages and acts with the user's sessions, so it is off
/// until turned on, in one of two ways:
/// - The user turns it on (Settings > General > Automation, off by default).
///   It listens on a port the system picks at each start, written to the
///   0600 endpoint file, which the bundled helper reads. Not a fixed port
///   (user decision, 2026-11-14): while Detour is not running, another
///   account on the Mac could listen on a fixed one and collect the token
///   from a client configured with the address.
/// - A test run sets `DETOUR_MCP=1`. Only with an isolated data directory
///   (`DETOUR_DATA_DIR` set and not the production one), so an agent's
///   scripted run can never open the user's real profile to automation. It
///   listens on an ephemeral port unless `DETOUR_MCP_PORT` names one.
/// Never in the XCTest host: tests start their own endpoint on their own port.
nonisolated enum AutomationGate {

    enum Mode: Equatable, Sendable {
        case off
        /// Turned on by the user's setting.
        case userEnabled(port: UInt16)
        /// Turned on for a test run against an isolated data directory. Port 0
        /// lets the system pick one; the endpoint file says which.
        case testRun(port: UInt16)

        var port: UInt16? {
            switch self {
            case .off: nil
            case .userEnabled(let port), .testRun(let port): port
            }
        }

        var isTestRun: Bool {
            if case .testRun = self { return true }
            return false
        }
    }

    /// Why a requested test run was not started: logged, never silent.
    enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case testRunNeedsIsolatedDataDirectory
        case badPort(String)

        var description: String {
            switch self {
            case .testRunNeedsIsolatedDataDirectory:
                "DETOUR_MCP=1 needs an isolated DETOUR_DATA_DIR (set, and not \"\(defaultDetourDataDirectoryName)\")"
            case .badPort(let value):
                "DETOUR_MCP_PORT \"\(value)\" is not a port number"
            }
        }
    }

    static let testRunEnvironmentKey = "DETOUR_MCP"
    static let testRunPortEnvironmentKey = "DETOUR_MCP_PORT"

    /// The user's setting (in the data directory's defaults suite).
    static let enabledDefaultsKey = "AutomationEndpointEnabled"
    /// An optional fixed port for the user's setting (advanced, not in
    /// Settings): it brings back the risk a fixed port has (see above).
    static let portDefaultsKey = "AutomationEndpointPort"

    static func mode(environment: [String: String],
                     settingEnabled: Bool,
                     settingPort: Int?,
                     isRunningUnitTests: Bool) -> (mode: Mode, refusal: Refusal?) {
        guard !isRunningUnitTests else { return (.off, nil) }

        var refusal: Refusal?
        if environment[testRunEnvironmentKey] == "1" {
            let dataDirectory = environment["DETOUR_DATA_DIR"]
            if let dataDirectory, isIsolatedDataDirectoryName(dataDirectory) {
                if let portValue = environment[testRunPortEnvironmentKey], !portValue.isEmpty {
                    if let port = UInt16(portValue) {
                        return (.testRun(port: port), nil)
                    }
                    refusal = .badPort(portValue)
                } else {
                    return (.testRun(port: 0), nil)
                }
            } else {
                refusal = .testRunNeedsIsolatedDataDirectory
            }
        }

        if settingEnabled {
            return (.userEnabled(port: userPort(settingPort: settingPort)), refusal)
        }
        return (.off, refusal)
    }

    /// The port a user-enabled endpoint listens on: the fixed port setting,
    /// when it is a valid non-zero port, else 0 (the system picks one).
    static func userPort(settingPort: Int?) -> UInt16 {
        settingPort.flatMap { UInt16(exactly: $0) }.flatMap { $0 == 0 ? nil : $0 } ?? 0
    }

    /// Whether `name` (a `DETOUR_DATA_DIR` value, appended to Application
    /// Support) names a directory other than the production one. Compared as
    /// a standardised path and without regard to case, as APFS does by
    /// default: `detour`, `Detour/` and `./Detour` are all the user's profile.
    static func isIsolatedDataDirectoryName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let base = URL(fileURLWithPath: "/ApplicationSupport", isDirectory: true)
        let resolved = base.appendingPathComponent(name).standardizedFileURL.path
        let production = base.appendingPathComponent(defaultDetourDataDirectoryName).standardizedFileURL.path
        return resolved.caseInsensitiveCompare(production) != .orderedSame && resolved != base.standardizedFileURL.path
    }
}

/// The endpoint's token and the file that tells clients where it listens
/// (TASK-228.1). Both live in the data directory and are readable only by the
/// user (0600):
/// - `mcp-token`: the bearer token. Kept across launches, so a client
///   configured with it keeps working; replaced only by a reset.
/// - `mcp-endpoint.json`: `url`, `port`, `pid` and `token` of the running
///   endpoint, written once it listens and removed when it stops. The
///   scripts/ client and the bundled helper read it.
nonisolated enum AutomationCredentials {

    static let tokenFileName = "mcp-token"
    static let endpointFileName = "mcp-endpoint.json"

    struct FileError: Error, CustomStringConvertible {
        var description: String
    }

    /// The token in `directory`, creating one when there is none (or it is
    /// unreadable or empty).
    static func loadOrCreateToken(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(tokenFileName)
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            return token
        }
        return try resetToken(in: directory)
    }

    /// Replaces the token with a new random one and returns it.
    @discardableResult
    static func resetToken(in directory: URL) throws -> String {
        let token = try makeToken()
        try writePrivateFile(Data((token + "\n").utf8), to: directory.appendingPathComponent(tokenFileName))
        return token
    }

    /// 32 random bytes, base64url without padding (43 characters).
    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw FileError(description: "SecRandomCopyBytes failed: \(status)") }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The URL clients use. 127.0.0.1, never `localhost`: Node resolves
    /// `localhost` to ::1 first, where nothing listens.
    static func endpointURL(port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    static func endpointFileContents(port: UInt16, token: String, pid: Int32, testRun: Bool) -> JSONValue {
        [
            "url": .string(endpointURL(port: port)),
            "port": .int(Int(port)),
            "pid": .int(Int(pid)),
            "token": .string(token),
            "test_run": .bool(testRun),
        ]
    }

    static func writeEndpointFile(port: UInt16, token: String, pid: Int32, testRun: Bool, in directory: URL) throws {
        let contents = endpointFileContents(port: port, token: token, pid: pid, testRun: testRun)
        try writePrivateFile(contents.serialized(), to: directory.appendingPathComponent(endpointFileName))
    }

    /// Removes the endpoint file, but only when it still describes this
    /// process: another Detour on the same data directory may have replaced it.
    static func removeEndpointFile(in directory: URL, pid: Int32) {
        let url = directory.appendingPathComponent(endpointFileName)
        guard let data = try? Data(contentsOf: url), let value = try? JSONValue.parse(data),
              value["pid"]?.intValue == Int(pid) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `data` to a new file created with mode 0600, then renames it over
    /// `url`, so the secret is never readable by others, even for a moment.
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FileError(description: "cannot create \(temporary.path): errno \(errno)") }
        let written = data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { write(fd, $0, buffer.count) } ?? 0
        }
        close(fd)
        guard written == data.count else {
            unlink(temporary.path)
            throw FileError(description: "short write to \(temporary.path)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw FileError(description: "cannot replace \(url.path): errno \(errno)")
        }
    }
}
