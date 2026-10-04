---
id: TASK-165
title: >-
  Downloads: cancelling from the downloads popover leaves the partial file, and
  a normal download still running at quit is neither asked about nor cancelled
status: To Do
assignee: []
created_date: '2026-10-04 18:41'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Downloads/DownloadManager.swift
  - Detour/Browser/Downloads/DownloadPopoverViewController.swift
  - Detour/App/AppDelegate.swift
  - wiki/features/downloads.md
priority: low
ordinal: 188000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noticed 2026-10-04 while doing TASK-156 (a Private window's running download is cancelled, after asking, when the window closes or the app quits). Read from the code; neither case was produced in the running app.

1. The popover's cancel. DownloadManager.cancelDownload(_:) calls stop(item, removingPartialFile: false). TASK-156 measured that WKDownload.cancel stops the transfer and leaves the partial file where WebKit wrote it, so a download cancelled from the popover leaves a partial file in the downloads folder under the final file name, looking like a finished download. The Private-window paths (cancelPrivateDownloads, discardIncognitoDownloads) remove it.

2. Quit. AppDelegate.applicationShouldTerminate counts only Private downloads in flight (privateDownloadsInFlight(closing: .allWindows)), names them in the quit alert and cancels them. A normal download still running is not mentioned and not cancelled: the process exits mid-transfer. What that leaves has to be established first: the partial file on disk, the download row's state at the next launch (see TASK-143 for what is persisted at quit), and whether the item can be resumed or retried.

Chrome asks before quitting with downloads in progress and cancels them if the user goes ahead; Safari keeps the partial download as a resumable .download package. Decide the rule for each case before implementing; the pure rule belongs next to PrivateDownloadClosePolicy.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The task records what happens today in both cases, measured with a real download against a slow loopback server (SlowDownloadServer): the file left after a popover cancel, and the file and the download row after a quit mid-transfer and a relaunch
- [ ] #2 The intended behaviour is decided and recorded: whether a cancelled download's partial file is removed, and whether quitting with a normal download running asks, cancels, or keeps something resumable
- [ ] #3 Cancelling a running download from the popover leaves no file that looks like a finished download; a test with a real download fails before the change
- [ ] #4 Quitting with a normal download running follows the decided rule, with the quit alert's wording produced by a pure, tested function and one alert for normal and Private downloads together
- [ ] #5 After a quit mid-transfer and a relaunch, the downloads list does not show the interrupted download as running or finished
- [ ] #6 wiki/features/downloads.md is updated; the alerts are checked in the running app with /verify
<!-- AC:END -->
