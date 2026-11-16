import AppKit
import Combine

class Favorite {
    let id: UUID
    var url: URL
    var title: String
    var faviconURL: URL?
    /// Published so every window's tile re-renders when the download lands. A
    /// single `onFaviconDownloaded` callback only ever reached whichever tile
    /// registered last, leaving the other windows on the globe (TASK-53).
    @Published var favicon: NSImage?
    var sortOrder: Int
    /// nil = dormant. A tab arriving here is enumerable, so it is reported open
    /// (TASK-52, see `ExtensionTabLifecycle`).
    var tab: BrowserTab? {
        didSet { tab.map(ExtensionTabLifecycle.didPlace) }
    }

    /// The opener link (`BrowserTab.parentID`) of the backing tab this favourite
    /// last had, kept while it is dormant so the tab a wake builds gets it
    /// back, through `Space.liveOpenerID` (TASK-378). Set when the backing tab
    /// is dropped; read only while dormant. In memory only: a relaunch with
    /// the favourite dormant loses it.
    var dormantOpenerID: UUID?

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

        // Downloaded regardless of the backing tab: a restored tab is asleep and
        // publishes its own favicon only later, so a favourite that deferred to
        // it showed the globe until some other window rebuilt the tile
        // (TASK-53). FaviconLoader caches and coalesces per URL, so the tab's
        // identical fetch costs nothing extra.
        if favicon == nil, let faviconURL {
            downloadFavicon(from: faviconURL)
        }
    }

    private func downloadFavicon(from url: URL) {
        FaviconLoader.shared.load(from: url) { [weak self] image in
            guard let self, let image else { return }
            self.favicon = image
        }
    }
}
