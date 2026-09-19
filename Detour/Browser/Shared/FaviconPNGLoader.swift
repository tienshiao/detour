import AppKit
import Foundation

/// Favicon image *bytes* for a page URL, shared by the two schemes that hand
/// favicons to a web view: `detour-favicon://` (extensions holding the favicon
/// permission, `FaviconSchemeHandler`) and `detour://history/favicon` (the
/// History page, TASK-86). `FaviconLoader` is its counterpart for AppKit —
/// same job, but it produces an `NSImage` for the sidebar and the palette.
///
/// Detour persists no favicon image data anywhere: a `historyURL` row keeps only
/// the favicon *URL*, so a cache miss is a network fetch of that URL. Two things
/// follow, and both matter to the History page, which lists hundreds of rows:
///
///  - the cache is keyed by the resolved favicon URL, not by the page URL, so a
///    hundred pages of one site resolve to one icon and fetch it once;
///  - requests in flight for the same key are coalesced, so a burst of rows
///    appearing at once still makes a single request.
///
/// Lookups run off the calling thread: the History page's scheme handler is
/// asked from the main thread once per rendered row, and the `historyURL` read
/// is a disk read.
final class FaviconPNGLoader {
    static let shared = FaviconPNGLoader()

    /// A 1×1 transparent PNG — what `detour-favicon://` answers with when there
    /// is no icon, so an extension's `<img>` shows nothing rather than a broken
    /// image. (The History page 404s instead and draws its own placeholder.)
    static let transparentPixel: Data = {
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x01, 0xE5, 0x27, 0xDE, 0xFC, 0x00, 0x00,
            0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
            0x60, 0x82,
        ]
        return Data(bytes)
    }()

    /// The network fetch, as a test seam (mirrors `FaviconLoader.fetch`): tests
    /// replace it so no suite depends on the network. Only the download is
    /// replaced — the cache, the coalescing and the re-encode around it stand.
    var fetch: (URL, @escaping (Data?) -> Void) -> Void = { url, completion in
        URLSession.shared.dataTask(with: url) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    private let lock = NSLock()
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 200
        return cache
    }()
    private var inFlight: [NSString: [(Data?) -> Void]] = [:]

    /// The icon Detour recorded for `pageURL`, as image bytes, or nil when there
    /// is none (or it cannot be fetched).
    ///
    /// The *page* URL is what a caller names; which icon URL that resolves to is
    /// decided here, from the history database. So a caller can never point this
    /// at a host of its own choosing — only at the icon of a page the user has
    /// already visited.
    ///
    /// - Parameter size: a point size to re-encode the icon to, or nil to pass
    ///   the downloaded bytes through untouched (what `detour-favicon://`
    ///   does when an extension asks for no particular size). A size also
    ///   guarantees the result really is a PNG, which the internal scheme's
    ///   `nosniff` response needs.
    /// - Note: `completion` may run on any queue.
    func pngData(forPageURL pageURL: String, resizedTo size: Int?,
                 database: HistoryDatabase = .shared,
                 completion: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  let faviconURLString = database.faviconURL(for: pageURL),
                  let faviconURL = URL(string: faviconURLString),
                  let scheme = faviconURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                completion(nil)
                return
            }
            self.pngData(forFaviconURL: faviconURL, resizedTo: size, completion: completion)
        }
    }

    private func pngData(forFaviconURL faviconURL: URL, resizedTo size: Int?,
                         completion: @escaping (Data?) -> Void) {
        let key = "\(faviconURL.absoluteString)@\(size ?? 0)" as NSString

        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            completion(cached as Data)
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        fetch(faviconURL) { [weak self] data in
            guard let self else {
                completion(nil)
                return
            }
            // A requested size is also a re-encode to PNG; a failure to decode
            // the image at all is a failure, not a pass-through of bytes whose
            // type we would then be guessing at.
            let result: Data?
            if let size {
                result = data.flatMap { self.resizedPNG($0, to: size) }
            } else {
                result = data
            }
            self.lock.lock()
            if let result { self.cache.setObject(result as NSData, forKey: key) }
            let waiting = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for completion in waiting { completion(result) }
        }
    }

    private func resizedPNG(_ data: Data, to size: Int) -> Data? {
        guard size > 0, let image = NSImage(data: data) else { return nil }
        let targetSize = NSSize(width: size, height: size)
        let resized = NSImage(size: targetSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect)
            return true
        }
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    /// Test seam: drops the cache and any queued completions, so one test's
    /// downloads cannot satisfy the next test's lookups.
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
        inFlight.removeAll()
    }
}
