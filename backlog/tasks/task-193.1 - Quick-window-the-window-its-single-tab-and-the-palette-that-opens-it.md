---
id: TASK-193.1
title: 'Quick Detour: the window, its single tab and the palette that opens it'
status: Done
assignee: []
created_date: '2026-10-24 10:10'
updated_date: '2026-10-26 04:17'
labels:
  - window
  - feature
dependencies: []
parent_task_id: TASK-193
priority: medium
ordinal: 225000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First part of TASK-193. A new window type: one web view, minimal title-bar chrome (traffic lights, profile pill, host in the centre, extension and copy-link buttons, Open in <Space> on the right; reference docs/little-window/arc-little-arc.png), no sidebar. Opened in-app first (a menu item, File > New Quick Window, Opt-Cmd-N while Detour is active) showing the command palette; Return opens the URL or search in the window; Escape on an empty palette closes it. Clicking the host reopens the palette in place.

Model: the window's tab is a BrowserTab in no space list (like a Peek), built with the window's profile's configuration; several quick windows may be open. Decide and record: where its visits are recorded (history is keyed by spaceID; options: a per-profile hidden space id, the profile's first space, or no history), whether open quick windows are restored at launch, whether Private is allowed, and how extensions see the tab (tabs API: windowId/type). Find bar, zoom, back/forward keys work as in a normal window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A quick window opens from the menu and Opt-Cmd-N in-app, showing the palette; Return loads the page in its single web view; closing it tears the tab down cleanly
- [x] #2 The chrome matches the reference layout (profile pill, host, copy link, extension button, Open in placeholder), light and dark
- [x] #3 History, session restore, Private and the extension tabs API behaviour are decided, implemented and recorded
- [x] #4 Checked at runtime; tab-model rules covered by tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-25):
1. History: visits are recorded under the window's profile with no space, labelled Quick Detour on the History page; searchable like any visit; no space's history is touched.
2. Session restore: open Quick Detour windows are not restored at launch; on quit they go to the archive (with the archiving of TASK-193.5), so they can be recovered from there.
3. Private: allowed, chosen in the profile pill (TASK-193.4); a Private Quick Detour has its own throwaway data store and records no history. Quarantine (TASK-194) relies on this.
4. Extensions: visible; the tabs API reports the page as a tab in a window of type 'popup'; content scripts and the extension button work (1Password fills logins there).

Correction (user, 2026-10-25): Opt-Cmd-N (and the menu item) opens a palette-only window like Spotlight: a standalone command palette panel, centred, with no web view. Entering or selecting closes the panel and opens the Quick Detour web view window with the page; Escape or clicking away closes the panel and opens nothing. The host in an open Quick Detour's title bar still reopens the palette in place. TASK-193.2's global hotkey reuses the same panel.

