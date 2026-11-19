import Darwin
import Foundation
import Network
import Synchronization

/// What one scan found (TASK-411).
nonisolated struct LocalServerScan: Equatable, Sendable {
    /// The project servers that answered HTTP, by port.
    var servers: [LocalServer]
    /// Every port one of the user's processes listens on, project server or
    /// not: a history row is "not running" only when nothing listens on its
    /// port (a Docker container's forward is running, though not offered).
    /// Root's and other users' listeners cannot be read and are not in it.
    var listeningPorts: Set<Int>

    init(servers: [LocalServer], listeningPorts: Set<Int>? = nil) {
        self.servers = servers
        self.listeningPorts = listeningPorts ?? Set(servers.map(\.port))
    }

    static let empty = LocalServerScan(servers: [])
}

/// Reads the local servers the palette offers (TASK-411).
nonisolated protocol LocalServerScanning: Sendable {
    func scan() async -> LocalServerScan
}

/// Offers nothing: the scan in the XCTest host, so a test that opens a real
/// window never sees, or knocks on, the servers of the Mac it runs on.
nonisolated struct NoLocalServers: LocalServerScanning {
    func scan() async -> LocalServerScan { .empty }
}

/// The real scan, in three steps: enumerate the user's listening TCP sockets
/// through libproc (no `lsof`; Detour is not sandboxed, so it may read its
/// own user's processes), keep the project servers (`LocalServerRules`), and
/// probe each for HTTP. A listener is probed once for as long as the same
/// process holds it: only the enumeration (about 10 ms) runs on every scan, so
/// opening the palette does not knock on a dev server each time.
nonisolated final class LocalServerScanner: LocalServerScanning {

    enum ProbeResult: Sendable, Equatable {
        case https, http, notHTTP
        /// A probe ran out of time: asked again on the next scan, since a
        /// dev server can be slow to answer its first request (a compile, a
        /// busy Mac). Every other answer is kept for the listener's life.
        case noAnswer
    }

    typealias Probe = @Sendable (_ address: String, _ port: Int) async -> ProbeResult

    private struct ProbeKey: Hashable {
        var pid: Int32
        var port: Int
        var address: String
    }

    /// Detour's own listeners (the automation endpoint) are never offered.
    private let excludedProcessID: Int32?
    private let listListeners: @Sendable () -> [LocalListener]
    private let probe: Probe
    private let probes = Mutex<[ProbeKey: ProbeResult]>([:])

    /// `listeners` and `probe` are the real ones unless a test gives its own.
    init(excludedProcessID: Int32? = getpid(),
         listeners: @escaping @Sendable () -> [LocalListener] = { LocalServerScanner.listeners() },
         probe: @escaping Probe = { address, port in
             await LocalServerScanner.probe(address: address, port: port, timeout: .milliseconds(800))
         }) {
        self.excludedProcessID = excludedProcessID
        self.listListeners = listeners
        self.probe = probe
    }

    func scan() async -> LocalServerScan {
        let all = listListeners()
        let listeners = all.filter { $0.pid != excludedProcessID }
        let candidates = LocalServerRules.candidates(from: listeners)
        let live = Set(candidates.map(Self.key))
        // Forget listeners that went away: a new process on the port is
        // probed afresh.
        let cached = probes.withLock { probes in
            probes = probes.filter { live.contains($0.key) }
            return probes
        }
        let results = await withTaskGroup(of: (ProbeKey, ProbeResult).self) { group in
            for candidate in candidates {
                let key = Self.key(candidate)
                if let known = cached[key] {
                    group.addTask { (key, known) }
                } else {
                    let probe = probe
                    group.addTask { (key, await probe(candidate.probeAddress, candidate.listener.port)) }
                }
            }
            var results: [ProbeKey: ProbeResult] = [:]
            for await (key, result) in group { results[key] = result }
            return results
        }
        probes.withLock { $0.merge(results.filter { $0.value != .noAnswer }) { _, new in new } }

        let servers = candidates.compactMap { candidate -> LocalServer? in
            let result = results[Self.key(candidate)] ?? .notHTTP
            guard result == .http || result == .https else { return nil }
            let listener = candidate.listener
            return LocalServer(port: listener.port, isHTTPS: result == .https,
                               processName: Self.processName(listener.executablePath),
                               directory: listener.directory, listensOnIPv4: candidate.listensOnIPv4)
        }
        // Detour's own listeners are not offered, but they are running.
        return LocalServerScan(servers: servers, listeningPorts: Set(all.map(\.port)))
    }

    private static func key(_ candidate: LocalServerRules.Candidate) -> ProbeKey {
        ProbeKey(pid: candidate.listener.pid, port: candidate.listener.port, address: candidate.probeAddress)
    }

    private static func processName(_ executablePath: String) -> String {
        (executablePath as NSString).lastPathComponent
    }

    // MARK: - Enumerating listeners

    /// The listening TCP sockets of `pids`, or of every process the current
    /// user owns.
    static func listeners(pids: [Int32]? = nil) -> [LocalListener] {
        (pids ?? userProcessIDs()).flatMap(listeners(ofProcess:))
    }

    private static func userProcessIDs() -> [Int32] {
        let uid = UInt32(getuid())
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func listeners(ofProcess pid: Int32) -> [LocalListener] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }

        var sockets: [(port: Int, address: String)] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let endpoint = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport)))
            guard let address = boundAddress(endpoint) else { continue }
            sockets.append((port, address))
        }
        guard !sockets.isEmpty else { return [] }

        let executable = executablePath(pid)
        let directory = workingDirectory(pid)
        return sockets.map {
            LocalListener(pid: pid, port: $0.port, address: $0.address,
                          executablePath: executable, directory: directory)
        }
    }

    private static func boundAddress(_ endpoint: in_sockinfo) -> String? {
        if endpoint.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = endpoint.insi_laddr.ina_46.i46a_addr4
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text)
        }
        if endpoint.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = endpoint.insi_laddr.ina_6
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text)
        }
        return nil
    }

    private static func executablePath(_ pid: Int32) -> String {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift does not import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "" }
        return String(cString: path)
    }

    private static func workingDirectory(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // MARK: - Probing

    /// What the listener at `address`:`port` speaks: HTTPS when a TLS
    /// handshake completes (any certificate: the connection never leaves the
    /// loopback address it was opened to, and dev servers sign their own),
    /// else HTTP when a plain `HEAD /` gets an `HTTP/` status line back.
    /// Both run at once; HTTPS wins, since many HTTPS servers also answer a
    /// plain request with a 400.
    /// The plain request running out of time is `.noAnswer`, and so is a
    /// completed handshake whose request runs out of time (a slow HTTPS
    /// server). A TLS attempt that times out before its handshake completes
    /// is an HTTP server that waits on bytes it cannot read (as the test
    /// fixture does), not a slow HTTPS one: a handshake on loopback takes
    /// milliseconds.
    static func probe(address: String, port: Int, timeout: Duration) async -> ProbeResult {
        async let secure = exchange(address: address, port: port, tls: true, timeout: timeout)
        async let plain = exchange(address: address, port: port, tls: false, timeout: timeout)
        let (tls, clear) = await (secure, plain)
        if tls == .http { return .https }
        // The handshake completed, so it speaks TLS, but the request found
        // no answer in time (a dev server compiling its first page): ask
        // again next scan rather than keep a wrong answer for its life.
        if tls == .readyButTimedOut { return .noAnswer }
        switch clear {
        case .http: return .http
        case .timedOut, .readyButTimedOut: return .noAnswer
        case .other: return .notHTTP
        }
    }

    /// `readyButTimedOut`: connected (for TLS, the handshake completed) but
    /// no answer came in time.
    private enum Exchange: Sendable { case http, other, timedOut, readyButTimedOut }

    private static func exchange(address: String, port: Int, tls: Bool, timeout: Duration) async -> Exchange {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .other }
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, .global(qos: .utility))
            parameters = NWParameters(tls: options)
        } else {
            parameters = .tcp
        }
        parameters.requiredInterfaceType = .loopback
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "com.detourbrowser.mac.local-server-probe")
        let request = "HEAD / HTTP/1.1\r\nHost: localhost:\(port)\r\nUser-Agent: Detour\r\nConnection: close\r\n\r\n"

        return await withCheckedContinuation { continuation in
            let finished = Mutex(false)
            let connected = Mutex(false)
            let finish: @Sendable (Exchange) -> Void = { answered in
                let first = finished.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: answered)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connected.withLock { $0 = true }
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil { finish(.other) }
                    })
                    connection.receive(minimumIncompleteLength: 5, maximumLength: 64) { data, _, _, _ in
                        finish(data?.starts(with: Data("HTTP/".utf8)) == true ? .http : .other)
                    }
                case .failed, .cancelled, .waiting:
                    finish(.other)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            let nanoseconds = timeout.components.seconds * 1_000_000_000
                + timeout.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                finish(connected.withLock { $0 } ? .readyButTimedOut : .timedOut)
            }
        }
    }
}

/// The servers palettes offer, shared by every palette (TASK-411): the last
/// scan, kept so a palette can use it before its own scan lands, and the
/// scan in flight, so palettes opened together share one.
final class LocalServerDirectory {
    /// Inert in the XCTest host (`NoLocalServers`).
    static let shared = LocalServerDirectory(
        scanner: AppDelegate.isRunningUnitTests ? NoLocalServers() : LocalServerScanner())

    private let scanner: any LocalServerScanning
    /// The last scan; empty until one has finished.
    private(set) var last = LocalServerScan.empty
    private var inFlight: Task<LocalServerScan, Never>?

    init(scanner: any LocalServerScanning) {
        self.scanner = scanner
    }

    /// Scans again (or joins the scan in flight) and returns what it found.
    func refresh() async -> LocalServerScan {
        if let inFlight { return await inFlight.value }
        let scanner = scanner
        let task = Task.detached(priority: .userInitiated) { await scanner.scan() }
        inFlight = task
        let found = await task.value
        inFlight = nil
        last = found
        return found
    }
}
