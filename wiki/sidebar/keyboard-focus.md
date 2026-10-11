---
type: Concept
title: Keyboard focus in the window and sidebar
description: Which view holds first responder in a browser window, when focus is handed back to the web page, why a space's tab list never takes the keyboard, and why the archive page takes it only while on screen.
tags: [sidebar, window, focus, first-responder, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-11T08:08:38Z }
sources:
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (showWindow, restoreWebContentFocus, selectTab, keyDown)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (updatePageKeyboardFocus, resignOffscreenPageFocus, rebuildPages)
  - id: components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift (DraggableTableView, FocusGatedTableView)
  - id: cells
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift and FolderCellView.swift (inline rename)
  - id: archive-page
    resource: ../../Detour/Browser/Sidebar/ArchivePageView.swift
    title: ArchivePageView.swift
  - id: focus-tests
    resource: ../../DetourTests/SidebarPageFocusTests.swift
    title: SidebarPageFocusTests.swift
  - id: initial-tests
    resource: ../../DetourTests/InitialWindowFocusTests.swift
    title: InitialWindowFocusTests.swift
  - id: palette-tests
    resource: ../../DetourTests/CommandPaletteFocusTests.swift
    title: CommandPaletteFocusTests.swift
  - id: handoff-tests
    resource: ../../DetourTests/WebViewHandoffFocusTests.swift
    title: WebViewHandoffFocusTests.swift
  - id: task-135
    resource: backlog:TASK-135
    title: After a window takes over a tab's web view from another window, keyboard focus is on the window, not the page
  - id: task-78
    resource: backlog:TASK-78
    title: After Cmd+L and Return the page does not regain keyboard focus
  - id: task-128
    resource: backlog:TASK-128
    title: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
  - id: task-130
    resource: backlog:TASK-130
    title: Keyboard focus stays behind on a tab list whose page has slid off screen
  - id: task-131
    resource: backlog:TASK-131
    title: A focused tab list loses keyboard focus when the space list changes
  - id: task-174
    resource: backlog:TASK-174
    title: A space's tab list takes keyboard focus, so keys go to the list instead of the page after a click
  - id: notes-keyloop
    resource: "Agent session notes, 2026-10-02 (not in the repository)"
    title: Key-view loop probe findings
---

# Summary

The web page should have the keyboard unless the user put it somewhere else.
AppKit does not arrange that by itself: it focuses a sidebar control when a
window first appears, focuses a list when one of its rows is clicked, leaves
the *window* as first responder whenever the focused view is removed, and
lets a view keep focus after it has slid off screen. Five bugs came from
those behaviours.[^task-78][^task-128][^task-130][^task-131][^task-174]
The rules below are what fixed them, and they are easy to undo by accident.

In the sidebar only two things hold the keyboard: a row being renamed, and
the Archived Tabs page while it shows. A space's tab list never does.

# Rules

## 1. One function hands focus to the page

`BrowserWindowController.restoreWebContentFocus()` makes first responder the
presented [Peek](../tabs/peek.md)'s web view if a peek is showing, else the
selected tab's web view. In a [split](../tabs/split-tabs-hosting.md)
`selectedTabID` names the focused pane, so that pane gets it. It does nothing
when this window shows a snapshot rather than hosting the web view
([web view ownership](../architecture/webview-ownership.md)).

Call it; do not write another `makeFirstResponder(webView)`.

## 2. When focus goes back to the page

