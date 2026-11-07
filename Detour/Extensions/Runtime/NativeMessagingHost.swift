import Foundation
import os
import Synchronization

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "native-messaging")

/// Represents a native messaging host manifest (e.g. `com.1password.1password.json`).
///
/// Only what `parse` accepts exists: the fields a host needs before Detour
/// may start it are all present and of the right type (TASK-266).
nonisolated struct NativeHostManifest: Equatable, Sendable {
    let name: String
    let description: String?
    let path: String
    let allowedOrigins: [String]

    /// Why a manifest file is refused. Chrome treats every one of these as
    /// "host not found" (`NativeMessagingHostManifest::Parse` fails, or the
    /// launcher finds the name is not the host's, and answers
    /// `RESULT_NOT_FOUND`); the case is what Detour logs.
    enum Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        case unreadable
        case notAJSONObject
        case nameMissing
        /// `name` is not the name of the host whose file it is.
        case nameMismatch
        case pathMissing
        case typeNotStdio
        case allowedOriginsMissing
        case allowedOriginsNotAList
        case allowedOriginNotAString

        var description: String {
            switch self {
            case .unreadable: return "the file cannot be read"
            case .notAJSONObject: return "the file is not a JSON object"
            case .nameMissing: return "\"name\" is missing or not a string"
            case .nameMismatch: return "\"name\" is not the host's name"
            case .pathMissing: return "\"path\" is missing or not a string"
            case .typeNotStdio: return "\"type\" is not \"stdio\""
            case .allowedOriginsMissing: return "\"allowed_origins\" is missing"
            case .allowedOriginsNotAList: return "\"allowed_origins\" is not a list"
            case .allowedOriginNotAString: return "an \"allowed_origins\" entry is not a string"
            }
        }
    }

    /// The manifest in `data`, or why it is refused. Chrome's checks: a
    /// manifest with no `allowed_origins`, or one that is not a list of
    /// strings, is invalid (it used to admit every extension, TASK-266), and
    /// `type` must be "stdio". `description` is required by Chrome too but is
    /// not checked here: it plays no part in who may start the host. Whether
    /// `path` is absolute is checked by `connect()`, after the origin, where
    /// Chrome checks it.
    static func parse(_ data: Data) throws(Invalid) -> NativeHostManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { throw .notAJSONObject }
        guard let name = dict["name"] as? String else { throw .nameMissing }
        guard let path = dict["path"] as? String else { throw .pathMissing }
        guard dict["type"] as? String == "stdio" else { throw .typeNotStdio }
        guard let rawOrigins = dict["allowed_origins"], !(rawOrigins is NSNull) else {
            throw .allowedOriginsMissing
        }
        guard let list = rawOrigins as? [Any] else { throw .allowedOriginsNotAList }
        let origins = try list.map { entry throws(Invalid) -> String in
            guard let origin = entry as? String else { throw .allowedOriginNotAString }
            return origin
        }
        return NativeHostManifest(name: name, description: dict["description"] as? String,
                                  path: path, allowedOrigins: origins)
    }
}

