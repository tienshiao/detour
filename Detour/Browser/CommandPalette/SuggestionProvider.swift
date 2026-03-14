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

    func suggestions(for query: String, spaceID: String, tabs: [SuggestionProvider.TabInfo]) async -> [SuggestionItem] {
        let q = query.lowercased()

        async let searchSuggestions = searchService.fetchSuggestions(for: query)

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

        // Search suggestions
        let searchResults = await searchSuggestions
        let searchItems: [SuggestionItem] = searchResults.prefix(4).map { .searchSuggestion(text: $0) }

        var merged: [SuggestionItem] = []
        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        merged.append(contentsOf: searchItems)
        return Array(merged.prefix(12))
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
    }
}
