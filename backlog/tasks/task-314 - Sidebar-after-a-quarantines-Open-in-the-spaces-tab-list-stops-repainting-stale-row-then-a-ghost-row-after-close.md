---
id: TASK-314
title: >-
  Window: a closed browser window can be re-shown by a link placement, with its
  sidebar deaf to the store (stale rows, ghost rows)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-09T10:46:00Z'
updated_date: '2026-11-09T19:56:00Z'
labels:
  - sidebar
  - window
  - link-routing
  - bug
dependencies: []
references:
  - TASK-132.22
priority: medium
type: bug
ordinal: 376000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-11-09 (Detour build running then, pid 7900). A mail link opened in a Quarantine window; the page was Google's sign-in (logged out there). Open in > Home reloaded it in Home, where Google signed in on its own and redirected to search.google.com (Search Console, title 'Overview').

Observed:
1. The new row in Home's sidebar kept the address it was inserted with (accounts.google.com/v3/signin/..., globe icon), while the faux address bar showed search.google.com: the row never redrew its title or favicon.
2. Closing that tab selected the pinned 'The Old Reader' (content and address bar switched), but the list still showed the closed row, now titled 'Overview' with its favicon and the selection highlight, and The Old Reader's row was not highlighted. The row could not be closed. Clicking elsewhere in the sidebar made it disappear.

