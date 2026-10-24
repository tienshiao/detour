import AppKit

final class SuggestionProvider {
    static let maxSuggestions = 12
    static let maxSearchSuggestions = 4

    private let db: HistoryDatabase
    private let searchService = SearchSuggestionsService.shared

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
            return .historyResult(url: entry.url, title: Self.displayTitle(entry),
                                  faviconURL: entry.faviconURL)
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
    /// shown as a rich tab/history row), the verbatim typed input, other
    /// visited hosts matching a host prefix, matching open tabs, then history.
    func localSuggestions(for query: String, spaceID: String, tabs: [TabInfo],
                          allowAutocomplete: Bool, currentTabID: UUID? = nil) -> LocalSuggestions {
        let q = query.lowercased()
        let hostQuery = Self.isHostQuery(q)
        let hosts = hostQuery
            ? db.bestHostCompletions(prefix: q, spaceID: spaceID, limit: Self.maxOtherHosts + 1)
            : []

        // Top hit: open tabs first (the rule the palette's instant pass also
        // applies), else history — the best host for a host prefix, otherwise
        // the best URL.
        var topHit: TopHit?
        if allowAutocomplete {
            topHit = Self.tabTopHit(for: query, tabs: tabs, currentTabID: currentTabID)
            if hostQuery {
                if topHit == nil, let best = hosts.first {
                    topHit = TopHit(item: Self.hostItem(best), inlineCompletion: best.host, tabID: nil, url: best.url)
                } else if let hit = topHit, hit.tabID == nil,
                          let known = hosts.first(where: { $0.host == hit.inlineCompletion }) {
                    // The tabs named the host; history knows its root's title.
                    topHit = TopHit(item: Self.hostItem(known), inlineCompletion: hit.inlineCompletion,
                                    tabID: nil, url: known.url)
                }
            } else if topHit == nil, let match = db.bestURLCompletion(prefix: query, spaceID: spaceID) {
                let display = Self.displayURL(match.url)
                if display.lowercased().hasPrefix(q) {
                    topHit = TopHit(item: .historyResult(url: match.url, title: Self.displayTitle(match),
                                                         faviconURL: match.faviconURL),
                                    inlineCompletion: display, tabID: nil, url: match.url)
                }
            }
        }

        // Open tabs matching query (excluding the top hit)
        let matchingTabs = Self.matchingTabs(for: query, tabs: tabs, excluding: topHit?.tabID)

        // Other visited hosts the prefix could mean (excluding the top hit's,
        // and any whose root is already offered as an open tab row)
        let matchingTabURLs = Set(matchingTabs.map { $0.url })
        let otherHosts = hosts
            .filter { $0.host != topHit?.inlineCompletion && !matchingTabURLs.contains($0.url) }
            .prefix(Self.maxOtherHosts)
        let hostItems = otherHosts.map(Self.hostItem)
        let tabItems: [SuggestionItem] = matchingTabs.map {
            .openTab(tabID: $0.tabID, spaceID: $0.spaceID, url: $0.url, title: $0.title, favicon: $0.favicon)
        }

        // History search (excluding open tabs, the top hit and the host rows)
        var excludedURLs = matchingTabURLs
        if let topHit { excludedURLs.insert(topHit.url) }
        excludedURLs.formUnion(otherHosts.map(\.url))
        let historyItems: [SuggestionItem] = db.searchHistory(query: query, spaceID: spaceID, limit: 8)
            .filter { !excludedURLs.contains($0.url) }
            .map { .historyResult(url: $0.url, title: Self.displayTitle($0), faviconURL: $0.faviconURL) }

        var merged: [SuggestionItem] = []
        if let topHit { merged.append(topHit.item) }
        merged.append(.searchInput(text: query))
        merged.append(contentsOf: hostItems)
        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        return LocalSuggestions(items: Array(merged.prefix(Self.maxSuggestions)),
                                inlineCompletion: topHit?.inlineCompletion)
    }

    /// Visited hosts offered as rows after the verbatim one, besides the top hit.
    static let maxOtherHosts = 2

    /// The row a query autocompletes to, and the text it completes the field to.
    struct TopHit {
        let item: SuggestionItem
        /// Scheme-stripped, prefixed by the query (case-insensitively).
        let inlineCompletion: String
        /// The open tab the row switches to; nil when it navigates.
        let tabID: UUID?
        /// The URL the row stands for, kept out of the rows below it.
        let url: String
    }

