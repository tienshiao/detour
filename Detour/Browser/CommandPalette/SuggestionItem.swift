import AppKit

nonisolated enum SuggestionItem: Equatable, Sendable {
    case searchInput(text: String)
    case historyResult(url: String, title: String, faviconURL: String?)
    case openTab(tabID: UUID, spaceID: UUID, url: String, title: String, favicon: NSImage?)
    case searchSuggestion(text: String)
    /// In site-search mode (TASK-287): search `name` for `query`, at `url`.
    case siteSearch(name: String, query: String, url: String)
    /// Tab would enter a site search (`siteSearchForTab`: its keyword, host or
    /// name): activating the row switches the palette to searching that site.
    /// `fieldText` is what the field shows while the row is selected.
    case siteSearchHint(id: UUID, name: String, fieldText: String)
}
