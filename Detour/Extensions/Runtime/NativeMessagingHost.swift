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

    /// Called on the main queue when a message is received from the native
    /// host: any JSON value, not only an object, as in Chrome, where a native
    /// port's message and a `sendNativeMessage` response are both `any`.
    var onMessage: ((Any) -> Void)?
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

    /// How the teardown ends a host process that is still running: SIGTERM
    /// (and stdin closed), then SIGKILL if it is still running `grace`
    /// seconds later (TASK-241). Chrome closes the host's pipes and kills it
    /// after 2 s (`base::EnsureProcessTerminated`); the SIGTERM first is
    /// Detour's, and is what 1Password's host exits on.
    struct Termination: Sendable {
        var grace: TimeInterval
        /// For tests: called off the main actor just after a SIGKILL, with
        /// the pid it went to.
        var onKill: (@Sendable (pid_t) -> Void)?

        init(grace: TimeInterval = 2, onKill: (@Sendable (pid_t) -> Void)? = nil) {
            self.grace = grace
            self.onKill = onKill
        }
    }

    /// A host process Detour started and has not seen exit, with the
    /// SIGKILL timer of a teardown that is waiting on it.
    nonisolated private struct SpawnedProcess: Sendable {
        let process: Process
        var killTimer: (any DispatchSourceTimer)?
    }

    /// The host processes Detour started and has not seen exit, and whether
    /// a quit has ended them, after which no host starts.
    nonisolated private struct Registry: Sendable {
        var processes: [ObjectIdentifier: SpawnedProcess] = [:]
        /// Set by a quit's sweep: a host started after it (an extension
        /// reconnecting when its host exits on the SIGTERM, while the main
        /// thread still runs) would be left running once Detour exits.
        var isQuitting = false
    }

    /// Every host process Detour started that has not exited yet, whether an
    /// owner still holds its host or not (a torn-down host waiting out its
    /// SIGKILL grace is here too), so quitting can end them all (TASK-243).
    /// Added under the lock that `run()` is called under, so the sweep never
    /// sees a host that is not yet running, and removed by its termination
    /// handler, which runs on a thread of its own, hence the mutex.
    nonisolated private static let spawned = Mutex(Registry())

    private let endTiming: NativeHostEnding.Timing
    private let termination: Termination
    private var connection: Connection?

    var isConnected: Bool { connection?.isOpen ?? false }

    /// `endTiming` and `termination` are for tests; see
    /// `NativeHostEnding.Timing` and `Termination`.
    init(hostName: String, extensionID: String, endTiming: NativeHostEnding.Timing = .init(),
         termination: Termination = .init()) {
        self.hostName = hostName
        self.extensionID = extensionID
        self.endTiming = endTiming
        self.termination = termination
    }

    /// Isolated: the process and pipes are main-actor state. Letting go of
    /// the last reference ends the host process: the host's own machinery
    /// (the read loop, the termination handler and the end-of-stream waits)
    /// refers to it weakly, so only its owners keep it alive, and this runs
    /// when they let go even while the process is alive and silent
    /// (TASK-233). `disconnect()` then terminates it; the read loop, blocked
    /// on stdout, sees the end of stream and exits, releasing the read handle
    /// (unless a process the host started still holds its stdout, in which
    /// case the loop stays blocked until that one exits). A reference taken
    /// for a moment off the main actor (a report the loop is making) can be
    /// the last one, in which case the teardown hops to the main actor.
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
            Self.forget(process)
            stderr.fileHandleForReading.readabilityHandler = nil
            Self.record(.processExited(status: process.terminationStatus), on: connection,
                        hostName: hostNameCopy, reportingTo: self)
        }

        // Run and tracked under the lock: an exit straight after `run()`
        // waits in `forget` for the entry it removes, and a quit's sweep
        // either sees this host running or has already refused it.
        try Self.spawned.withLock { registry in
            guard !registry.isQuitting else { throw NativeMessagingError.quitting }
            try proc.run()
            registry.processes[ObjectIdentifier(proc)] = SpawnedProcess(process: proc)
        }
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
    ///
    /// `message` is any JSON value: Chrome's `Port.postMessage` takes `any`,
    /// and a native port writes it to the host as is (TASK-242). The one-shot
    /// `sendNativeMessage` refuses anything but an object before it gets here,
    /// as Chrome's signature check does.
    func sendMessage(_ message: Any) throws {
        guard let connection, connection.isOpen, let stdinPipe, process?.isRunning == true else {
            throw NativeMessagingError.notConnected
        }

        guard let data = Self.jsonBody(for: message) else {
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
        if let process, process.isRunning {
            process.terminate()
            Self.killIfStillRunning(process, after: termination, hostName: hostName)
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Sends SIGKILL to `process` if it is still running once the grace
    /// period is over: a host that ignores or blocks SIGTERM would otherwise
    /// outlive its port as a child of Detour. The wait holds the `Process`,
    /// never the host, so it runs after a teardown from `deinit` and does not
    /// keep the host alive. `isRunning` goes false when Foundation reaps the
    /// child, and until the reap the pid cannot be reused (an exited child is
    /// a zombie that keeps it), so a host that exited on SIGTERM is never sent
    /// anything. Only a reap landing between the check and the `kill` (both
    /// microseconds apart) and the pid being reused within it could misfire.
    nonisolated private static func killIfStillRunning(
        _ process: Process, after termination: Termination, hostName: String
    ) {
        let onKill = termination.onKill
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + termination.grace)
        timer.setEventHandler {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            log.notice("[1PW-DEBUG] NM KILL [\(hostName, privacy: .public)] still running \(termination.grace)s after SIGTERM; sending SIGKILL")
            if Darwin.kill(pid, SIGKILL) != 0 {
                let code = errno
                log.error("[1PW-DEBUG] NM KILL [\(hostName, privacy: .public)] failed: errno \(code)")
            }
            onKill?(pid)
        }
        // Kept with the process, so its exit cancels the timer and lets go of
        // the `Process` and its pipes at once rather than after the grace
        // period. No entry means the termination handler has run (the host
        // exited between the teardown's `isRunning` and here): it needs no
        // timer, which is cancelled. Resumed either way: releasing a source
        // that was never activated crashes libdispatch.
        let tracked = spawned.withLock { registry in
            guard registry.processes[ObjectIdentifier(process)] != nil else { return false }
            registry.processes[ObjectIdentifier(process)]?.killTimer = timer
            return true
        }
        if !tracked { timer.cancel() }
        timer.resume()
    }

    /// Stops tracking `process`, which has exited, and cancels the SIGKILL
    /// timer waiting on it.
    nonisolated private static func forget(_ process: Process) {
        let entry = spawned.withLock { $0.processes.removeValue(forKey: ObjectIdentifier(process)) }
        entry?.killTimer?.cancel()
    }

    /// What `terminateAllSpawnedHosts` did: the pids sent SIGTERM, and those
    /// of them still running at the deadline and sent SIGKILL.
    struct QuitReport: Sendable, Equatable {
        var terminated: [pid_t] = []
        var killed: [pid_t] = []
    }

    /// Ends every host process Detour started that is still running, owned
    /// or torn down: SIGTERM to each, a wait of at most `timeout` for them all
    /// together, then SIGKILL to the rest (TASK-243). For quitting: the app
    /// is about to exit, which ends no host by itself (a host is not in a
    /// process group that dies with Detour, and one that does not read its
    /// stdin never sees the pipe close), and takes every SIGKILL timer with
    /// it. Blocks the calling thread, which may be the main thread: the
    /// reaping that makes `isRunning` false happens on Foundation's own
    /// queue. The owners hear nothing: their reports are main-actor tasks,
    /// and the app exits first. The pid reasoning is `killIfStillRunning`'s.
    /// `refusingNewHosts` (the quit paths; tests pass false) makes every
    /// later `connect()` throw, so no host starts after the sweep.
    @discardableResult
    nonisolated static func terminateAllSpawnedHosts(
        within timeout: TimeInterval, refusingNewHosts: Bool
    ) -> QuitReport {
        let running = spawned.withLock { registry in
            if refusingNewHosts { registry.isQuitting = true }
            return registry.processes.values.map(\.process)
        }.filter(\.isRunning)
        var report = QuitReport()
        guard !running.isEmpty else { return report }
        for process in running {
            let pid = process.processIdentifier
            if Darwin.kill(pid, SIGTERM) == 0 { report.terminated.append(pid) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while running.contains(where: \.isRunning), Date() < deadline {
            usleep(5_000)
        }
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            if Darwin.kill(pid, SIGKILL) == 0 { report.killed.append(pid) }
        }
        log.notice("NM QUIT: \(report.terminated.count) host(s) sent SIGTERM, \(report.killed.count) still running after \(timeout)s sent SIGKILL")
        return report
    }

    /// How long quitting waits for the hosts to exit on SIGTERM, all of them
    /// together, before it kills the rest (TASK-243). Shorter than a
    /// teardown's 2 s grace because it delays the quit; hosts that exit on
    /// SIGTERM (1Password's) take milliseconds, so it is spent only on one
    /// that ignores it.
    nonisolated static let quitGrace: TimeInterval = 1

    /// The SIGTERM source, made and started once, by the first
    /// `installSIGTERMHandler` call.
    nonisolated private static let sigtermSource: any DispatchSourceSignal = {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            log.notice("SIGTERM: ending native hosts before exiting")
            terminateAllSpawnedHosts(within: quitGrace, refusingNewHosts: true)
            // Then die of the SIGTERM, as without the handler: no quit
            // path runs, the exit status is unchanged. Cancelled first: the
            // source sees the re-sent signal too, whatever its disposition.
            source.cancel()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        source.resume()
        return source
    }()

    /// Makes a SIGTERM to Detour end its native hosts first (TASK-243): by
    /// default the signal ends the app at once, leaving every host running,
    /// reparented to launchd. The handler runs on a global queue, so it works
    /// with the main thread busy or hung, and then lets the signal take its
    /// default course. SIGTERM is ignored so the dispatch source sees it; a
    /// child does not inherit that (Foundation's `Process` resets signal
    /// dispositions when it spawns), so hosts still exit on SIGTERM.
    nonisolated static func installSIGTERMHandler() {
        _ = sigtermSource
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
    private func deliver(_ message: Any, from source: Connection) {
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

        // The loop holds the host weakly (TASK-233): it spends most of its
        // life blocked in `readData` on a host that has nothing to say, and a
        // strong reference there would keep the host, and so its process,
        // alive after the owner let go. Ending the connection, by
        // `disconnect()` or by the owner's release running it, terminates the
        // process, so the read returns the end of stream and the loop exits.
        readQueue.async { [weak self] in
            while connection.isOpen {
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
                    Task { @MainActor [weak self] in
                        self?.deliver(json, from: connection)
                    }
                } else {
                    log.error("[1PW-DEBUG] ← NM RECV [\(hostName, privacy: .public)] (\(messageData.count) bytes): failed to parse as JSON")
                }
            }
        }
    }

    /// A message body parsed as any JSON value (a string, number, array or
    /// null as well as an object, TASK-242), or nil when it is not JSON.
    /// `sending`: the result is a fresh object graph nothing else refers to,
    /// so the read loop can hand it to the main actor.
    nonisolated private static func parsedMessage(_ data: Data) -> sending Any? {
        try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// The JSON body for `message`, any JSON value, or nil when it is not one.
    /// Validated first, wrapped in an array (the one top-level value
    /// `isValidJSONObject` accepts that can hold a fragment), because
    /// `data(withJSONObject:)` raises an Objective-C exception, which Swift
    /// cannot catch, for a value it cannot encode: NaN or infinity, a
    /// non-string key, a type that is not JSON. An object encodes exactly as it
    /// did before fragments were allowed.
    static func jsonBody(for message: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([message]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)
    }

    // MARK: - Errors

    enum NativeMessagingError: LocalizedError {
        case manifestNotFound(String)
        case hostNotFound(String)
        case originNotAllowed(String)
        case notConnected
        case invalidMessage
        case messageTooLarge(Int)
        /// Detour is quitting and has ended its hosts (TASK-243).
        case quitting

        var errorDescription: String? {
            switch self {
            case .manifestNotFound(let name): return "Native messaging host \"\(name)\" not found"
            case .hostNotFound(let path): return "Native messaging host binary not found at \(path)"
            case .originNotAllowed(let id): return "Extension \(id) is not in the native host's allowed_origins"
            case .notConnected: return "Not connected to native messaging host"
            case .invalidMessage: return "Failed to serialize message as JSON"
            case .messageTooLarge(let size): return "Message size \(size) exceeds 1MB limit"
            case .quitting: return "Detour is quitting"
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