    /// The top hit open tabs alone give, with no SQLite: shared by
    /// `localSuggestions` and the palette's instant pass, so the field does
    /// not complete to one answer and then another.
    ///
    /// A query that could still be a bare host (`isHostQuery`) completes to
    /// the first matching tab's **host**, not to that tab's page (TASK-182):
    /// the row switches to a tab already at the site root, otherwise it opens
    /// the root. The current tab may name the host but is never switched to.
    /// A query with a path completes to the first other tab whose display URL
    /// it prefixes.
    static func tabTopHit(for query: String, tabs: [TabInfo], currentTabID: UUID?) -> TopHit? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        if isHostQuery(q) {
            // Web pages only: `detour://history` or `about:blank` has no site root.
            guard let named = tabs.first(where: { $0.isWebPage && $0.displayHost.hasPrefix(q) }) else { return nil }
            let host = named.displayHost
            if let atRoot = tabs.first(where: {
                $0.tabID != currentTabID && $0.isWebPage && $0.displayURL.lowercased() == host
            }) {
                return TopHit(item: .openTab(tabID: atRoot.tabID, spaceID: atRoot.spaceID, url: atRoot.url,
                                             title: atRoot.title, favicon: atRoot.favicon),
                              inlineCompletion: host, tabID: atRoot.tabID, url: atRoot.url)
            }
            let root = rootURL(host: host, like: named.url)
            return TopHit(item: .historyResult(url: root, title: host, faviconURL: nil),
                          inlineCompletion: host, tabID: nil, url: root)
        }
        guard let tab = tabs.first(where: { $0.tabID != currentTabID && $0.displayURL.lowercased().hasPrefix(q) })
        else { return nil }
        return TopHit(item: .openTab(tabID: tab.tabID, spaceID: tab.spaceID, url: tab.url, title: tab.title,
                                     favicon: tab.favicon),
                      inlineCompletion: tab.displayURL, tabID: tab.tabID, url: tab.url)
    }

    /// Up to three open tabs whose URL or title contains the query, other than
    /// the top hit's. Shared with the palette's instant pass.
    static func matchingTabs(for query: String, tabs: [TabInfo], excluding topHitTabID: UUID?) -> [TabInfo] {
        let q = query.lowercased()
        return Array(tabs.filter {
            $0.tabID != topHitTabID && ($0.url.lowercased().contains(q) || $0.title.lowercased().contains(q))
        }.prefix(3))
    }

    /// Whether the typed text could still be a bare host (`youtu`,
    /// `localhost:30`): no whitespace, and no path, query or fragment yet.
    /// Such a query completes to a host; once it has a path, to a URL.
    static func isHostQuery(_ query: String) -> Bool {
        !query.isEmpty && !query.contains { $0.isWhitespace || $0 == "/" || $0 == "?" || $0 == "#" }
    }

    private static func hostItem(_ host: HistoryDatabase.HostCompletion) -> SuggestionItem {
        .historyResult(url: host.url, title: host.title.isEmpty ? host.host : host.title,
                       faviconURL: host.faviconURL)
    }

    /// Network search suggestions for the query. Deduplicate against the query
    /// itself, since the .searchInput row covers it.
    func searchSuggestions(for query: String, engine: SearchEngine) async -> [String] {
        let q = query.lowercased()
        return await searchService.fetchSuggestions(for: query, engine: engine)
            .filter { $0.lowercased() != q }
    }

    /// What a history row is labelled with. `historyURL.title` can be empty
    /// since TASK-91 — deleting the visit a URL's latest known title came from
    /// leaves the URL with no title at all — and a blank suggestion row is
    /// unusable, so the scheme-stripped URL stands in.
    static func displayTitle(_ entry: HistoryURL) -> String {
        entry.title.isEmpty ? displayURL(entry.url) : entry.title
    }

    /// The host part of `displayURL`, lowercased: what a host prefix is
    /// matched against and completes to (`youtube.com`, `localhost:3000`).
    static func displayHost(_ urlString: String) -> String {
        let display = displayURL(urlString)
        let end = display.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? display.endIndex
        return display[..<end].lowercased()
    }

    /// The root of `host` (a `displayHost`), with the scheme and `www.` that
    /// `sample`, a page on that host, uses.
    static func rootURL(host: String, like sample: String) -> String {
        let lower = sample.lowercased()
        let scheme = lower.hasPrefix("http://") ? "http://" : "https://"
        let www = lower.dropFirst(scheme.count).hasPrefix("www.") ? "www." : ""
        return "\(scheme)\(www)\(host)/"
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
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        FaviconLoader.shared.load(from: url, completion: completion)
    }

    struct TabInfo {
        let tabID: UUID
        let spaceID: UUID
        let url: String
        let title: String
        let favicon: NSImage?
        let displayURL: String
        let displayHost: String
        /// An `http`/`https` page: one whose host can be completed to.
        let isWebPage: Bool

        init(tabID: UUID, spaceID: UUID, url: String, title: String, favicon: NSImage?) {
            self.tabID = tabID
            self.spaceID = spaceID
            self.url = url
            self.title = title
            self.favicon = favicon
            self.displayURL = SuggestionProvider.displayURL(url)
            self.displayHost = SuggestionProvider.displayHost(url)
            let lower = url.lowercased()
            self.isWebPage = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        }
    }
}