| Moment | Where | Why |
|---|---|---|
| The window is first shown | `showWindow` override, once (`hasSettledInitialFocus`) | With no `initialFirstResponder`, AppKit focuses the window's first key view. That was the archive page's search field, off screen, which then swallowed typing.[^task-128] If a sidebar control still holds focus after the restore (no page to focus), focus is set to nothing |
| A tab is selected | end of `selectTab` | Only if the palette was showing or nothing holds focus (`isKeyboardFocusUnheld`): the launch path selects the session's tab *after* the window is shown, and a keyboard tab switch removes the focused web view from the window |
| The command palette is dismissed | `dismissCommandPalette(restoringFocus:)`, and again after the commit paths host the new web view | The palette's field held focus; without this the page got no keys until clicked.[^task-78] See [command palette](../features/command-palette.md) |
| The sidebar gives the keyboard up, or never wanted it | `tabSidebarDidReleaseKeyboardFocus` | A click on a tab list, the end of an inline rename (rule 3), a page that slid away (rule 4), rebuilt pages (rule 5) |
| The window becomes key, or takes the web view over without becoming key | `windowDidBecomeKey` (after the Peek is restored) and `ensureOwnsWebView`, through `focusWebContentIfUnheld` | Only if nothing holds focus. A window showing a tab that another window hosts has no page to focus: its first responder went back to the window when the web view left. `claimWebView` only re-hosts, so without this the page took no keys after Cmd-backtick (seen with posted keys and the call switched off: the first responder was the window and a typed letter never reached the page's input; with the call the letter arrives).[^task-135] |
| The find bar closes | `dismissFindBar` | Focuses the selected tab's web view directly |

`isKeyboardFocusUnheld` is true when the first responder is the window
itself, or is inside `pipContentView` — the outgoing page kept parented for
its picture-in-picture capture. That page never left the window, so it would
keep the keys and then drop them on the window when the hold ends.[^task-128]

**Focus held by a control stays** across a tab switch that did not come from
a click on the tab list: Control+Tab or Cmd+Option+Up/Down with the find
bar's field focused leaves the keyboard in the find bar
(`testSelectingATabLeavesFocusOnAControlThatHoldsIt`). This is the reason the
restore in `selectTab` is conditional. A click on the tab list is different;
see rule 3.

`selectTab` dismisses an open palette with `restoringFocus: false` and
focuses the incoming tab at its end. Restoring at dismissal could land on an
outgoing tab still parented for picture-in-picture.[^task-78]

## 3. A space's tab list never takes the keyboard

`DraggableTableView`, the list of every space page, returns false from
`acceptsFirstResponder` **and** from `becomeFirstResponder`. The second
override is required: `NSWindow.makeFirstResponder` does not consult
`acceptsFirstResponder`.[^task-130]

Choosing a tab with the mouse is not a reason to type at the list. It used
to be treated as one: the click made the list first responder, `selectTab`
saw focus as held and left it there, and every key went to the list (arrow
keys walked rows, everything else was dropped) until the page was
clicked.[^task-174] The reasons for the change, and what it gave up, are
under [Why the tab list does not take focus](#why-the-tab-list-does-not-take-focus).

Refusing focus is not enough by itself, because a click on a view that
refuses it leaves first responder wherever it was. Three things used to
happen as a side effect of the list taking focus and are now done on
purpose:

- **A click hands the keyboard to the page.** `DraggableTableView.mouseDown`
  lets AppKit handle the click and then calls `onReleaseKeyboardFocus`; the
  sidebar tells its delegate, and the window calls
  `restoreWebContentFocus()` unless the command palette is open
  (`tabSidebarDidReleaseKeyboardFocus`). So the keyboard leaves the find
  bar, a click on the already selected row with nothing focused focuses the
  page, and the palette that the New Tab row opens keeps the keyboard. The
  window decides, from state it owns. A first version had the list compare
  first responder before and after the click and hand over only if it had
  not moved; that gave the palette's keyboard to the page when the find bar
  had been focused, because a window has one field editor that every text
  field edits through, so first responder was the same object before and
  after (`testAClickThatOpensThePaletteTakesTheKeyboardFromAnotherField`).[^task-174]
- **A click ends a rename.** `mouseDown` first resigns a first responder
  inside the list (`makeFirstResponder(nil)`), which commits the rename as
  any loss of focus does.
- **Return, Tab and Escape in a rename give the keyboard to the page.** Both
  cells handle `insertNewline:`, `insertTab:`, `insertBacktab:` and
  `cancelOperation:` in `control(_:textView:doCommandBy:)`, end the edit, and
  call the list's `releaseKeyboardFocus()`. Left to AppKit, Return keeps
  first responder on the label, and Tab commits and leaves the window as
  first responder, since the list is no longer there to take it.[^task-174]
  Escape used to focus the list.

The Archived Tabs page is the exception, because it is a search UI:
`ArchivePageView.acceptsKeyboardFocus` is true only while the archive shows.
It drives the list (`FocusGatedTableView.allowsKeyboardFocus`) and sets
`refusesFirstResponder` on the search field and the Clear and Filter
buttons. `TabSidebarViewController.updatePageKeyboardFocus()` sets it from
`isShowingArchivePage`'s `didSet` and from `updateActivePage()`. The gate is
by state, not by key-view-loop surgery, because which strip views AppKit
links into the loop depends on what existed when the window was first shown
(see below).

## 4. Focus is not left behind on a page that slid away

A view that already has focus keeps it when its page leaves the screen.
When the tab lists still took focus, the Down arrow switched tabs behind the
archive page, and after a space switch the arrows walked the old space's
hidden rows.[^task-130] What can be left behind now is a rename field on a
space page, or the archive page's search field or list.

`resignOffscreenPageFocus()` runs with the gate: if the first responder is
inside the page strip but not inside the current page, it calls
`makeFirstResponder(nil)` and tells the delegate, and the window calls
`restoreWebContentFocus()`. On a space switch the sidebar resigns before
`setActiveSpace`'s `selectTab` runs, so rule 2's "nothing holds focus"
branch focuses the new space's page.

Side effect, intended: leaving the archive page with its search field or
list focused now focuses the web page; it used to leave nothing focused.

## 5. Rebuilding pages must not drop the keyboard or the highlight

`rebuildPages()` tears down every space page when the space list changes
(see [space paging](./space-paging.md)). The rebuilt list came back with no
selected row.[^task-131]

The rebuild records the selected row and re-selects it under
`suppressingSelectionCallbacks`, **only if the active page shows the same
space before and after** (`activePageSpaceID`): when the active space itself
was deleted the page falls back to another space, which has no such row.

A rename under way goes down with its row, and removing the focused field
from the window leaves the window as first responder. If focus was inside
the active space's page before the rebuild and nothing holds it afterwards,
the sidebar tells the delegate and the page takes the keyboard. (Before
TASK-174 the rebuilt list inherited the old list's focus.[^task-131])

## 6. Small ones

- A key the page declines must not beep, and a key a native control declines
  still should: `BrowserWindowController.keyDown` and
  `keyWasDeclinedByWebContent`. See [AppKit gotchas](../platform/appkit-gotchas.md).
  Any native view parented inside a web view must stay non-focusable, or its
  declined keys go silent.

# The key-view loop, as measured

Measured in the running app with a key-view probe, Full Keyboard Access
off:[^notes-keyloop][^task-130]

- AppKit builds the window's key-view loop once, when the window is first
  shown. It contains only views that existed then: sidebar chrome, the
  archive page, the find bar.
- Web views and the space pages' tables are created later and have
  `nextKeyView == nil`. Tab from a page, from a tab list, or with nothing
  focused never reaches an off-screen sidebar control. A review finding that
  claimed otherwise was wrong; the real defect was rule 4.
- `canBecomeKeyView` is false for scroll and clip views and, with Full
  Keyboard Access off, for buttons.

Not measured: Full Keyboard Access on. It could not be enabled for one
process (the `-AppleKeyboardUIMode 2` launch argument and swizzling
`NSApplication.isFullKeyboardAccessEnabled` both left
`NSButton.canBecomeKeyView` false).[^notes-keyloop] By AppKit's rules the
archive page's buttons become key views then, which is why they are gated
anyway.

# Why the tab list does not take focus

Decided 2026-10-11.[^task-174] Before, the active space's list took focus on
a click so that the arrow keys could walk its rows, and rules 3 to 5 existed
to keep that focus on the right list (only the page on screen accepted it,
it was resigned when the page slid away, and carried across a rebuild).

- **What it cost.** After choosing a tab with the mouse, typing did not
  reach the page. The user has to know that the list is focused to make
  sense of that, and nothing shows it.
- **What it gave up.** Walking rows with the arrow keys after a click, and
  type-select in the list. Cmd+Option+Up/Down and Control+Tab
  ([tab switching](../tabs/tab-switching.md)) change tab from the keyboard
  wherever focus is.
- **Rejected: only refuse focus.** A click on a view that refuses focus
  changes nothing, so the keyboard would stay in the find bar after a click
  on a row, a rename would survive a click elsewhere in the list, and a
  click on the selected row with nothing focused would still leave nothing
  focused. Hence the hand-over in `mouseDown`.
- **Rejected: hand over in the window's row-selection handlers.**
  Cmd+Option+Up/Down goes through the same delegate methods as a row click
  ([tab switching](../tabs/tab-switching.md)), and a keyboard switch should
  leave a focused find bar alone. The hand-over belongs to the click.
- **Out of scope: the archive page.** Its search field has to take typing,
  and its list is reached from the field with the Down arrow.

# What was seen in the running app

With the harness in
[docs/harness/task173-174-harness.patch](../../docs/harness/task173-174-harness.patch)
(posted mouse and key events, isolated profile, the app launched from a
shell and so not the active application):[^task-174]

| Step | Old code | With the list refusing focus |
|---|---|---|
| Page focused, click another row, type a key | first responder is `DraggableTableView`; no page receives the key | the web view keeps first responder; the page receives the key |
| Find bar focused, click a row, type a key | `DraggableTableView`; no page receives it | the web view; the page receives it |
| Nothing focused, click the selected row, type a key | `DraggableTableView`; no page receives it | the web view; the page receives it |

"Receives" is the page's own `keydown` listener. In these runs the posted
click did not change the list's selection, in either build, so the step
"click another row and its page takes the keys" was not seen end to end; it
is covered by `testSelectingATabRowFocusesItsPage` and by the steps above
taken together.

# Open items

- A click on a row, by a person, followed by typing has not been tried in
  an active application.[^task-174]

- A focusable control added to a sidebar page later must be gated by hand:
  the archive page's through `acceptsKeyboardFocus`, a space page's by not
  accepting focus at all. Row buttons on off-screen pages are ungated and
  unmeasured under Full Keyboard Access.[^task-130]
- A row reloaded under its own rename (`reloadData(forRowIndexes:)` after a
  title or favicon change of a pinned tab being renamed) ends the rename and
  leaves the keyboard with the window, until the next click or tab switch.
  Before TASK-174 the list picked it up. Two hooks were tried in the cell
  and neither fired with the cell still attached to its list
  (`viewWillMove(toWindow:)` while editing, and the end of the edit).[^task-174]
- Leaving the archive page for a space other than the active one focuses the
  outgoing space's page for a moment before `setActiveSpace` focuses the new
  one: a spurious focus and blur on the page being left; the end state is
  correct.[^task-130]
- Real key presses and clicks were not used in verifying rules 4 and 5; the
  probe sent `keyDown` to the first responder directly.[^task-130][^task-131]

# Where it lives and how to test

| Piece | Location |
|---|---|
| `restoreWebContentFocus`, `showWindow`, `isKeyboardFocusUnheld`, `keyDown` | [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift) |
| `updatePageKeyboardFocus`, `resignOffscreenPageFocus`, `rebuildPages` | [TabSidebarViewController.swift](../../Detour/Browser/Sidebar/TabSidebarViewController.swift) |
| `DraggableTableView` (`mouseDown`, `releaseKeyboardFocus`), `FocusGatedTableView` | [SidebarComponents.swift](../../Detour/Browser/Sidebar/SidebarComponents.swift) |
| Inline rename (`control(_:textView:doCommandBy:)`) | [TabCellView.swift](../../Detour/Browser/Sidebar/TabCellView.swift), [FolderCellView.swift](../../Detour/Browser/Sidebar/FolderCellView.swift) |
| `ArchivePageView.acceptsKeyboardFocus` | [ArchivePageView.swift](../../Detour/Browser/Sidebar/ArchivePageView.swift) |

Suites: `InitialWindowFocusTests`, `SidebarPageFocusTests`,
`CommandPaletteFocusTests`, `UnhandledKeyFallthroughTests`,
`WebViewHandoffFocusTests` (two windows on one space; "becoming key" is the
delegate call, since the test host is not reliably the active app).

Three rules for focus tests:

- Assert on `window.firstResponder`, never on `makeFirstResponder`'s return
  value: it returns `true` even when the view's `becomeFirstResponder`
  declines and the window takes focus instead.[^task-130]
- A regular (non-incognito) window needs real spaces: add spaces to
  `TabStore.shared` under an existing profile, create
  `BrowserWindowController(incognito: false)`, `setActiveSpace`,
  `showWindow`, and delete the spaces in `tearDown`. Save and restore
  `TabStore.lastActiveSpaceID` and `ExtensionManager.lastActiveSpaceID`,
  which such a window would otherwise leave naming a deleted
  space.[^task-130]

- A synthetic mouse-down handed to an `NSTableView` in the test host does
  not select the row under it. The host is not the active application, and
  neither `tableView.mouseDown(with:)` with the mouse-up queued nor posted
  events pumped through `NSApp.sendEvent` changed the selection (the pumped
  click did move first responder to a list that accepted it).[^task-174]
  `SidebarPageFocusTests` therefore hands the mouse-down to the list for
  what the list's own `mouseDown` does, and makes the selection with
  `selectRowIndexes` where a test needs it. The one thing a tab list holds
  the keyboard for is a rename, so those tests start one on a pinned folder
  (`beginRename`).

The probe itself is described in [UI probes](../playbooks/ui-probes.md).

# Related

- [Sidebar overview](./overview.md)
- [Space paging](./space-paging.md) — the page strip the gate follows.
- [AppKit gotchas](../platform/appkit-gotchas.md) — the first-responder and responder-chain behaviours behind these rules.
- [Command palette](../features/command-palette.md) — focus return on dismissal.
- [Browser window controller](../architecture/browser-window-controller.md)
- [Tab switching](../tabs/tab-switching.md) — keyboard tab changes that leave focus on the page.

[^task-78]: After Cmd+L and Return the page does not regain keyboard focus
[^task-135]: After a window takes over a tab's web view from another window, keyboard focus is on the window, not the page
[^task-128]: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
[^task-130]: Keyboard focus stays behind on a tab list whose page has slid off screen
[^task-131]: A focused tab list loses keyboard focus when the space list changes
[^task-174]: A space's tab list takes keyboard focus, so keys go to the list instead of the page after a click
[^notes-keyloop]: Key-view loop probe findings
