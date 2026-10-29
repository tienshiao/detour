---
id: TASK-227
title: >-
  Tabs: YouTube tabs come back from a relaunch titled with their URL
  (youtube.com/watch?v=…)
status: To Do
assignee: []
created_date: '2026-10-29T04:08:00Z'
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
- [ ] #1 A tab whose document title settles after its last URL or favicon change still has that title in the session after a relaunch, including when the app exits without applicationWillTerminate
- [ ] #2 A tab that is put to sleep, or archived, keeps the settled document title rather than the stripped-URL placeholder shown during navigation
- [ ] #3 A restored tab whose stored title is a placeholder takes the real document title once it wakes and the page sets it, and that title is saved
- [ ] #4 Regression tests reproduce the YouTube pattern with a local fixture: a script-set late title, a replaceState URL change and sleep or relaunch. They fail before the fix
- [ ] #5 Root cause recorded in the task notes, and in the wiki if it is a lasting rule about when session state is saved
<!-- AC:END -->
