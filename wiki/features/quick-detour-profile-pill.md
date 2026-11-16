---
type: Feature
title: Quick Detour profile pill
description: "The profile pill in a Quick Detour's address capsule (TASK-193.4): its menu, switching reloading the address in a new BrowserTab on the other profile in the same window, what that means for extensions, history, Open in and the palette, into and out of Private with the download question, and the edge cases."
tags: [window, profiles, privacy, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-4
    resource: backlog:TASK-193.4
    title: "Quick Detour: a profile selector in the title bar"
  - id: task-209
    resource: backlog:TASK-209
    title: "Command palette: scope suggestions to the palette's profile"
  - id: profile-switch
    resource: ../../Detour/Browser/QuickDetour/QuickDetourProfileSwitch.swift
    title: QuickDetourProfileSwitch.swift (the pill's menu, the switch decision)
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
  - id: palette-scope
    resource: ../../Detour/Browser/CommandPalette/PaletteTabScope.swift
    title: PaletteTabScope.swift (historySpaceIDs)
---

The pill at the left of the address capsule in the [title bar](./quick-detour-title-bar.md) names the window's profile and switches it.

# What it does

TASK-193.4. The pill at the left of the address capsule shows the window's
profile: a person symbol (eyeglasses for Private) and the profile's name —
profiles have no icon, emoji or colour of their own — with a small
up-and-down chevron saying it is a menu. It follows a rename
(`TabStore.updateProfile`'s notification). Pressed, it opens its menu at
once, as a pop-up button does (`QuickDetourProfilePill`: the menu tracks the
rest of the click, and the pill never drags the window as the title bar
around it does; accessibility role pop-up button). It shows itself pressed
(a stronger fill) while its menu is open, reported to the title bar through
`onHighlightChange`.

# The menu

`QuickDetour.profileMenu`: every live normal profile in the store's order,
then **Private last, after a separator**; deleted profiles left out; the
window's own profile checked. With only one profile it lists that one and
Private. Each other profile's item has a tooltip saying what a switch does:
"Reload this page in Work: its cookies and sign-ins, without this page's
back and forward history" — the subtle mark of the reload (decided: a
tooltip only; a subtitle on every item, as Open in's "Reloads the page"
was until TASK-210, would mark every row the same).

# Switching: a new page in the same window

`QuickDetourWindowController.switchProfile(to:)` reloads the page's address
on the chosen profile in a **new web view**, in the **same window**.

**Why a new `BrowserTab` rather than swapping the web view inside the old
one.** A web view's data store is fixed when it is made, so another profile
always means another web view. Replacing the whole tab
(`TabStore.replaceQuickDetourTab`) makes every consequence the one a close and
a new Quick Detour already have: the old tab's `teardown` reports its close
to its own profile's extensions, its history scope and Private-session
membership go with it, and the new tab is built and subscribed exactly as
`openQuickDetourTab` builds one. Only the archive differs: the old page is
taken down (`takeDownQuickDetourTab`) without a closed-tab record, a switch
not being a close ([archive](./quick-detour-archive.md)). Swapping the web view inside one tab would
have kept a tab id across two profiles' extension contexts (WebKit maps a
tab to a web view and a context; `didCreateWebView` re-announces within one
profile only), and left `quickDetourProfile`, the history subscription and
the Private bookkeeping to be changed in place. **Why the same window, not a
new one:** the window keeps its frame, its place among the windows, its
full-screen or zoomed state and its source space; only the page changes.

| Step | Who | What |
|---|---|---|
| 1 | Quick Detour | refused while a sheet is up, for the same profile or a deleted one; leaving Private with Private downloads running asks first (below) |
| 2 | Quick Detour | `releasePage`: palette, find bar, popovers and link status closed, its subscriptions and delegates on the old web view dropped, the container out of the content view |
| 3 | `replaceQuickDetourTab` | the old tab out of `quickDetourTabs`, unsubscribed and torn down: `tabs.onRemoved` for the old profile's contexts |
| 4 | the hook, between the pages | `didCloseWindow` to the old profile's contexts (`windows.onRemoved`; the window lists no tab now), the window takes the new profile and a new tab id (the palette reads the profile's history when it is next shown), `didOpenWindow` to the new profile's contexts (`windows.onCreated`, a `popup`) |
| 5 | `replaceQuickDetourTab` | a new tab on the new profile's configuration enters `quickDetourTabs` (`tabs.onCreated` in that popup); the Private session ends if the old page was its last user; observers hear `tabStoreDidReplaceQuickDetour`, **never** `tabStoreDidCloseQuickDetour` (which would close the window) |
| 6 | Quick Detour | the pill, the window's appearance (dark for Private), Open in and the extension buttons follow the profile; the new web view is hosted and loads the address (`loadRecordedURL`) |

