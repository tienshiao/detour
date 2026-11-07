import Foundation

/// A site search (TASK-287): typing `keyword` then Tab or Space in the
/// command palette switches it to searching `name`, and Return opens
/// `urlTemplate` with the query in place of `%s`. App-wide, like Link Routes:
/// one list for every profile, kept by `SiteSearchStore`.
nonisolated struct SiteSearch: Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var keyword: String
    var urlTemplate: String
    /// The entry's place in the list; set by the store.
    var sortOrder: Int = 0

    /// What a template's query goes in place of (Chrome's and Safari's).
    static let placeholder = "%s"

    /// The results URL for `query`, or nil when the template does not make a URL.
    func url(for query: String) -> URL? {
        Self.url(template: urlTemplate, query: query)
    }

    /// `template` with every `%s` replaced by `query`, percent-encoded so that
    /// only RFC 3986's unreserved characters stay as typed. That is safe in a
    /// path (`/wiki/%s`) as well as in a query (`?q=%s`): `&`, `=`, `+`, `/`,
    /// `?` and `#` in the query can never end a parameter or the path, and a
    /// space becomes `%20`, which every site reads as a space.
    static func url(template: String, query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: placeholder, with: encoded))
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The site's host as the palette's history rows name hosts
    /// (`SuggestionProvider.displayHost`: lowercased, no `www.`), or nil for a
    /// template that does not make a URL. History rows in site-search mode are
    /// the visits to this host.
    var displayHost: String? {
        guard let url = Self.url(template: urlTemplate, query: "x"), let host = url.host, !host.isEmpty
        else { return nil }
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    /// Whether `text` is this entry's keyword: the whole of it, ignoring case.
    func matches(keyword text: String) -> Bool {
        !text.isEmpty && text.caseInsensitiveCompare(keyword) == .orderedSame
    }

    /// The fields as they are saved: name, keyword and template trimmed.
    var normalized: SiteSearch {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.urlTemplate = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// The entries a new database starts with (migration v21). Seeded once:
    /// one the user deletes stays deleted.
    static let starterSet: [SiteSearch] = [
        SiteSearch(name: "YouTube", keyword: "yt", urlTemplate: "https://www.youtube.com/results?search_query=%s"),
        SiteSearch(name: "Wikipedia", keyword: "w", urlTemplate: "https://en.wikipedia.org/wiki/Special:Search?search=%s"),
        SiteSearch(name: "GitHub", keyword: "gh", urlTemplate: "https://github.com/search?q=%s"),
        // maps.google.com, not www.google.com/maps: host matching would
        // otherwise send Tab on a completed google.com to Maps.
        SiteSearch(name: "Google Maps", keyword: "maps", urlTemplate: "https://maps.google.com/?q=%s"),
        SiteSearch(name: "Amazon", keyword: "amz", urlTemplate: "https://www.amazon.com/s?k=%s"),
        SiteSearch(name: "Reddit", keyword: "r", urlTemplate: "https://www.reddit.com/search/?q=%s"),
    ]
}

/// What keeps a site search from being saved.
nonisolated enum SiteSearchProblem: Equatable, Sendable {
    case emptyName
    /// A keyword is one word: the palette enters the mode on the space after it.
    case keywordHasWhitespace
    /// Another entry has the same keyword (ignoring case).
    case duplicateKeyword
    /// The template does not make an `http` or `https` URL with a host.
    case invalidURL
    /// The template has no `%s`, so the query would go nowhere.
    case missingPlaceholder

    /// The sentence the Settings sheet shows.
    var message: String {
        switch self {
        case .emptyName: return "Enter a name."
        case .keywordHasWhitespace: return "The keyword can't contain spaces."
        case .duplicateKeyword: return "Another site search uses this keyword."
        case .invalidURL: return "Enter a web address starting with https:// or http://."
        case .missingPlaceholder: return "Put %s in the address where the search terms go."
        }
    }
}

/// Everything wrong with `entry` (normalized first), given the other entries
/// in the list; `others` may include `entry` itself, which is skipped by id.
/// Empty when it can be saved.
nonisolated func siteSearchProblems(_ entry: SiteSearch, among others: [SiteSearch]) -> [SiteSearchProblem] {
    let entry = entry.normalized
    var problems: [SiteSearchProblem] = []
    if entry.name.isEmpty { problems.append(.emptyName) }
    // The keyword is optional: an entry without one is reached through its
    // host or name (`siteSearchForTab`).
    if entry.keyword.contains(where: \.isWhitespace) {
        problems.append(.keywordHasWhitespace)
    } else if others.contains(where: { $0.id != entry.id && $0.matches(keyword: entry.keyword) }) {
        problems.append(.duplicateKeyword)
    }
    let sample = SiteSearch.url(template: entry.urlTemplate, query: "x")
    let scheme = sample?.scheme?.lowercased()
    if sample == nil || !(scheme == "https" || scheme == "http") || (sample?.host ?? "").isEmpty {
        problems.append(.invalidURL)
    }
    if !entry.urlTemplate.contains(SiteSearch.placeholder) { problems.append(.missingPlaceholder) }
    return problems
}

/// The site search Tab enters (TASK-287), Arc's way as well as Chrome's.
/// `typed` is what the user typed (trimmed); `completedText` is the whole
/// field while an inline completion is pending, nil when none is.
///
/// 1. `typed` is an entry's keyword.
/// 2. Else the field (the completed text, or the typed text) is just an
///    entry's host: `you` completing to `youtube.com` searches YouTube, but
///    `github.com/t` completing to `github.com/tma/repo` accepts the
///    completion.
/// 3. Else, with no completion pending, `typed` (two characters or more)
///    starts an entry's name or host: `wiki` searches Wikipedia on a Mac
///    that has never visited it.
///
/// A pending completion to a host that no entry has gives nil, so Tab goes
/// on accepting the completion. Text with whitespace is a search being
/// typed, never a site.
nonisolated func siteSearchForTab(typed: String, completedText: String?, entries: [SiteSearch]) -> SiteSearch? {
    guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
    if let entry = entries.first(where: { $0.matches(keyword: typed) }) { return entry }

    // Only a bare host: `github.com/tma/repo` (typed, or a completion Tab
    // would accept) is a page on the site, not the site.
    let field = completedText ?? typed
    let fieldHost = SuggestionProvider.displayHost(field)
    if !fieldHost.isEmpty, SuggestionProvider.displayURL(field).lowercased() == fieldHost,
       let entry = entries.first(where: { $0.displayHost == fieldHost }) { return entry }
    guard completedText == nil, typed.count >= 2 else { return nil }

    let prefix = typed.lowercased()
    return entries.first {
        $0.name.lowercased().hasPrefix(prefix) || ($0.displayHost?.hasPrefix(prefix) ?? false)
    }
}
