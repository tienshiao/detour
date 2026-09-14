# Architecture Overview

Detour is a macOS-native browser built with Swift and WebKit. It targets macOS 14+ and is organized around **Spaces** (workspaces with isolated cookie stores) containing **Tabs**.

## Core Concepts

### Spaces

A Space is a workspace container. Each Space has a name, emoji, color, and is linked to a **Profile** that determines its cookie store, user agent, search engine, and content blocking settings. Multiple Spaces can share the same Profile.

Spaces are global objects owned by `TabStore`, but the *active* space is per-window -- each `BrowserWindowController` tracks its own `activeSpaceID`. This means multiple windows can view different spaces simultaneously.

### Tabs

A `BrowserTab` wraps a `WKWebView` and exposes reactive state via `@Published` properties (title, URL, loading state, favicon, audio playback, etc.). Tabs can be in one of three states:

- **Active** -- has a live `WKWebView`, fully interactive
- **Sleeping** -- `WKWebView` has been torn down to save memory, interaction state serialized for later restoration
- **Closed/Archived** -- removed from the space, stored as a `ClosedTabRecord` in the database for reopening

### Profiles

A Profile holds per-space settings: user agent mode, search engine, archive/sleep thresholds, content blocker toggles, and cookie store isolation. Each Profile gets its own `WKWebsiteDataStore`, providing full cookie isolation between profiles.

A special built-in incognito profile (fixed UUID `00000000-0000-0000-0000-000000000001`) uses a non-persistent data store. Incognito spaces are never persisted to the session database.

### Pinned Tabs

Tabs can be pinned within a space. Pinned tabs have a `pinnedURL` (their "home") and a `pinnedTitle`. When a user closes a pinned tab that has navigated away from home, it resets to the pinned URL instead of being removed. Pinned tabs can be organized into hierarchical **PinnedFolders**.

## Singletons

| Singleton | File | Purpose |
|-----------|------|---------|
| `TabStore.shared` | `Browser/TabStore.swift` | Owns all spaces, tabs, profiles. Central state manager. |
| `AppDatabase.shared` | `Storage/Database.swift` | Session SQLite database (spaces, tabs, settings). |
| `HistoryDatabase.shared` | `Storage/HistoryDatabase.swift` | Browsing history SQLite database with FTS5. |
| `ContentBlockerManager.shared` | `Browser/ContentBlocker/ContentBlockerManager.swift` | Ad/tracker filter list management. |
| `DownloadManager.shared` | `Browser/Downloads/DownloadManager.swift` | File download tracking. |
| `SettingsWindowController.shared` | `Browser/Settings/SettingsWindowController.swift` | Settings window. |

## Communication Patterns

### TabStoreObserver (Protocol)

The primary communication mechanism. `BrowserWindowController` implements this protocol to receive notifications about tab insertions, removals, reorders, updates, pin/unpin operations, and folder changes. Observers are stored as weak references to prevent retain cycles.

All observer methods have default empty implementations, so conformers only need to implement what they care about.

### Delegate Protocols

- **`TabSidebarDelegate`** -- sidebar user actions (tab selection, close, navigation, space switching, pin operations) flow up from `TabSidebarViewController` to `BrowserWindowController`
- **`CommandPaletteDelegate`** -- URL submissions and tab-switch requests from the command palette
- **`DownloadManagerObserver`** -- download add/update/remove notifications

### Per-Tab Combine Subscriptions

`TabStore` subscribes to each tab's `@Published` properties via Combine. When a tab's URL, title, favicon, or loading state changes, the store:
1. Notifies all `TabStoreObserver`s with the updated tab
2. Records history visits (on load completion, for non-incognito spaces)
3. Schedules a debounced save

### NotificationCenter

Used sparingly for cross-cutting concerns:

| Notification | Purpose |
|--------------|---------|
| `webViewOwnershipChanged` | Triggers WebView transfer when window focus changes |
| `contentBlockerRulesDidChange` | Signals all windows to reapply content blocking rules |
| `contentBlockerStatusDidChange` | Updates settings UI with current rule compilation status |
| `UserAgentDidChange` | Reapplies user agent string to all tabs in affected profile |

## App Initialization Flow

