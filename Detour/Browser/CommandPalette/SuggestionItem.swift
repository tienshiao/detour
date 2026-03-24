import AppKit

enum SuggestionItem {
    case searchInput(text: String)
    case historyResult(url: String, title: String, faviconURL: String?)
    case openTab(tabID: UUID, spaceID: UUID, url: String, title: String, favicon: NSImage?)
    case searchSuggestion(text: String)
}
