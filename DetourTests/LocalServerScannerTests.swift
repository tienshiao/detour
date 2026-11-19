import XCTest
import Network
import Synchronization
@testable import Detour

/// The real scan's two steps over sockets the test opens itself (TASK-411):
/// libproc finds this process's listeners, and the probe tells the one that
/// speaks HTTP from one that does not. The project-server filter is pure and
/// covered by `LocalServerRulesTests`: the test host itself, started from `/`
/// on a dynamic port, is exactly what it leaves out.
nonisolated final class LocalServerScannerTests: XCTestCase {

    /// Accepts connections on loopback and answers each with a line that is
    /// not HTTP, then closes it: a database or a mail server, as the probe
    /// sees one.
    private final class NotHTTPServer: Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "detour-test-not-http")

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                connection.send(content: Data("220 not a web server\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
            return try await withCheckedThrowingContinuation { continuation in
                let resumed = Mutex(false)
                listener.stateUpdateHandler = { [listener] state in
                    let first: Bool
                    switch state {
                    case .ready:
                        first = resumed.withLock { done in defer { done = true }; return !done }
                        if first { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error):
                        first = resumed.withLock { done in defer { done = true }; return !done }
                        if first { continuation.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    @MainActor func testTheScanFindsThisProcesssListenersAndTheProbeKnowsWhichSpeaksHTTP() async throws {
        let http = try LoopbackHTTPServer(routes: ["/": "<p>hello</p>"])
        let notHTTP = try NotHTTPServer()
        let httpPort = Int(try await http.start())
        let otherPort = Int(try await notHTTP.start())
        defer {
            http.stop()
            notHTTP.stop()
        }

        let listeners = LocalServerScanner.listeners(pids: [getpid()])
        let httpListener = try XCTUnwrap(listeners.first { $0.port == httpPort }, "the HTTP fixture is listening")
        let otherListener = try XCTUnwrap(listeners.first { $0.port == otherPort }, "so is the other one")
        XCTAssertEqual(httpListener.pid, getpid())
        XCTAssertFalse(httpListener.executablePath.isEmpty, "the executable is read")
        XCTAssertFalse(httpListener.directory.isEmpty, "the working directory is read")

        let httpAddress = try XCTUnwrap(LocalServerRules.reachableAddress(forBound: httpListener.address),
                                        "bound where localhost reaches it: \(httpListener.address)")
        let otherAddress = try XCTUnwrap(LocalServerRules.reachableAddress(forBound: otherListener.address))
        let answer = await LocalServerScanner.probe(address: httpAddress, port: httpPort, timeout: .seconds(2))
        XCTAssertEqual(answer, .http)
        XCTAssertEqual(http.requestedPaths, ["/"], "one plain request; the TLS attempt never reads as one")
        let other = await LocalServerScanner.probe(address: otherAddress, port: otherPort, timeout: .seconds(2))
        XCTAssertEqual(other, .notHTTP)
    }

    func testAPortNobodyListensOnIsNotHTTPAndDoesNotWaitForTheTimeout() async throws {
        // Bind and release a port, so nothing listens on it.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "detour-test-closed-port")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state else { return }
                if resumed.withLock({ done in defer { done = true }; return !done }) {
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: queue)
        }
        listener.cancel()
        try await Task.sleep(for: .milliseconds(100))

        let started = ContinuousClock.now
        let result = await LocalServerScanner.probe(address: "127.0.0.1", port: Int(port), timeout: .seconds(5))
        XCTAssertEqual(result, .notHTTP)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "a refused connection ends the probe")
    }

    @MainActor func testTheDirectoryKeepsTheLastScanAndSharesOneInFlight() async throws {
        let calls = Mutex(0)
        struct CountingScanner: LocalServerScanning {
            let calls: @Sendable () -> Void
            func scan() async -> LocalServerScan {
                calls()
                try? await Task.sleep(for: .milliseconds(100))
                return LocalServerScan(servers: [LocalServer(port: 3000, isHTTPS: false, processName: "node",
                                                             directory: "/p", listensOnIPv4: true)])
            }
        }
        let directory = LocalServerDirectory(scanner: CountingScanner { calls.withLock { $0 += 1 } })
        XCTAssertEqual(directory.last, .empty, "nothing before the first scan")
        async let first = directory.refresh()
        async let second = directory.refresh()
        let (a, b) = await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(calls.withLock { $0 }, 1, "the second palette joined the scan in flight")
        XCTAssertEqual(directory.last.servers.map(\.port), [3000])
    }

    // MARK: - Scanning with a given listing and probe

    private static let project = LocalListener(pid: 500, port: 3000, address: "127.0.0.1",
                                               executablePath: "/opt/homebrew/bin/node",
                                               directory: "/Users/dev/Projects/website")
    private static let docker = LocalListener(pid: 600, port: 3300, address: "127.0.0.1",
                                              executablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                                              directory: "/Users/dev/Library/Containers/com.docker.docker/Data")

    func testADefiniteAnswerIsProbedOnceAndEveryListeningPortIsReported() async {
        let probes = Mutex<[Int]>([])
        let scanner = LocalServerScanner(excludedProcessID: nil, listeners: { [Self.project, Self.docker] },
                                         probe: { _, port in
                                             probes.withLock { $0.append(port) }
                                             return .http
                                         })
        let first = await scanner.scan()
        let second = await scanner.scan()
        XCTAssertEqual(first.servers.map(\.port), [3000], "Docker's forward is not offered")
        XCTAssertEqual(first.listeningPorts, [3000, 3300], "but it is listening")
        XCTAssertEqual(second, first)
        XCTAssertEqual(probes.withLock { $0 }, [3000], "probed once, and only the project server")
    }

    func testAProbeThatTimedOutIsAskedAgainOnTheNextScan() async {
        let answers = Mutex<[LocalServerScanner.ProbeResult]>([.noAnswer, .http])
        let scanner = LocalServerScanner(excludedProcessID: nil, listeners: { [Self.project] },
                                         probe: { _, _ in answers.withLock { $0.removeFirst() } })
        let slow = await scanner.scan()
        XCTAssertEqual(slow.servers, [], "no answer yet")
        XCTAssertEqual(slow.listeningPorts, [3000])
        let answered = await scanner.scan()
        XCTAssertEqual(answered.servers.map(\.port), [3000], "offered once it answers")
    }

    func testANewProcessOnThePortIsProbedAfresh() async {
        let listener = Mutex(Self.project)
        let probes = Mutex(0)
        let scanner = LocalServerScanner(excludedProcessID: nil, listeners: { [listener.withLock { $0 }] },
                                         probe: { _, _ in
                                             probes.withLock { $0 += 1 }
                                             return .notHTTP
                                         })
        _ = await scanner.scan()
        _ = await scanner.scan()
        listener.withLock { $0.pid = 501 }
        _ = await scanner.scan()
        XCTAssertEqual(probes.withLock { $0 }, 2, "the restart is a new listener")
    }

    func testDetoursOwnListenersAreNeverOffered() async {
        let mine = LocalListener(pid: getpid(), port: 3000, address: "127.0.0.1",
                                 executablePath: "/opt/homebrew/bin/node", directory: "/Users/dev/Projects/website")
        let scanner = LocalServerScanner(listeners: { [mine] }, probe: { _, _ in .http })
        let scan = await scanner.scan()
        XCTAssertEqual(scan.servers, [])
        XCTAssertEqual(scan.listeningPorts, [3000], "but its port is running: its history rows are not demoted")
    }
}
