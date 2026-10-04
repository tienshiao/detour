import XCTest
import WebKit
import Network
@testable import Detour

/// A loopback HTTP server whose `/file` is a large attachment sent slowly, so a
/// download of it is still in flight for as long as a test needs. Any other
/// path answers a small page.
///
/// The body is one 16 KB buffer sent again and again, never held whole. The
/// listener and its connections run on the main queue, so every property is
/// read and written there.
final class SlowDownloadServer: @unchecked Sendable {
    /// The length `/file` declares. No test runs long enough to reach it.
    static let declaredLength = 512 * 1024 * 1024
    private static let chunk = Data(repeating: 0x41, count: 16 * 1024)
    private static let chunkInterval: TimeInterval = 0.01

    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var isReady = false
    private var isStopped = false

    /// Body bytes of `/file` the server has handed to the socket.
    private(set) var bytesSent = 0
    /// The client closed or reset the `/file` connection.
    private(set) var peerClosed = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(timeout: TimeInterval = 5) async throws {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.isReady = true }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main)
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady {
            guard Date() < deadline else { throw XCTSkip("the fixture server did not start") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func stop() {
        isStopped = true
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            if path.hasPrefix("/file") {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                    + "Content-Disposition: attachment; filename=\"slow.bin\"\r\n"
                    + "Content-Length: \(Self.declaredLength)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
                    self?.sendNextChunk(on: connection)
                })
                self.watchForClose(of: connection)
            } else {
                let body = "<html><head><title>Fixture</title></head><body>fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    /// The client sends nothing after its request, so the next thing this read
    /// reports is the end of the connection.
    private func watchForClose(of connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.peerClosed = true
            } else {
                self.watchForClose(of: connection)
            }
        }
    }

    private func sendNextChunk(on connection: NWConnection) {
        guard !isStopped, !peerClosed, bytesSent < Self.declaredLength else { return }
        connection.send(content: Self.chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.peerClosed = true
                return
            }
            self.bytesSent += Self.chunk.count
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.chunkInterval) { [weak self] in
                self?.sendNextChunk(on: connection)
            }
        })
    }
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

/// A real `WKDownload` from a non-persistent data store against a server that
/// controls the pace (TASK-156): what WebKit does with it once the web view is
/// gone, and what closing a Private window does to it.
@MainActor
final class PrivateDownloadTransferTests: XCTestCase {

