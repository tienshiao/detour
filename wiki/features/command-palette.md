---
type: Feature
title: Command palette
description: "The overlay used for URL entry, tab switching, history and web search: its two modes, how it is opened and dismissed, inline completion, keyboard handling, and how focus returns to the page."
tags: [command-palette, navigation, keyboard, focus, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T08:06:00Z }
sources:
  - id: palette-view
    resource: ../../Detour/Browser/CommandPalette/CommandPaletteView.swift
    title: CommandPaletteView.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (newTab, focusAddressBar, showCommandPalette, dismissCommandPalette, restoreWebContentFocus, CommandPaletteDelegate)
  - id: sidebar-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift (faux address bar entry)
  - id: classifier
    resource: ../../Detour/Browser/CommandPalette/AddressInputClassifier.swift
    title: AddressInputClassifier.swift
  - id: doc
    resource: ../../docs/command-palette.md
    title: docs/command-palette.md
  - id: task-78
    resource: backlog:TASK-78
    title: After Cmd+L and Return the page does not regain keyboard focus
  - id: task-83
    resource: backlog:TASK-83
    title: Treat host:port and localhost input as a URL
  - id: focus-tests
    resource: ../../DetourTests/CommandPaletteFocusTests.swift
    title: CommandPaletteFocusTests.swift
---

# What it does

One overlay, `CommandPaletteView`, replaces the address bar: it takes a URL or
a search, switches to an open tab, and suggests history and web searches. The
sidebar's `FauxAddressBar` only *displays* the current host and opens the
palette when clicked. What fills the list is on
[suggestion pipeline](./suggestion-pipeline.md); this page covers the view and
its window integration.

# How it works

## Two modes, three entry points

The mode is `BrowserWindowController.commandPaletteNavigatesInPlace`, read
once when the user submits.

| Entry point | Action | Mode | Prefilled | Position |
|---|---|---|---|---|
| File > New Tab (Cmd+T) | `newTab(_:)` | new tab | no | centred |
| File > Open Location… (Cmd+L) | `focusAddressBar(_:)` | in place, **unless a Peek is open** | the display tab's URL, selected | centred |
| Click on the faux address bar | `tabSidebarDidRequestOpenCommandPalette(_:anchorFrame:)` | in place when `displayTab === selectedTab` | same | anchored at the address bar |

With a [Peek](../tabs/peek.md) open, Cmd+L shows the Peek's URL but submits
into a new tab, like Cmd+T.

Cmd+T while a palette is already showing: an anchored palette switches to the
centred new-tab mode (`switchToCentered`, which clears the field), a centred
one is dismissed.

A palette is created per showing (`showCommandPalette` builds a new
`CommandPaletteView`) and given `tabStore`, `activeSpaceID`, `currentTabID`
and `profile` at that moment. Two scrims go up with it: one behind the sidebar
on the split view (the glass sidebar is partly transparent) and one above the
content.

## View structure

```
CommandPaletteView            full-window overlay, catches clicks outside
  GlassContainerView          500 pt wide
    search icon + CommandPaletteTextField
    separator
    NSScrollView > NSTableView   rows 36 pt, at most 6 visible
```

The centred position is computed against the palette's *maximum* height, so
the box does not move as the list grows and shrinks.

## Submitting

| What was activated | Delegate call | Result |
|---|---|---|
| The field's text (Return with no row selected) | `didSubmitInput` | `AddressInputClassifier.directURL` decides URL vs search |
| `.searchInput` row (the verbatim typed text) | `didSubmitInput` with the **row's** text | same; the field may hold an inline completion the row does not mean |
| `.historyResult` row | `didSubmitInput` with the URL | navigates |
| `.searchSuggestion` row | `didSubmitSearch` | always a search, never classified |
| `.openTab` row | `didRequestSwitchToTab(tabID, in: spaceID)` | switches space if needed, selects the tab |

`paletteLoadURL` records the visit as **typed** only when the input was
classified as a direct URL; a search-engine URL is not typed. Typed visits
weigh double in inline-completion ranking and bypass the 30 s history dedup
(see [history recording and search](./history-recording-and-search.md)).

Typed `detour://history` is routed to `loadInternalPage`, because plain
`load(_:)` refuses the internal scheme; see
[internal pages](./internal-pages.md).

## Keyboard

