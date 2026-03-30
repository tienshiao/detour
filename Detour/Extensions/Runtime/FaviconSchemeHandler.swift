import WebKit

/// Handles `detour-favicon://` URLs by looking up favicon images from the history database.
/// Extensions use `chrome.runtime.getURL("/_favicon/?pageUrl=X")` to get favicons;
/// our polyfill redirects these to this custom scheme so we can serve the images.
class FaviconSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "detour-favicon"

    private static let transparentPixel: Data = {
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

    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()
    private let cache = NSCache<NSString, NSData>()

    override init() {
        cache.countLimit = 200
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock(); defer { lock.unlock() }
        activeTasks.insert(taskID)

        guard let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let pageUrl = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        // Check cache first
        if let cached = cache.object(forKey: pageUrl as NSString) {
            respond(urlSchemeTask, taskID: taskID, data: cached as Data, mimeType: "image/png")
            return
        }

        guard let faviconURLString = HistoryDatabase.shared.faviconURL(for: pageUrl),
              let faviconURL = URL(string: faviconURLString) else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        let task = URLSession.shared.dataTask(with: faviconURL) { [weak self] data, response, _ in
            guard let self else { return }
            let httpResponse = response as? HTTPURLResponse
            if let data, httpResponse?.statusCode == 200 {
                self.cache.setObject(data as NSData, forKey: pageUrl as NSString)
                self.respond(urlSchemeTask, taskID: taskID, data: data, mimeType: httpResponse?.mimeType)
            } else {
                self.respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            }
        }
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.lock(); defer { lock.unlock() }
        activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func respond(_ task: any WKURLSchemeTask, taskID: ObjectIdentifier, data: Data?, mimeType: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            let isActive = self.activeTasks.remove(taskID) != nil
            guard isActive else { return }

            let url = task.request.url ?? URL(string: "about:blank")!
            let responseData = data ?? Self.transparentPixel
            let responseMime = data != nil ? (mimeType ?? "image/png") : "image/png"
            let response = URLResponse(url: url, mimeType: responseMime, expectedContentLength: responseData.count, textEncodingName: nil)
            task.didReceive(response)
            task.didReceive(responseData)
            task.didFinish()
        }
    }
}
