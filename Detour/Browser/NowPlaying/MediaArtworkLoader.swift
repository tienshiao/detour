import AppKit
import ImageIO

/// Fetches the artwork a page names in its Media Session metadata, for the
/// now-playing bar (TASK-192). The page picks the URL and can change it as
/// often as it likes, and the app — not the page — makes the request, so:
///
/// - **Its own ephemeral session** (`makeSessionConfiguration`): no cookies
///   sent or stored, no credentials, no URL cache. The request carries
///   nothing of the app's or any profile's, Private ones included, and
///   leaves nothing on disk. Private fetches get a session of their own, so
///   no connection or TLS session is reused between a Private window's
///   request and a normal one's. (Favicons still use `URLSession.shared`.)
/// - **A size cap** (`maxResponseBytes`), checked against the declared length
///   and while the body arrives, and a pixel-size cap before decoding; the
///   image is decoded straight to the bar's size.
/// - **One fetch per tab, newest wins.** A request waits `debounce` before it
///   starts; a newer URL for the same tab replaces a waiting request and
///   cancels one in flight, whose result is then dropped. Windows asking for
///   the same tab's same URL share one fetch.
/// - **Memory only.** Images for normal profiles are cached in memory; a
///   Private tab's are not kept at all.
///
/// Main thread only.
final class MediaArtworkLoader {
    static let shared = MediaArtworkLoader()

    static let maxResponseBytes = 2 * 1024 * 1024
    /// The widest image decoded at all; larger ones are refused from their header.
    static let maxPixelSide = 4096
    /// The decoded size: the pixels `MediaSessionReport` picks an image for.
    static let thumbnailPixels = MediaSessionReport.preferredArtworkPixels
    static let defaultDebounce: TimeInterval = 0.25

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }

    /// Decodes `data` to an image at most `thumbnailPixels` on its longer
    /// side. Nil for anything ImageIO cannot read, and for an image whose
    /// header names a side over `maxPixelSide` (never decoded).
    static func decodeArtwork(_ data: Data, maxPixelSide: Int = maxPixelSide,
                              thumbnailPixels: Int = thumbnailPixels) -> NSImage? {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxPixelSide, height <= maxPixelSide else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Starts downloading a URL (the second argument: for a Private tab) and
    /// returns a function that cancels it. The completion gets the body, or
    /// nil (error, non-200, over the cap, cancelled), on any thread. A test
    /// seam: tests replace it to finish fetches by hand.
    typealias Fetch = (URL, Bool, @escaping (Data?) -> Void) -> () -> Void
    var fetch: Fetch
    var debounce: TimeInterval

    private let fetcher: CappedDataFetcher
    private let privateFetcher: CappedDataFetcher
    private let cache = NSCache<NSURL, NSImage>()
    private var requests: [UUID: Request] = [:]

    /// The one request a tab has waiting or in flight.
    private final class Request {
        let url: URL
        let isPrivate: Bool
        var completions: [(NSImage?) -> Void]
        var start: DispatchWorkItem?
        var cancel: (() -> Void)?

        init(url: URL, isPrivate: Bool, completion: @escaping (NSImage?) -> Void) {
            self.url = url
            self.isPrivate = isPrivate
            completions = [completion]
        }

        func abandon() {
            start?.cancel()
            cancel?()
            completions.removeAll()
        }
    }

    init(configuration: URLSessionConfiguration = MediaArtworkLoader.makeSessionConfiguration(),
         maxResponseBytes: Int = MediaArtworkLoader.maxResponseBytes,
         debounce: TimeInterval = MediaArtworkLoader.defaultDebounce) {
        // Each session copies the configuration, so the two share no state.
        let fetcher = CappedDataFetcher(configuration: configuration, limit: maxResponseBytes)
        let privateFetcher = CappedDataFetcher(configuration: configuration, limit: maxResponseBytes)
        self.fetcher = fetcher
        self.privateFetcher = privateFetcher
        self.debounce = debounce
        fetch = { url, isPrivate, completion in
            (isPrivate ? privateFetcher : fetcher).start(url, completion: completion)
        }
        cache.countLimit = 32
    }

    /// Delivers `url`'s image for `tabID` on the main thread: at once from the
    /// cache, else after the fetch; nil when it cannot be had. A completion
    /// whose request a newer URL for the same tab replaced is never called.
    func load(_ url: URL, tabID: UUID, isPrivate: Bool, completion: @escaping (NSImage?) -> Void) {
        if !isPrivate, let cached = cache.object(forKey: url as NSURL) {
            requests.removeValue(forKey: tabID)?.abandon()
            completion(cached)
            return
        }
        if let request = requests[tabID], request.url == url, request.isPrivate == isPrivate {
            request.completions.append(completion)
            return
        }
        requests.removeValue(forKey: tabID)?.abandon()
        let request = Request(url: url, isPrivate: isPrivate, completion: completion)
        requests[tabID] = request
        let start = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.requests[tabID] === request else { return }
            request.start = nil
            request.cancel = self.fetch(url, request.isPrivate) { data in
                let image = data.flatMap { Self.decodeArtwork($0) }
                DispatchQueue.main.async { [weak self] in self?.finish(request, tabID: tabID, image: image) }
            }
        }
        request.start = start
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: start)
    }

    private func finish(_ request: Request, tabID: UUID, image: NSImage?) {
        guard requests[tabID] === request else { return }
        requests[tabID] = nil
        if let image, !request.isPrivate { cache.setObject(image, forKey: request.url as NSURL) }
        let completions = request.completions
        request.completions.removeAll()
        for completion in completions { completion(image) }
    }

    /// Cancels everything and ends the session (tests: a session keeps its
    /// delegate alive until invalidated).
    func invalidate() {
        for request in requests.values { request.abandon() }
        requests.removeAll()
        fetcher.invalidate()
        privateFetcher.invalidate()
    }
}

/// Downloads into memory up to a byte limit: a declared length over it is
/// refused at the response, and a body that grows past it is cancelled.
private final class CappedDataFetcher: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private let lock = NSLock()
    private var downloads: [Int: Download] = [:]
    private var session: URLSession!

    private final class Download {
        var data = Data()
        var refused = false
        let completion: (Data?) -> Void
        init(completion: @escaping (Data?) -> Void) { self.completion = completion }
    }

    init(configuration: URLSessionConfiguration, limit: Int) {
        self.limit = limit
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(_ url: URL, completion: @escaping (Data?) -> Void) -> () -> Void {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        lock.withLock { downloads[task.taskIdentifier] = Download(completion: completion) }
        task.resume()
        return { [weak task] in task?.cancel() }
    }

    func invalidate() { session.invalidateAndCancel() }

    private func download(for task: URLSessionTask) -> Download? {
        lock.withLock { downloads[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        // -1 when the length is not declared: the body is counted instead.
        guard status == 200, response.expectedContentLength <= Int64(limit) else {
            download(for: dataTask)?.refused = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = download(for: dataTask), !download.refused else { return }
        download.data.append(data)
        if download.data.count > limit {
            download.refused = true
            download.data = Data()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let download = lock.withLock({ downloads.removeValue(forKey: task.taskIdentifier) }) else { return }
        download.completion(error == nil && !download.refused ? download.data : nil)
    }
}
