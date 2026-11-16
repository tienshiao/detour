---
type: Overview
title: Quick Detour
description: "A small window with one page for a quick lookup, after Arc's Little Arc, opened from a Spotlight-like launcher (File > New Quick Detour Window, or a system-wide hotkey, Opt-Cmd-N by default): what it is, the decisions it rests on, and the pages for each part."
tags: [window, tabs, history, privacy, extensions, palette]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193
    resource: backlog:TASK-193
    title: "Quick Detour: a minimal one-page window opened by a global hotkey"
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: reference
    resource: ../../docs/little-window/arc-little-arc.png
    title: Arc's Little Arc, the visual reference
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/QuickDetour.swift
    title: QuickDetour.swift (history scope, which profile, palette scope)
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
  - id: code-dir
    resource: ../../Detour/Browser/QuickDetour
    title: Detour/Browser/QuickDetour (every Quick Detour source file)
---

A Quick Detour is a small window with one web view, for looking something
up without opening a tab in any space (after Arc's Little Arc; the name is
the user's choice, TASK-193). This page says what it is and links the pages
for each part; the code is under
[Detour/Browser/QuickDetour](../../Detour/Browser/QuickDetour).

# Summary

- **Opening.** File > New Quick Detour Window, or the global hotkey
  (Opt-Cmd-N by default, pressed in any app), shows the launcher panel: the
  command palette alone, centred like Spotlight. Submitting opens the window
  on that page; Escape or clicking away opens nothing, so no Quick Detour
  window ever has an empty page. Opt-Cmd-click on a link or a sidebar tab,
  the link menu, and links from other apps through Link Routes open one too.
- **The window.** 900 × 640 points, several at once, no sidebar. A title bar
  with a back button, an address capsule (the profile pill, the host,
  pinned extensions, Copy Link, site settings) that opens the palette and
  shows load progress, and **Open in <Space> ⌘O**.
- **The page is a tab in no space**: a `BrowserTab` in
  `TabStore.quickDetourTabs`, hosted only by its window, never saved with
  the session.
- **Decisions of TASK-193.1** (user, 2026-10-25): history recorded under a
  per-profile scope that is no space, labelled "Quick Detour" on the
  History page; open windows not restored at launch; Private allowed (the
  Private profile, no history); extensions see the window as a `popup`
  window with one tab.
- **Leaving it.** Open in moves the page into a space (the same tab and web
  view within a profile, a reload across profiles); the profile pill
  reloads the address on another profile in the same window; a close, a
  quit or the idle timer sends it to the Archived Tabs page, from which it
  reopens as a Quick Detour.

# Pages

| Page | What it covers |
|---|---|
| [Launcher panel](./quick-detour-launcher.md) | the non-activating floating panel, its suggestions and undo, which profile a new Quick Detour uses, activating Detour with only the new window forward |
| [Global hotkey](./quick-detour-hotkey.md) | the Carbon registration, conflicts (measured), where it registers, the toggle, the Settings recorder, layout limits |
| [Window and its page](./quick-detour-window.md) | the window, undo, the tab in no space, links and windows the page opens, no session restore, Private, extensions, teardown, edge cases |
| [History scope](./quick-detour-history.md) | the per-profile scope id, the History page label, the launch sweep, the rejected migration, palette suggestions |
| [Title bar](./quick-detour-title-bar.md) | the bar's layout, the site settings popover, drag handles, the back button, the whole capsule and its load progress |
| [Open in <Space>](./quick-detour-open-in.md) | Cmd+O: the default space, the dropdown, the hand-over steps, another profile's reload, Private, extension events |
| [Profile pill](./quick-detour-profile-pill.md) | the menu, switching as a new tab in the same window, consequences, into and out of Private |
| [Entry points](./quick-detour-entry-points.md) | Opt-Cmd-click on a link, the link menu, a sidebar tab's copy, links from other apps |
| [Archive and idle auto-close](./quick-detour-archive.md) | closed-tab rows under the scope, what is archived, the archive page and restore, the idle rule |
| [Dock menu](./quick-detour-dock-menu.md) | Hide All / Show All Quick Detour Windows |
| [Settings](./quick-detour-settings.md) | Settings > Quick Detour, its rows and defaults keys |
| [Tests and runtime checks](./quick-detour-tests.md) | the suites, what was written first, each runtime pass |

# Related

- [Peek](../tabs/peek.md) — the other tab in no space; a Peek hangs off a host tab, a Quick Detour off its own window.
- [History recording and search](./history-recording-and-search.md) — the scope the visits are filed under.
- [History page](./history-page.md) — the label.
- [Incognito](../architecture/incognito.md) — the Private session a Private Quick Detour shares.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — `ExtensionListedWindow` and the placement rule.
- [Command palette](./command-palette.md) — the palette the window opens with.
- [App shell](../architecture/app-shell.md) — the menu item, the Dock menu, and that not every window is a browser window.
- [Closed tabs and the archive](../tabs/closed-tabs-and-archive.md) — the records closed Quick Detours share.
- [Link Routes](./link-routing.md) — the Quick Detour target, and Opt-Cmd's place in the click rule.
- [Quarantine](./quarantine.md) — a Quick Detour on the Private profile whose page has a throwaway store of its own (TASK-194): its badge, Open in as a fresh load, downloads asked, the privacy protections.
