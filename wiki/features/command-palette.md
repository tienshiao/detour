---
type: Feature
title: Command palette
description: "The overlay used for URL entry, tab switching, history and web search: its two modes, how it is opened and dismissed, inline completion, keyboard handling, and how focus returns to the page."
tags: [command-palette, navigation, keyboard, focus, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T04:55:17Z }
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
  - id: selection
    resource: ../../Detour/Browser/CommandPalette/PaletteSelection.swift
    title: PaletteSelection.swift
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
  - id: task-144
    resource: backlog:TASK-144
    title: Cmd+L then Return activates the first recent-history row instead of the pre-filled URL
  - id: task-181
    resource: backlog:TASK-181
    title: Backspace after moving the caret off an inline completion deletes back to the typed prefix
  - id: task-184
    resource: backlog:TASK-184
    title: The list changes height several times per keystroke, so the palette flickers while typing
  - id: rows
    resource: ../../Detour/Browser/CommandPalette/PaletteRows.swift
    title: PaletteRows.swift
  - id: rows-tests
    resource: ../../DetourTests/PaletteRowsTests.swift
    title: PaletteRowsTests.swift
  - id: selection-tests
    resource: ../../DetourTests/PaletteSelectionTests.swift
    title: PaletteSelectionTests.swift
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

[Quick Detour](./quick-detour.md) (TASK-193.1) uses the same
`CommandPaletteView` twice: alone in the launcher panel that Opt-Cmd-N shows
(submitting opens the Quick Detour window on the page; dismissing opens
nothing), and over a Quick Detour window's page on Cmd+L or a click on the
host in its title bar, navigating that page in place. Both hand the palette
no `tabStore` (no open tab of any window is offered), the Quick Detour's
profile, and as `activeSpaceID` the space it was asked from when that is
the same profile's, else the profile's Quick Detour history scope
(`QuickDetour.paletteHistorySpaceID`).

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
    NSScrollView > NSTableView   rows 36 pt, always 6 rows tall
```

The list area has one height, six rows (`PaletteRows.visibleRows`), whenever
the palette shows a list, and the rows fill it: like Arc, the palette does not
show empty rows.[^task-184] For a typed query `PaletteRows.compose` builds the
list from

1. the matches of the latest local pass (top hit, verbatim row, hosts, open
   tabs, history);
2. search suggestions, the usual four, or as many as fill the room below six
   (the service returns at most five);
3. rows of the default (empty-field) list as filler, skipping a URL already
   listed, until there are six. A query with no matches (gibberish, offline,
   search suggestions off) shows its verbatim row over recent pages.

Only a profile with nothing to pad with (no history, no open tabs) can show
blank space; an empty default list drops the list area.

Fitting the box to its rows made it flicker, because each keystroke rebuilds
the list up to three times ([two passes and the
network](./suggestion-pipeline.md#two-passes-per-keystroke)): a 60 Hz frame
log of typing and deleting "youtu" counted 9 height changes between 78 and
258 pt before, none after, and no moment with fewer than six rows. The
centred position is computed against the same height, so the box does not
move either.

Two rules keep the rows themselves from jumping:

- **Carried suggestions.** Until the new query's search suggestions arrive,
  the previous query's suggestions that the new text still prefixes stay
  (`carriedSearchSuggestions`), so the bottom rows do not blank and refill on
  every keystroke.
- **Late passes leave the user's row alone.** Once the user has moved the
  selection with the arrow keys, a pass that lands later (history, network)
  is applied only if the rows up to the selected one are unchanged, and then
  keeps the selection; otherwise it is skipped (`latePassOutcome`). The
  history pass's inline completion is not applied then either, since the
  field shows the selected row's text. "Moved" is a flag
  (`selectionMovedByUser`), not "the index differs from the initial row":
  Down then Up lands back on row 0, which the user then chose. A skipped
  pass is retried on the next arrow key, so it lands once the selection
  allows it (e.g. after arrowing off the list). Before, the history pass
  reset the selection to the first row, and search suggestions were only
  appended.

## Submitting

| What was activated | Delegate call | Result |
|---|---|---|
| The field's text (Return with no row selected) | `didSubmitInput` with the trimmed text; nothing when it is blank | `AddressInputClassifier.directURL` decides URL vs search |
| `.searchInput` row (the verbatim typed text) | `didSubmitInput` with the **row's** text | same; the field may hold an inline completion the row does not mean |
| `.historyResult` row | `didSubmitInput` with the URL | navigates |
| `.searchSuggestion` row | `didSubmitSearch` | always a search, never classified |
| `.openTab` row | `didRequestSwitchToTab(tabID, in: spaceID)` | switches space if needed, selects the tab |

`paletteLoadURL` records the visit as **typed** only when the input was
classified as a direct URL; a search-engine URL is not typed. Typed visits
weigh double in inline-completion ranking and bypass the 30 s history dedup
(see [history recording and search](./history-recording-and-search.md)).

In new-tab mode a URL (not a search) is first offered to
[Link Routes](./link-routing.md#typed-urls-and-links-clicked-in-a-page)
(`typedURLIsRoutable`, TASK-191.4): a route that sends it to another space or
a Private window opens it there, placed as a link from another app, and no
tab is added here. In place (Cmd+L, the address bar) never routes. Cmd+L or
an address bar click with a Peek open submits in new-tab mode, so it routes.

Typed `detour://history` is routed to `loadInternalPage`, because plain
`load(_:)` refuses the internal scheme; see
[internal pages](./internal-pages.md).