So the tab list (page strip area) stopped repainting while the address bar above it kept updating; the store and the sidebar model look right (the row's cell had the fresh title when it was finally drawn).

Ruled out so far (2026-11-09):
- Store / sidebar model: a diagnostic real-window test (QuarantineWindowTests style: quarantine on a loopback page, Open in to a space, wait for the title, read TabCellView titles from tabSidebar.tableView, closeTab, read again) passes: the row shows the loaded title and is removed on close, both with the window already on the target space and with Open in switching it from another space (placement .switchWindow). Patch kept in the session scratchpad only; easy to recreate.
- tabSubscriptions keyed by tab.id, the sidebar's isDragging/pendingState deferral, LinkRouting tab mutations, occlusion handling: nothing that would leave the model stale.

Not yet tried: a runtime repro in the Debug app (DETOUR_DATA_DIR, Quarantine as the Links Default, open a link from another app, Open in by the title-bar button and by Cmd+O, with a redirect to another host after load), capturing the window to see whether the table area is frozen; candidates: the table's insert animation (slideDown) started while the browser window was behind the key Quick Detour window, Open in run inside the title bar's mouse tracking loop, the window closing during that loop.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Reproduced at runtime (or with a test that fails) and the cause recorded
- [x] #2 After a quarantine's Open in, the new row shows the page's title and favicon as they load
- [x] #3 Closing that tab removes its row at once and the newly selected row is highlighted
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. BrowserWindowController records that its window closed (flag set in windowWillClose). NSApplication.browserWindowControllersFrontToBack skips closed ones (not isVisible: a miniaturized window or a hidden app's window must still count). Unit-test the filter, plus a real-window test: close a second window, then a placement into its space must not re-show it (it opens or switches another window instead).
2. Audit the other front-to-back callers above with the same filter in mind.
3. Follow-up, separate task: find what keeps a closed BrowserWindowController alive (a leak: its tabs' web view handlers, Combine sinks, RoutedOpenRecord, etc.). Fixing the leak alone would not fix this bug, because any retained window would still be revivable.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-09, from the user: Open in was clicked, Home picked from the dropdown because the default named the other space, so the window was on the other space (a mail link's default is the most recent window's space). The app was 0.4.2 (10), launched 01:43, about an hour before: not long uptime.

Runtime repro attempt (docs/harness/task314-harness.patch): Debug build, isolated data dirs, the window on a second space, a quarantine on a fixture /signin page, a real HID click on the Open in chevron and Down + Return to pick Home (the menu's own tracking loop), Home signed in by cookie so the page script-navigates to another host after the move and retitles itself; once with Home empty, once with a pinned 'News' folder of three pinned tabs. NOT reproduced: the row showed the address then 'Overview' (model, cells and the captured window agree), and closing it removed the row at once with the first pinned tab highlighted.

Left untried: the Release build (optimizer, the signed app), extensions loaded in the target space's profile (1Password etc.: tab events on a new tab), Google's real pages (several redirects, process swaps). Next time it happens: before clicking anything, capture the window (screencapture -l) and note whether hovering rows changes them; that tells a frozen layer from a table/model desync.

ROOT CAUSE FOUND (2026-11-09, reproduced in the Debug build). Not quarantine-specific: the user then reproduced it with a link opened straight into the space and with Cmd+T + paste, in their running production app, and with 1Password off.

Live diagnosis of the user's production app (pid 7900, read-only via the Accessibility API, axwatch/axvis tools in the session scratchpad): two browser windows. In the affected one, NSTableView really keeps the closed tab's row (6 AX rows vs 5 in the other window on the same space). As a bystander, the other window got every title live and removed the row on close. The affected window got nothing from the store: its own selected row kept a stale title across Jira -> Atlassian login -> MARBI-911 navigations. It changed only when its own selection code resynced the list (new tab selected, close selecting the neighbour first, a click, a space switch).

Mechanism:
1. Closing a browser window runs windowWillClose: store.removeObserver(self), NotificationCenter removeObserver, AppDelegate drops it from windowControllers. Something still holds the BrowserWindowController (and its window, isReleasedWhenClosed false), so the closed window stays in memory.
2. AppKit keeps a closed but still-retained window in NSApp.orderedWindows (standalone check: closed window B stays listed). NSApplication.browserWindowControllersFrontToBack (AppDelegate.swift:1317) maps orderedWindows to controllers, so it returns the closed window's controller.
3. A link placement (AppDelegate.openLink -> placeTab -> linkPlacement over browserWindowsByRecency) picks it when its activeSpaceID matches. In the user's first report that was the quarantine's Open in > Home, where the closed window had last shown Home. present() then calls makeKeyAndOrderFront, which re-shows the closed window.
4. The re-shown window is off the TabStore observer list, so tabStoreDidInsert/Update/RemoveTab never reach it: titles never update, a closed tab's row stays (ghost), and the highlight drifts until a click or space switch resyncs.

Repro (harness mode 'zombie', docs/harness patch to be refreshed): window A on Work; createNewWindow(showing: Home) as B; B.performClose; log shows B alive=true and listed as (closed) in browserWindowControllersFrontToBack. openLink(example.com, .openInSpace(Home)) gives placed in B, revivedB=true; the row stays 'example.com/' while the tab's title is 'Example Domain'; after closeCurrentTab the store has no such tab but B's sidebar.tabs and cells still list 'Example Domain'. Captures match the user's screenshots.

Other users of browserWindowControllersFrontToBack can also pick a closed window: frontmostBrowserWindowController, HelpMenu, the extension options page, ExtensionInstallTarget, DownloadOpenedTab.

CORRECTION (same day): in the 'zombie' harness run, B stayed alive only because the harness kept a strong local reference to it (let b). The revival mechanism holds: a closed window that is still in memory stays in orderedWindows and gets re-shown by present(). But a plain closed browser window is NOT leaked. Harness mode 'leak' keeps only a weak reference: B is freed within 1 s of performClose, and 'leaks --traceTree' finds nothing at its address. A closed-but-alive NSWindow keeps its window number and stays in CGWindowList as off-screen (standalone check). The user's running app lists only its two browser windows plus Settings and panels, so closed windows are not piling up. Something specific to that window's history kept it alive after close; still unknown. RoutedOpenRecord holds its windows weakly, so it isn't that. Next: reproduce the retention (two windows sharing a tab, Quick Detour/quarantine Open in into it, Peek, extension popups), with a weak-ref check plus leaks --traceTree. The orderedWindows filter is still the fix for the revival; the retainer is a separate leak.

FIX implemented (uncommitted, 2026-11-09):
- BrowserWindowController.hasClosed, set first thing in windowWillClose.
- NSApplication.browserWindowControllersFrontToBack (AppDelegate.swift) skips closed controllers. It feeds browserWindowsByRecency (link placement), frontmostBrowserWindowController, HelpMenu, the extension options page, ExtensionInstallTarget and DownloadOpenedTab.
- extensionBrowserWindows() (WKExtensionTabConformance.swift) skips closed browser windows. extensionListedWindows() (WKExtensionWindowConformance.swift, WebKit's openWindowsFor) skips closed browser windows and Quick Detour controllers no longer in openControllers. Both read NSApp.windows, which keeps closed windows that are still in memory, so an extension could have been told about one (or focused it, re-showing it).
- Filtered on hasClosed, not isVisible: a miniaturized window or a hidden app's window is not visible but still open.

Tests:
- ExternalLinkRoutingTests: testALinkNeverShowsAClosedWindowAgain, testAClosedWindowIsListedNowhere. Without the filter, both fail with 5 failures between them (the closed window is shown again and takes the link). With it, both pass.
- Affected suites (DownloadOpenedTab, ExtensionPolyfillIntegration, ExtensionPolyfillProfileWiring, ExtensionTabLifecycle, ExtensionWindowsCreatePrivate, ExternalLinkRouting, InPageLinkRouting, QuickDetourExtension, QuickDetourOpenIn, QuickDetourOpenInWindow, QuickDetourWindow, WebKitDelegateReachability): 288 tests, 0 failures, 13 skipped (their own gating).

Runtime (Debug, DETOUR_DATA_DIR=DetourVerify314c, harness mode zombie): the closed window B is still held but no longer listed. The link goes to window A, which switches to Home. The row follows the title to 'Example Domain', and closing removes it at once, highlighting the next tab. Captured.

Not verified: the production build, and the full test suite. /code-review not run yet. The harness is saved as docs/harness/task314-harness.patch (modes same/other/bg/zombie/leak, plus the AX watcher used on the user's live app) and removed from the source. Wiki: platform/appkit-gotchas.md, new section 'Windows'. Follow-up TASK-315: what kept the user's closed window in memory.

/code-review --fix: 7 findings, 6 fixed by the reviewer and 1 deferred.
Fixed:
- handleSpaceDeletionBlocked, showQuickDetourLauncher and openInQuickDetour read orderedWindows directly; they now skip closed browser windows.
- One rule for 'open': ExtensionListedWindow.isOpenForExtensions (browser window: !hasClosed; Quick Detour: in openControllers), used by extensionListedWindows() and extensionBrowserWindows().
- Comments: removed wording claiming WebKit had been told a browser window closed. It hasn't been.
- testAClosedWindowIsListedNowhere: added the AppKit precondition and a positive check for extensionListedWindows.
Deferred: Detour never calls didCloseWindow for a browser window, so WebKit keeps it in windows.getAll and windows.onRemoved never fires. That is already TASK-132.22 (on the epic branch), so no new task.

Follow-up (user review, 2026-11-09): one source of truth for 'is this window open'. hasClosed answers it. AppDelegate.windowControllers is ownership only (now private(set), documented as such). browserWindowsByRecency filters its registry additions on hasClosed too, so it can no longer append a closed window, and it asserts (Debug) that no registered controller has hasClosed set, so drift between ownership and state fails in development. The assertion sits where windows are listed, not in the willClose observer: the registry removal and the delegate's windowWillClose both run during the close notification, in no guaranteed order. New test: ExternalLinkRoutingTests.testClosingAWindowLeavesTheRegistryAndTheFlagInAgreement. 8 placement suites: 157 tests, 0 failures; the assertion ran on every placement without firing.

/code-review --fix on the follow-up: 6 findings. Fixed by the reviewer:
- The launch window now registers through registerWindowController, so it is registered and watched for close in one step (before, it was appended and only watched about 35 lines later).
- applicationShouldTerminate counts windows with !hasClosed.
Fixed by me: the reviewer correctly pointed out that a window's windowWillClose sets hasClosed before AppDelegate's willClose observer removes it from the registry, so during every close the two briefly disagree. The drift assertion moved from browserWindowsByRecency into that observer, right after the removal; browserWindowsByRecency keeps only the filter (the Release safety net).
Left as they are: the registration test exercises the invariant, not a placement (testALinkNeverShowsAClosedWindowAgain covers the placement after a close).
Moved to TASK-315: observeWindowClose discards its observer token.
8 placement suites: 157 tests, 0 failures. Every window close in them ran the assertion without it firing.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Cause: a browser window the user had closed was still in memory. AppKit keeps such a window in NSApp.orderedWindows / NSApp.windows. browserWindowControllersFrontToBack therefore still returned it, and a link placement (here, a quarantine's Open in > Home) picked it as the window showing Home and re-showed it with makeKeyAndOrderFront. windowWillClose had already removed it from the TabStore observers, so its sidebar never heard of title changes or closes. That gave the URL-titled row, the ghost row after close, and the wrong highlight until a click or space switch resynced it. Found in the user's running production app with the Accessibility API and the system window list. Reproduced in Debug (harness mode zombie).

Fix: BrowserWindowController.hasClosed, set in windowWillClose. Every list of open windows skips closed ones: browserWindowControllersFrontToBack (placement, frontmost window, Help, options page, extension install target, download restore), the extension window lists (ExtensionListedWindow.isOpenForExtensions) and the direct orderedWindows reads (space-deletion alert, Quick Detour launcher, Quick Detour link profile). Filtered on the flag, not isVisible, so minimized and hidden-app windows still count.

Verification: two new ExternalLinkRoutingTests tests, which fail without the filter; 17 affected suites, 400 tests, 0 failures, 13 skipped by their own gating; Debug runtime check after the review fixes. /code-review --fix: 6 of 7 findings fixed, 1 deferred to the existing TASK-132.22 (WebKit is never told a browser window closed). Not verified: the full suite and a production build.

Follow-ups: TASK-315 (what kept the user's closed window in memory), TASK-132.22. Wiki: platform/appkit-gotchas.md, section Windows. Harness: docs/harness/task314-harness.patch.
<!-- SECTION:FINAL_SUMMARY:END -->
