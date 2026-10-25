import XCTest
import AppKit
@testable import Detour

/// TASK-192: a page's Media Session artwork is a URL the page picks, fetched
/// by the app. It goes through its own ephemeral session (no cookies, no
/// cache), with a size cap, and at most one fetch in flight per tab with the
/// newest URL winning.
@MainActor
final class MediaArtworkLoaderTests: XCTestCase {

    private var loaders: [MediaArtworkLoader] = []

    override func tearDown() {
        for loader in loaders { loader.invalidate() }
        loaders.removeAll()
        ArtworkStubProtocol.reset()
        if let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://artwork.test/")!) {
            for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) }
        }
        super.tearDown()
    }

    // MARK: - Images

    /// A PNG of `side` x `side` pixels. `noise` makes it incompressible, so
    /// its size is about `side * side * 4` bytes.
    private static func png(side: Int, noise: Bool = false) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var generator = SystemRandomNumberGenerator()
        for x in 0..<side {
            for y in 0..<side {
                let value = noise ? CGFloat(UInt8.random(in: 0...255, using: &generator)) / 255 : 0.5
                rep.setColor(NSColor(deviceRed: value, green: 1 - value, blue: 0.3, alpha: 1), atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - The session

    func testTheSessionKeepsNoCookiesAndNoCache() {
        let configuration = MediaArtworkLoader.makeSessionConfiguration()
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies, "the app's cookie jar must not reach the page's server")
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache, "nothing a page names is written to the on-disk URL cache")
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    private func makeNetworkLoader(maxResponseBytes: Int) -> MediaArtworkLoader {
        let configuration = MediaArtworkLoader.makeSessionConfiguration()
        configuration.protocolClasses = [ArtworkStubProtocol.self]
        let loader = MediaArtworkLoader(configuration: configuration, maxResponseBytes: maxResponseBytes, debounce: 0)
        loaders.append(loader)
        return loader
    }

    /// What the loader delivers for `path`; nil also when it delivers nothing
    /// within the timeout (the test then fails on the expectation).
    private func load(_ loader: MediaArtworkLoader, _ path: String) async -> NSImage? {
        let delivered = expectation(description: "the loader delivers \(path)")
        var result: NSImage?
        loader.load(URL(string: "https://artwork.test\(path)")!, tabID: UUID(), isPrivate: false) {
            result = $0
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 5)
        return result
    }

    func testAnImageArrivesWithoutTheAppsCookies() async throws {
        HTTPCookieStorage.shared.setCookie(HTTPCookie(properties: [
            .domain: "artwork.test", .path: "/", .name: "session", .value: "secret", .secure: "TRUE",
        ])!)
        ArtworkStubProtocol.stub("/art.png", body: Self.png(side: 32))
        let loader = makeNetworkLoader(maxResponseBytes: 100_000)

        let image = await load(loader, "/art.png")

        XCTAssertNotNil(image)
        let request = try XCTUnwrap(ArtworkStubProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testAResponseOverTheCapIsDropped() async throws {
        let body = Self.png(side: 64, noise: true)
        XCTAssertGreaterThan(body.count, 8_000)
        ArtworkStubProtocol.stub("/declared.png", body: body, declareLength: true)
        ArtworkStubProtocol.stub("/streamed.png", body: body, declareLength: false)

        let image = await load(makeNetworkLoader(maxResponseBytes: body.count + 1), "/declared.png")
        XCTAssertNotNil(image, "the same image under the cap decodes")
        let declared = await load(makeNetworkLoader(maxResponseBytes: 8_000), "/declared.png")
        XCTAssertNil(declared, "a declared length over the cap is refused")
        let streamed = await load(makeNetworkLoader(maxResponseBytes: 8_000), "/streamed.png")
        XCTAssertNil(streamed, "a body that grows past the cap is cut off")
    }

    func testAnErrorStatusIsDropped() async {
        ArtworkStubProtocol.stub("/missing.png", status: 404, body: Self.png(side: 16))
        let image = await load(makeNetworkLoader(maxResponseBytes: 100_000), "/missing.png")
        XCTAssertNil(image)
    }

    // MARK: - Decoding

    func testDecodingBoundsTheImage() throws {
        let image = try XCTUnwrap(MediaArtworkLoader.decodeArtwork(Self.png(side: 200), maxPixelSide: 256,
                                                                   thumbnailPixels: 64))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 64, "drawn at the bar's size, not the page's")
        XCTAssertNil(MediaArtworkLoader.decodeArtwork(Self.png(side: 300), maxPixelSide: 256, thumbnailPixels: 64),
                     "an image wider than the limit is never decoded")
        XCTAssertNil(MediaArtworkLoader.decodeArtwork(Data("not an image".utf8)))
    }

    // MARK: - One fetch per tab, newest wins

    /// Records the fetches a loader starts and lets the test finish them.
    private final class FakeFetch {
        var started: [URL] = []
        var cancelled: [URL] = []
        var privateFetches: [URL] = []
        var pending: [URL: (Data?) -> Void] = [:]

        func finish(_ url: URL, with data: Data?) { pending.removeValue(forKey: url)?(data) }
    }

    private func makeFakeLoader(debounce: TimeInterval = 0.05) -> (MediaArtworkLoader, FakeFetch) {
        let fake = FakeFetch()
        let loader = MediaArtworkLoader(debounce: debounce)
        loader.fetch = { url, isPrivate, completion in
            fake.started.append(url)
            if isPrivate { fake.privateFetches.append(url) }
            fake.pending[url] = completion
            return { fake.cancelled.append(url) }
        }
        loaders.append(loader)
        return (loader, fake)
    }

    private let a = URL(string: "https://cdn.test/a.png")!
    private let b = URL(string: "https://cdn.test/b.png")!
    private let c = URL(string: "https://cdn.test/c.png")!

    func testAPageChangingItsArtworkQuicklyFetchesOnlyTheNewest() async throws {
        let (loader, fake) = makeFakeLoader()
        let tab = UUID()
        var delivered: [URL] = []
        for url in [a, b, c] {
            loader.load(url, tabID: tab, isPrivate: false) { image in if image != nil { delivered.append(url) } }
        }
        try await waitUntil("the fetch") { !fake.started.isEmpty }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fake.started, [c], "the debounce lets only the last change through")

        fake.finish(c, with: Self.png(side: 8))
        try await waitUntil("the image") { delivered == [c] }
    }

    func testANewerURLCancelsTheFetchInFlight() async throws {
        let (loader, fake) = makeFakeLoader()
        let tab = UUID()
        var delivered: [URL] = []
        loader.load(a, tabID: tab, isPrivate: false) { _ in delivered.append(self.a) }
        try await waitUntil("a's fetch") { fake.started == [self.a] }

        loader.load(b, tabID: tab, isPrivate: false) { _ in delivered.append(self.b) }
        XCTAssertEqual(fake.cancelled, [a], "one fetch in flight per tab")
        try await waitUntil("b's fetch") { fake.started == [self.a, self.b] }

        fake.finish(a, with: Self.png(side: 8))
        fake.finish(b, with: Self.png(side: 8))
        try await waitUntil("b's image") { delivered.contains(self.b) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(delivered, [b], "a superseded fetch delivers nothing")
    }

    func testEveryWindowAskingForTheSameArtworkSharesOneFetch() async throws {
        let (loader, fake) = makeFakeLoader()
        let tab = UUID()
        var deliveries = 0
        loader.load(a, tabID: tab, isPrivate: false) { _ in deliveries += 1 }
        loader.load(a, tabID: tab, isPrivate: false) { _ in deliveries += 1 }
        try await waitUntil("the fetch") { !fake.started.isEmpty }
        fake.finish(a, with: Self.png(side: 8))
        try await waitUntil("both deliveries") { deliveries == 2 }
        XCTAssertEqual(fake.started, [a])
    }

    func testTabsDoNotCancelEachOther() async throws {
        let (loader, fake) = makeFakeLoader()
        loader.load(a, tabID: UUID(), isPrivate: false) { _ in }
        loader.load(b, tabID: UUID(), isPrivate: false) { _ in }
        try await waitUntil("both fetches") { Set(fake.started) == [self.a, self.b] }
        XCTAssertTrue(fake.cancelled.isEmpty)
    }

    func testNormalArtworkIsKeptInMemory() async throws {
        let (loader, fake) = makeFakeLoader()
        var image: NSImage?
        loader.load(a, tabID: UUID(), isPrivate: false) { image = $0 }
        try await waitUntil("the fetch") { !fake.started.isEmpty }
        fake.finish(a, with: Self.png(side: 8))
        try await waitUntil("the image") { image != nil }

        var again: NSImage?
        loader.load(a, tabID: UUID(), isPrivate: false) { again = $0 }
        XCTAssertNotNil(again, "a cached image is delivered at once")
        XCTAssertEqual(fake.started, [a], "and not fetched again")
    }

    func testPrivateArtworkIsNotCached() async throws {
        let (loader, fake) = makeFakeLoader()
        var image: NSImage?
        loader.load(a, tabID: UUID(), isPrivate: true) { image = $0 }
        try await waitUntil("the fetch") { !fake.started.isEmpty }
        fake.finish(a, with: Self.png(side: 8))
        try await waitUntil("the image") { image != nil }

        loader.load(a, tabID: UUID(), isPrivate: true) { _ in }
        try await waitUntil("a second fetch") { fake.started.count == 2 }
        loader.load(a, tabID: UUID(), isPrivate: false) { _ in }
        try await waitUntil("a normal window's own fetch") { fake.started.count == 3 }
        XCTAssertEqual(fake.privateFetches, [a, a], "Private fetches go through the Private session")
    }
}

/// Serves stubbed responses for `artwork.test` and records the requests.
private final class ArtworkStubProtocol: URLProtocol {
    private struct Stub { var status: Int; var body: Data; var declareLength: Bool }
    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func stub(_ path: String, status: Int = 200, body: Data, declareLength: Bool = true) {
        lock.withLock { stubs[path] = Stub(status: status, body: body, declareLength: declareLength) }
    }

    static func reset() {
        lock.withLock { stubs.removeAll(); recorded.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let stub = Self.lock.withLock { () -> Stub? in
            Self.recorded.append(request)
            return Self.stubs[url.path]
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var headers = ["Content-Type": "image/png"]
        if stub.declareLength { headers["Content-Length"] = String(stub.body.count) }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + 1_000, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
