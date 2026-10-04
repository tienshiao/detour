---
id: TASK-159
title: 'Tabs: a data: URL tab that is selected right after it is created never loads'
status: To Do
assignee: []
created_date: '2026-10-04 09:14'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+Navigation.swift
  - Detour/Browser/BrowserTab.swift
priority: low
ordinal: 182000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-10-04 in a debug harness (TASK-133/135 runtime checks); not investigated, and it may be intended.

The harness created two tabs with TabStore.addTab(in:url:) from base64 data:text/html URLs that differ only in their title. The first was left in the background and loaded normally (title set, its script ran). The second was selected with selectTab in the same run-loop turn it was created in, and never loaded: its title stayed the URL, document.getElementById on its content returned null, and calling BrowserTab.load with the same URL again 2.5 s later changed nothing. The same happened in an earlier harness run with a percent-encoded data: URL in a Private window (also selected immediately); https tabs created and selected the same way loaded.

One difference between the two cases: the background tab loads under BrowserTab's own navigation delegate, which allows every action, while the selected tab's web view is claimed by the window, whose navigation policy handles non-web schemes (external apps) and downloads. Whether that policy refuses or diverts a top-level data: navigation, on purpose or not, is the first thing to establish.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The behaviour is reproduced in a test or harness and its cause is recorded: which policy branch, or which race between creation, claim and load, stops the navigation
- [ ] #2 The intended rule for top-level data: URLs is decided and recorded (allowed everywhere, blocked everywhere, or allowed only when typed), and a background tab and a selected tab behave the same way
- [ ] #3 A test covers the decided rule for a tab selected immediately after creation and for one loaded in the background
- [ ] #4 If top-level data: navigations are refused on purpose, the tab shows that instead of an empty page titled with the URL
<!-- AC:END -->
