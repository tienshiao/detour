---
type: Concept
title: Keyboard focus in the window and sidebar
description: Which view holds first responder in a browser window, when focus is handed back to the web page, and why only the sidebar page on screen may take the keyboard.
tags: [sidebar, window, focus, first-responder, appkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (showWindow, restoreWebContentFocus, selectTab, keyDown)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (updatePageKeyboardFocus, resignOffscreenPageFocus, rebuildPages)
  - id: components
    resource: ../../Detour/Browser/Sidebar/SidebarComponents.swift
    title: SidebarComponents.swift (FocusGatedTableView)
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
  - id: notes-keyloop
    resource: "Agent session notes, 2026-10-02 (not in the repository)"
    title: Key-view loop probe findings
---

# Summary

The web page should have the keyboard unless the user put it somewhere else.
AppKit does not arrange that by itself: it focuses a sidebar control when a
window first appears, leaves the *window* as first responder whenever the
focused view is removed, and lets a view keep focus after it has slid off
screen. Four bugs came from those three behaviours.[^task-78][^task-128][^task-130][^task-131]
The rules below are what fixed them, and they are easy to undo by accident.

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
| A sidebar page gives up focus | `tabSidebarDidReleaseKeyboardFocus` | Rule 4 |
| The find bar closes | `dismissFindBar` | Focuses the selected tab's web view directly |

`isKeyboardFocusUnheld` is true when the first responder is the window
itself, or is inside `pipContentView` — the outgoing page kept parented for
its picture-in-picture capture. That page never left the window, so it would
keep the keys and then drop them on the window when the hold ends.[^task-128]

**Focus held by a control stays.** Clicking a tab row focuses the list and
selects the tab; `selectTab` then sees focus as held and leaves it, so the
arrow keys keep walking rows. This is tested
(`testSelectingATabLeavesFocusOnASidebarControl`) and is the reason the
restore in `selectTab` is conditional.

`selectTab` dismisses an open palette with `restoringFocus: false` and
focuses the incoming tab at its end. Restoring at dismissal could land on an
outgoing tab still parented for picture-in-picture.[^task-78]

## 3. Only the page the strip rests on accepts focus

`TabSidebarViewController.updatePageKeyboardFocus()` is the single gate. It
runs from `isShowingArchivePage`'s `didSet` and from `updateActivePage()`:

- each `SpacePageView.acceptsKeyboardFocus` is true only for the active
  space's page while the archive is not showing; it drives
  `DraggableTableView.allowsKeyboardFocus`;
- `ArchivePageView.acceptsKeyboardFocus` is true only while the archive
  shows; it drives the list and sets `refusesFirstResponder` on the search
  field and the Clear and Filter buttons.

Both lists inherit `FocusGatedTableView`, which overrides
`acceptsFirstResponder` **and** `becomeFirstResponder`. The second override
is required: `NSWindow.makeFirstResponder` does not consult
`acceptsFirstResponder`.[^task-130]

The gate is by state, not by key-view-loop surgery, because which strip
views AppKit links into the loop depends on what existed when the window
was first shown (see below).

## 4. Focus is not left behind on a page that slid away

A list that already has focus keeps it when its page leaves the screen. With
the archive page showing, the Down arrow switched tabs behind it; after a
space switch the arrows walked the old space's hidden rows and the new list
ignored the keyboard.[^task-130]

`resignOffscreenPageFocus()` runs with the gate: if the first responder is
inside the page strip but not inside the current page, it calls
`makeFirstResponder(nil)` and tells the delegate, and the window calls
`restoreWebContentFocus()`. On a space switch the sidebar resigns before
`setActiveSpace`'s `selectTab` runs, so rule 2's "nothing holds focus"
branch focuses the new space's page.

Side effect, intended: leaving the archive page with its search field or
list focused now focuses the web page; it used to leave nothing focused.

## 5. Rebuilding pages must not move the keyboard

`rebuildPages()` tears down every space page when the space list changes
(see [space paging](./space-paging.md)). Removing the focused list from the
window left the window as first responder, and the rebuilt list came back
with no selected row, so the next Down arrow landed on the New Tab row and
opened the palette.[^task-131]

The rebuild records the selected row and whether focus was inside the active
space's page, then re-selects that row under `suppressingSelectionCallbacks`
and re-focuses the new list. It does so **only if the active page shows the
same space before and after** (`activePageSpaceID`). When the active space
itself was deleted the page falls back to another space; carrying focus
there gave another space's list the keyboard, and `setActiveSpace` then saw
focus as held and never gave it to the page.[^task-131]

## 6. Small ones

- Esc during an inline rename (`TabCellView`, `FolderCellView`) cancels the
  edit and focuses the table.
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

# Open items

- The gate is per control while resigning is generic. A focusable control
  added to a page later must be wired into `acceptsKeyboardFocus` by hand.
  Row buttons on off-screen pages are ungated and unmeasured under Full
  Keyboard Access.[^task-130]
- Leaving the archive page for a space other than the active one focuses the
  outgoing space's page for a moment before `setActiveSpace` focuses the new
  one: a spurious focus and blur on the page being left; the end state is
  correct.[^task-130]
- Real key presses and clicks were not used in verifying rules 3–5; the
  probe sent `keyDown` to the first responder directly.[^task-130][^task-131]

# Where it lives and how to test

| Piece | Location |
|---|---|
| `restoreWebContentFocus`, `showWindow`, `isKeyboardFocusUnheld`, `keyDown` | [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift) |
| `updatePageKeyboardFocus`, `resignOffscreenPageFocus`, `rebuildPages` | [TabSidebarViewController.swift](../../Detour/Browser/Sidebar/TabSidebarViewController.swift) |
| `FocusGatedTableView` | [SidebarComponents.swift](../../Detour/Browser/Sidebar/SidebarComponents.swift) |
| `ArchivePageView.acceptsKeyboardFocus` | [ArchivePageView.swift](../../Detour/Browser/Sidebar/ArchivePageView.swift) |

Suites: `InitialWindowFocusTests`, `SidebarPageFocusTests`,
`CommandPaletteFocusTests`, `UnhandledKeyFallthroughTests`.

Two rules for focus tests:

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

The probe itself is described in [UI probes](../playbooks/ui-probes.md).

# Related

- [Sidebar overview](./overview.md)
- [Space paging](./space-paging.md) — the page strip the gate follows.
- [AppKit gotchas](../platform/appkit-gotchas.md) — the first-responder and responder-chain behaviours behind these rules.
- [Command palette](../features/command-palette.md) — focus return on dismissal.
- [Browser window controller](../architecture/browser-window-controller.md)
- [Tab switching](../tabs/tab-switching.md) — keyboard tab changes that leave focus on the page.

[^task-78]: After Cmd+L and Return the page does not regain keyboard focus
[^task-128]: On launch the sidebar's hidden Search Archive field holds keyboard focus instead of the page
[^task-130]: Keyboard focus stays behind on a tab list whose page has slid off screen
[^task-131]: A focused tab list loses keyboard focus when the space list changes
[^notes-keyloop]: Key-view loop probe findings
