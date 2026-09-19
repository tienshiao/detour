import AppKit
import WebKit

/// Handles `detour-favicon://` URLs by looking up favicon images from the history database.
/// Extensions use `chrome.runtime.getURL("/_favicon/?pageUrl=X")` to get favicons;
/// our polyfill redirects these to this custom scheme so we can serve the images.
///
/// The permission gate below is this handler's own; everything after it — the
/// history lookup, the cache, the download and the resize — is
/// `FaviconPNGLoader`, shared with the History page's `favicon` route (TASK-86).
class FaviconSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "detour-favicon"

    /// WebKit-assigned extension hosts that have the "favicon" manifest permission.
    /// Populated at extension load time by Profile.loadExtensionContext(_:).
    private static var permittedHosts = Set<String>()
    private static let permittedHostsLock = NSLock()

    static func grantFaviconPermission(forWebKitHost host: String) {
        permittedHostsLock.lock()
        permittedHosts.insert(host)
        permittedHostsLock.unlock()
    }

    static func revokeFaviconPermission(forWebKitHost host: String) {
        permittedHostsLock.lock()
        permittedHosts.remove(host)
        permittedHostsLock.unlock()
    }

    private static func hasFaviconPermission(forWebKitHost host: String) -> Bool {
        permittedHostsLock.lock()
        defer { permittedHostsLock.unlock() }
        return permittedHosts.contains(host)
    }

    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock(); defer { lock.unlock() }
        activeTasks.insert(taskID)

        guard let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let extensionID = requestURL.host, !extensionID.isEmpty,
              let pageUrl = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        // Verify the extension has the "favicon" permission (cached at load time).
        guard Self.hasFaviconPermission(forWebKitHost: extensionID) else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        // No size asked for means "whatever the site serves", which is the one
        // case the bytes pass through unconverted.
        let requestedSize = components.queryItems?
            .first(where: { $0.name == "size" })
            .flatMap { $0.value.flatMap(Int.init) } ?? 0

        FaviconPNGLoader.shared.pngData(forPageURL: pageUrl,
                                        resizedTo: requestedSize > 0 ? requestedSize : nil,
                                        undecodablePassesThrough: true) { [weak self] data in
            self?.respond(urlSchemeTask, taskID: taskID, data: data, mimeType: data != nil ? "image/png" : nil)
        }
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
            let responseData = data ?? FaviconPNGLoader.transparentPixel
            let responseMime = data != nil ? (mimeType ?? "image/png") : "image/png"
            let response = URLResponse(url: url, mimeType: responseMime, expectedContentLength: responseData.count, textEncodingName: nil)
            task.didReceive(response)
            task.didReceive(responseData)
            task.didFinish()
        }
    }
}