**The address** is the old tab's `url`: the page's own, also while a load is
in flight (the URL being loaded) or an error page is showing (the URL that
failed). An internal page the user had opened (the History page) is reopened
as one, now on the new profile. The load is not a typed visit.

**What is lost**, decided and acceptable for a quick lookup: the
back/forward history, text typed into a form, the scroll position, the zoom
level, and `window.opener` both ways (a page-opened Quick Detour's opener
stays on the old profile's page, which is gone). A Quick Detour the page had
opened keeps its own profile.

# Consequences

| | Old profile | New profile |
|---|---|---|
| Extensions | `tabs.onRemoved` for the page, then `windows.onRemoved` for the popup; both refused by id afterwards | `windows.onCreated` (`popup`, `incognito` for Private), then `tabs.onCreated` in it; listed by `windows.getAll`; the active tab announced |
| History | the visits so far stay under its Quick Detour scope | from the switch on, its Quick Detour scope; **nothing** for Private |
| Open in | — | follows at once: the button and the dropdown are the new profile's (the source space no longer matches unless it is the same profile's, so the button names the new profile's most recently used space; switching back names the source space again); Private: Open in Private Window, no dropdown |
| Palette | — | suggests from the new profile's whole history, its spaces and its Quick Detour scope (`PaletteTabScope.historySpaceIDs`, read when the palette is next shown; TASK-209); nothing for Private |

A third profile's extensions hear nothing. Switching back is a new popup
window for the first profile's contexts, not the one they were told closed
(WebKit forgets a closed window, `forgetWindow`, so the same controller
reported open again gets a new window id).

# Private

- **Into Private** it is a Private Quick Detour from then on: the profile's
  non-persistent store, no history, a dark window, Private downloads scoped
  to the new tab's id, and a user of the Private session
  (`hasLivePrivateSession`), with the Private site settings' lifetime.
- **Out of Private**, with Private downloads still running in the window,
  the switch asks first, as closing it would (`QuickDetour.profileSwitchDecision`):
  "Switch to Work?" / "1 download is in progress. Leaving Private browsing
  cancels it." with **Switch Profile** (cancels them, removing the partial
  files, and switches) and **Continue Downloading** (Escape: nothing
  changes). Decided over moving them to the new page: a Private download
  must not be listed, or keep running, under a normal profile. Ended Private
  downloads go with the old page, unasked. The Private session then ends if
  this was its last page.

# Edge cases decided

| Case | Decision |
|---|---|
| The same profile chosen | nothing |
| The page is mid-load | the address being loaded reloads on the new profile |
| A form with typed text | lost with the old page |
| A sheet is up (alert, file panel, permission or sign-in prompt) | refused, and the pill opens no menu: its completion would outlive its web view |
| The profile is deleted while its Quick Detour is open | the window closes, as before; after a switch that is the profile switched to (`closeQuickDetourTabs(of:)` matches the new tab) |
| The chosen profile is deleted, or a sheet is put up, while the question is up | nothing switches and the downloads keep running: they are cancelled only once the switch is certain (found in the code review) |
| Only one profile | the menu shows it and Private |

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Quick Detour window and its page](./quick-detour-window.md) — the tab the switch replaces, and Private.
- [Quick Detour launcher panel](./quick-detour-launcher.md) — which profile a new Quick Detour starts on.
- [Incognito](../architecture/incognito.md) — the Private session a switch joins or leaves.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
