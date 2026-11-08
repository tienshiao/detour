---
id: TASK-307
title: >-
  Peek: ⌘O opens the Peek as a tab, a setting turns Peek off, and ⇧⌘T / ⌘Z
  reopen a closed Peek
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T10:00:00Z'
updated_date: '2026-11-08T11:06:00Z'
labels:
  - peek
dependencies: []
references:
  - TASK-292.6
priority: medium
ordinal: 368000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Three Peek behaviors Arc had (Arc's Peek help article; Arc for macOS 2023 release notes: "CMD Z and CMD SHIFT T will now reopen a closed Peek, like they re-open closed tabs") that Detour lacks. The website's Peek guide page (TASK-292.6) lists them under "Not in Detour" today. Requested by the user, Nov 8 2026.

1. A shortcut that opens the Peek as a tab. Arc used ⌘O ("open Peek in a new tab"). Today the only way is the Open in New Tab button next to the Peek. ⌘O is File › Open Quick Detour in Space, enabled only while a Quick Detour is key (AppDelegate ~718, QuickDetourWindowController.openInDefaultSpace); a browser window with a Peek up could take the same key for the same idea ("move this preview into a tab"), via its own menu item or validation.
2. A setting that turns Peek off. Arc had one (Arc › Settings › Links). With Peek off, links from pinned tabs and favorites to other sites (and target=_blank / window.open in them) open as new tabs instead of Peeks; whether Shift-click still peeks, and whether the setting is app-wide or per Profile, are to be decided.
3. Reopening a closed Peek with ⇧⌘T (Reopen Closed Tab) or ⌘Z, like a closed tab. A closed Peek leaves no closed-tab record today (BrowserWindowController.closePeekOverlay/hidePeekUI, BrowserTab.peekTab = nil); reopening means recording it (URL, interaction state, host tab) and restoring it as a Peek on its host if the host is still open, else as a tab.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With a Peek up in a browser window, ⌘O (or the agreed key) opens the Peek's page as a new tab exactly as Open in New Tab does, listed in a menu with the key; Quick Detour's ⌘O is unchanged
- [x] #2 A Peek setting exists (scope and Shift-click behavior agreed with the user); with Peek off, links that would auto-peek from pinned tabs and favorites open in new tabs
- [x] #3 Closing a Peek can be undone with ⌘Z and reopened with ⇧⌘T: it comes back as a Peek on its host tab with its page and scroll state, or as a tab when the host is gone; Private windows follow their existing closed-tab rules
- [x] #4 Tests cover the setting's effect on the auto-peek rule, the closed-Peek record and both reopen paths
- [x] #5 Checked at runtime with /verify
- [ ] #6 The website's Peek guide page moves these from Not in Detour to how-to steps
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Cmd+O: the File menu keeps one Cmd+O item (action openInDefaultSpace(_:)); BrowserWindowController implements the same selector (expandPeekToNewTab while a Peek is presented) and validates it: titled 'Open Peek in New Tab' and enabled only with a Peek up, else the Quick Detour title, disabled. Quick Detour's own validation unchanged; the File menu is matched natively by AppKit (not MenuKeyEquivalentMatcher).
2. Setting: PeekSettings (UserDefaultsScope, key PeekEnabled, default on) with a checkbox in Settings > General. Pure rules in PeekAnchor: anchoredLinkAction(anchorURL:to:opensNewWindow:peekEnabled:) -> none/peek/newTab and scriptedWindowPeeks(to:wantsPopup:peekEnabled:). With Peek off a plain cross-host link opens a new tab (selected), _blank and window.open are left to WebKit's new window (a tab). Shift-click untouched.
3. Closed Peek: migration v23 adds closedTab.peekHostTabID. BrowserWindowController.closePeekOverlayByUser (Close button, click outside, Escape, Cmd+W) calls TabStore.recordClosedPeek (row unless Private, undo 'Close Peek'). Reopen paths (Reopen Closed Tab, Archived Tabs page, Undo) go through reopenClosedPeek: host still a live tab of the space with no Peek -> its parked-Peek fields (peekURL, peekInteractionState, favicon) are set and the host is returned/selected, which presents the Peek; else a tab at the host's position. Hidden (tab switch), expanded, replaced or extension-removed Peeks record nothing.
4. Tests: PeekAnchorTests (setting rule + PeekSettings), ClosedPeekTests (record, Private, reopen host open/gone/busy, pinned host, archive restore, undo incl. consumed record and host gone), PeekWindowCommandsTests (Cmd+O validation/expand, undo in a real window, extension close not recorded).
5. Runtime check of all three; wiki peek.md, closed-tabs, session-database.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: the Peek setting is app-wide (Settings › General); with Peek off, auto-peek from pinned tabs/favorites opens new tabs, but Shift-click still peeks (explicit request). ⌘O is the key for opening a Peek as a tab.

Implemented as planned. Files: BrowserWindowController.swift (closePeekOverlayByUser for the Close button/click outside/Escape/Cmd+W; openInDefaultSpace(_:) + its validation), BrowserWindowController+Navigation.swift and +WKUIDelegate.swift (the setting), PeekAnchor.swift (AnchoredLinkAction, anchoredLinkAction, scriptedWindowPeeks, PeekSettings), GeneralSettingsViewController.swift (Peek section), TabStore.swift (ClosedPeek, recordClosedPeek, reopenClosedPeek, reopenClosedTabRecord hands peek rows over), Database.swift (v23 closedTab.peekHostTabID, selected in summaries), ClosedTabRecord.swift.

Decisions made here (conservative, recorded):
- One File-menu Cmd+O item: BrowserWindowController implements the Quick Detour's selector openInDefaultSpace(_:) and validates it ('Open Peek in New Tab', enabled only with a Peek presented; otherwise the existing Quick Detour title, disabled). No AppDelegate change. The File menu is matched natively by AppKit; MenuKeyEquivalentMatcher (delegate-driven menus) is not involved and its tests still pass.
- With Peek off: a plain cross-host link in a pinned tab/favourite opens a new tab after it, selected (not in place, which would take the pinned tab off its site); _blank and tab-style window.open are left to WebKit's new window, which becomes a tab. Link Routes still win. Shift-click still peeks.
- What counts as a close: only the user's explicit close (Close button, click outside, Escape, Cmd+W on the Peek). Hiding by a tab/space switch, parking (host sleeps), expanding into a tab or split, replacing with another Peek, and an extension's tabs.remove record nothing.
- Reopen: host still a live tab of the space (normal, pinned or favourite) with no Peek of its own -> back as the host's parked Peek (peekURL + interaction state + favicon) and the host is selected, which rebuilds it with its page and scroll position; otherwise a tab at the record's position (after the host). A host showing another Peek keeps it; the closed one comes back as a tab. The undo registers no redo. Private windows: no record (Reopen Closed Tab has nothing), Undo works. The Archived Tabs page lists closed Peeks as ordinary rows and restores them the same way; extension sessions.restore returns the host for such a row.

Tests: PeekAnchorTests 29 (6 new: setting on/off for plain, _blank, same-host, scripted, PeekSettings default/persist), ClosedPeekTests 11 (record, Private, reopen host open/gone/busy, pinned host, archive restore, undo, undo after reopen, undo with host gone, v23 migration from v22), PeekWindowCommandsTests 4 (Cmd+O validation and expand, Undo in a real window, extension close not recorded). Regression: ExtensionActiveTabTests 15, PeekStateTests 11, ArchivedTabRestoreTests 20, TabStoreTests 40, AppDatabaseTests 28, SettingsPaneColumnsTests 22, SplitOpeningTests 20, PeekHistoryTests 7, QuickDetourOpenInWindowTests 17, MenuKeyEquivalentMatcherTests 15: all pass.

Runtime (Nov 8, DetourB8-307-1/-2, temp harness posting real keys and clicks, local python http.server on 127.0.0.1:8762 and localhost:8762 as the second host):
- Cmd+O: with a Shift-click Peek up the File item read 'Open Peek in New Tab' enabled (Cmd+O); a posted Cmd+O opened the Peek as a tab (selected 'Long Peek'); without a Peek the item read 'Open Quick Detour in Space', disabled. With a Quick Detour key the item read 'Open in 🏠 Home', enabled, and a posted Cmd+O moved the Quick Detour into the space (window closed, tab added): unchanged.
- Close/reopen: Peek scrolled to 1500 px; Escape closed it (undo 'Close Peek', Reopen enabled); posted Cmd+Z brought it back presented, scrollY 1500. A click outside closed it; Reopen Closed Tab brought it back, scrollY 1500. Cmd+W closed the Peek, Cmd+W the host; Reopen once -> the host (new id), Reopen again -> the Peek as a tab (host gone). In a Private window: Escape then Cmd+Z brought the Peek back; Reopen Closed Tab disabled (no record).
- Setting: off -> plain cross-host link in a pinned tab opened 'Other Page' as a new selected tab, a _blank link opened another tab, Shift-click opened a Peek; on -> the plain link opened a Peek. Settings > General captured with the Peek section (content height 164).
browser.db closedTab rows carried peekHostTabID. WebKit store dirs for DetourB8-307-1/-2 left under ~/Library/WebKit/com.detourbrowser.mac.

Website facts for AC #6 (Peek guide page; move from Not in Detour to how-to steps):
- Open a Peek as a tab: File > Open Peek in New Tab, ⌘O (same as the Peek's Open in New Tab button). In a Quick Detour ⌘O is still File > Open in <Space>.
- Turn Peek off: Settings > General > Peek > 'Open links from pinned tabs and favorites in a Peek' (on by default, applies to the whole app). Off, links to other sites from pinned tabs and favorites (and links that open a new window, and window.open) open in new tabs. Shift-click still opens a Peek.
- Reopen a closed Peek: after closing a Peek (close button, Escape, ⌘W or a click outside), Edit > Undo (⌘Z) or File > Reopen Closed Tab (⇧⌘T) brings it back as a Peek on its tab, at the page and scroll position it had. If that tab has been closed, it comes back as a tab. Switching tabs does not close a Peek, and opening it as a tab is not a close. In Private windows ⌘Z works but Reopen Closed Tab does not (Private closes are not kept). Closed Peeks also appear on the Archived Tabs page.

Website AC pending (held for release).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Three Peek features. Cmd+O: the File menu's one Cmd+O item is answered by a browser window too (BrowserWindowController implements openInDefaultSpace(_:)), reading 'Open Peek in New Tab' and enabled only while a Peek is up; Quick Detour's Cmd+O is unchanged. Setting: Settings > General > Peek ('Open links from pinned tabs and favorites in a Peek', app-wide, default on); off, auto-peek links open as tabs through the pure PeekAnchor.anchoredLinkAction / scriptedWindowPeeks, and Shift-click still peeks. Reopen: a user-closed Peek (Close, click outside, Escape, Cmd+W) is a closed-tab row with peekHostTabID (v23) plus an undo 'Close Peek'; Undo, Reopen Closed Tab and the archive page bring it back as the host's Peek (page and scroll state) while the host is open, else as a tab; Private follows tab rules. Tests in PeekAnchorTests, ClosedPeekTests, PeekWindowCommandsTests and affected suites pass; all three parts checked at runtime with posted events. Website AC pending (facts in notes).
<!-- SECTION:FINAL_SUMMARY:END -->