2026-10-25 implementation:
- Entry: File > New Quick Detour Window and Opt-Cmd-N (free in the menus) open a Spotlight-style launcher panel (borderless non-activating NSPanel, canBecomeKey, floating, joins all Spaces, 560x321 centred on the key window's screen or the screen under the pointer). Return/selection closes it and opens the window already loading the page; Escape on an empty field or the panel resigning key closes it, nothing opens. Suggestions come from the profile the window will use; no open-tab rows (switching would bring a browser window forward). One panel at a time.
- Window: normal level, 900x640 (min 480x320), cascading 22 pt; no sidebar. Title bar: profile pill (name only; menu is 193.4), host (click or Cmd+L reopens the palette in place), extension buttons, copy link, 'Open in <Space> ⌘O' visible but disabled (193.3; hidden for Private). Find, zoom, back/forward, reload, Cmd+W; Cmd+click and page-opened windows open another Quick Detour (page-opened keeps window.opener). Dark-mode panel: Liquid Glass takes its brightness from what is behind a transparent panel, so it read grey over light windows; the launcher tints its glass (GlassContainerView.tintColor).
- Model: BrowserTab in TabStore.quickDetourTabs, in no space, built from the profile's configuration; the window is the only host of its web view (no ownership hand-off). Space-walking queries: tab(hosting:) finds it; per-space lookups, Peek, favourites, pinned don't; never in the session save, never slept/archived; included in allLiveTabs (GPU recycler); excluded from now-playing and open-tab suggestions. Profile for a new window: the frontmost window's (Private from a Private window), else the first non-Private profile. Profile deletion closes its Quick Detours.
- Decisions implemented: (1) history: historyVisit.spaceID = profile id XOR a fixed mask (stable, never a space id); included in the profile's scope (History page, chrome.history.search), labelled Quick Detour; the launch sweep keeps them but never counts them as proof the space table is intact. Rejected: nullable spaceID + profileID column (every query/index is keyed by space). (2) not restored at launch (archiving is 193.5). (3) Private Quick Detour on the Private profile's store, no history; Private site settings dropped only when no Private space and no Private Quick Detour remain; downloads scoped to the tab; close/quit confirmation and cancel as Private windows. (4) extensions: new ExtensionListedWindow; type popup with one tab, to its own profile's contexts only; didOpenWindow/didCloseWindow sent explicitly (WebKit's windows.getAll lists only windows it was told about).
- Other choices: not counted in the quit confirmation's window count; downloads show a toast, no downloads button; WebKit's own link menu items kept; internal pages load only when typed; .crx links offer the install via the shared CRX path. Shared code extracted: FindInPageSession, HTTP sign-in prompt, external-app prompt.
- TDD: QuickDetourTests red 26/28 failing then 28/28; QuickDetourLauncherTests red 10/11 then 11/11. Window and extension suites written after the code; mutation-checked (window type .normal: 6 failures; unfiltered openWindowsFor: isolation test fails; no didOpenWindow: fails).
- /code-review high --fix: 10 findings, 7 fixed: launch history sweep treated Quick Detour scopes as proof and could wipe every space's history after a session reset (keep-list now separate; 2 tests); launcher kept the last Profile alive (blocked data removal); Private Quick Detour close/quit dropped downloads without confirmation or left partial files; popover onClose removed a newer popover; Quick Detour tabs triggered session saves and sidebar scans (subscribeToTab inSession:false); duplicate applyUserAgent branches; dead init parameter and wrapper. Skipped: focus forwarding to other profiles' contexts (pre-existing, affects all windows); configuration-profile refactor. CRX interception (left as a product call) was then added for consistency.
- Tests (after review): 583 pass + 1 gated skip across TabStore 40, SessionSaveAtomicity 10, SessionSaveFailure 12, SessionSnapshotRepair 10, HistoryDatabase 130, HistoryDeletionIntegration 63, DownloadManager 35, PrivateDownloadClosePolicy 10, PrivateDownloadTransfer 2, ProfileDeletionUndo 13, ProfileDataRemoval 25, QuickDetour 28, QuickDetourLauncher 12, QuickDetourWindow 15, QuickDetourExtension 8, InternalPageIntegration 13, ExtensionTabLifecycle 42, ExtensionActiveTab 15, WKExtensionIntegration 20, NowPlayingTab 20, GPUProcessRecyclePolicy 14, PeekState 11, MoveTabToSpace 31, CommandPaletteFocus 4; ExtensionPolyfillIntegration 26 and ExtensionPolyfillProfileWiring 43 (+7 skipped) alone. Before the review, a wider set (History*, Palette*, Peek*, Extension*, Download*, Session*, NowPlaying, SiteSettings, etc.) also passed.
- Runtime (docs/harness/task193-1-harness.patch, loopback fixture, real posted input, two passes, light + dark): panel flow; navigation, find (Escape closes the find bar, fixed), zoom, two windows, Cmd+W; test extension sees popup windows, content script and action click reach the worker; History page labels; Private Quick Detour uses the Private store and records nothing; Private download close confirmation (Continue keeps, Close cancels, no file left); windowless quit cancels the Private download; deleting a profile after using its launcher releases it; relaunch restores nothing and keeps Quick Detour visits; unsigned .crx refused by the install gate. Not verified: the panel taking typing while another app is frontmost (193.2), Cmd+click/page-opened windows, normal downloads, HTTP sign-in, external-app prompt, a signed .crx install, 1Password itself; whether Escape closes the find bar in browser windows.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour exists: Opt-Cmd-N (or File > New Quick Detour Window) shows a Spotlight-style palette, and choosing a URL or search opens a small single-page window with the profile pill, host, extension and copy-link buttons and an Open in placeholder. Its tab lives outside every space; visits go to the profile labelled Quick Detour; windows are not restored; Private is supported with the Private download rules; extensions see it as a popup window. 583 tests pass after a high-effort review whose 7 fixes include a history-sweep guard; checked at runtime twice in light and dark.
<!-- SECTION:FINAL_SUMMARY:END -->
