---
type: Feature
title: Quick Detour Open in <Space>
description: "Open in <Space> (Cmd+O) moves a Quick Detour's page into a tab of a space: which space the button names, the dropdown grouped by profile, the same BrowserTab and web view handed over within a profile (the ordered steps), a reload in another profile's space, Private into a Private window, history, extension events and the edge cases."
tags: [window, tabs, profiles, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-3
    resource: backlog:TASK-193.3
    title: "Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)"
  - id: task-210
    resource: backlog:TASK-210
    title: "Quick Detour: page settings menu, draggable bar, Open In and palette text"
  - id: task-307
    resource: backlog:TASK-307
    title: "Peek: ⌘O opens the Peek as a tab, a setting turns Peek off, and ⇧⌘T / ⌘Z reopen a closed Peek"
  - id: task-320
    resource: backlog:TASK-320
    title: "Command palette: browser commands (a shared command registry, also for AppleScript, Shortcuts and MCP)"
  - id: open-in
    resource: ../../Detour/Browser/QuickDetour/QuickDetourOpenIn.swift
    title: QuickDetourOpenIn.swift (the default space, the menu model)
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
---

**Open in <Space> ⌘O**, at the right of the [title bar](./quick-detour-title-bar.md), moves the page into a tab of a space and closes the window.

# What it does

TASK-193.3, the user's decisions of 2026-10-26. The capsule at the right of
the title bar: its main part, **Open in 💼 Work ⌘O**, moves the page to the
space it names; its chevron opens the dropdown. File > Open Quick Detour in
Space (⌘O) does what the main part does while a Quick Detour is key, its
title then naming the target ("Open in 💼 Work"; `validateMenuItem`, which
answers the [command registry](./browser-commands.md)'s `page.open-in-space`
rule since TASK-320, put back to the general title when the window resigns
key). Since TASK-307 a
browser window answers the same item too: "Open Peek in New Tab" while a
[Peek](../tabs/peek.md) is up, otherwise the general title, disabled; with
any other window key nothing answers it and it is disabled.

# Which space the button names

`QuickDetour.openInDefaultSpace` (decision 1): the space of the browser
window in front when the Quick Detour was opened (`sourceSpaceID`, which the
launcher already passed), while it still exists and is the window's
profile's; otherwise **the profile's most recently used space**:

- `TabStore.spaceUseOrder`, most recent first: a normal space is *used* when
  a browser window switches to it (`setActiveSpace`) or a window showing it
  becomes key (`windowDidBecomeKey`), through `noteSpaceUsed`. Private and
  unknown spaces are never recorded. In memory only, seeded at launch with
  the restored last active space (and by `ensureDefaultSpace`); deleted
  spaces are skipped when read, not pruned.
- `QuickDetour.mostRecentlyUsedSpace(ofProfile:)`: the first of that order
  that is a normal space of the profile, else the profile's first space in
  sidebar order.
- A profile with no space at all (possible: the first normal profile is
  used when no browser window is in front) names the most recently used
  space of any profile, which then reloads (the button's tooltip says so).
  No normal space anywhere: the capsule is hidden.

It is computed live (`openInMenu`), refreshed when the spaces change and
when the window becomes key: a deleted source space falls back at once.
A window the page opens and a Cmd+click Quick Detour inherit the source
space, so they name the same space.

# The dropdown

`QuickDetour.openInMenu` (decision 2): every normal space of every live
profile, one section per profile with spaces, **the window's own profile
first** (its spaces keep the page) and the others in profile order, spaces
in sidebar order, each "emoji name". Section headers
(`NSMenuItem.sectionHeader`, the profile's name) only when more than one
profile has spaces. Another profile's spaces carry a tooltip naming what
changes (that profile's cookies and sign-ins, no back/forward history): the
subtle mark the decision asked for. A "Reloads the page" subtitle under
their names was dropped at the user's request (TASK-210).
The default item shows ⌘O as its key equivalent. Private and deleted
profiles' spaces never appear.

# The same profile: the page moves intact

`QuickDetourWindowController.handOver`, the same idea as
`expandPeekToNewTab` ([Peek](../tabs/peek.md)) but without a second object:
**the Quick Detour's own `BrowserTab` moves**, so its id, its web view, its
back/forward list, scroll position, typed form text, `window.opener`, a load
in flight and its extension registration all survive.

| Step | Who | What |
|---|---|---|
| 1 | Quick Detour | `releasePage`: palette and find bar (matches cleared) closed, popovers closed, link status hidden, its subscriptions on the page dropped, its delegates and script handlers taken off the web view, the web view's container removed from its content view |
| 2 | `AppDelegate.placeTab` | The Link Routes placement (`linkPlacement`): a window showing the space, else the most recent normal window switched to it, else a new window on it |
| 3 | `makeTab` → `TabStore.moveQuickDetourTab(_:into:announcingMove: false)` | out of `quickDetourTabs`, unsubscribed, `quickDetourProfile` cleared, `insertTab` at the new-tab position (no parent: the top of the list), subscribed as a space's tab (saved with the session from now on); observers get `tabStoreDidInsertTab` then `tabStoreDidMoveQuickDetour`, **never** `tabStoreDidCloseQuickDetour` |
| 4 | the browser window | `selectTab`: the container has no superview, so it claims the web view at once (delegates, its own script handlers) rather than showing a snapshot |
| 5 | `didSelect`, inside `holdingExtensionActivation` | `ExtensionTabLifecycle.didMove(tab, fromIndex: 0, in: quickDetour)`, then the window's own `didActivate` |
| 6 | the browser window | `makeKeyAndOrderFront` |
| 7 | Quick Detour | `window.close()` → `tearDown`: `tab` no longer resolves (it is not in `quickDetourTabs`), so it closes nothing in the store and lists no tab; `didCloseWindow` sends only `windows.onRemoved`; it leaves `openControllers` and is released |

The order is the risky part. Step 1 before step 4 is what lets the browser
window claim the web view instead of snapshotting a page still parented in
the Quick Detour. Step 7 last, and keyed on the store, is what keeps the
close from tearing the page down. Checked by a leak test: the controller is
released, the web view is not, and lives in the browser window. Should no
window take the page (a space gone meanwhile), the Quick Detour hosts it
again and stays open.

**Refused** (nothing changes): across the Private boundary either way, into
a space that is no longer in the store, a tab that is not an open Quick
Detour's, a page without a web view (`canMoveQuickDetourTab`).

**Not while a sheet is up.** `open(in:)` does nothing while the window has
an attached sheet, and `validateMenuItem` disables Cmd+O then (found in the
code review; since TASK-320 the fact is the window's `canOpenInSpace`, read
by the registry's rule). The page's `alert()`/`confirm()`/`prompt()`, a file panel, a
camera or microphone question and HTTP sign-in all run as sheets on the
Quick Detour window, whose completion WebKit (or the page's process) is
waiting on; moving the page from under one, then closing the window, left
the sheet's completion running against a torn-down window — a crash.
Dismiss it first, and Cmd+O works again (tested with a sheet and with a
real page alert, both failing with the guard removed; checked at runtime).
Cmd+O is also disabled when the target is another profile's space and the
page has no URL to reopen. And a link routed to Private never falls back to
the most recent normal space when it could not be placed (`openLink`).

# Another profile: the address reloads there

`reopen`: a new tab of that space on `tab.url` (an internal page the user
had opened is opened as one, never through `addTab(in:url:)`), placed by the
same rule; then the window closes as on Cmd+W, taking its page and web view
down, but with `closeDisposition = .discard`, so it writes no
[archive](./quick-detour-archive.md) record (the page lives on in the space). That profile's data store, so its cookies; the back/forward history is
lost (decision 2; rejected: listing the same profile's spaces only).

# Private

Decision 3: **Open in Private Window ⌘O**, no dropdown (the only
destination; a one-item menu would add nothing). The page moves intact,
as above, into the most recent Private window, else a new one
(`placeInNewPrivateWindow`: a Private window holding only the page, no empty
tab of its own). The same Private store, no reload; the Private session
stays live throughout (`hasLivePrivateSession`).

# History

The visits recorded while it was a Quick Detour stay under the profile's
Quick Detour scope; from the move on `historySpaceID` is the space's
(`spaceID` set, `quickDetourProfile` cleared), so later visits are the
space's. A load in flight when the page moves finishes in the space and its
visit is the space's.

# Extensions

Within one profile it is a **move of the same tab** (WebKit's
`didMoveTab`): `tabs.onDetached` from the popup window (`oldPosition` 0),
`tabs.onAttached` to the browser window with its position, then
`tabs.onActivated` there, then `windows.onRemoved` for the popup. No
`tabs.onRemoved`, no second `tabs.onCreated`; `tabs.get(id)` now names the
browser window. The move is announced once the receiving window has the tab
selected: WebKit lists a window's tabs only while one is selected, and
announced earlier the attach arrived with `newPosition: null`
(see [tab and window bridge](../extensions/tab-and-window-bridge.md)).
Another profile's extensions hear nothing. Across profiles it is a close
and a create: `tabs.onRemoved` and `windows.onRemoved` for the Quick
Detour's profile, `tabs.onCreated` for the other's.

# Edge cases decided

| Case | Decision |
|---|---|
| The source space was deleted | the button falls back at once (the profile's most recent) |
| The page is mid-load | moved as it is; the load finishes in the space, its visit the space's |
| Find bar or palette open | closed by `releasePage`; the find matches cleared |
| A Peek | a Quick Detour has none; one over the receiving window's selected tab is put away as on any tab switch |
| A download in flight | normal: `.normal`, listed in every normal window already, untouched. Private: **its scope moves with the page** (`DownloadManager.moveIncognitoDownloads`, from `tabStoreDidMoveQuickDetour`): listed in the receiving Private window and cancelled, after asking, when that window closes, as the Private download rules do for a window's own |
| The profile was deleted | its Quick Detours close with it (unchanged); a target space of a deleted profile is never listed |
| A page-opened Quick Detour (`window.opener`) | the same web view moves, so the opener relationship is kept both ways; a reload in another profile loses it |

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Peek](../tabs/peek.md) — `expandPeekToNewTab`, the same idea with a second object, and the Cmd+O item a browser window answers.
- [Browser commands](./browser-commands.md) — the `page.open-in-space` rule.
- [Link Routes](./link-routing.md) — `linkPlacement`, which places the page.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — why the move is announced after selection.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
