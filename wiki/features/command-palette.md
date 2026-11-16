---
type: Feature
title: Command palette
description: "The overlay used for URL entry, tab switching, history, web search and browser commands: its two modes, how it is opened and dismissed, inline completion, command rows and the > list, a command's chip that asks for its space, tab or extension, keyboard handling, and how focus returns to the page."
tags: [command-palette, navigation, keyboard, focus, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:02:38Z }
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
  - id: task-297
    resource: backlog:TASK-297
    title: "Command palette: the empty-state line shows under the palette, off-center from it"
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
  - id: task-320
    resource: backlog:TASK-320
    title: "Command palette: browser commands (a shared command registry, also for AppleScript, Shortcuts and MCP)"
  - id: palette-commands
    resource: ../../Detour/Browser/CommandPalette/PaletteCommands.swift
    title: PaletteCommands.swift
  - id: palette-chip
    resource: ../../Detour/Browser/CommandPalette/PaletteChip.swift
    title: PaletteChip.swift (the chip's enter, Backspace and Escape rules)
  - id: command-choices
    resource: ../../Detour/Commands/CommandChoices.swift
    title: CommandChoices.swift (what a parameterised command may run on, the filter)
  - id: chip-tests
    resource: ../../DetourTests/PaletteCommandChipTests.swift
    title: PaletteCommandChipTests.swift
  - id: chip-window-tests
    resource: ../../DetourTests/PaletteCommandChipWindowTests.swift
    title: PaletteCommandChipWindowTests.swift
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
profile, and that profile's history scope (`historySpaceIDs`). Every
palette's history is its profile's: the spaces of the profile and its Quick
Detour scope, none for the Private profile (TASK-209; see
[suggestion pipeline](./suggestion-pipeline.md#history-is-profile-scoped)).

Cmd+T while a palette is already showing: an anchored palette switches to the
centred new-tab mode (`switchToCentered`, which clears the field), a centred
one is dismissed.

A palette is created per showing (`showCommandPalette` builds a new
`CommandPaletteView`) and given `tabStore`, then `activeSpaceID`,
`currentTabID`, `profile` and `historySpaceIDs` (`scopeCommandPalette`). The
window scopes it again when it switches spaces with the palette still open
(selecting a tab dismisses it, but Next Space into an empty space does not),
and `reloadSuggestions` rebuilds the list for what the field holds without an
inline completion, so a palette never goes on offering the previous space's
profile (found in TASK-209's code review). Two scrims go up with it: one behind the sidebar
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
| `.siteSearch` row, or Return in site-search mode | `didSubmitSiteSearch(url)` (required of every owner) | loads the site's results page as a search; see [site search](./site-search.md) |
| `.siteSearchHint` row | none | enters site-search mode |

`paletteLoadURL` records the visit as **typed** only when the input was
classified as a direct URL; a search-engine URL is not typed. Typed visits
weigh double in inline-completion ranking and bypass the 30 s history dedup
(see [history recording and search](./history-recording-and-search.md)).

In new-tab mode a URL (not a search) is first offered to
[Link Routes](./link-routing-in-page.md)
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
| Tab | when the typed text is a [site search](./site-search.md) keyword, or the field is or completes to a site search's host, or (no completion) starts its name or host, enters that site search (before the completion). Otherwise accepts the inline completion (the suffix becomes typed text). Consumed even with no completion, so focus never leaves the open palette |
| Backspace | with a completion still selected, removes only the completion and suppresses autocomplete for the next change; otherwise deletes as usual |
| Escape | prefilled palette (Cmd+L, address bar click): dismiss at once. Otherwise staged (`PaletteChip.escapeAction`): leave site-search mode or a command's chip and clear the field, or drop the completion, then clear the text, then dismiss |
| Space | a keyword followed by one space enters its site search (`controlTextDidChange`, since typing never reaches this method) |

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

## Browser commands

Since TASK-320 a browser window's and a Quick Detour's palette also offer
the browser's commands, from the [command registry](./browser-commands.md).
The owner hands the palette a `commandSource`
(`PaletteCommands.source(for:)`): the registry's palette commands that its
kind of window answers, each resolved (available now by the rule that
enables its menu item, titled as its item would be, with the live item's
shortcut) only when typed text matches it, and once per showing
(`resolvedCommands`), since some rules read the session database. A palette
with no source, the Quick Detour launcher's, offers none and treats `>` as
text.

| Typed | Rows | Return |
|---|---|---|
| Text of 3 characters or more that a command's title or alias matches | At most two command rows right after the verbatim row (`PaletteRows.insertingCommands`); the top hit and the verbatim row keep their places | Unchanged: row 0 is the top hit or the verbatim text. Arrowing to a command row (the field shows its title) and Return runs it |
| `>` then text | Commands only: every available one in menu order for a bare `>`, else the matches, best first. No history pass, no search suggestions (the text never goes to the search engine), no inline completion, no filler, no site-search entry by Tab or Space | Runs the selected command (row 0 after each rebuild). With no matching command, nothing: the text is never submitted as a search |

Matching (`PaletteCommands`): a name matches when it starts with the typed
words (`new pri` for New Private Window: *prefix*), or when every typed
word starts a different word of it (`tab close` for Close Tab: *words*).
Names are split at anything that is not a letter or digit, so
"Pin/Unpin Tab" is pin, unpin, tab. Ranking: prefix before words, title
before alias, then the shorter title, then menu order. In the `>` list the
field is the filter: the arrow keys move the selection without changing it.

A command row shows the command's symbol, its title in the window ("Unpin
Tab" for a pinned tab, "Open in 🏠 Home" in a Quick Detour) and, where a
history row shows its address, the live menu item's shortcut ("⇧⌘T"; the
Quick Detour item's follows its hotkey setting, and a cleared hotkey shows
none).

Activating one calls `commandPalette(_:didRequestCommand:)`. The owner
dismisses the palette first (so focus goes back to the page, and New Tab
and Open Location… would not see a palette), then runs the command through
`CommandDispatch.perform`: from its live main-menu item, validated and sent
as a click on it would be. A window controller's command is sent to that
controller (`controller: self`), whose rule offered it, rather than to the
first responder along the chain: with the page focused, `WKWebView`'s own
`goBack:`/`goForward:` are ahead of the controller (and `NSWindow` declares
`selectNextTab:`/`selectPreviousTab:` for window tabbing, though a Detour
window was not seen to take them). So the palette's
Back can close a tab to its opener (TASK-325); since TASK-331 Cmd+[ with the
page focused does too (`BrowserWebView` hands `goBack:` to the controller).
A command refused at that point (its state changed since
the row was offered; rows are resolved once per showing) beeps, as a
disabled menu key equivalent does.

Not offered in the palette: New Tab and Open Location… (they open the
palette), Undo and Redo (they act on whatever had focus), AppKit's text,
window and application items, Develop's per-extension items (the Develop
menu lists every profile's extensions, the palette only its window
profile's), and a command whose parameter has no list (a URL, a position;
none is declared). Commands that need a space, a tab or an extension ask
for it with a chip (below). Decided by the user (2026-11-14): commands are
both ranked in among the URL rows (3 characters or more, at most 2 rows,
below the typed row) and listed alone after `>`; the alternatives were only
after a prefix, or always mixed in.

## A command's chip

A command that needs a space, a tab or an extension asks for it in the
field, as a [site search](./site-search.md) asks for its query (TASK-320
AC #3, the user's choice on 2026-11-14 over a nested list and typed
arguments such as `>move work`).

| Command | Choices (`CommandChoices`, from the window's controller) | Runs |
|---|---|---|
| Switch to Space (`space.switch`) | What the Spaces menu offers: every space of a normal profile in Settings › Spaces order, another profile's too (its row names the profile), but the window's own. None in a Private window | `selectSpaceFromMenu(_:)`, as a Spaces menu item |
| Move Tab to Space (`tab.move-to-space`) | What the sidebar's Move to offers (every normal space; nothing from a Private window, TASK-38), but the tab's own space and any space the store would refuse the tab (`canMoveTab` / `canMovePinnedEntry`: a page the profile cannot serve). Not for a tab in a split (the sidebar has no Move to on a split row) | `moveSelectedTabToSpace(_:)` → the sidebar's `didRequestMoveTabAt` path: selection settles first, refusals explain themselves, one Move to Space undo |
| Split with Tab (`tab.split-with`) | The window space's unpinned tabs in no split, in sidebar order, but the selected one; in a Private window its own tabs only. Not for a pinned tab or one in a split | `splitSelectedTabWith(_:)` → the sidebar's create-split path, the chosen tab to the right (Split with Next Tab for any tab) |
| Show Extension Popup, Extension Options (`extension.show-popup`, `extension.options`) | The extensions the Extensions menu lists for the window's profile whose item is live there (`ExtensionMenuItems`: a declared popup, never read through `popupWebView`, TASK-55; an options page and a context in the profile, TASK-103). None in a Quick Detour | The submenu item's action on the app delegate |

A profile list (`CommandChoices.profiles`: normal profiles, none from a
Private window) is built and tested but no command takes a profile yet.

**Offered** only when the window's rule holds (the same `isAvailable(in:)`
as the menu) **and** there is a choice: Move Tab to Space with one space,
Switch to Space in a Private window and Split with Tab in a one-tab space
are not listed (`PaletteCommands.resolve`). The rows show the command's
symbol and title, no shortcut.

**Entering.** Return on the row (row 0 of a `>` list, or arrowed to among
the URL rows) or a click on it: the chip (`PaletteChipView`, the site
search's, with the command's symbol before its title, in the space's color)
goes before the field, the field is emptied, its placeholder says "Choose a
space" (a tab, an extension), and the rows are the command's choices, read
once from the owner (`PaletteCommandSource.choices`), the first selected.
What the user had typed (`>move`, or `move to` before arrowing, never the
row's title the field showed) is kept in `PaletteChip.CommandState`.

**In the mode.** The field filters the choices (`CommandChoices.filtered`:
a title that starts with the words, then one whose words they start, then a
title or address that contains the text; the list's order breaks ties).
Arrows move the selection and leave the field alone, as in the `>` list.
Return runs the command on the selected choice; with none (nothing matches)
it does nothing: the text is never a search or an address. No history pass,
no search suggestions (the filter never reaches the search engine), no
inline completion, no filler. Space after a keyword and Tab do not enter a
site search, and a filter starting with `>` stays a filter.

**Leaving**, exactly as a site search: Backspace with the caret at the start
puts back the entered text (then a space and the filter, if any), the caret
after it; Escape leaves the chip and clears the field, and the next Escape
dismisses; a Cmd+L palette dismisses at once. Cmd+T over the palette leaves
it. If the window changes under the open palette (`reloadSuggestions`), the
choices are read again, and the chip goes as by Backspace when the command
is no longer offered.

**Running.** `commandPalette(_:didRequestCommand:argument:)`: the owner
dismisses the palette (focus back to the page, as for any command), then
`CommandDispatch.performFromPalette` checks the choice against the window's
choices now (a tab closed or a space deleted since the chip opened is
refused with a beep) and `perform(_:argument:in:controller:)` builds the
command's item with the value as `representedObject`, as the menu items
that run it carry it, validates it with the controller's rule and sends it.
Then the browser window restores the page's focus once more, as after
switching to a tab: Split with Tab re-hosts the selected tab's web view in
the split, which left nothing focused (measured at runtime: the endpoint's
`press_key` found no focused view; `testSplitWithTab…` fails without it).

**Spaces of other profiles.** A normal window's Switch to Space and Move
Tab to Space list every normal profile's spaces, as the Spaces menu and the
sidebar's Move to do (the row names the other profile): the user's decision
of 2026-11-15, keeping what was built.[^task-320] The rejected alternative
was the window's profile only, as the palette's open-tab and history rows
are (TASK-209).

# Edge cases

- **Profiles and Incognito**: a Private window's palette lists only its own
  space's open tabs and no history; a normal window's palette lists the tabs
  of every space of its profile (pinned entries included), never another
  profile's and never a Private window's (TASK-209, TASK-137). The rule is
  `PaletteTabScope`, see [suggestion pipeline](./suggestion-pipeline.md).
- **`currentTabID` is never switched to by the top hit**, so Cmd+L on a page
  does not autocomplete to that same tab. Its host can still complete: Cmd+L
  on a video, then `you`, goes to the site root in place.
- **No selected tab**: only the split-view scrim is added, and the
  empty-state line ("A rare moment of tab peace." / "Where to next?") is
  hidden while the palette is up. The palette centers on the whole window
  and the label on the content area, so both on screen sat half a sidebar
  apart; in a Private window the suggestion list is short enough that both
  showed. The label's visibility is derived from the empty state and
  `commandPaletteView != nil` (`updateEmptyStateLabelVisibility`), so a
  dismiss without opening anything shows it again, and a commit that
  selects a tab ends the empty state in the same turn (no frame shows the
  label). The palette shows and hides without animation, so the label
  simply toggles in the same transaction (TASK-297).
- **Search engine**: `activeSpace?.profile?.searchEngine`, default Google;
  suggestions can be turned off per profile (`searchSuggestionsEnabled`).

# Tests

- `PaletteCommandsTests` - matching, ranking, the `>` query, where command
  rows go, and what a window's source offers and resolves (TASK-320).
- `PaletteCommandRowsTests` - a real palette over a fake source: a command
  row after the top hit and the verbatim row, Return still taking the top
  hit, arrowing to the command, the `>` list alone (no late pass adds to
  it), Return with no match doing nothing, each matched command resolved
  once, and `>` as text without a source. Command rows can push the last
  history or tab matches past the 12-row cap (`compose`).
- `CommandChoicesTests` - each command's choices (the window's own space,
  Private windows, another profile's space, the store's refusals, split
  partners, profiles, extensions), the filter's order, and the chip's rules
  (entering, Backspace, Escape) (TASK-320 AC #3).
- `PaletteCommandChipTests` - a real palette over a fake source: Return on a
  parameterised command enters its chip (from `>` and from the URL rows),
  typing filters, arrows keep the field, Return runs on the choice or does
  nothing, no history or searches, keywords, `>` and Tab stay the filter,
  Backspace (empty, with a filter, at its start, after arrowing) and Escape
  (two steps; a Cmd+L palette at once).
- `PaletteCommandChipWindowTests` - real windows: Move Tab to Space (a tab
  and a pinned entry; not for a split), Switch to Space and Split with Tab
  through the chip; a normal window never lists a Private window's space; a
  Private window offers neither space command and splits only its own tabs.
- `PaletteCommandWindowTests` - real windows: a normal, a Private, a Quick
  Detour and a quarantine window's `>` list is exactly the palette commands
  its main menu enables there (and the parameterised ones whose rule holds
  and that have a choice); Return pins and unpins the tab through the
  menu item and the palette is gone; Next Tab and Back reach the
  controller (Back closes a child tab to its opener); a Quick Detour's Copy
  URL runs in it.
- `EmptyStatePaletteTests` - the empty-state line is hidden under the
  palette in all three modes (Cmd+T, Cmd+L, anchored), shown again after a
  dismiss, stays hidden after a commit, and stays hidden when the selection
  is cleared under an open palette (TASK-297).
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

- [Site search](./site-search.md) - keyword shortcuts and the mode they enter.
- [Suggestion pipeline](./suggestion-pipeline.md) - what the rows are and how they are ranked.
- [Keyboard focus](../sidebar/keyboard-focus.md) - first responder rules for the window and sidebar.
- [Find in page](./find-in-page.md) - the other overlay in the content area; its dismissal restores focus on its own, simpler path.
- [Sidebar overview](../sidebar/overview.md) - `FauxAddressBar` and the delegate that opens the palette.
- [BrowserWindowController](../architecture/browser-window-controller.md) - the palette's delegate.
- [Web view ownership](../architecture/webview-ownership.md) - why focus is restored only when this window hosts the web view.

[^task-320]: TASK-320
[^task-78]: After Cmd+L and Return the page does not regain keyboard focus
[^task-144]: Cmd+L then Return activates the first recent-history row instead of the pre-filled URL
[^task-181]: Backspace after moving the caret off an inline completion deletes back to the typed prefix
[^task-184]: The list changes height several times per keystroke, so the palette flickers while typing. Harness: `docs/harness/task184-harness.patch`; rules tested in `PaletteRowsTests`
