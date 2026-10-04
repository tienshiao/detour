---
id: TASK-156
title: >-
  Downloads: a Private window's download that is still running when the window
  closes cannot be seen or cancelled
status: In Progress
assignee: []
created_date: '2026-10-04 09:14'
updated_date: '2026-10-04 09:49'
labels: []
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - wiki/features/downloads.md
priority: low
ordinal: 179000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follows from the rule chosen in TASK-148 (2026-10-04), raised by the code review of the batch as a behaviour to confirm.

A Private window's downloads are listed only in that window and are dropped from the list when it closes. One that is still in flight then moves to DownloadManager.unlistedItems: it keeps transferring and writing to ~/Downloads, no window lists or badges it, and nothing can cancel it short of quitting the app. Chrome asks before closing an incognito window with downloads in progress and cancels them if the user goes ahead; Safari keeps them listed.

Also not verified in TASK-148: whether WebKit keeps a real WKDownload transferring once the web view and non-persistent data store that started it are gone (the tests use manual items).

Decide the behaviour first: cancel on close (with or without a prompt), keep running but reachable somewhere, or keep today's rule.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The intended behaviour for a Private download in flight at window close is decided and recorded in the task
- [x] #2 What WebKit does with a real WKDownload after its Private window closes is measured (local fixture server) and recorded
- [x] #3 The decided behaviour is implemented with tests that fail before it; no download keeps running with no way for the user to see or stop it, unless the decision says so explicitly
- [x] #4 wiki/features/downloads.md and wiki/architecture/incognito.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure what WebKit does with a real WKDownload once the web view that started it is gone (standalone spike, then a test against a slow loopback server).
2. Decide the behaviour and record it.
3. Tests first: a real download in a Private window that closes (transfer must stop, partial file removed); the manager dropping an incognito space with an item in flight (must be cancelled); then the pure rule and the window's question.
4. Implement: PrivateDownloadClosePolicy (pure: which downloads a closing window or a quit cancels, whether to ask, the wording), DownloadManager cancels instead of keeping an unlisted item, BrowserWindowController.windowShouldClose asks through an injectable confirmation, AppDelegate's quit alert names the downloads and cancels them.
5. Update wiki/features/downloads.md and wiki/architecture/incognito.md, wiki-lint, log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Measurement (AC #2), 2026-10-04, macOS 26 WebKit

Standalone spike first (swiftc, WKWebView on WKWebsiteDataStore.nonPersistent(), loopback server sending a 16 KB chunk every 20 ms with a large Content-Length), then the same as tests against SlowDownloadServer.

- Releasing the web view (delegate cleared, stopLoading, last reference dropped) and then the data store did not stop the transfer: the file kept growing at the server's pace (about 1 MB per 1.5 s in every leg) and the server saw no close. Dropping the last reference to the WKDownload did not stop it either. The weak references to the web view and the store stayed non-nil in the spike, so WebKit itself keeps them alive for the download.
- In the app flow, before the change: PrivateDownloadTransferTests.testClosingAPrivateWindowCancelsItsRunningDownloadAndRemovesThePartialFile closed a Private window (window.close → removeIncognitoSpace → tab teardown) with a real download running. In the 5 s after the close the server sent 6,995,968 more bytes, the file grew from 147,456 to 7,143,424 bytes and the item stayed .downloading in unlistedItems.
- WKDownload.cancel stops it: the server sees the connection close, the completion handler gets nil resume data, and no didFail callback follows. The partial file stays on disk where WebKit wrote it.
- Removing the file right after calling cancel works: it is gone and is not recreated.

So WebKit neither kills nor fails the download; nothing but our own cancel stops it.

## Decision (AC #1)

Chrome's rule, as recommended. A Private window's download still in flight when the window goes away is cancelled and its partial file removed; nothing keeps running unseen. Reason: the measurement shows the download would otherwise run to completion with no list to show it and no way to stop it short of quitting, and a Private window is expected to leave nothing going behind it.

- performClose (close button, Close Window, Cmd+W with no tab selected): windowShouldClose asks "N downloads are in progress. Closing this Private window cancels them." Close Window cancels and closes; Continue Downloading (Escape) keeps the window.
- Quit: the existing quit confirmation adds "N downloads in Private windows are in progress and will be cancelled." and Quit cancels them. One alert, not two.
- A window closed with close() and no question (an extension's windows.remove, the only other caller): not asked; DownloadManager.discardIncognitoDownloads cancels what is in flight when the incognito space is removed. That is the backstop for every path that removes the space, and unlistedItems is gone, so nothing can hold a running Private download.
- A normal download is never cancelled by a window closing (every normal window lists it).
- A Private window's CRX fetch counts as a download in progress and is cancelled the same way (its URLSessionTask), so no install prompt follows a closed window.

## Implementation

- PrivateDownloadClosePolicy (new, pure): cancels(downloadIn:isInFlight:closing:), decision(inFlightCount:) with the prompt's wording, quitWarning(inFlightCount:).
- DownloadManager: stop(_:removingPartialFile:) shared by cancelDownload, cancelPrivateDownloads(closing:) and discardIncognitoDownloads; privateDownloadsInFlight(closing:); unlistedItems removed; decideDestinationUsing returns nil for a download no listed item holds (so a download cancelled before WebKit asked writes nothing) and reads the item on the main actor; downloadsDirectory is a variable for tests.
- The partial file is removed twice on purpose: at once (at quit WebKit's reply never arrives) and on the cancel's reply (a file created in between). Only for an in-flight WKDownload; a manual item has no file.
- BrowserWindowController.windowShouldClose + confirmClosingWithPrivateDownloads (injectable; default runs the alert). AppDelegate.applicationShouldTerminate adds the warning and cancels.

## Tests (AC #3)

Failed before the change (run against main plus the downloadsDirectory seam): the real-download window-close test (6 assertions: transfer went on, item .downloading, file present and growing) and DownloadManagerTests.testAPrivateDownloadStillInFlightIsCancelledWhenItsWindowCloses (state .downloading, not .cancelled). The WebKit measurement test passed before and after, as it should. The policy and windowShouldClose tests use API that did not exist before.

After: PrivateDownloadTransferTests 2/2, PrivateDownloadClosePolicyTests 10/10, PrivateDownloadCloseWindowTests 5/5, DownloadManagerTests 35/35 (three unlistedItems tests replaced by five for cancel-on-close), DownloadWindowScopeTests 2/2, TabStoreTests 40/40, InitialWindowFocusTests 7/7, WebViewHandoffFocusTests 7/7. One xcodebuild run of 199 tests over the three tasks of this stream, 0 failures in these suites.

Not unit-tested: the three lines in applicationShouldTerminate (the alert is modal) and the alert itself.

## Review and runtime check

/code-review and /verify are not run here; they happen at batch integration. The runtime check should look at: closing a Private window with a download running (the question, its wording and buttons, Return = Close Window, Escape = Continue Downloading; declining keeps the window and the download; going ahead closes it and leaves no partial file in ~/Downloads); the quit confirmation's extra sentence with a Private download running; no question for a Private window with only finished downloads or for a normal window.

## Wiki (AC #4)

wiki/features/downloads.md (window-close section rewritten, edge cases, tests), wiki/architecture/incognito.md (downloads rules, where it lives), wiki/architecture/app-shell.md (quit), wiki/log.md.
<!-- SECTION:NOTES:END -->
