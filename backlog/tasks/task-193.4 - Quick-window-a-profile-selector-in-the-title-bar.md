---
id: TASK-193.4
title: 'Quick Detour: a profile selector in the title bar'
status: Done
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 15:49'
labels:
  - window
  - profiles
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: low
ordinal: 228000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fourth part of TASK-193. The pill at the left of the title bar ("Default" in the screenshot) shows the quick window's profile and switches it. Switching reloads the current URL in a fresh web view on the new profile's data store (cookies and logins differ), and the Open in dropdown then offers that profile's spaces. Default profile for a new quick window: decide (the frontmost window's, the last used in a quick window, or a setting).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The pill shows the profile; choosing another reloads the page in that profile's data store
- [x] #2 The default profile for a new quick window is decided and implemented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-10-26): a new Quick Detour starts in the frontmost window's profile (Private from a Private window; from another app via the hotkey, the last Detour window used), as TASK-193.1 implemented. Rejected: last profile used in a Quick Detour; a fixed profile setting.

2026-10-26 implementation:
- Pill = QuickDetourProfilePill: opens its menu on mouse-down (pop-up role), small up/down chevron, pressed highlight; menu lists profiles (window's checked) then a separator and Private; other profiles carry a reload tooltip. The launcher panel has no pill (uses the frontmost window's profile, as decided).
- Switching replaces the window's BrowserTab with a new Quick Detour tab on the target profile, in the same window (frame, window order, full screen, source space kept). Why: a web view's data store is fixed at creation, and a new tab lets extension close/open, history scope and Private membership follow the existing close/open paths; rejected: swapping the web view inside one tab (one tab id across two profiles' contexts). Order: release page -> remove and tear down old tab (shared takeDownQuickDetourTab) -> didCloseWindow to the old profile, window takes the new profile/tab id/history scope, didOpenWindow to the new profile -> new tab enters the list -> observers get tabStoreDidReplaceQuickDetour -> pill, appearance, Open in, extension buttons follow -> load the old URL (internal pages stay internal; mid-load reloads the URL being loaded; error page reloads the failed URL).
- Consequences: old profile's extensions see tabs.onRemoved then windows.onRemoved; new profile's see windows.onCreated (popup, incognito when Private) then tabs.onCreated; others nothing. History before stays in the old Quick Detour scope; Private records nothing. Into Private: Private store, dark window, Private download scope, Private session user, Open in Private Window. Out of Private with downloads: 'Switch to X?' Switch Profile (cancels, removes partials) / Continue Downloading; Private session ends if this was its last page. Lost on a switch (accepted): typed form text, back/forward, scroll, zoom, window.opener. Refused while a sheet is up. Same profile or deleted target: no-op. A page-opened Quick Detour keeps its own profile when its opener switches.
- TDD: 36 of 42 new tests red against stubs (store 20/23, window 12/15, extension 4/4), then green; two first-green failures were test timing/synchronous-release assumptions, fixed.
- /code-review high --fix: 6 findings, 5 fixed: the post-alert guard didn't check for a sheet put up during the alert (switch would tear the page out from under it) -> refused, downloads cancelled only after the guard, 2 tests (profile deleted / sheet during the alert); duplicated removal sequence; pill repaint via superview cast -> onHighlightChange; duplicate profile lookup. Not fixed (own change): windowIsClosing is false on the old profile's tab close, as on the normal close path.
- Tests (after review): QuickDetourProfileSwitch 23, QuickDetourProfileSwitchWindow 17, QuickDetour 28, QuickDetourLauncher 12, QuickDetourWindow 15, QuickDetourHotKey 22, QuickDetourExtension 15, QuickDetourOpenIn 30, QuickDetourOpenInWindow 17, PrivateDownloadClosePolicy 10, PrivateDownloadTransfer 2, DownloadManager 35, ExtensionTabLifecycle 42, TabStore 40; ExtensionPolyfillProfileWiring 43 (+7 skipped) alone. Before the review also HistoryDatabase 130, SiteSettingsStore 11, ProfileDataRemoval 25, ProfileDeletionUndo 13, WKExtensionIntegration 20.
- Runtime (docs/harness/task193-4-harness.patch, 4 phases, light + dark, 12 s HID idle before every input, no user input seen): pill and menu; switch to Second reloads under Second's cookies (Not logged in vs Logged in), old web view released, Open in names Play; history split by profile; extension events per profile; back to Default gets a new window id; into Private (dark, no history, incognito popup); out of Private with a download asks, Escape keeps, Return cancels and leaves no partial file, Private session ends; History page reopens as the History page; after review: pressed highlight light/dark, one switch, the Private question. Not verified: a person's click, VoiceOver, mid-load and rename/delete at runtime (unit tests only), several displays.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Quick Detour profile pill now switches profiles: its menu lists the profiles and Private, and choosing one reloads the page on that profile's data store in the same window (a new tab replaces the old, so extensions, history and the Private session follow the normal close/open paths). Leaving Private with a download asks first. A new Quick Detour still starts in the frontmost window's profile. Tests pass; checked at runtime in light and dark, before and after a high-effort review.
<!-- SECTION:FINAL_SUMMARY:END -->
