import AppKit

class Favorite {
    let id: UUID
    var url: URL
    var title: String
    var faviconURL: URL?
    var favicon: NSImage?
    var onFaviconDownloaded: (() -> Void)?
    var sortOrder: Int
    var tab: BrowserTab?       // nil = dormant

    var isLive: Bool { tab != nil }

    var displayFavicon: NSImage? {
        tab?.favicon ?? favicon
    }

    init(id: UUID = UUID(), url: URL, title: String, faviconURL: URL? = nil,
         favicon: NSImage? = nil, sortOrder: Int = 0, tab: BrowserTab? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.favicon = favicon
        self.sortOrder = sortOrder
        self.tab = tab

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
