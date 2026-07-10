import AppKit

final class SuggestionProvider {
    static let maxSuggestions = 12
    static let maxSearchSuggestions = 4

    private let faviconCache = NSCache<NSString, NSImage>()
    private let db: HistoryDatabase
    private let searchService = SearchSuggestionsService.shared
    private var inFlightFavicons: [String: [(NSImage?) -> Void]] = [:]

    init(db: HistoryDatabase = .shared) {
        self.db = db
    }

    func defaultSuggestions(spaceID: String, tabs: [TabInfo]) -> [SuggestionItem] {
        let tabsByURL = Dictionary(tabs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let history = db.recentHistory(spaceID: spaceID, limit: 12)
        return history.map { entry -> SuggestionItem in
            if let tab = tabsByURL[entry.url] {
                return .openTab(tabID: tab.tabID, spaceID: tab.spaceID, url: tab.url, title: tab.title, favicon: tab.favicon)
            }
            return .historyResult(url: entry.url, title: entry.title, faviconURL: entry.faviconURL)
        }
    }

    struct LocalSuggestions {
        let items: [SuggestionItem]
        /// Scheme-stripped URL whose prefix matches the query; drives the
        /// inline completion in the text field. Nil when there is no top hit.
        let inlineCompletion: String?
    }

    /// Synchronous suggestions from local data only. Cheap enough to run on
    /// every keystroke. Ordering: top hit (the URL the query autocompletes to,
    /// shown as a rich tab/history row), the verbatim typed input, matching
    /// open tabs, then history.
    func localSuggestions(for query: String, spaceID: String, tabs: [TabInfo],
                          allowAutocomplete: Bool, currentTabID: UUID? = nil) -> LocalSuggestions {
        let q = query.lowercased()

        // Top hit: the best open tab or history URL whose display URL starts
        // with the typed prefix.
        var topHit: SuggestionItem?
        var inlineCompletion: String?
        var topHitTabID: UUID?
        var topHitURL: String?
        if allowAutocomplete {
            if let tab = tabs.first(where: { $0.tabID != currentTabID && $0.displayURL.lowercased().hasPrefix(q) }) {
                topHit = .openTab(tabID: tab.tabID, spaceID: tab.spaceID, url: tab.url, title: tab.title, favicon: tab.favicon)
                inlineCompletion = tab.displayURL
                topHitTabID = tab.tabID
                topHitURL = tab.url
            } else if let match = db.bestURLCompletion(prefix: query, spaceID: spaceID) {
                let display = Self.displayURL(match.url)
                if display.lowercased().hasPrefix(q) {
                    topHit = .historyResult(url: match.url, title: match.title, faviconURL: match.faviconURL)
                    inlineCompletion = display
                    topHitURL = match.url
                }
            }
        }

        // Open tabs matching query (excluding the top hit)
        let matchingTabs = Array(tabs.filter {
            $0.tabID != topHitTabID && ($0.url.lowercased().contains(q) || $0.title.lowercased().contains(q))
        }.prefix(3))
        let tabItems: [SuggestionItem] = matchingTabs.map {
            .openTab(tabID: $0.tabID, spaceID: $0.spaceID, url: $0.url, title: $0.title, favicon: $0.favicon)
        }

        // History search (excluding open tabs and the top hit)
        var excludedURLs = Set(matchingTabs.map { $0.url })
        if let topHitURL { excludedURLs.insert(topHitURL) }
        let historyItems: [SuggestionItem] = db.searchHistory(query: query, spaceID: spaceID, limit: 8)
            .filter { !excludedURLs.contains($0.url) }
            .map { .historyResult(url: $0.url, title: $0.title, faviconURL: $0.faviconURL) }

        var merged: [SuggestionItem] = []
        if let topHit { merged.append(topHit) }
        merged.append(.searchInput(text: query))
        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        return LocalSuggestions(items: Array(merged.prefix(Self.maxSuggestions)), inlineCompletion: inlineCompletion)
    }

    /// Network search suggestions for the query. Deduplicate against the query
    /// itself, since the .searchInput row covers it.
    func searchSuggestions(for query: String, engine: SearchEngine) async -> [String] {
        let q = query.lowercased()
        return await searchService.fetchSuggestions(for: query, engine: engine)
            .filter { $0.lowercased() != q }
    }

    static func displayURL(_ urlString: String) -> String {
        var s = urlString
        for prefix in ["https://www.", "http://www.", "https://", "http://"] {
            if s.lowercased().hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                break
            }
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    func loadFavicon(for urlString: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = faviconCache.object(forKey: urlString as NSString) {
            completion(cached)
            return
        }
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        // Coalesce concurrent loads for the same URL: queue the completion behind
        // the in-flight request instead of starting a second network fetch.
        if inFlightFavicons[urlString] != nil {
            inFlightFavicons[urlString]?.append(completion)
            return
        }
        inFlightFavicons[urlString] = [completion]
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image { self.faviconCache.setObject(image, forKey: urlString as NSString) }
                let completions = self.inFlightFavicons.removeValue(forKey: urlString) ?? []
                for completion in completions { completion(image) }
            }
        }.resume()
    }

    struct TabInfo {
        let tabID: UUID
        let spaceID: UUID
        let url: String
        let title: String
        let favicon: NSImage?
        let displayURL: String

        init(tabID: UUID, spaceID: UUID, url: String, title: String, favicon: NSImage?) {
            self.tabID = tabID
            self.spaceID = spaceID
            self.url = url
            self.title = title
            self.favicon = favicon
            self.displayURL = SuggestionProvider.displayURL(url)
        }
    }
}