```
applicationDidFinishLaunching
  |
  +-- Initialize AppDatabase.shared, HistoryDatabase.shared
  +-- Expire old history visits (> 90 days)
  +-- Create BrowserWindowController
  +-- ContentBlockerManager.shared.initialize()  (fetch/compile filter lists)
  +-- TabStore.shared.restoreSession()
  |     +-- Load profiles from DB
  |     +-- Reconstruct spaces with tabs (selected tab gets live WebView, others sleep)
  |     +-- Load pinned folders and pinned tabs
  |     +-- Load closed tab stack
  +-- TabStore.shared.ensureDefaultSpace()  (create "Home" space if empty)
  +-- TabStore.shared.startArchiveTimer()   (5-min periodic tick)
  +-- Set active space and select tab in window
  +-- Show window
```

## Directory Layout

```
Detour/
+-- App/                          AppDelegate, main entry point
+-- Browser/
|   +-- BrowserTab.swift          Tab model with WebView lifecycle
|   +-- TabStore.swift            State singleton + Space class
|   +-- Profile.swift             Profile settings + enums
|   +-- PinnedFolder.swift        Folder model for pinned tab hierarchy
|   +-- TabInsertion.swift        Child tab grouping logic
|   +-- Window/                   BrowserWindowController (+ extensions), BrowserWebView,
|   |                             FindBarView, ErrorSchemeHandler
|   +-- Sidebar/                  TabSidebarViewController, TabCellView, FauxAddressBar,
|   |                             AddSpaceViewController, AddProfileViewController, layout
|   +-- CommandPalette/           CommandPaletteView, SuggestionProvider, SuggestionItem,
|   |                             SearchSuggestionsService
|   +-- Downloads/                DownloadManager, DownloadItem, DownloadPopoverViewController
|   +-- Settings/                 SettingsWindowController, ProfilesSettingsViewController,
|   |                             ContentBlockerSettingsViewController
|   +-- ContentBlocker/           ContentBlockerManager, ContentRuleStore, EasyListParser,
|   |                             ContentBlockerWhitelist
|   +-- Shared/                   HoverButton, WindowDragView, ToastView, LinkStatusBar,
|                                 PeekOverlayView, GlassContainerView, NSColor+Hex
+-- Storage/
|   +-- Database.swift            Session DB (GRDB, 14 migrations)
|   +-- HistoryDatabase.swift     History DB (GRDB, FTS5)
|   +-- Models/                   GRDB record types
+-- Resources/                    Assets, entitlements
```

## Component Relationships

```
BrowserWindowController (one per window)
  +-- TabSidebarViewController         User actions via TabSidebarDelegate
  |     +-- FauxAddressBar             Click opens CommandPalette
  +-- CommandPaletteView               URL input via CommandPaletteDelegate
  |     +-- SuggestionProvider         Merges: open tabs + history FTS + web search
  +-- FindBarView                      Cmd+F find-in-page
  +-- LinkStatusBar                    Shows hovered link URL
  +-- WKWebView / NSImageView          Owned tab's webview or snapshot fallback
  +-- PeekOverlayView                  Link preview overlay

TabStore.shared
  +-- Space[]                          Each with tabs[], pinnedTabs[], pinnedFolders[]
  +-- Profile[]                        Settings + WKWebsiteDataStore
  +-- closedTabStack[]                 Reopenable closed tabs
  +-- TabStoreObserver[] (weak)        Window controllers
  +-- AppDatabase.shared               Session persistence
  +-- HistoryDatabase.shared           Visit recording
```

## Key Design Decisions

1. **Observer protocol over Combine for store notifications** -- `TabStoreObserver` provides fine-grained callbacks (insert at index, remove at index) that map directly to table view animations, which Combine's stream-based model doesn't express cleanly.

2. **Combine for per-tab properties** -- Individual tab state (`@Published`) uses Combine because it maps naturally to KVO on WKWebView properties and provides automatic cleanup via `AnyCancellable`.

3. **Two separate databases** -- Session state and browsing history are deliberately separated. History is never written for incognito spaces. This also makes it straightforward to clear history without affecting session state.

4. **Profiles own data stores, not spaces** -- Multiple spaces can share a profile (and thus cookies). Changing a space's profile is a simple reassignment.

5. **Debounced persistence** -- All mutations schedule a 1-second debounced save via `DispatchWorkItem`, preventing excessive writes during rapid operations like bulk tab closes or drag reordering.
