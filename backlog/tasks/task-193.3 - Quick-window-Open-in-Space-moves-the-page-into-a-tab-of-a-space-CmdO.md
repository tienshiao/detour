---
id: TASK-193.3
title: 'Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)'
status: Done
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 09:20'
labels:
  - window
  - spaces
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: medium
ordinal: 227000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-193. The Open in <Space> button (Cmd+O) moves the quick window's page into a new tab of the shown space and closes the quick window; its dropdown lists the other spaces (emoji and name). Which space is shown by default: the most recently used space of the window's profile (decide). When the target space uses the window's profile, hand over the same web view (as `expandPeekToNewTab` does), keeping history and state; when it uses another profile, the web view cannot move (different data store): either reload the URL there or list only same-profile spaces (decide; the profile pill, TASK-193.4, affects this). The new tab is selected in a window showing that space (else the most recent window switches to it), the same placement rule as TASK-191.2.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Cmd+O and the button move the page to a new tab in the shown space and close the quick window; the dropdown picks another space
- [x] #2 Same-profile moves keep the web view (back/forward history intact); cross-profile behaviour is decided and implemented
- [x] #3 TabStore insertion is test-first; checked at runtime
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-26):
1. Default space named on the button: the space that was in front when the Quick Detour was opened, if it uses the same profile; otherwise that profile's most recently used space.
2. Dropdown lists all normal spaces grouped by profile. Same-profile spaces get the page moved intact (same web view: scroll, back/forward, form state). Another profile's space reloads the URL there (that profile's cookies/logins; back/forward history lost). Rejected: same-profile spaces only.
3. Private Quick Detour: Open in Private Window moves the page intact into a new tab of the most recent Private window, else a new Private window (same throwaway store, no reload).

2026-10-26 implementation:
- Default target: the source space while it exists, is not Private and belongs to the window's profile; else the profile's most recently used space (new in-memory TabStore.spaceUseOrder: a space counts as used when a browser window switches to it or a window showing it becomes key; seeded with the restored last active space; deleted spaces skipped); else the profile's first space; a profile with no spaces names the most recently used space of any profile (reloads). Recomputed on space changes and window key.
- Control: capsule 'Open in <emoji name> ⌘O' + chevron dropdown; File > Open Quick Detour in Space (⌘O, enabled only while a Quick Detour is key; ⌘O is therefore now a Detour menu shortcut the hotkey recorder refuses). Dropdown: every normal space of every live profile, own profile first, profile headers only when more than one profile has spaces, other-profile items subtitled 'Reloads the page'. Private: 'Open in Private Window ⌘O', no dropdown.
- Same-profile hand-over moves the Quick Detour's own BrowserTab (tab id, web view, back/forward, scroll, form state, opener, in-flight load, extension registration survive): Quick Detour lets go (shared letGo helper) -> AppDelegate.placeTab (the ATC placement, now shared with openLink) -> TabStore.moveQuickDetourTab inserts at the normal new-tab position -> browser window selects and claims the web view -> extensions get onDetached/onAttached/onActivated then windows.onRemoved (announced after selection: earlier gave newPosition null) -> window forward -> Quick Detour closes without closing the tab. Leak test: controller freed, web view kept. Cross-profile: new tab on the URL in that space (internal pages stay internal), then normal close. Private: into the most recent Private window or a new one; in-flight Private downloads move with the page.
- History: earlier visits stay under the Quick Detour scope; the scope switches at the move.
- Side effects recorded: a routed external link no longer shows the collapsed-sidebar 'Opened new tab in background' toast (the tab is selected straight away); a new Private window made for a placement holds only the placed tab.
- TDD: QuickDetourOpenInTests red 23/29 then green (30 with the deferred-announcement test); QuickDetourOpenInWindowTests red 14/15 then green; extension tests red 2/3 then green.
- /code-review high --fix: 8 findings, 7 fixed: Open in while a sheet (alert/confirm/prompt, file panel, permission prompt) was up closed the window and dropped WebKit's completion handler (crash) -> refused and Cmd+O disabled, 2 tests incl. a real page alert, mutation-checked; openLink fell back to a normal space for a declined Private placement; Cmd+O enabled with nothing to reload; duplicated detach code (letGo); constraint churn in the title bar; duplicated internal-page idiom; unused lookup. Skipped: rolling back a switched/new window if makeTab declines (unreachable: open(in:) checks canMoveQuickDetourTab first).
- Tests (after review): QuickDetourOpenIn 30, QuickDetourOpenInWindow 17, QuickDetourWindow 15, QuickDetour 28, QuickDetourLauncher 12, QuickDetourExtension 11, QuickDetourHotKey 22, ExternalLinkRouting 13, InPageLinkRouting 21, LinkPlacement 19, PrivateDownloadClosePolicy 10, PrivateDownloadTransfer 2, DownloadManager 35, ExtensionTabLifecycle 42, TabStore 40, MoveTabToSpace 31, ExtensionPolyfillProfileWiring 43 (+7 skipped) alone. Before the review also PeekState/PeekAnchor/FavoritePeekPersistence, HistoryDatabase 130, ExtensionActiveTab, WKExtensionIntegration, DownloadWindowScope, SessionSave*.
- Runtime (docs/harness/task193-3-harness.patch, loopback fixture, two profiles, three phases, light + dark): default names the source space; dropdown grouping and reload marking; Cmd+O with another window in front brings the Work window forward with the same tab and web view (scrollY, typed text, Back kept), controller released; history split at the move; extension events as above; cross-profile reload uses the other store (no cookie, no back history); mid-load move finishes in the space; Private moves into an existing and a new Private window (download moved); after review: title bars light/dark, alert blocks Cmd+O until dismissed. During one early run the user was active and some of their keystrokes reached the debug Detour and one capture caught their Chrome window (deleted, phase re-run); the harness now waits for 12 s of HID idle before every activation and input. Not verified: Cmd+O typed by a person, several displays, 1Password / content-script port across a move, the receiving Private window's close prompt after a moved download (unit-tested only).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour's Open in <Space> (button, dropdown, ⌘O) moves the page into a tab of a space: the space you came from by default, any space via the dropdown grouped by profile. Same-profile moves hand over the same tab and web view (scroll, back/forward, form state, opener kept; extensions see a detach/attach); other profiles reload the URL; Private moves into a Private window. Placement reuses Air Traffic Control's rule. Refused while a dialog is up (crash found in review). Tests pass; checked at runtime in light and dark.
<!-- SECTION:FINAL_SUMMARY:END -->
