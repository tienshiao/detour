import AppKit

/// Nonisolated: `localSuggestions` runs on the command palette's query queue
/// (it reads SQLite), and its only state is the `Sendable` history database.
/// The network and favicon entry points stay on the main actor.
nonisolated final class SuggestionProvider: Sendable {
    static let maxSuggestions = 12
    static let maxSearchSuggestions = 4

    private let db: HistoryDatabase

    init(db: HistoryDatabase = .shared) {
        self.db = db
    }

    func defaultSuggestions(historySpaceIDs: [String], tabs: [TabInfo]) -> [SuggestionItem] {
        let tabsByURL = Dictionary(tabs.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let history = db.recentHistory(spaceIDs: historySpaceIDs, limit: 12)
        return history.map { entry -> SuggestionItem in
            if let tab = tabsByURL[entry.url] {
                return .openTab(tabID: tab.tabID, spaceID: tab.spaceID, url: tab.url, title: tab.title, favicon: tab.favicon)
            }
            return .historyResult(url: entry.url, title: Self.displayTitle(entry),
                                  faviconURL: entry.faviconURL)
        }
    }

    /// Where each history row of `items` was last visited, for a palette
    /// suggesting across `profiles` (TASK-409): the `historyVisit.spaceID` of
    /// the URL's newest visit among them, which names the row's profile and
    /// its chip. Empty without `profiles`, or with only one.
    func historyRowSpaceIDs(for items: [SuggestionItem], profiles: PaletteHistoryProfiles?) -> [String: String] {
        guard let profiles, profiles.profiles.count > 1 else { return [:] }
        let urls = items.compactMap { item -> String? in
            if case .historyResult(let url, _, _) = item { return url }
            return nil
        }
        guard !urls.isEmpty else { return [:] }
        return db.latestVisitSpaceIDs(forURLs: urls, spaceIDs: profiles.spaceIDs)
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
    ///
    /// `localServers` are the servers running on this Mac (TASK-411). Local
    /// input (`localhost:51`) completes to an open tab first, then to a
    /// running server, then to history; `serverTopHitAllowed` is false when
    /// the field already completed to something else before the scan landed.
    /// A server another row in the list stands for (same port) gets no row
    /// of its own; history rows for local ports nothing listens on
    /// (`listeningPorts`, every port the user's processes listen on, offered
    /// or not; the servers' own when nil) go last.
    func localSuggestions(for query: String, historySpaceIDs: [String], tabs: [TabInfo],
                          allowAutocomplete: Bool, currentTabID: UUID? = nil,
                          localServers: [LocalServer] = [], listeningPorts: Set<Int>? = nil,
                          serverTopHitAllowed: Bool = true) -> LocalSuggestions {
        let q = query.lowercased()
        let hostQuery = Self.isHostQuery(q)
        let serverMatch = LocalServerRules.match(query, servers: localServers)
        let livePorts = listeningPorts ?? Set(localServers.map(\.port))
        // Rows for local ports nothing is running on now go after the others.
        let isDeadLocal = { (url: String) -> Bool in
            guard !livePorts.isEmpty, let port = LocalServerRules.loopbackPort(ofURL: url) else { return false }
            return !livePorts.contains(port)
        }
        let hosts = hostQuery
            ? Self.stablyDemoting(db.bestHostCompletions(prefix: q, spaceIDs: historySpaceIDs,
                                                         limit: Self.maxOtherHosts + 1)) { isDeadLocal($0.url) }
            : []

        // Top hit: open tabs first (the rule the palette's instant pass also
        // applies), then a running server for local input, else history — the
        // best host for a host prefix, otherwise the best URL.
        var topHit: TopHit?
        if allowAutocomplete {
            topHit = Self.tabTopHit(for: query, tabs: tabs, currentTabID: currentTabID)
            if topHit == nil, serverTopHitAllowed {
                topHit = Self.serverTopHit(for: serverMatch)
            }
            if topHit?.isLocalServer == true {
                // The server is the answer; history does not replace it.
            } else if hostQuery {
                if topHit == nil, let best = hosts.first {
                    topHit = TopHit(item: Self.hostItem(best), inlineCompletion: best.host, tabID: nil, url: best.url)
                } else if let hit = topHit, hit.tabID == nil,
                          let known = hosts.first(where: { $0.host == hit.inlineCompletion }) {
                    // The tabs named the host; history knows its root's title.
                    topHit = TopHit(item: Self.hostItem(known), inlineCompletion: hit.inlineCompletion,
                                    tabID: nil, url: known.url)
                }
            } else if topHit == nil, let match = db.bestURLCompletion(prefix: query, spaceIDs: historySpaceIDs) {
                let display = Self.displayURL(match.url)
                if display.lowercased().hasPrefix(q) {
                    topHit = TopHit(item: .historyResult(url: match.url, title: Self.displayTitle(match),
                                                         faviconURL: match.faviconURL),
                                    inlineCompletion: display, tabID: nil, url: match.url)
                }
            }
        }

        // Open tabs matching query (excluding the top hit), and tabs on the
        // servers whose folder name it matches
        let matchingTabs = Self.matchingTabs(for: query, tabs: tabs, excluding: topHit?.tabID,
                                             serverPorts: Self.folderMatchedPorts(serverMatch))

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
        let historyItems: [SuggestionItem] = Self.stablyDemoting(
            db.searchHistory(query: query, spaceIDs: historySpaceIDs, limit: 8)
                .filter { !excludedURLs.contains($0.url) }) { isDeadLocal($0.url) }
            .map { .historyResult(url: $0.url, title: Self.displayTitle($0), faviconURL: $0.faviconURL) }

        // Servers the text matches that no row above stands for
        var coveredURLs = Set(matchingTabURLs).union(otherHosts.map(\.url))
        if let topHit { coveredURLs.insert(topHit.url) }
        let serverItems = Self.serverRows(
            for: serverMatch, coveredURLs: coveredURLs,
            historyURLs: historyItems.compactMap { if case .historyResult(let url, _, _) = $0 { url } else { nil } },
            rowsBeforeHistory: (topHit == nil ? 0 : 1) + 1 + hostItems.count + tabItems.count)

        var merged: [SuggestionItem] = []
        if let topHit { merged.append(topHit.item) }
        merged.append(.searchInput(text: query))
        // Visited local hosts nothing runs on now follow the running servers.
        let deadHosts = hostItems.filter { if case .historyResult(let url, _, _) = $0 { isDeadLocal(url) } else { false } }
        merged.append(contentsOf: hostItems.filter { !deadHosts.contains($0) })
        merged.append(contentsOf: serverItems)
        merged.append(contentsOf: deadHosts)
        merged.append(contentsOf: tabItems)
        merged.append(contentsOf: historyItems)
        return LocalSuggestions(items: Array(merged.prefix(Self.maxSuggestions)),
                                inlineCompletion: topHit?.inlineCompletion)
    }

    /// History rows for a query in site-search mode (TASK-287): the profile's
    /// visits matching `query` whose host is `host` (a `SiteSearch.displayHost`)
    /// or one of its subdomains, so the site's own pages follow the search row.
    /// `excludingURL` is the search row's own URL: a past search for the same
    /// query is that row, not another one.
    func siteSearchHistory(for query: String, host: String, historySpaceIDs: [String],
                           excludingURL: String? = nil, limit: Int = 5) -> [SuggestionItem] {
        db.searchHistory(query: query, spaceIDs: historySpaceIDs, limit: 30)
            .filter {
                guard $0.url != excludingURL else { return false }
                let entryHost = Self.displayHost($0.url)
                let hostOnly = entryHost.split(separator: ":").first.map(String.init) ?? entryHost
                return hostOnly == host || hostOnly.hasSuffix("." + host)
            }
            .prefix(limit)
            .map { .historyResult(url: $0.url, title: Self.displayTitle($0), faviconURL: $0.faviconURL) }
    }

    /// The favicon URL the profile has recorded for the site on `host`
    /// (`SiteSearch.displayHost`: lowercased, no `www.`; TASK-290): its root,
    /// or the page of the host visited most recently, without and with
    /// `www.`. Nil with no scope (a Private window) or for a site the profile
    /// never visited.
    func siteFaviconURL(forHost host: String, historySpaceIDs: [String]) -> String? {
        guard !historySpaceIDs.isEmpty, !host.isEmpty else { return nil }
        for candidate in [host, "www." + host] {
            if let url = db.faviconURL(for: "https://\(candidate)/", visitedInSpaces: historySpaceIDs) { return url }
        }
        return nil
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

        var isLocalServer: Bool {
            if case .localServer = item { return true } else { return false }
        }
    }

    // MARK: - Local servers (TASK-411)

    /// The top hit a running server gives typed local input (`localhost:51`
    /// → `localhost:5173`), with no SQLite: shared by `localSuggestions` and
    /// the palette's instant pass, after `tabTopHit`. Only text that is
    /// completing a host qualifies; a bare port or a folder name never takes
    /// the row Return activates.
    static func serverTopHit(for match: LocalServerMatch) -> TopHit? {
        guard let host = match.completingHost, let server = match.servers.first else { return nil }
        let url = server.url(host: host)
        return TopHit(item: .localServer(url: url, server: server),
                      inlineCompletion: "\(host):\(server.port)", tabID: nil, url: url)
    }

    /// The ports of the servers `match` found by folder name, whose open tabs
    /// are offered whatever their title says. Typed addresses and ports find
    /// those tabs by their URL already.
    static func folderMatchedPorts(_ match: LocalServerMatch) -> Set<Int> {
        guard match.completingHost == nil else { return [] }
        return Set(match.servers.map(\.port))
    }

    /// At most this many server rows of their own.
    static let maxServerRows = 4

    /// The server rows of a list: one for each matched server that no row
    /// above the servers (`coveredURLs`) and no history row that makes the
    /// list stands for. History rows follow the servers after
    /// `rowsBeforeHistory` other rows, and a history row past
    /// `maxSuggestions` is cut, so it stands for nothing; dropping a server
    /// row moves history up, so this settles on the rows that fit.
    static func serverRows(for match: LocalServerMatch, coveredURLs: Set<String>, historyURLs: [String],
                           rowsBeforeHistory: Int) -> [SuggestionItem] {
        var rows = serverRows(for: match, coveredURLs: coveredURLs)
        while true {
            let room = max(0, maxSuggestions - rowsBeforeHistory - rows.count)
            let next = serverRows(for: match, coveredURLs: coveredURLs.union(historyURLs.prefix(room)))
            let settled = next.count == rows.count
            rows = next
            if settled { return rows }
        }
    }

    /// A row for each matched server whose port no URL in `coveredURLs`
    /// (the other rows of the list) is on.
    static func serverRows(for match: LocalServerMatch, coveredURLs: Set<String>) -> [SuggestionItem] {
        let coveredPorts = Set(coveredURLs.compactMap(LocalServerRules.loopbackPort(ofURL:)))
        let host = match.completingHost ?? "localhost"
        return match.servers
            .filter { !coveredPorts.contains($0.port) }
            .prefix(maxServerRows)
            .map { .localServer(url: $0.url(host: host), server: $0) }
    }

    /// `items` with those `isDemoted` picks moved after the rest, each part
    /// in its own order.
    static func stablyDemoting<T>(_ items: [T], _ isDemoted: (T) -> Bool) -> [T] {
        items.filter { !isDemoted($0) } + items.filter(isDemoted)
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
    /// `serverPorts` are local servers the query named by folder (TASK-411):
    /// their tabs match too.
    static func matchingTabs(for query: String, tabs: [TabInfo], excluding topHitTabID: UUID?,
                             serverPorts: Set<Int> = []) -> [TabInfo] {
        let q = query.lowercased()
        return Array(tabs.filter {
            $0.tabID != topHitTabID && ($0.url.lowercased().contains(q) || $0.title.lowercased().contains(q)
                || (!serverPorts.isEmpty
                    && LocalServerRules.loopbackPort(ofURL: $0.url).map(serverPorts.contains) == true))
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
    @MainActor
    func searchSuggestions(for query: String, engine: SearchEngine) async -> [String] {
        let q = query.lowercased()
        return await SearchSuggestionsService.shared.fetchSuggestions(for: query, engine: engine)
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

    @MainActor
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
