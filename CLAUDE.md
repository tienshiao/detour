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

macOS native browser (Swift 5.10, macOS 14+) using WebKit. Organized around **Profiles** (which own cookies, history, and extensions via `WKWebsiteDataStore`) and **Spaces** (workspaces that group tabs). Each Space references a Profile; multiple Spaces can share the same Profile and thus share cookies.

### Key Architectural Decisions

**State management**: `TabStore` singleton owns all spaces and tabs. Controllers observe changes via `TabStoreObserver` protocol (not Combine). `BrowserTab` exposes `@Published` properties for per-tab reactive updates consumed by `BrowserWindowController`.

**WebView ownership**: Only one window at a time "owns" a tab's WKWebView. Other windows showing the same tab display a snapshot (NSImageView). Ownership transfers on window focus via `webViewOwnershipChanged` notification. This is critical — never assume a tab's webView is attached.

**Two databases**: Session state (`Database.swift` — spaces, tabs, closed tabs) is separate from browsing history (`HistoryDatabase.swift` — URLs, visits with FTS5 search). Both use GRDB with SQLite.

**Per-window space state**: Each `BrowserWindowController` tracks its own `activeSpaceID`. Spaces are global in `TabStore` but the active space is per-window.

**Incognito**: Assigns the Space to a special incognito `Profile`, whose `dataStore` is `.nonPersistent()`. No history recording. Space removed on window close.

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
  ├── Profile[] (each owns a WKWebsiteDataStore)         [Browser/Profile.swift]
  ├── Space[] (each references a Profile for its data store)
  ├── TabStoreObserver[] (weak references)
  ├── Database.shared (session persistence)             [Storage/Database.swift]
  └── HistoryDatabase.shared (visit recording)          [Storage/HistoryDatabase.swift]
```

### Delegate Flow

Sidebar actions flow through `TabSidebarDelegate` → `BrowserWindowController` → `TabStore`. The command palette uses `CommandPaletteDelegate`. The palette has two modes: "new tab" (Cmd+T) and "navigate in place" (Cmd+L or clicking the faux address bar), controlled by `commandPaletteNavigatesInPlace`.

### Sidebar Row Layout

Sidebar table rows are: top spacer (row 0), flattened pinned items (entries + folders), separator, "New Tab" cell, then normal-tab **items**. An item is a lone tab or a split group (two adjacent tabs in `space.tabs` sharing a `splitGroupID`, rendered as one row) — `SidebarRow.normalTab(index:)` is an item index, never a tab index. Never do row math inline — conversions between table rows, item indices, and tab indices go through the pure functions in `Sidebar/SidebarLayout.swift` (`sidebarRow(for:)`, `rowForNormalTab`, `rowForPinnedItem`) and `Sidebar/TabListItems.swift` (`tabListItems(from:)`, `itemIndex(forTabIndex:)`, `tabGapIndex(forItemGap:)`), unit-tested in `SidebarLayoutTests` / `SplitTabTests`.

### Split Tabs

A split is two adjacent normal tabs sharing `splitGroupID` (one split per tab, 2 panes max — product decision). TabStore enforces member contiguity in every mutation: insertion indices snap out of group interiors (`snappedToSplitGroupBoundary`), `moveTab` moves the whole block, `closeTab`/`pinTab`/`detachTab` dissolve undersized groups. **Splits survive pinning** (design doc §12): a pinned split is two sibling `PinnedEntry`s (same `folderID`, consecutive sort order) sharing `entry.splitGroupID` — while pinned the group lives ONLY on the entries (backing tabs' `splitGroupID` stays nil). `splitGroup(containing:)`/`splitFraction(containing:)` resolve groups in both sections; pinned mutations keep pairs adjacent (`movePinnedTabToFolder` moves grouped pairs as a block, anchors snap via `snappedPinnedAnchor`) and `sanitizePinnedSplitGroups` defends at load. In the window, a selected split hosts both pane containers in an `NSSplitView` (frame-based — Auto Layout breaks the docked Web Inspector); `selectedTabID` always identifies the *focused pane*, never the group, and pane focus follows `becomeFirstResponder`. Structural changes that bypass `selectTab` converge via `refreshSplitHostingIfNeeded()`. Design + phasing: `docs/split-tabs-design.md`.

### Sidebar Drag & Drop

Drag pasteboards carry ID-based payloads (`SidebarDragPayload` / `FavoriteDragPayload` in `Sidebar/SidebarDragDrop.swift`), never row numbers or array indices — rows can shift mid-drag, and payloads from another window's sidebar are rejected via `sidebarID`. Drop handling resolves the source by ID at drop time, then runs through the pure functions `validateSidebarDrop` / `sidebarDropDestination` / `resolveSidebarDrop` (tested in `SidebarDragDropTests`). Any drop that issues more than one store mutation must wrap them in `TabSidebarViewController.performDropTransaction` so the table animates once. When adding new drop targets (e.g. split tabs), extend the resolver enums + tests rather than branching in the view controller.

### Reminders
* When adding/updating Web Extension APIS, make sure to add/update corresponding tests and update the API Explorer extension to cover the new APIs.
* When adding/updating extension permissions, make sure to add/update the corresponding tests with both positive and negative cases.
* When implementing polyfills, prefer `let`/`const` over `var`.

## Model delegation when running as Fable

If the task's complexity does not require Fable to solve, do the planning/analysis with Fable, then delegate the execution/implementation to a subagent running Opus (pass `model: "opus"` on the Agent call). Reserve Fable itself for the genuinely hard parts (e.g. WKWebView ownership-transfer and snapshot semantics across windows, extension permission security reviews, tab-index offset math and other invariant-heavy state logic in TabStore).