    private var server: SlowDownloadServer!
    private var directory: URL!
    private var previousDownloadsDirectory: URL!
    private var controller: BrowserWindowController?
    /// Downloads a test started through `DownloadManager.shared`.
    private var startedItems: [DownloadItem] = []
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateDownloadTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Before anything can download: never write into the user's Downloads.
        previousDownloadsDirectory = DownloadManager.shared.downloadsDirectory
        DownloadManager.shared.downloadsDirectory = directory
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
        server = try SlowDownloadServer()
        try await server.start()
    }

    override func tearDown() async throws {
        // Only reached with a download still running when a test failed half way.
        for item in startedItems where item.state == .downloading {
            DownloadManager.shared.cancelDownload(item)
        }
        for item in startedItems { DownloadManager.shared.removeDownload(item) }
        startedItems.removeAll()
        controller?.window?.close()
        controller = nil
        server.stop()
        server = nil
        DownloadManager.shared.downloadsDirectory = previousDownloadsDirectory
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - What WebKit does

    /// Turns the attachment into a download and keeps the `WKDownload`, as
    /// `DownloadItem` does.
    private final class RawDownloadDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let destination: URL
        private(set) var download: WKDownload?
        private(set) var ended: String?

        init(destination: URL) { self.destination = destination }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            .download
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            self.download = download
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            destination
        }

        func downloadDidFinish(_ download: WKDownload) { ended = "finished" }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            ended = "failed: \(error.localizedDescription)"
        }
    }

    /// Starts the download in a web view on a fresh non-persistent store and
    /// returns once both are released: the caller holds neither.
    private func startRawDownloadAndReleaseItsWebView(delegate: RawDownloadDelegate) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: server.url("/file")))
        try await waitUntil("the download to start writing") { fileSize(delegate.destination) >= 64 * 1024 }
        // What tearing a tab down does to its web view.
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    /// The measurement behind the rule: WebKit does not stop a download when
    /// the web view that started it goes away. The `WKDownload` keeps
    /// transferring and writing for as long as something retains it, on a
    /// non-persistent store too. Cancelling it is what stops the transfer, and
    /// the partial file stays on disk.
    func testWebKitKeepsADownloadRunningAfterItsWebViewIsGoneAndCancelLeavesThePartialFile() async throws {
        let destination = directory.appendingPathComponent("raw.bin")
        let delegate = RawDownloadDelegate(destination: destination)
        try await startRawDownloadAndReleaseItsWebView(delegate: delegate)
        let download = try XCTUnwrap(delegate.download)

        let sentAtRelease = server.bytesSent
        let sizeAtRelease = fileSize(destination)
        try await waitUntil("the transfer to go on after the web view is gone") {
            server.bytesSent >= sentAtRelease + 256 * 1024 && fileSize(destination) >= sizeAtRelease + 256 * 1024
        }
        XCTAssertFalse(server.peerClosed, "the connection is still open")
        XCTAssertNil(delegate.ended, "the download neither finished nor failed")

        var cancelled = false
        download.cancel { _ in cancelled = true }
        try await waitUntil("the cancel to complete") { cancelled }
        try await waitUntil("the server to see the connection close") { server.peerClosed }

        XCTAssertNil(delegate.ended, "a cancel through the API reports no failure")
        XCTAssertGreaterThan(fileSize(destination), 0, "WebKit leaves the partial file where it wrote it")
    }

    // MARK: - What closing a Private window does

    private func makePrivateWindow() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    /// Opens `/file` in a selected tab of a Private window and returns the
    /// download once it is writing.
    private func startDownload(in wc: BrowserWindowController, space: Space) async throws -> (DownloadItem, URL) {
        let manager = DownloadManager.shared
        let scope = wc.downloadScope
        let tab = TabStore.shared.addTab(in: space, url: server.url("/file"))
        wc.selectTab(id: tab.id)
        wc.showWindow(nil)

        try await waitUntil("the Private window's download to start writing") {
            guard let item = manager.items(in: scope).first else { return false }
            if !self.startedItems.contains(where: { $0 === item }) { self.startedItems.append(item) }
            guard let file = item.destinationURL else { return false }
            return fileSize(file) >= 64 * 1024
        }
        let item = try XCTUnwrap(manager.items(in: scope).first)
        let file = try XCTUnwrap(item.destinationURL)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path,
                       directory.standardizedFileURL.path, "the download is written to the test's directory")
        XCTAssertNotNil(item.download, "a real WKDownload")
        return (item, file)
    }

    /// A Private window that goes away without the question (an extension's
    /// `windows.remove`, anything that calls `close()`): its running download
    /// is cancelled, the transfer stops and the partial file is removed.
    func testClosingAPrivateWindowCancelsItsRunningDownloadAndRemovesThePartialFile() async throws {
        let (wc, space) = try makePrivateWindow()
        let (item, file) = try await startDownload(in: wc, space: space)
        let manager = DownloadManager.shared

        wc.window?.close()
        let sentAtClose = server.bytesSent
        let sizeAtClose = fileSize(file)

        XCTAssertNil(TabStore.shared.space(withID: space.id))
        let deadline = Date().addingTimeInterval(5)
        while !server.peerClosed, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(server.peerClosed, """
            the transfer went on after the window closed: the server sent \(server.bytesSent - sentAtClose) more \
            bytes, the file grew from \(sizeAtClose) to \(fileSize(file)), the item is \(item.state)
            """)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertNil(item.download)
        XCTAssertFalse(manager.items.contains { $0 === item }, "no window lists it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the partial file is removed")

        // And it stays stopped and removed.
        let sentAfterClose = server.bytesSent
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.bytesSent, sentAfterClose)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