/// Manages a single native messaging host process, implementing Chrome's native messaging protocol.
///
/// Protocol: 4-byte little-endian uint32 length prefix + UTF-8 JSON message body.
/// Max message size: 1 MB from the host, 64 MiB to it (Chrome's limits).
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

    /// The largest message a host may send: 1 MB, Chrome's
    /// `kMaximumNativeMessageSize`, which protects the browser from a
    /// misbehaving host. A longer prefix ends the connection.
    nonisolated static let maxIncomingMessageSize = 1_048_576 // 1 MB

    /// What Detour will send a host (TASK-265).
    struct OutgoingLimits: Sendable, Equatable {
        /// The largest JSON body `sendMessage` writes.
        var maxMessageSize: Int
        /// The most bytes of framed messages waiting to be written to one
        /// host at a time: what a host that stops reading stdin can make
        /// Detour hold. A message that would go over it is refused.
        var maxPendingBytes: Int

        /// Chrome's 64 MiB for a message to a host (the renderer's
        /// `kMaxMessageBytes`, for every extension message), and room for one
        /// such message, framed, waiting to be written. Chrome's write queue
        /// has no bound.
        static let standard = OutgoingLimits(maxMessageSize: 64 * 1024 * 1024,
                                             maxPendingBytes: 64 * 1024 * 1024 + 4)
    }

    /// The limits each host takes when it connects. Tests lower them, so a
    /// refused message does not need 64 MiB of JSON.
    static var outgoingLimits = OutgoingLimits.standard

    private let hostName: String
    let extensionID: String
    private var process: Process?
    private var stdinWriter: StdinWriter?
    private var outgoing = OutgoingLimits.standard
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

    /// Writes framed messages to one host process's stdin without blocking
    /// any thread (TASK-265). A blocking write on the main actor froze the
    /// app, and kept a normal quit from running, as soon as a host stopped
    /// reading and the pipe's buffer (64 KB) filled.
    ///
    /// A `DispatchIO` stream channel owns the descriptor: libdispatch makes it
    /// non-blocking and writes as the pipe drains, and a stream channel's
    /// writes go out in the order they were submitted, so the host gets the
    /// messages in `sendMessage` order. `close()` stops the channel: a write
    /// still waiting on a host that never reads is abandoned (Chrome too
    /// drops its write queue when it closes a host's pipes), and the
    /// descriptor is closed once the channel has let go of it. Nothing on the
    /// quit and teardown paths waits on a write.
    ///
    /// `submit` and `close` are called on the main actor; the completions run
    /// on a global queue, hence the mutex.
    nonisolated private final class StdinWriter: Sendable {
        enum Submission: Equatable {
            case queued
            /// The frame would take the bytes waiting past the bound.
            case full
            /// Closed, or a write has failed: nothing more is written.
            case closed
        }

        private struct State {
            /// Bytes of submitted frames not yet completely written.
            var pendingBytes = 0
            var isClosed = false
            var hasFailed = false
        }

        private let channel: DispatchIO
        private let state = Mutex(State())
        private let maxPendingBytes: Int
        /// Called once, on a global queue, with the errno of the first write
        /// that failed other than by `close()`.
        private let onFailure: @Sendable (Int32) -> Void

        init(writingTo handle: FileHandle, maxPendingBytes: Int,
             onFailure: @escaping @Sendable (Int32) -> Void) {
            self.maxPendingBytes = maxPendingBytes
            self.onFailure = onFailure
            let descriptor = handle.fileDescriptor
            // A write to a host that has gone fails with EPIPE rather than
            // raising SIGPIPE, which `main.swift` also ignores process-wide.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            // The handle is held until the channel is done with the
            // descriptor: closing it earlier (the handle's own deinit does)
            // could hand the number to another file mid-write.
            channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: .global()) { _ in
                try? handle.close()
            }
        }

        var pendingBytes: Int { state.withLock { $0.pendingBytes } }

        func submit(_ frame: Data) -> Submission {
            let submission = state.withLock { state -> Submission in
                guard !state.isClosed, !state.hasFailed else { return .closed }
                guard state.pendingBytes + frame.count <= maxPendingBytes else { return .full }
                state.pendingBytes += frame.count
                return .queued
            }
            guard submission == .queued else { return submission }
            let size = frame.count
            let data = frame.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: data, queue: .global()) { [self] done, _, error in
                guard done else { return }
                let failed = state.withLock { state -> Bool in
                    state.pendingBytes -= size
                    // ECANCELED is `close()` stopping the channel.
                    guard error != 0, !state.isClosed, !state.hasFailed else { return false }
                    state.hasFailed = true
                    return true
                }
                if failed { onFailure(error) }
            }
            return .queued
        }

        func close() {
            let wasOpen = state.withLock { state -> Bool in
                defer { state.isClosed = true }
                return !state.isClosed
            }
            if wasOpen { channel.close(flags: .stop) }
        }
    }

    /// How the teardown ends a host process that is still running: SIGTERM
    /// (and stdin closed), then SIGKILL if it, or a process it started, is
    /// still running `grace` seconds later (TASK-241, TASK-274); both go to
    /// the host's process group. Chrome closes the host's pipes and kills
    /// the host's pid alone after 2 s (`base::EnsureProcessTerminated`); the
    /// SIGTERM first is Detour's, and is what 1Password's host exits on.
    struct Termination: Sendable {
        var grace: TimeInterval
        /// For tests: called off the main actor just after a SIGKILL, with
        /// the host's pid (its group's id).
        var onKill: (@Sendable (pid_t) -> Void)?

        init(grace: TimeInterval = 2, onKill: (@Sendable (pid_t) -> Void)? = nil) {
            self.grace = grace
            self.onKill = onKill
        }
    }

    /// A host process Detour started and has not seen exit, with the
    /// SIGKILL timer of a teardown that is waiting on it.
    ///
    /// Signals go to the host's process tree (TASK-274): Foundation's
    /// `Process` starts the host as the leader of a process group of its
    /// own, and what the host starts is in that group unless it leaves it,
    /// so a wrapper script that runs its real host without `exec` has the
    /// real host signalled too. The group's id is the host's pid. XNU never
    /// hands out an id that a live process, process group or session has,
    /// so the id cannot name anyone else's processes while the host is
    /// unreaped or any member of its group is alive; once all are gone, it
    /// can only come back after the pid counter has gone all the way round
    /// (99,999 pids). Groups are only signalled while the host is unreaped
    /// (`isRunning`) or within a teardown's grace period or the quit's wait
    /// after it, never later.
    nonisolated private struct SpawnedProcess: Sendable {
        let process: Process
        /// The process group the host leads; nil when it was not the leader
        /// of a group of its own at spawn, and then only its pid is signalled.
        let group: pid_t?
        var killTimer: (any DispatchSourceTimer)?
        /// The host process has exited, torn down, while processes it
        /// started were still running in its group: the entry stays until
        /// the SIGKILL timer fires, so the timer, and a quit before then,
        /// still reach them.
        var hostExited = false

        /// The group the just-started `process` leads, if it leads one of
        /// its own: never Detour's group, which a `killpg` would end Detour
        /// and its other children with.
        static func ownGroup(of process: Process) -> pid_t? {
            let pid = process.processIdentifier
            return NativeMessagingHost.signallableGroup(host: pid, hostGroup: getpgid(pid), detourGroup: getpgrp())
        }

        /// The host, or a process it started that is still in its group, is
        /// alive. `killpg` counts no zombie, and fails once only zombies are
        /// left.
        var isAlive: Bool {
            if process.isRunning { return true }
            guard let group else { return false }
            return killpg(group, 0) == 0
        }

        /// Sends `signal` to the host's group, and to the host itself when
        /// it is running and has left the group. Nil if anything got it,
        /// else the errno of the last attempt (ESRCH when there was nothing
        /// to send it to).
        func send(_ signal: Int32) -> Int32? {
            let pid = process.processIdentifier
            var sent = false
            var failure = ESRCH
            if let group {
                if killpg(group, signal) == 0 { sent = true } else { failure = errno }
            }
            if process.isRunning, group == nil || getpgid(pid) != group {
                if Darwin.kill(pid, signal) == 0 { sent = true } else { failure = errno }
            }
            return sent ? nil : failure
        }
    }

    /// The process group a host's signals may go to (`SpawnedProcess`): the
    /// one the host leads, `hostGroup` (what `getpgid` reported for it, -1
    /// on failure) being its own pid, and never `detourGroup`, which a
    /// `killpg` would end Detour and its other children with. Nil otherwise,
    /// and then only the host's pid is signalled.
    nonisolated static func signallableGroup(host pid: pid_t, hostGroup: pid_t, detourGroup: pid_t) -> pid_t? {
        hostGroup == pid && hostGroup > 1 && hostGroup != detourGroup ? hostGroup : nil
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

        // The checks and their order are Chrome's (`NativeProcessLauncher`):
        // a valid manifest (`discoverManifest`), the origin, then an absolute
        // path. The manifests are in user-writable directories, so the origin
        // check is the only thing tying a host to the extensions it was
        // installed for, and it is never skipped (TASK-266).
        let expectedOrigin = "chrome-extension://\(extensionID)/"
        guard manifest.allowedOrigins.contains(expectedOrigin) else {
            log.error("Origin validation failed: extension \(self.extensionID, privacy: .public) not in allowed_origins for \(self.hostName, privacy: .public)")
            throw NativeMessagingError.originNotAllowed(extensionID)
        }

        // macOS has no relative form (Windows resolves one against the
        // manifest's directory): a relative path would resolve against
        // Detour's working directory.
        let hostPath = manifest.path
        guard hostPath.hasPrefix("/") else {
            log.error("Refusing native host \(self.hostName, privacy: .public): its manifest's path is not absolute")
            throw NativeMessagingError.pathNotAbsolute(hostName)
        }

        // Validate the host binary exists
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
        //
        // Until it has started, the process and its pipes are only this
        // call's: a throw here (quitting, or `run()` failing) closes every
        // pipe end, so a failed connect leaves nothing behind (TASK-275).
        // Closing through the handles is safe after a failed `run()`, which
        // has closed the child's ends through them already: a second close
        // is a no-op and never reaches a descriptor number reused since.
        let leadsOwnGroup: Bool
        do {
            leadsOwnGroup = try Self.spawned.withLock { registry in
                guard !registry.isQuitting else { throw NativeMessagingError.quitting }
                try proc.run()
                let entry = SpawnedProcess(process: proc, group: SpawnedProcess.ownGroup(of: proc))
                registry.processes[ObjectIdentifier(proc)] = entry
                return entry.group != nil
            }
        } catch {
            proc.terminationHandler = nil
            for pipe in [stdin, stdout, stderr] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        if !leadsOwnGroup {
            // Foundation's `Process` makes one; only a host that exited at
            // once, and was reaped before the check, has none to read.
            log.notice("[1PW-DEBUG] NM GROUP [\(self.hostName, privacy: .public)] the host does not lead a process group of its own: only its own pid will be signalled")
        }
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc
        self.connection = connection
        // Only once the host runs, so a failed connect never has a reader
        // to stop; a host that has exited already gets it too, and it reads
        // what is left and the end of stream. The termination handler's
        // clear can come first: the end of stream clears it then, or, when
        // a process the host started still holds stderr, the teardown does
        // once the connection ends.
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

        outgoing = Self.outgoingLimits
        // A failed write (the host closed its stdin or exited) is recorded
        // first, so the exit the teardown causes cannot report a reason of
        // its own; it is joined with the end of stream like an exit, since a
        // reply the host wrote before going away may still be in the pipe.
        // Then the teardown runs, as for a write that failed in place.
        stdinWriter = StdinWriter(writingTo: stdin.fileHandleForWriting,
                                  maxPendingBytes: outgoing.maxPendingBytes) { [weak self] code in
            let reason = "Native host write failed: \(String(cString: strerror(code)))"
            log.notice("[1PW-DEBUG] NM WRITE FAILED [\(hostNameCopy, privacy: .public)]: errno \(code)")
            Self.record(.writeFailed(reason), on: connection, hostName: hostNameCopy, reportingTo: self)
            Task { @MainActor [weak self] in
                self?.writeFailed(on: connection)
            }
        }
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
    ///
    /// Returns once the message is queued: the write happens off the main
    /// actor, in order (TASK-265). A write that fails later (the host has
    /// gone) ends the connection through `onDisconnect`. Throws, and writes
    /// nothing, for a message that is not JSON, one over
    /// `OutgoingLimits.maxMessageSize`, one that would take the bytes still
    /// waiting for the host past `maxPendingBytes`, and when the connection
    /// is gone; the connection stays as it was, and what to do about it is
    /// the caller's.
    func sendMessage(_ message: Any) throws {
        guard let connection, connection.isOpen, let stdinWriter, process?.isRunning == true else {
            throw NativeMessagingError.notConnected
        }

        guard let data = Self.jsonBody(for: message) else {
            throw NativeMessagingError.invalidMessage
        }

        guard data.count <= outgoing.maxMessageSize else {
            log.warning("NM SEND REFUSED [\(self.hostName, privacy: .public)]: \(data.count) bytes is over the \(self.outgoing.maxMessageSize)-byte limit")
            throw NativeMessagingError.messageTooLarge(data.count)
        }

        switch stdinWriter.submit(Self.encodeMessage(data)) {
        case .queued:
            // Payload contents are deliberately never logged (see doc comment above).
            log.notice("[1PW-DEBUG] → NM SEND [\(self.hostName, privacy: .public)] (\(data.count) bytes)")
        case .full:
            log.warning("NM SEND REFUSED [\(self.hostName, privacy: .public)]: \(data.count) bytes would take what waits for the host past \(self.outgoing.maxPendingBytes) bytes; the host is not reading")
            throw NativeMessagingError.sendQueueFull
        case .closed:
            throw NativeMessagingError.notConnected
        }
    }

    /// Bytes queued for the host that are not written yet (tests).
    var pendingWriteBytes: Int { stdinWriter?.pendingBytes ?? 0 }

    /// A write on `failed` has failed: the host is gone, or closed its
    /// stdin. Tears the process down, unless that connection has ended
    /// already; the report comes through the join.
    private func writeFailed(on failed: Connection) {
        guard failed === connection, failed.isOpen else { return }
        teardownProcess()
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
        // Abandons whatever is still waiting to be written, and closes stdin
        // once the channel lets go of it.
        stdinWriter?.close()
        if let process, process.isRunning {
            Self.terminate(process, with: termination, hostName: hostName)
        }
        process = nil
        stdinWriter = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Sends SIGTERM to the running `process`'s tree, and SIGKILL if the
    /// host or a process it started in its group is still running once the
    /// grace period is over: one that ignores or blocks SIGTERM would
    /// otherwise outlive its port, a child of Detour or, once a wrapper
    /// script has exited, of launchd. The wait holds the `Process`, never the
    /// host, so it runs after a teardown from `deinit` and does not keep the
    /// host alive. `isRunning` goes false when Foundation reaps the child,
    /// and until the reap the pid cannot be reused (an exited child is a
    /// zombie that keeps it), so a host that exited on SIGTERM, with nothing
    /// it started left, is never sent anything. Only a reap landing between
    /// the check and the signal (microseconds apart) and the id being reused
    /// within it could misfire; `SpawnedProcess` has the group's reasoning.
    nonisolated private static func terminate(
        _ process: Process, with termination: Termination, hostName: String
    ) {
        let onKill = termination.onKill
        let id = ObjectIdentifier(process)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + termination.grace)
        timer.setEventHandler {
            // Fires once, after which the entry has no timer, and an entry
            // kept only for it (`hostExited`) goes.
            let entry = spawned.withLock { registry -> SpawnedProcess? in
                guard let entry = registry.processes[id] else { return nil }
                if entry.hostExited {
                    registry.processes[id] = nil
                } else {
                    registry.processes[id]?.killTimer = nil
                }
                return entry
            }
            // Lets go of this handler, and the `Process` it holds.
            entry?.killTimer?.cancel()
            guard let entry, entry.isAlive else { return }
            let pid = process.processIdentifier
            log.notice("[1PW-DEBUG] NM KILL [\(hostName, privacy: .public)] the host or a process it started still running \(termination.grace)s after SIGTERM; sending SIGKILL")
            // ESRCH: the last of them exited since `isAlive`.
            if let code = entry.send(SIGKILL), code != ESRCH {
                log.error("[1PW-DEBUG] NM KILL [\(hostName, privacy: .public)] failed: errno \(code)")
            }
            onKill?(pid)
        }
        // Kept with the process, so its exit cancels the timer and lets go of
        // the `Process` and its pipes at once rather than after the grace
        // period (unless what it started is still running, `forget`). Kept
        // before the SIGTERM goes, so an exit on it finds the timer there. No
        // entry means the termination handler has run (the host exited by
        // itself between the teardown's `isRunning` and here): it gets no
        // signal and needs no timer, which is cancelled. Resumed either way:
        // releasing a source that was never activated crashes libdispatch.
        let entry = spawned.withLock { registry -> SpawnedProcess? in
            registry.processes[id]?.killTimer = timer
            return registry.processes[id]
        }
        if let entry {
            // ESRCH: the host exited by itself since the entry was read.
            if let code = entry.send(SIGTERM), code != ESRCH {
                log.error("[1PW-DEBUG] NM TERM [\(hostName, privacy: .public)] failed: errno \(code)")
            }
        } else {
            timer.cancel()
        }
        timer.resume()
    }

    /// Stops tracking `process`, which has exited, and cancels the SIGKILL
    /// timer waiting on it, unless it was torn down and processes it
    /// started are still running in its group: then the entry stays until
    /// the timer fires (within the grace period), for the timer and the quit
    /// to reach them.
    nonisolated private static func forget(_ process: Process) {
        let id = ObjectIdentifier(process)
        let entry = spawned.withLock { registry -> SpawnedProcess? in
            guard let entry = registry.processes[id] else { return nil }
            if entry.killTimer != nil, entry.isAlive {
                registry.processes[id]?.hostExited = true
                return nil
            }
            registry.processes[id] = nil
            return entry
        }
        entry?.killTimer?.cancel()
    }

    /// What `terminateAllSpawnedHosts` did: the pids sent SIGTERM, and those
    /// of them still running at the deadline and sent SIGKILL.
    struct QuitReport: Sendable, Equatable {
        var terminated: [pid_t] = []
        var killed: [pid_t] = []
    }

    /// Ends every host process Detour started that is still running, owned
    /// or torn down, with the processes it started in its group (TASK-274):
    /// SIGTERM to each tree, a wait of at most `timeout` for them all
    /// together, then SIGKILL to the rest (TASK-243). A torn-down wrapper
    /// script that has exited while its SIGTERM-ignoring child waits out the
    /// grace period is among them. For quitting: the app is about to exit,
    /// which ends no host by itself (a host's process group is its own, not
    /// one that dies with Detour, and a host that does not read its stdin
    /// never sees the pipe close), and takes every SIGKILL timer with it.
    /// Blocks the calling thread, which may be the main thread: the reaping
    /// that makes `isRunning` false happens on Foundation's own queue. The
    /// owners hear nothing: their reports are main-actor tasks, and the app
    /// exits first. The pid reasoning is `terminate(_:with:hostName:)`'s and
    /// `SpawnedProcess`'s.
    /// `refusingNewHosts` (the quit paths; tests pass false) makes every
    /// later `connect()` throw, so no host starts after the sweep.
    @discardableResult
    nonisolated static func terminateAllSpawnedHosts(
        within timeout: TimeInterval, refusingNewHosts: Bool
    ) -> QuitReport {
        let running = spawned.withLock { registry in
            if refusingNewHosts { registry.isQuitting = true }
            return Array(registry.processes.values)
        }.filter(\.isAlive)
        var report = QuitReport()
        guard !running.isEmpty else { return report }
        for entry in running where entry.send(SIGTERM) == nil {
            report.terminated.append(entry.process.processIdentifier)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while running.contains(where: \.isAlive), Date() < deadline {
            usleep(5_000)
        }
        for entry in running where entry.isAlive && entry.send(SIGKILL) == nil {
            report.killed.append(entry.process.processIdentifier)
        }
        log.notice("NM QUIT: \(report.terminated.count) host(s) sent SIGTERM, \(report.killed.count) still running after \(timeout)s sent SIGKILL")
        return report
    }

    #if DEBUG
    /// For tests: sets or lifts a quit's refusal of new hosts without ending
    /// any, so a test of the refusal can undo it (it is never lifted otherwise).
    nonisolated static func setRefusingNewHostsForTesting(_ refusing: Bool) {
        spawned.withLock { $0.isQuitting = refusing }
    }
    #endif

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
            throw NativeMessagingError.invalidName(hostName)
        }
        let filename = "\(hostName).json"

        for dir in Self.searchDirectories {
            let path = (dir as NSString).appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: path) else { continue }

            // A file that is there but refused ends the search, as Chrome's
            // does (it loads the first manifest it finds, and an invalid one
            // is "not found"): a later directory does not stand in for it.
            let manifest: NativeHostManifest
            do throws(NativeHostManifest.Invalid) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    throw NativeHostManifest.Invalid.unreadable
                }
                manifest = try NativeHostManifest.parse(data)
                guard manifest.name == hostName else { throw NativeHostManifest.Invalid.nameMismatch }
            } catch {
                log.error("Refusing native host \(self.hostName, privacy: .public): its manifest in \(dir, privacy: .public) is invalid: \(error.description, privacy: .public)")
                throw NativeMessagingError.invalidManifest(hostName, error)
            }
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

                guard length > 0, length <= Self.maxIncomingMessageSize else {
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

    /// What `connect()` and `sendMessage` throw. A `connect()` refusal is
    /// what the extension sees (a rejected `sendNativeMessage`, a port
    /// disconnected with the error), so those carry Chrome's own wording
    /// (`native_process_launcher.cc` / `native_message_process_host.cc`);
    /// the specifics (the host name, the manifest's fault) go to the log,
    /// where `connect()` writes them (TASK-266).
    enum NativeMessagingError: LocalizedError, Equatable {
        /// The host name is not one Chrome allows (`isValidHostName`).
        case invalidName(String)
        /// No manifest file for the host in the search directories.
        case manifestNotFound(String)
        /// The host's manifest file is there but refused.
        case invalidManifest(String, NativeHostManifest.Invalid)
        /// The manifest's `path` is not absolute.
        case pathNotAbsolute(String)
        case hostNotFound(String)
        case originNotAllowed(String)
        case notConnected
        case invalidMessage
        /// The JSON body is over `OutgoingLimits.maxMessageSize`.
        case messageTooLarge(Int)
        /// The host is not reading: the message would take what waits to be
        /// written past `OutgoingLimits.maxPendingBytes` (TASK-265).
        case sendQueueFull
        /// Detour is quitting and has ended its hosts (TASK-243).
        case quitting

        static let invalidNameMessage = "Invalid native messaging host name specified."
        static let notFoundMessage = "Specified native messaging host not found."
        static let failedToStartMessage = "Failed to start native messaging host."

        var errorDescription: String? {
            switch self {
            // Chrome's RESULT_INVALID_NAME.
            case .invalidName: return Self.invalidNameMessage
            // Chrome's RESULT_NOT_FOUND: no manifest, an invalid one, or a
            // relative path.
            case .manifestNotFound, .invalidManifest, .pathNotAbsolute: return Self.notFoundMessage
            // Chrome's RESULT_FAILED_TO_START: the launch itself fails.
            case .hostNotFound: return Self.failedToStartMessage
            // Chrome's RESULT_FORBIDDEN, the same text as a user's denial.
            case .originNotAllowed: return ExtensionManager.nativeHostForbiddenMessage
            case .notConnected: return "Not connected to native messaging host"
            case .invalidMessage: return "Failed to serialize message as JSON"
            // Chrome's renderer refuses a message over 64 MiB with this.
            case .messageTooLarge: return "Message exceeded maximum allowed size of 64MiB."
            // Chrome's kHostInputOutputError, what it closes a native port
            // with when a write to the host fails.
            case .sendQueueFull: return "Error when communicating with the native messaging host."
            case .quitting: return "Detour is quitting"
            }
        }

        /// The specifics `errorDescription` leaves out (Chrome's wording is
        /// the same for several causes), for Detour's own log.
        var logDetail: String {
            switch self {
            case .invalidName(let name): return "invalid host name \(name)"
            case .manifestNotFound(let name): return "no manifest for \(name)"
            case .invalidManifest(let name, let fault): return "the manifest for \(name) is invalid: \(fault)"
            case .pathNotAbsolute(let name): return "the manifest for \(name) has a path that is not absolute"
            case .hostNotFound(let path): return "no executable at \(path)"
            case .originNotAllowed(let id): return "\(id) is not in the manifest's allowed_origins"
            case .messageTooLarge(let size): return "a \(size)-byte message is over the limit"
            case .sendQueueFull: return "the host is not reading its stdin and the messages waiting for it are at the limit"
            default: return errorDescription ?? "\(self)"
            }
        }
    }

    // MARK: - Encoding/Decoding Helpers

    /// Encode a message into Chrome's length-prefixed format: the body's
    /// byte count as a little-endian UInt32, then the body. `sendMessage`
    /// caps the body at `OutgoingLimits.maxMessageSize` (64 MiB) before
    /// calling this, so the count fits.
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