## Keyboard

Handled in `control(_:textView:doCommandBy:)`. The decisions themselves are
the pure functions of `PaletteSelection` (`initialRow`, `row(afterMoving:)`,
`returnAction`, `restoredFieldText`); the view only applies them.

| Key | Behaviour |
|---|---|
| Up / Down | moves the keyboard selection and puts the row's text in the field, fully selected. With no row selected, Down selects the first row and Up the last. Moving past either end clears the selection and restores what the user typed, or the pre-filled URL (selected again) while the field is unedited |
| Return | activates the selected row; with none, submits the field's text; with none and a blank field, does nothing. The field has no target/action: Return never leaves this method |
| Tab | accepts the inline completion (the suffix becomes typed text). Consumed even with no completion, so focus never leaves the open palette |
| Backspace | with a completion still selected, removes only the completion and suppresses autocomplete for the next change; otherwise deletes as usual |
| Escape | prefilled palette (Cmd+L, address bar click): dismiss at once. Otherwise staged: drop the completion, then clear the text, then dismiss |

Which row is selected after a list rebuild depends on what the list is:

| List | Selected after a rebuild | Return |
|---|---|---|
| Typed query | row 0 | activates it: the top hit when there is one, otherwise the verbatim input |
| Default list (nothing typed: Cmd+L's pre-filled field, Cmd+T's or a cleared field) | none | Cmd+L: submits the pre-filled URL. Empty field: nothing |

The default list is told apart by `suggestionsQuery == nil`. Until TASK-144 it
also started with row 0 selected, so Cmd+L followed by Return activated the
space's most recent history entry instead of the address shown. That is
usually the current page, which hid the bug, but not when another tab of the
space navigated more recently or the current page records no history (an
internal page, a Private window, a failed load); and Cmd+T followed by Return
opened that entry from an empty field. Reproduced in-process by
`PaletteReturnKeyTests`, not in the launched app.[^task-144]

Mouse behaviour is separate and was not changed: hover highlights a row
without selecting it, and a click activates the clicked row whatever the
keyboard selection is.

## Inline completion

`applyInlineCompletion` appends the completion's suffix to the field and
selects it, so typing replaces it; it then scrolls back so the typed prefix
stays visible. For a host prefix the completion is the host, not a page on
it (see [suggestion pipeline](./suggestion-pipeline.md)).

A completion is *pending* only while it is exactly the field's selection.
Moving the caret or the selection off it (Cmd+Right, End, Left, a click)
accepts it: `acceptInlineCompletionIfDeselected` makes the field's text the
typed text before every command, since movement keys never reach
`controlTextDidChange`. Until TASK-181 the completion stayed pending after
Cmd+Right, so the next Backspace took the "remove the completion" branch
and reset the field to the typed prefix, instead of deleting the last
character.[^task-181] Selection ranges are UTF-16 offsets throughout
(`utf16.count`, not `count`). `userTypedText` always holds what the user actually typed,
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
- **`currentTabID` is never switched to by the top hit**, so Cmd+L on a page
  does not autocomplete to that same tab. Its host can still complete: Cmd+L
  on a video, then `you`, goes to the site root in place.
- **No selected tab**: only the split-view scrim is added.
- **Search engine**: `activeSpace?.profile?.searchEngine`, default Google;
  suggestions can be turned off per profile (`searchSuggestionsEnabled`).

# Tests

- `CommandPaletteFocusTests` - commit in place, commit into a new tab, Escape,
  and Escape in a split leave the right web view first responder. All four
  fail with `restoreWebContentFocus()` disabled.[^task-78]
- `PaletteSelectionTests` - the selection and submit rules: Return on an
  unedited pre-filled field, on an empty field, after arrowing to a row and on
  a typed query; arrow movement from no selection and past either end.
- `PaletteReturnKeyTests` - the same through a real `CommandPaletteView` in a
  window, over an in-memory history database (`suggestionProvider` is
  replaceable for this). Keys are sent as the field editor's
  `doCommand(by:)`, the call a key press ends in, and typing as
  `insertText(_:replacementRange:)`; the assertions are on what the delegate
  receives.[^task-144]
- `PaletteReturnKeyTests` inline-completion cases (TASK-181): Backspace
  after Cmd+Right and after placing the caret inside the completion, Backspace
  on the selected completion, and Tab after moving off it keeping focus. The
  first two and the Tab case fail on the old code.[^task-181]
- Runtime: the [TASK-181/182 harness](../../docs/harness/task181-182-harness.patch)
  sends Cmd+Right, Left and Backspace through the field editor's real key
  bindings in a Debug build. `you` → `youtube.com`, Cmd+Right, Backspace
  left `youtube.co`; Left then Backspace on `youtube.com/w|atch?v=1` left
  `youtube.com/atch?v=1`.
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
[^task-144]: Cmd+L then Return activates the first recent-history row instead of the pre-filled URL
[^task-181]: Backspace after moving the caret off an inline completion deletes back to the typed prefix
[^task-184]: The list changes height several times per keystroke, so the palette flickers while typing. Harness: `docs/harness/task184-harness.patch`; rules tested in `PaletteRowsTests`
