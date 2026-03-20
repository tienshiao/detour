# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Regenerate Xcode project (required after adding/removing files)
xcodegen generate

# Build
xcodebuild -scheme Detour -configuration Debug build

# Run tests
xcodebuild -scheme DetourTests -configuration Debug test

# Run a single test
xcodebuild -scheme DetourTests -configuration Debug test -only-testing:DetourTests/SuggestionProviderTests/testExample
```

## Architecture

macOS native browser (Swift 5.10, macOS 14+) using WebKit. Organized around **Spaces** (workspaces with isolated cookie stores) containing **Tabs**.

### Key Architectural Decisions

**State management**: `TabStore` singleton owns all spaces and tabs. Controllers observe changes via `TabStoreObserver` protocol (not Combine). `BrowserTab` exposes `@Published` properties for per-tab reactive updates consumed by `BrowserWindowController`.

**WebView ownership**: Only one window at a time "owns" a tab's WKWebView. Other windows showing the same tab display a snapshot (NSImageView). Ownership transfers on window focus via `webViewOwnershipChanged` notification. This is critical — never assume a tab's webView is attached.

**Two databases**: Session state (`Database.swift` — spaces, tabs, closed tabs) is separate from browsing history (`HistoryDatabase.swift` — URLs, visits with FTS5 search). Both use GRDB with SQLite.

**Per-window space state**: Each `BrowserWindowController` tracks its own `activeSpaceID`. Spaces are global in `TabStore` but the active space is per-window.

**Incognito**: Creates an isolated `Space` with a non-persistent `WKWebsiteDataStore`. No history recording. Space removed on window close.

### Directory Layout

```
Detour/
├── App/                          AppDelegate, main
├── Browser/
│   ├── BrowserTab.swift          core tab model
│   ├── TabStore.swift            core state singleton
│   ├── Window/                   BrowserWindowController, BrowserWebView, FindBarView, ErrorSchemeHandler
│   ├── Sidebar/                  TabSidebarViewController, TabCellView, FauxAddressBar, AddSpaceViewController
│   ├── CommandPalette/           CommandPaletteView, SuggestionProvider, SuggestionItem, SearchSuggestionsService
│   ├── Downloads/                DownloadManager, DownloadPopoverViewController, DownloadCellView, DownloadAnimation
│   ├── Settings/                 SettingsWindowController
│   └── Shared/                   HoverButton, WindowDragView, ToastView, LinkStatusBar, PeekOverlayView, NSColor+Hex
├── Storage/
│   ├── Database.swift            session DB singleton
│   ├── HistoryDatabase.swift     history DB singleton
│   └── Models/                   GRDB record types (SpaceRecord, TabRecord, etc.)
└── Resources/                    assets, entitlements
```

### Component Relationships

```
BrowserWindowController (per window)                    [Browser/Window/]
  ├── TabSidebarViewController (sidebar: spaces, tabs)  [Browser/Sidebar/]
  │     └── FauxAddressBar (read-only hostname display, opens CommandPalette on click)
  ├── CommandPaletteView (URL input + suggestions)      [Browser/CommandPalette/]
  │     └── SuggestionProvider (merges: open tabs + history FTS + web search)
  ├── FindBarView (Cmd+F find-in-page)                  [Browser/Window/]
  └── WKWebView (owned tab) or NSImageView (snapshot)

TabStore.shared (singleton)                             [Browser/TabStore.swift]
  ├── Space[] (each with tabs[], WKWebsiteDataStore)
  ├── TabStoreObserver[] (weak references)
  ├── Database.shared (session persistence)             [Storage/Database.swift]
  └── HistoryDatabase.shared (visit recording)          [Storage/HistoryDatabase.swift]
```

### Delegate Flow

Sidebar actions flow through `TabSidebarDelegate` → `BrowserWindowController` → `TabStore`. The command palette uses `CommandPaletteDelegate`. The palette has two modes: "new tab" (Cmd+T) and "navigate in place" (Cmd+L or clicking the faux address bar), controlled by `commandPaletteNavigatesInPlace`.

### Tab List Offset

The table view's row 0 is always the "New Tab" cell. Actual tabs start at row 1. All index conversions between table rows and tab array indices account for this +1 offset.

### Reminders
* When adding/updating Web Extension APIS, make sure to add/update corresponding tests and update the API Explorer extension to cover the new APIs.
* When adding/updating extension permissions, make sure to add/update the corresponding tests with both positive and negative cases.