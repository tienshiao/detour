---
id: TASK-227
title: >-
  Tabs: YouTube tabs come back from a relaunch titled with their URL
  (youtube.com/watch?v=…)
status: Done
assignee:
  - '@claude'
created_date: '2026-10-29T04:08:00Z'
updated_date: '2026-10-29T04:52:00Z'
labels:
  - bug
  - tabs
dependencies: []
priority: medium
type: bug
ordinal: 263000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported Oct 28 2026: after restarting the browser, two YouTube video tabs in the sidebar showed `youtube.com/watch?v=0Rxd1e…` and `youtube.com/watch?v=CyytYR…` instead of their titles, while the plain `youtube.com` tab and other sites kept theirs. The stored session already had the URL as the title, so the relaunch only shows what was saved; the wrong title was written at some point before.

Evidence from the user's data (~/Library/Application Support/Detour, read Oct 28 2026). The user archived both tabs at 21:06:45, and their closedTab rows (ids 1347 and 1348) keep what the session held:
- `https://www.youtube.com/watch?v=0Rxd1ehkWBQ`, title `youtube.com/watch?v=0Rxd1ehkWBQ`. history.db has one visit, Oct 21 09:29, to `…watch?v=0Rxd1ehkWBQ&pp=ugUEEgJlbg%3D%3D`, with the real title ("iPhone Duo Review … - YouTube"). The tab's saved URL has no `&pp=`, so the URL changed after the first load (YouTube drops the parameter with replaceState, or a later wake loaded the bare URL).
- `https://www.youtube.com/watch?v=CyytYRPyUW4`, title `youtube.com/watch?v=CyytYRPyUW4`. Visits on Oct 23 00:02 and 00:04 have the real title ("2027 Honda Passport TrailSport | First Drive - YouTube").
YouTube video tabs closed earlier the same day (closedTab 1335 to 1344) have proper titles, so this does not happen to every YouTube tab. Both affected tabs were days old and had probably been put to sleep and woken, or restored by relaunches, several times.

