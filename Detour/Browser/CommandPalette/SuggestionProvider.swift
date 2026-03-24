import AppKit

final class SuggestionProvider {
    private let faviconCache = NSCache<NSString, NSImage>()
    private let db = HistoryDatabase.shared
    private let searchService = SearchSuggestionsService.shared

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

    func suggestions(for query: String, spaceID: String, tabs: [SuggestionProvider.TabInfo],
                     searchEngine: SearchEngine = .google, searchSuggestionsEnabled: Bool = true) async -> [SuggestionItem] {
        let q = query.lowercased()

        async let searchSuggestions = searchSuggestionsEnabled
            ? searchService.fetchSuggestions(for: query, engine: searchEngine)
            : [String]()

        // Open tabs matching query
        let matchingTabs = tabs.filter {
            $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
        let tabItems: [SuggestionItem] = Array(matchingTabs.prefix(3)).map {
            .openTab(tabID: $0.tabID, spaceID: $0.spaceID, url: $0.url, title: $0.title, favicon: $0.favicon)
        }
        let tabURLs = Set(matchingTabs.prefix(3).map { $0.url })

        // History search
        let historyResults = db.searchHistory(query: query, spaceID: spaceID, limit: 8)
        let historyItems: [SuggestionItem] = historyResults
            .filter { !tabURLs.contains($0.url) }
            .map { .historyResult(url: $0.url, title: $0.title, faviconURL: $0.faviconURL) }

        // Search suggestions (deduplicate against the query itself, since .searchInput covers it)
        let searchResults = await searchSuggestions
        let searchItems: [SuggestionItem] = searchResults
            .filter { $0.lowercased() != q }
            .prefix(4).map { .searchSuggestion(text: $0) }

        var merged: [SuggestionItem] = [.searchInput(text: query)]
        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        merged.append(contentsOf: searchItems)
        return Array(merged.prefix(12))
    }

    /// Returns the best autocomplete URL (scheme-stripped) for a typed prefix, or nil.
    func bestAutocomplete(for prefix: String, spaceID: String, tabs: [TabInfo]) -> String? {
        let lower = prefix.lowercased()

        // Check open tabs first (displayURL is precomputed)
        for tab in tabs {
            if tab.displayURL.lowercased().hasPrefix(lower) {
                return tab.displayURL
            }
        }

        // Fall back to history
        if let match = db.bestURLCompletion(prefix: prefix, spaceID: spaceID) {
            let display = Self.displayURL(match.url)
            if display.lowercased().hasPrefix(lower) {
                return display
            }
        }

        return nil
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
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.faviconCache.setObject(image, forKey: urlString as NSString)
            DispatchQueue.main.async { completion(image) }
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
