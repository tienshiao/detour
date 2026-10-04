import AppKit
import WebKit

/// Handles `detour-favicon://` URLs by looking up favicon images from the history database.
/// Extensions use `chrome.runtime.getURL("/_favicon/?pageUrl=X")` to get favicons;
/// our polyfill redirects these to this custom scheme so we can serve the images.
///
/// One handler belongs to one `Profile`: the profile's extension controller
/// builds one for its extension pages, and each of its spaces builds one for
/// its tabs (`Space.makeWebViewConfiguration`), where an extension's frame can
/// sit inside a web page. Everything a request may learn is decided from that
/// profile (TASK-152), never from the request:
///
/// - the URL's host must be the WebKit host of an extension context loaded in
///   *this* profile, and that extension must hold the `favicon` permission
///   (the permission Chrome requires for `_favicon`);
/// - the lookup is scoped to the profile's own history — the spaces
///   `HistoryPageBridge.scope(forProfile:)` gives its History page and
///   `chrome.history`. The Private profile, a deleted profile and a profile no
///   space uses have no scope and get no icon.
///
/// A refused request and a page with no icon in scope get the same answer, the
/// transparent pixel, so a page only another profile visited is
/// indistinguishable from one nobody visited.
///
/// Not checked, because WebKit does not tell a scheme handler which frame is
/// asking: that the requesting frame *is* the extension the host names. A
/// frame in this profile that knows the host of a `favicon` extension loaded
/// here gets what that extension would get.
///
/// The gate below is this handler's own; everything after it — the
/// history lookup, the cache, the download and the resize — is
/// `FaviconPNGLoader`, shared with the History page's `favicon` route (TASK-86).
class FaviconSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "detour-favicon"

    /// The profile whose web views this handler serves. Weak: the profile (or
    /// one of its spaces' configurations) owns the handler. A handler whose
    /// profile is gone, or that never had one (a space with no usable profile),
    /// answers nothing.
    private weak var profile: Profile?

    init(profile: Profile?) {
        self.profile = profile
        super.init()
    }

    /// What a request naming `webKitHost` may look up: the history scope of
    /// this handler's profile and the database to read, or nil when the
    /// request is refused. Main thread (WebKit calls a scheme handler there).
    private func lookupScope(forWebKitHost webKitHost: String) -> (spaceIDs: [String], database: HistoryDatabase)? {
        guard let profile,
              let extensionID = profile.extensionID(forOriginScheme: ExtensionPageURL.scheme, host: webKitHost),
              ExtensionManager.shared.extension(withID: extensionID)?.manifest.permissions?.contains("favicon") == true,
              let spaceIDs = HistoryPageBridge.scope(forProfile: profile), !spaceIDs.isEmpty else { return nil }
        // The polyfill handler's database is the test seam `chrome.history`
        // uses too; production never assigns it.
        return (spaceIDs, profile.polyfillHandler?.historyDatabase ?? .shared)
    }

    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock(); defer { lock.unlock() }
        activeTasks.insert(taskID)

        guard let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let webKitHost = requestURL.host, !webKitHost.isEmpty,
              let pageUrl = components.queryItems?.first(where: { $0.name == "pageUrl" })?.value else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        // The host must be a `favicon` extension of this handler's profile, and
        // the profile must have a history to answer from.
        guard let lookup = lookupScope(forWebKitHost: webKitHost) else {
            respond(urlSchemeTask, taskID: taskID, data: nil, mimeType: nil)
            return
        }

        // No size asked for means "whatever the site serves", which is the one
        // case the bytes pass through unconverted.
        let requestedSize = components.queryItems?
            .first(where: { $0.name == "size" })
            .flatMap { $0.value.flatMap(Int.init) } ?? 0

        FaviconPNGLoader.shared.pngData(forPageURL: pageUrl, scope: .spaces(lookup.spaceIDs),
                                        resizedTo: requestedSize > 0 ? requestedSize : nil,
                                        undecodablePassesThrough: true,
                                        database: lookup.database) { [weak self] data in
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
