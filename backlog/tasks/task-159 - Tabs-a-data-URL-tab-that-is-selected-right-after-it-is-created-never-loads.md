---
id: TASK-159
title: 'Tabs: a data: URL tab that is selected right after it is created never loads'
status: Done
assignee: []
created_date: '2026-10-04 09:14'
updated_date: '2026-10-04 10:23'
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
- [x] #1 The behaviour is reproduced in a test or harness and its cause is recorded: which policy branch, or which race between creation, claim and load, stops the navigation
- [x] #2 The intended rule for top-level data: URLs is decided and recorded (allowed everywhere, blocked everywhere, or allowed only when typed), and a background tab and a selected tab behave the same way
- [x] #3 A test covers the decided rule for a tab selected immediately after creation and for one loaded in the background
- [x] #4 If top-level data: navigations are refused on purpose, the tab shows that instead of an empty page titled with the URL
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce in a real BrowserWindowController: a data: tab created and selected in one run-loop turn, next to one left in the background (DataURLTabTests), and have the failure report what the window did instead.
2. Record the cause and decide the rule for top-level data: URLs.
3. Make the scheme rule a pure function with tests, fix the window's policy, and cover a selected tab, a background tab, a typed load, a data: frame and a page's own top-level navigation.
4. Wiki: external apps page and the navigation notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Cause (AC #1), 2026-10-04

Reproduced in a real BrowserWindowController (DataURLTabTests). Not a race in the load and not BrowserTab's delegate: the window's navigation policy refuses the navigation.

BrowserWindowController.decidePolicy (BrowserWindowController+Navigation.swift) hands every scheme other than http, https, about, blob, webkit-extension and browser-error to handleExternalAppNavigation and returns .cancel. data was not on that list. No application is registered for data: (NSWorkspace.urlForApplication(toOpen:) returns nil), so ExternalAppLaunchPolicy.decide returns .reportNoHandler for a main-frame request on screen: the window shows the toast "No application can open “data:” links" and the navigation is cancelled. The failing test recorded exactly that toast, no sheet, the web view with no URL and the tab titled with the URL.

Why 'selected in the same run-loop turn' matters: WebKit asks for the policy asynchronously after load(), and selectTab has by then made the window the web view's navigation delegate. A tab left in the background is its own delegate, which allows every action, so it loads. A later BrowserTab.load of the same URL in the selected tab is cancelled the same way, which is why loading it again 2.5 s later changed nothing.

The same branch also cancelled, before the fix: a data: URL loaded into the tab on screen (toast), a reload of a data: document, and every data: frame of a page on screen (ExternalAppLaunchPolicy drops a subframe request with no handler silently; its own comment named 'a data: iframe').

## Decision (AC #2)

As recommended: a data: URL is a document, never an external application's. data joins the schemes the browser loads itself, and Detour adds no rule of its own; what may navigate to one is left to WebKit, the same for a background tab and a selected one. Measured in a real window (macOS 26 WebKit): a data: URL the app loads (new tab, typed load), a reload of it, a sleeping tab's restored data: item and a data: frame all load; a page's script setting the top frame's location to a data: URL is refused by WebKit and the page stays where it is.

The scheme rule is now a pure function, ExternalAppLaunchPolicy.isForExternalApp(scheme:) over schemesLoadedInTheBrowser, and decidePolicy calls it.

AC #4 does not apply: nothing refuses a browser-started data: navigation on purpose. The one refusal left is WebKit's, of a page's own top-level navigation, and there the page stays as it is rather than leaving an empty tab.

## Tests (AC #3)

Failed before the fix (two runs against main): 5 of 7 DataURLTabTests — selected right after creation (base64, percent-encoded, Private window), a data: URL loaded into the selected tab, a data: frame in a selected tab. Passed before and after: the background tab, and a page's own top-level navigation staying refused.

After: DataURLTabTests 8/8 (the eighth, a sleeping tab woken by selecting it, was added after the fix and not run against the old code), ExternalAppLaunchPolicyTests 12/12 (3 new: which schemes are an application's), ExternalAppPermissionStoreTests 5/5, BrowserTabUnclaimedNavigationTests 3/3, WebViewHandoffFocusTests 7/7, InitialWindowFocusTests 7/7.

## Review and runtime check

/code-review and /verify are not run here; they happen at batch integration. The runtime check should look at: a data: tab selected at creation (it shows the document, takes its title, no toast); a data: URL typed into the address bar of the tab on screen; a page with a data: iframe.

## Wiki

wiki/features/external-apps.md (where it is caught, a section on data: URLs with the cause and WebKit's rules, edge cases, tests), wiki/log.md.

Integrated on branch bugfix-batch-2 (worktree .claude/worktrees/bugfix-batch-2), 2026-10-04. Full DetourTests suite on the integrated tree: 2081 tests, 10 skipped (gated legs), 0 failures; after the review fixes 2083 tests, 10 skipped, 1 failure — ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds'), a garbage-collection timing test outside this batch that passed in the first run and passes alone (26/26). Code review of the range a98904c..HEAD run with --fix (high).
Review: one real bug, fixed and folded into this task's commit. With data: allowed by the window's navigation policy, a page's target=_blank link to a data: URL reached createWebViewWith, which loads the URL into a new tab as an app-started load that WebKit does not refuse — so a page could open a top-level data: document (window.open could already, before this task). createWebViewWith now refuses a data: URL for a page's own new-window request; the context menu's Open Link in New Tab/Window still opens one. Two tests added (the _blank link and window.open), both failing before the fix; DataURLTabTests 10/10.
Runtime check (harness build, isolated profile): a data: tab created and selected in the same turn loaded (title and body present), as did one left in the background.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A data: URL now loads in a tab on screen: the window's navigation policy sent every scheme outside its list to the external-app prompt and cancelled it, and data was not on the list. The scheme rule is the pure ExternalAppLaunchPolicy.isForExternalApp(scheme:). Detour adds no rule of its own for browser-started data: loads; a page's own top-level navigation to one stays refused by WebKit, and its _blank link or window.open to one is refused in createWebViewWith (found in review). Verified in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
