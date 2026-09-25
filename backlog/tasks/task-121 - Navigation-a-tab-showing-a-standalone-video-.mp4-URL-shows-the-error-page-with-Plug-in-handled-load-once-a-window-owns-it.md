---
id: TASK-121
title: >-
  Navigation: a tab showing a standalone video (.mp4 URL) shows the error page
  with 'Plug-in handled load' once a window owns it
status: Done
assignee:
  - '@claude'
created_date: '2026-09-25 18:14'
updated_date: '2026-09-25 18:27'
labels:
  - bug
  - navigation
dependencies: []
priority: medium
ordinal: 121000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Loading a bare media URL such as https://simulationcorner.net/A_Bunch_of_Rocks.mp4 plays for about a second and then the tab shows the 'Looks like you took a Detour.' error page with the reason 'Plug-in handled load'. Reloading does the same.

Cause: WebKit renders a standalone video as a media document. When the media player takes over fetching the resource, WebKit cancels the main-resource load and reports it through webView(_:didFail:withError:) as WebKitErrorDomain code 204 (WebKitErrorPlugInWillHandleLoad). That is a benign signal, not a failed navigation, but BrowserWindowController's navigation delegate forwards every non-ignored failure to BrowserTab.didFailNavigation, which loads the error page. The tab's own delegate (used while no window owns the web view, e.g. a background load) has no failure handlers, so the same tab shows the video fine when first loaded in the background and only breaks once it is selected/woken and the window's delegate is attached. isIgnoredNavigationError already treats WebKitErrorDomain 102 and NSURLErrorCancelled this way; 204 belongs in the same set.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Opening or reloading a direct .mp4 (or other media document) URL in a selected tab plays the video and never shows the Detour error page
- [x] #2 isIgnoredNavigationError returns true for WebKitErrorDomain code 204 and still returns true for code 102 and NSURLErrorCancelled
- [x] #3 A real failure such as NSURLErrorCannotConnectToHost still shows the error page (isIgnoredNavigationError returns false)
- [x] #4 Unit tests cover the ignored/not-ignored classification
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend Error.isIgnoredNavigationError (BrowserWindowController+Navigation.swift) to also return true for WebKitErrorDomain code 204 (WebKitErrorPlugInWillHandleLoad); update its doc comment to explain the media-document case.
2. Add DetourTests/NavigationErrorClassificationTests.swift covering: WebKitErrorDomain 102 ignored, 204 ignored, NSURLErrorCancelled ignored, NSURLErrorCannotConnectToHost not ignored, WebKitErrorDomain 101 (cannot show URL) not ignored.
3. xcodegen generate; build; run the new tests (sandbox off).
4. Runtime check: load the .mp4 URL in a selected tab in a Debug build and confirm the video keeps playing with no error page.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause confirmed in WebKit source (WebLocalFrameLoaderClient::committedLoad): for a MediaDocument the main-resource load is cancelled with pluginWillHandleLoadError (WebKitErrorDomain 204) right after commit; WebKit's own shouldFallBack treats it like a cancellation. Detour's BrowserTab-as-delegate (unowned web view) has no didFail handlers, so a background load never showed the error page; the window controller's delegate did. Fix: isIgnoredNavigationError now ignores 204. Unit tests (NavigationErrorClassificationTests, 6 tests) pass.

Runtime check (Debug build, isolated DETOUR_DATA_DIR, temporary env-gated harness since reverted): with the fix, the selected tab's webView.url stays https://simulationcorner.net/A_Bunch_of_Rocks.mp4 through the initial load and a reload. Baseline without the fix: webView.url becomes browser-error://error?...&message=Plug-in%20handled%20load within 4 s of load and again after reload — the exact report.

Code review (/code-review --fix) split the predicate: isSupersededNavigationError (WebKit 102 + NSURLErrorCancelled: another callback follows) vs isPlugInHandledLoadError (WebKit 204: committed, no didFinish follows); isIgnoredNavigationError = both, used only by the window delegate. OffscreenDocumentHost.failLoad now checks isSupersededNavigationError so a media-document 204 settles createDocument as a failure instead of hanging. 9 classification tests pass. Review also noted (not fixed, pre-existing): BrowserTab's own WKNavigationDelegate has no didFail handlers, so a genuinely failing background load never shows the error page.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
isIgnoredNavigationError (BrowserWindowController+Navigation.swift) now also ignores WebKitErrorDomain 204 (WebKitErrorPlugInWillHandleLoad), the benign error WebKit reports after committing a standalone media document once the media player takes over the resource load. New NavigationErrorClassificationTests (6 tests) pin the ignored set (102, 204, NSURLErrorCancelled) and the non-ignored cases (cannot connect, WebKit 101, code 204 in another domain). Verified in a Debug build with an isolated data dir: the .mp4 tab's web view stays on https:// through load and reload, whereas the unfixed build switched to browser-error://...Plug-in%20handled%20load within 4 s. Not committed.
<!-- SECTION:FINAL_SUMMARY:END -->