Leads from the code (not yet checked):
- In TabStore's per-tab observers, `observe(\.$title)` does not schedule a save, but `$url` and `$favicon` do. The title is saved only when something else triggers a save. A title that settles after the last URL or favicon save is lost on an exit that skips `applicationWillTerminate`'s `saveNow()`, such as an Xcode stop, a crash, or an update relaunch.
- `BrowserTab.updateTitle()` shows the stripped URL while `navigationPending` is set, or when the web view has no title yet. YouTube sets `document.title` late from script. If a save runs in that window (the URL change itself schedules one) and the tab then sleeps or the app exits before another save, the URL title is what persists. A sleeping tab keeps its title, so the wrong title stays across later relaunches until the tab is woken and shown.
- Related earlier fixes: TASK-114 (an unclaimed background tab shows the URL until commit), TASK-45 (a restored tab's persisted title outranks the raw URL while restoring), TASK-88 (history title correction after the title settles).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A tab whose document title settles after its last URL or favicon change still has that title in the session after a relaunch, including when the app exits without applicationWillTerminate
- [x] #2 A tab that is put to sleep, or archived, keeps the settled document title rather than the stripped-URL placeholder shown during navigation
- [x] #3 A restored tab whose stored title is a placeholder takes the real document title once it wakes and the page sets it, and that title is saved
- [x] #4 Regression tests reproduce the YouTube pattern with a local fixture: a script-set late title, a replaceState URL change and sleep or relaunch. They fail before the fix
- [x] #5 Root cause recorded in the task notes, and in the wiki if it is a lasting rule about when session state is saved
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Root cause (research, Oct 28 2026): when a WebContent process dies (a crash or memory kill, common for days-old background tabs on this machine), WebKit's PageLoadState::reset clears the web view's url and title. BrowserTab keeps its url (lastAttemptedURL guard), but updateTitle() falls through to strippedScheme(lastAttemptedURL), so the sidebar shows youtube.com/watch?v=…. An unclaimed web view's own delegate does not reload on termination, so nothing brings the title back until the tab is shown. Any later save, or the save at quit, stores the placeholder, and a tab that sleeps keeps it for good. The same placeholder replaces a restored tab's persisted title at commit when the document has not reported its title yet (restoringSession is cleared at commit). Title changes alone never schedule a save (observe(\.$title) has no save:), so a title that settles late reaches disk only with an unrelated save.
2. Red tests (new TabTitleRetentionTests): killed process keeps title and url, and a sleep after it keeps the title; woken restored tab keeps its persisted title until the document reports one, then takes it; a navigation to a different URL still shows the placeholder; TabStore saves a title change of an in-session tab within the title-save delay, a title that changes faster than the delay does not postpone the save, and a tab outside the session does not schedule one.
3. BrowserTab: remember which URL the current title belongs to (document title, persisted title, archived title). updateTitle keeps that title instead of the URL placeholder while the URL to show is the same.
4. TabStore: a title change schedules a save that does not postpone a pending one (injectable delay, default 5 s).
5. Run the new tests and the title, wake, history-title and session-save suites; /code-review --fix; /verify; update the wiki (persistence save triggers, tab title rule, WebKit process-kill fact) and wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (Oct 28 2026): BrowserTab.titledURL records which page the current title belongs to: a document title tied to `_committedURL` (private; WebKit changes it in the same transaction as the title, at commit and at a same-document change), a non-empty persisted or archived title, moved by retarget(to:). Neither URL placeholder in updateTitle() replaces a title for the same page; with the process gone, the committed `url` counts too, which covers a redirected load. TabStore: a title change calls scheduleSaveUnlessPending(after: titleSaveDelay = 5 s), which never cancels a pending save, so a title that flashes faster than the delay cannot hold saves off.
/code-review --fix found 6 issues; it fixed 5 (a page-started navigation tied the old title to the destination, a redirect plus a kill lost the title, empty persisted titles, retarget, a double weak-self read) and added two tests. I then replaced its isLoading heuristic with _committedURL: under that heuristic a replaceState while still loading (YouTube dropping &pp=) left the title tied to the old URL, and test testAKilledWebProcessKeepsTheTitleAfterAReplaceStateWhileLoading covers that case. Not fixed, by decision: a page whose title changes constantly causes one full session save every 5 s (before this change, title changes saved nothing); and per the review, a window reloading a crashed page that had redirected may show the pre-redirect URL until the reload reports a title.
Tests: TabTitleRetentionTests has 10 tests. All 10 pass; the first 5 failed before the fix (red run recorded). Full DetourTests: 3335 tests, 17 skipped, 3 tests failing. SettingsPaneColumnsTests.testTheLinksPaneDoesNotNeedMoreThanTheListMinimum also fails on HEAD with this change stashed (1287 > 400), so it is not caused by this work. BrowserWindowSidebarModeTests.testAutosaveRestoreArrivesAsExternalCollapse and ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection pass when rerun alone, and both passed in the first full run.
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify227, local page with no <title> that sets one 8 s after load). Seeded a selected tab titled "Old Fixture Title". Window title (CGWindowList) and the saved title, sampled every 0.5 s: the persisted title held through commit with no URL flash; the page's title appeared at ~10 s and was saved at ~15 s without a quit. kill -9 of the page's WebContent process (WebKit logged reason=Crash, the window reloaded it in a new process): both titles stayed on the page title for 16 s, through the 8 s untitled reload. kill -9 of the app, then relaunch: the window shows the saved title. Not checked at runtime: an unclaimed background tab's kill (covered by unit tests) and a real YouTube page. Profile, defaults keys and server cleaned up.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed tabs coming back from a relaunch titled with their URL. Cause: when a web content process dies (a crash or a memory kill, common for long-lived background YouTube tabs), WebKit clears the web view's title, and BrowserTab replaced the title with the URL placeholder. The next save stored that, and a tab put to sleep kept it for good. The same placeholder replaced a restored tab's persisted title at commit, before the document had a title. Now a tab keeps the title it has for the same page (BrowserTab.titledURL, tied to WebKit's _committedURL), and a title change saves the session within 5 s without postponing pending saves, so it survives a crash or forced quit. Tests: 10 new in TabTitleRetentionTests, all passing. The full suite has one failure that already fails on HEAD (SettingsPaneColumnsTests links pane) and two flaky tests that pass when rerun. Runtime check in an isolated profile: no URL flash at wake or after a page process kill, the late title is saved without quitting and is restored after a SIGKILL of the app. Trade-offs: a page whose title changes constantly causes one session save every 5 s, and a page that clears its own title keeps the old one. Wiki: browser-tab, persistence, unresponsive-web-process.
<!-- SECTION:FINAL_SUMMARY:END -->