Handled in `control(_:textView:doCommandBy:)`:

| Key | Behaviour |
|---|---|
| Up / Down | moves the keyboard selection and puts the row's text in the field, fully selected. Moving past either end clears the selection and restores what the user typed |
| Return | activates the selected row; with none, submits the field |
| Tab | accepts the inline completion (the suffix becomes typed text) |
| Backspace | with a completion showing, removes only the completion and suppresses autocomplete for the next change |
| Escape | prefilled palette (Cmd+L, address bar click): dismiss at once. Otherwise staged: drop the completion, then clear the text, then dismiss |

After every list rebuild the first row is keyboard-selected, so Return on a
fresh list activates row 0: the top hit when there is one, otherwise the
verbatim input.

## Inline completion

`applyInlineCompletion` appends the completion's suffix to the field and
selects it, so typing replaces it; it then scrolls back so the typed prefix
stays visible. `userTypedText` always holds what the user actually typed,
separate from the field's contents. Autocomplete is off for one change after a
backspace and whenever the text has trailing whitespace (a multi-word search
is being typed). `setTextFieldQuietly` sets the field without re-entering
`controlTextDidChange`.

## Dismissal and focus

`dismissCommandPalette(restoringFocus:)` removes the view and scrims, resets
the mode, and calls `restoreWebContentFocus()`. Before TASK-78 only the Peek
case restored first responder; after Cmd+L and Return the window kept it and
the page received no keys until clicked.[^task-78]

`restoreWebContentFocus()` makes first responder the presented Peek's web
view, else the selected tab's (in a split, the focused pane, which is what
`selectedTabID` names), and only when that web view is hosted in this window
rather than shown as a snapshot.

It has to run **twice** on the commit paths:

1. in `dismissCommandPalette`, which covers Escape, click-outside and an
   in-place commit;
2. again after `selectTab` / the load (`paletteLoadURL` uses `defer`), because
   a new tab's web view only joins the window in `selectTab`, and an in-place
   load may first reclaim the web view.

`selectTab` itself dismisses with `restoringFocus: false` and focuses the
*incoming* tab at its end. Otherwise focus could land on an outgoing tab that
stays parented for Picture in Picture.[^task-78]

A click outside the glass container dismisses and then re-sends the event to
the window (`targetWindow?.sendEvent(event)`), so the click also lands on
whatever was under it.

# Edge cases

- **Incognito**: a Private window's palette lists only its own space's open
  tabs; a normal window's palette lists the tabs of every non-incognito space
  (pinned entries included) and never a Private window's. The rule is
  `PaletteTabScope`, see [suggestion pipeline](./suggestion-pipeline.md).
- **`currentTabID` is excluded from the top hit**, so Cmd+L on a page does not
  autocomplete to that same tab.
- **No selected tab**: only the split-view scrim is added.
- **Search engine**: `activeSpace?.profile?.searchEngine`, default Google;
  suggestions can be turned off per profile (`searchSuggestionsEnabled`).

# Tests

- `CommandPaletteFocusTests` - commit in place, commit into a new tab, Escape,
  and Escape in a split leave the right web view first responder. All four
  fail with `restoreWebContentFocus()` disabled.[^task-78]
- `AddressInputClassifierTests`, `SuggestionProviderTests` - see
  [suggestion pipeline](./suggestion-pipeline.md).
- Verified at runtime in a signed build with synthetic keys: Cmd+L and Cmd+T
  commit, Escape, and both panes of a split. Not runtime-verified:
  click-outside dismissal, Peek, and the Picture in Picture tab-switch
  case.[^task-78]

# Related

- [Suggestion pipeline](./suggestion-pipeline.md) - what the rows are and how they are ranked.
- [Keyboard focus](../sidebar/keyboard-focus.md) - first responder rules for the window and sidebar.
- [Find in page](./find-in-page.md) - the other overlay in the content area; its dismissal restores focus on its own, simpler path.
- [Sidebar overview](../sidebar/overview.md) - `FauxAddressBar` and the delegate that opens the palette.
- [BrowserWindowController](../architecture/browser-window-controller.md) - the palette's delegate.
- [Web view ownership](../architecture/webview-ownership.md) - why focus is restored only when this window hosts the web view.

[^task-78]: After Cmd+L and Return the page does not regain keyboard focus
