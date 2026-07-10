import AppKit

/// Shared favicon fetcher: downloads, validates the HTTP status, decodes the
/// image, and delivers the result on the main thread. Successful decodes are
/// cached in-memory keyed by favicon URL, and concurrent requests for the same
/// URL are coalesced onto a single network fetch.
final class FaviconLoader {
    static let shared = FaviconLoader()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: [(NSImage?) -> Void]] = [:]

    func load(from url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        // Coalesce concurrent loads for the same URL: queue the completion behind
        // the in-flight request instead of starting a second network fetch.
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            var image: NSImage?
            if let data,
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.cache.setObject(image, forKey: key) }
                let completions = self.inFlight.removeValue(forKey: key) ?? []
                for completion in completions { completion(image) }
            }
        }.resume()
    }
}
