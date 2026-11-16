---
type: Feature
title: Quick Detour archive and idle auto-close
description: "Where closed Quick Detours go: closed-tab rows under the profile's Quick Detour scope (no migration), what writes one (closed, at quit, auto-closed) and what does not, the Archived Tabs listing and restore, and the idle auto-close (a pure wall-clock rule, what counts as use, the periodic and wake check, a Debug override)."
tags: [window, archive, tabs]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: entry-points
    resource: ../../Detour/Browser/QuickDetour/QuickDetourEntryPoints.swift
    title: QuickDetourEntryPoints.swift (the settings, the Opt-Cmd click, the routed link's profile, the idle rule)
  - id: idle-monitor
    resource: ../../Detour/Browser/QuickDetour/QuickDetourIdleMonitor.swift
    title: QuickDetourIdleMonitor.swift
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
---

A closed Quick Detour goes to the sidebar's Archived Tabs page, labelled "Quick Detour", and so does every open one at quit and one left unused for the configured time, "auto-closed".

# What it does

TASK-193.5, decisions 3 and 4 (user, 2026-10-26): a Quick Detour closed by hand, at quit or
by the idle timer goes to the sidebar's Archived Tabs page (all spaces),
labelled; restoring one reopens a Quick Detour window on that profile.

# Storage: a closed-tab row under the profile's Quick Detour scope

A closed Quick Detour is a `closedTab` row like a closed tab's
([closed tabs and the archive](../tabs/closed-tabs-and-archive.md)), with
`spaceID` = the profile's Quick Detour scope
(`QuickDetour.historySpaceID(forProfileID:)`, the id its visits are filed
under). **No migration.** Every existing query is keyed by a space id and
no space has that id, so each stays correct unchanged: Reopen Closed Tab
(the active space's records) never offers one, a space's deletion and its
undo never touch them, the session save (no foreign key on `closedTab`)
keeps them. Only the archive page's listing, its "has records" check and
Clear needed to know the scopes. `archivedAt` marks the idle timer's
close, as it marks the archive sweep's for a tab; a close by hand or at
quit is a plain close (`archivedAt` nil). `tabID`, `url`, `title`,
`faviconURL`, `interactionState` (the back/forward list) and `extensionID`
are captured as for a tab; `sortOrder` is 0. Rejected: a `kind` or
`profileID` column (a migration, and every closed-tab query would have had
to learn to skip the new rows); filing under a space of the profile (it
would be reopened by Cmd+Shift+T there and deleted with that space).

| When | Record |
|---|---|
| Closed by hand (Cmd+W, the close button), or by an extension's `tabs.remove` | a plain close: "Quick Detour" |
| Auto-closed by the idle timer | `archivedAt` set: "Quick Detour · auto-closed" |
| Quitting (`applicationWillTerminate` → `TabStore.archiveOpenQuickDetours`) | a plain close for every open one; their windows stay until the app exits, and `quickDetourTabIDsArchivedAtQuit` keeps a later close from writing a second |
| Moved by Open in (same profile: handed over; another profile: reloaded there) | nothing: the page lives on in the space |
| Replaced by the profile pill | nothing: a switch, not a close |
| Its profile deleted | nothing, and its archived ones are deleted with the profile (`deleteProfile`) |
| A Private Quick Detour | never, whatever closes it, as Private tabs never write a record |
| A page with no address | nothing |

`TabStore.closeQuickDetourTab(_:disposition:)` takes
`QuickDetourCloseDisposition` (`.archive(autoClosed:)`, the default, or
`.discard`), and writes the record before the teardown releases the web
view the back/forward list is read from. The window passes its
`closeDisposition` from `tearDown`.

# The archive page

`archiveEntries()` lists, beside the spaces' records, those under the Quick
Detour scope of a live normal profile, as `ArchiveEntry.kind =
.quickDetour(profileID:autoClosed:)` (a scope of a profile no longer there
is not listed). The row's second line is `archiveEntrySubtitle`: "Quick
Detour · example.com/page", or "Quick Detour · auto-closed · …". No space
badge. A space filter hides them (they are no space's); with no filter
Clear Archive… and Navigate > Clear Archived Tabs… cover them
(`archiveClearScope`, `TabStore.quickDetourArchiveScopeIDs`). Retention is
the archive's: none — they stay until deleted or cleared.

# Restoring

A click (Return, the context menu) on a Quick Detour entry calls
`BrowserWindowController.restoreArchivedTab`, which sees
`isQuickDetourArchiveRecord` and calls `QuickDetourWindowController.restore(recordID:sourceSpace:)`:
`TabStore.takeQuickDetourArchiveRecord` consumes the record and returns
its page (`QuickDetourArchivedPage`), and a new window opens on that
profile, its tab built by `openQuickDetourTab(profile:restoring:)` —
`BrowserTab.restoreArchivedPage`, the closed-tab rebuild factored out:
the back/forward list (else the address), the archived title (until the
page reports its own) and favicon. Its Open in names the restoring
window's space when it is the same profile's. The sidebar leaves the
archive page. An extension's page comes back on its live origin without
its back/forward list; a disabled extension's is not restorable (listed
dimmed); an uninstalled one's record is purged — the closed-tab rules.

# Idle auto-close

A Quick Detour not used for the configured time closes into the archive as
auto-closed. Settings > Quick Detour: Never, 1 hour, **6 hours**
(the default, as Arc's), 12 hours, 1 day.

**The rule** is pure, `QuickDetour.shouldAutoClose(_:now:interval:)` over
`QuickDetourIdleState`: it closes once `now - lastUsedAt >= interval`, on
the wall clock, and **never** while the window is frontmost (the key
window, or the front one of Detour's browser and Quick Detour windows,
visible and not minimized — Detour may be in the background with it on
screen), while its page plays sound (`BrowserTab.isAudible`: playing and
not muted), while a sheet is up (a page's dialog or a file panel, whose
completion would outlive the window), or when it is **Private** (decided
here: nothing would be archived, so the timer would simply lose it). A
clock set back never closes one. A window hidden by the [Dock menu](./quick-detour-dock-menu.md)
is not visible, so never frontmost, and still closes (TASK-309).

**What counts as use** (`QuickDetourWindowController.noteUse`): opening or
restoring the window; becoming key, and ceasing to be key (key until then);
a key press, a mouse-down (any button), a scroll, a magnify or swipe in it
(`QuickDetourWindow.sendEvent` — a scroll reaches a window that is not
key, so reading one beside another app counts); and its page starting or
stopping sound. **Navigation alone does not**: a page can reload or
navigate itself, and one the user starts follows input in the window.

**Timing** (`QuickDetourIdleMonitor`): a repeating check every 60 s (10 %
tolerance, `.common` mode) and one on `NSWorkspace.didWakeNotification`,
each asking the rule about every open window, rather than one long timer
per window: a timer does not fire while the Mac sleeps, and the rule is on
the wall clock, so **time asleep counts as time unused** — a Mac asleep
overnight closes the Quick Detours left behind on wake (except the
frontmost). Not started in the XCTest host, whose tests drive `check()` on
an injected clock (`now`) and settings. **Debug override**:
`DETOUR_QUICK_DETOUR_IDLE_SECONDS=<n>` replaces the interval of any setting
but Never and checks every n/4 seconds (at least 1, at most 60); read in
Debug builds only.

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Closed tabs and the archive](../tabs/closed-tabs-and-archive.md) — the records closed Quick Detours share.
- [Quick Detour history scope](./quick-detour-history.md) — the scope id the rows are filed under.
- [Quick Detour Dock menu](./quick-detour-dock-menu.md) — hidden windows still auto-close.
- [Quick Detour settings](./quick-detour-settings.md) — the idle pop-up.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
