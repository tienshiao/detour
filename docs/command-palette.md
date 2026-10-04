# Command Palette

The command palette is Detour's unified interface for URL entry, tab switching, history search, and web search suggestions.

## Two Modes

The palette operates in two modes, controlled by `commandPaletteNavigatesInPlace`:

| Mode | Trigger | Behavior |
|------|---------|----------|
| **New tab** | Cmd+T | Opens a new tab with the entered URL/search |
| **Navigate in place** | Cmd+L, or clicking the faux address bar | Navigates the current tab to the entered URL/search |

Both modes use the same `CommandPaletteView` and `SuggestionProvider`. While a Peek is open, Cmd+L pre-fills the Peek's URL but commits into a new tab rather than in place.

## UI Structure

```
CommandPaletteView (full-window overlay)
  +-- GlassContainerView (frosted glass popup, 500px wide)
       +-- Search icon (magnifying glass)
       +-- CommandPaletteTextField (text input)
       +-- Separator line
       +-- NSScrollView + NSTableView (suggestion list, max 6 visible rows)
```

The palette is displayed as an overlay over the whole window. Clicking outside the glass container dismisses it and passes the click on to whatever was under it. Escape dismisses it, in stages when text has been typed (see Keyboard Navigation).

### Positioning

- **Centered** (default): vertically centered in the window assuming max suggestion height (6 rows), horizontally centered
- **Anchored**: when opened from the faux address bar, positioned at the address bar's location. Pressing Cmd+T while an anchored palette is open clears the field, re-centers it and switches it to new-tab mode (`switchToCentered`); Cmd+T while a centered palette is open dismisses it.

## Suggestion Pipeline

For a typed query the list is built from five kinds of row, in this order, capped at 12 rows in total (`SuggestionProvider.maxSuggestions`):

### 1. Top Hit (0 or 1)

The best URL the typed text autocompletes to: the first open tab whose scheme-stripped URL starts with the text (never the current tab), otherwise the history URL returned by `HistoryDatabase.bestURLCompletion`, which ranks the active space's visits by frecency (recent and typed visits weigh more). It is shown as an ordinary open-tab or history row, and its URL is offered as an inline completion in the text field with the completed part selected. There is no top hit right after a backspace or while the input starts or ends with whitespace (a multi-word search is being typed).

### 2. Typed Input (always 1)

A `.searchInput` row holding the text exactly as typed. It shows a globe icon when the text classifies as a URL (`AddressInputClassifier.directURL`) and a magnifying glass when it is a search.

### 3. Open Tabs (max 3)

Searches across all spaces' tabs (both regular and pinned) for URL or title matches against the query; an incognito window offers only its own space's tabs. Results show a "Switch to Tab" badge. Activating switches to the matching tab's space and selects it.

### 4. History Search (max 8)

`HistoryDatabase.searchHistory` uses the history database's FTS5 indexes. The query is split into alphanumeric tokens and each is matched with prefix expansion (`term*`). A URL qualifies if the active space has visited it and the query matches its address, or if the query matches a title the active space itself recorded for it (`historyTitleSearch`); the shared latest title is used only for a URL that this space visited without a title and that no other space has visited. Results are ranked by FTS relevance, then visit count. URLs already shown as open tabs or as the top hit are excluded.

### 5. Web Search Suggestions (max 4)

Fetched asynchronously from the profile's configured search engine API and appended below the local rows when they arrive, in whatever room the 12-row cap leaves. A suggestion equal to the typed text is dropped, since the typed-input row already covers it. Can be disabled per-profile via `searchSuggestionsEnabled`. The search engine is configured in the profile (Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi).

### Default Suggestions

When the palette opens with an empty query, `defaultSuggestions()` shows recent history for the active space (up to 12 entries), with open tabs promoted to show as "Switch to Tab" items.

### Threading and Debouncing

Every change to the text rebuilds the local rows immediately; nothing local is debounced. `refreshLocalSuggestions` runs in two passes:

1. **Instant, on the main thread**: the open-tab top hit, the typed-input row and the matching open tabs, from in-memory tab data only.
2. **Background**: the two history queries (`bestURLCompletion` and `searchHistory`) run on the palette's serial `historyQueryQueue`, and the full list replaces the instant one on the main thread. A generation counter drops a result whose query is no longer the current one.

Only the network search-suggestion fetch is debounced, at 150ms, and each keystroke cancels the pending fetch and the in-flight task. A response is ignored unless it is for the query the list was built for. The empty-query default list (`recentHistory`) is read synchronously on the main thread.

## Suggestion Types

```swift
enum SuggestionItem {
    case searchInput(text: String)
    case historyResult(url: String, title: String, faviconURL: String?)
    case openTab(tabID: UUID, spaceID: UUID, url: String, title: String, favicon: NSImage?)
    case searchSuggestion(text: String)
}
```

The top hit is not a type of its own: it is an `openTab` or `historyResult` placed first.

## Activation

When a suggestion is selected (Enter or click):

| Type | Action |
|------|--------|
| `searchInput` | Submit the row's own text via `didSubmitInput` (the typed text, not an inline completion the field may be showing) |
| `historyResult` | Submit the URL via `didSubmitInput` |
| `searchSuggestion` | Submit the search text via `didSubmitSearch` — always a search, never classified as a URL |
| `openTab` | Request tab switch via `didRequestSwitchToTab` delegate method |

The delegate (`BrowserWindowController`) then either navigates the current tab or creates a new one, depending on the mode.

For `didSubmitInput` — a `searchInput` or `historyResult` row, or the field's raw text when no suggestion is selected — the delegate determines whether the text is a URL (loads directly) or a search query (wraps in the search engine URL), using `AddressInputClassifier`.

## Keyboard Navigation

- **Up/Down arrows**: Move through suggestions with visual highlight; the selected row's text is placed in the field. Moving past either end clears the selection and restores the typed text
- **Enter**: Activate selected suggestion, or submit text if none selected. The first row is selected after every list rebuild, so Enter on a fresh list activates it
- **Tab**: Accept the inline completion
- **Backspace**: With an inline completion showing, remove only the completion; autocomplete is off for the next change
- **Escape**: Dismiss palette. When the palette was opened pre-filled (Cmd+L, address bar click) it dismisses at once; otherwise it is staged — drop the inline completion, then clear the text, then dismiss

## Delegate Protocol

```swift
protocol CommandPaletteDelegate: AnyObject {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String)
    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String)
    func commandPaletteDidDismiss(_ palette: CommandPaletteView)
    func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID)
}
```

`didSubmitSearch` and `didRequestSwitchToTab` have empty default implementations.

## Integration with Sidebar

The `FauxAddressBar` in the sidebar displays the current tab's hostname as a read-only label. Clicking it opens the command palette in "navigate in place" mode, anchored at the address bar's position, pre-filled with the current URL.
