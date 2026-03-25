import Foundation
import AppKit

class PinnedEntry {
    let id: UUID
    var pinnedURL: URL
    var pinnedTitle: String
    var faviconURL: URL?       // cached for dormant display
    var favicon: NSImage?      // cached image for dormant display
    var onFaviconDownloaded: (() -> Void)?
    var folderID: UUID?
    var sortOrder: Int
    var tab: BrowserTab?       // nil = dormant

    var isLive: Bool { tab != nil }

    /// The favicon to display: live tab's favicon when live, cached image when dormant.
    var displayFavicon: NSImage? {
        tab?.favicon ?? favicon
    }

    var displayTitle: String {
        if !isLive || isAtPinnedHome { return pinnedTitle }
        if isNavigatedWithinPinnedHost {
            let pageTitle = tab?.webView?.title ?? tab?.title ?? pinnedTitle
            return "/ \(pageTitle)"
        }
        return tab?.title ?? pinnedTitle
    }

    var isAtPinnedHome: Bool {
        guard let tab else { return true }  // dormant = at home
        return tab.url == pinnedURL
    }

    var isNavigatedWithinPinnedHost: Bool {
        guard let tab, let currentURL = tab.url else { return false }
        return currentURL.host == pinnedURL.host && currentURL != pinnedURL
    }

    init(id: UUID = UUID(), pinnedURL: URL, pinnedTitle: String,
         faviconURL: URL? = nil, favicon: NSImage? = nil, folderID: UUID? = nil,
         sortOrder: Int = 0, tab: BrowserTab? = nil) {
        self.id = id
        self.pinnedURL = pinnedURL
        self.pinnedTitle = pinnedTitle
        self.faviconURL = faviconURL
        self.favicon = favicon
        self.folderID = folderID
        self.sortOrder = sortOrder
        self.tab = tab

        // Download favicon for dormant entries that have a URL but no cached image
        if tab == nil, favicon == nil, let faviconURL {
            downloadFavicon(from: faviconURL)
        }
    }

    private func downloadFavicon(from url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tab == nil else { return }
                self.favicon = image
                self.onFaviconDownloaded?()
            }
        }.resume()
    }
}
