---
id: TASK-132.5
title: >-
  Extensions: tabs.create and windows.create with chrome://newtab open a blank
  new tab
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:07
updated_date: '2026-11-07T23:22:00Z'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: medium
ordinal: 137000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension opens every agent tab with tabs.create({url: 'chrome://newtab', active: false}) and reports 'chrome://newtab/' as the tab URL. Detour has no mapping for it, so the tab would load an error page. Map Chrome's new-tab URL to Detour's blank tab in the openNewTabUsing / openNewWindowUsing delegate paths.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 tabs.create({url: 'chrome://newtab'}) and the trailing-slash form create a blank tab that shows no error page and can then be navigated with tabs.update
- [x] #2 windows.create({url: 'chrome://newtab'}) opens a window with one blank tab
- [x] #3 Other chrome:// URLs are still refused rather than loaded
- [x] #4 Tests cover the mapped and refused cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Research: where extension tab/window creation lands (ExtensionManager openNewTabUsing / openNewWindowUsing, BrowserTab.loadURL for tabs.update; the polyfill does not wrap tabs.create/windows.create), what WebKit passes through (canNavigateToURL refuses only javascript: and file:), and what the Claude extension relies on.
2. Add one pure rule in ExtensionManager next to isJavaScriptURL: chrome://newtab (with or without trailing slash, any case, ignoring query/fragment) maps to about:blank, the same blank tab tabs.create({}) opens; every other chrome: URL is refused with a message.
3. Apply it in openNewTabUsing, openNewWindowUsing (every URL in the list; refused before a window opens) and loadURL (tabs.update), alongside the javascript: refusal.
4. Tests in ExtensionWindowsCreatePrivateTests (real contexts, worker + extension page, promise + callback): the rule; tabs.create both forms of newtab -> blank tab, then tabs.update navigates it; windows.create newtab -> one window, one blank tab reported in window.tabs; chrome://settings etc refused by tabs.create, windows.create and tabs.update with nothing opened. One profile to keep retained profiles down.
5. API Explorer check if meaningful; wiki (tab-and-window-bridge, epic table, log); /code-review --fix, /verify, commit on task-132.5.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Research (2026-11-07):
- Extension tab/window creation lands in ExtensionManager openNewTabUsing / openNewWindowUsing; tabs.update in BrowserTab.loadURL (WKExtensionTabConformance). The polyfill wraps none of tabs.create / windows.create / tabs.update.
- WebKit passes chrome: URLs through: WebExtensionContext::canNavigateToURL refuses only javascript: and (without file access) file:. The URL arrives as written, resolved against the base URL (chrome://newtab keeps no slash). Before this change a chrome: URL went down the external-application path (not a scheme a web view loads) and left an empty tab.
- Claude extension bundle 1.0.105: tabs.create({url:'chrome://newtab'|'chrome://newtab/', active:false}) and windows.create({url:'chrome://newtab'|'chrome://newtab/'}) then reads tabs[0].id. It writes 'chrome://newtab/' only into tab lists it builds itself; its own URL checks treat about:, chrome:// and '' alike as not-a-site (Nz, xye, the 'system' classifier, hostname fallback 'blank').

Decision: chrome://newtab (with/without slash, any case, query/fragment ignored) -> about:blank, the same blank tab tabs.create({}) already opens. Every other chrome: URL is refused before anything opens/loads (tabs.create, windows.create - one refused URL in the list refuses the call - and tabs.update), message 'Cannot open <url>: the only chrome: URL Detour opens is chrome://newtab'. tabs.update to chrome://newtab blanks the tab, for consistency.
What the extension sees: url '' (and no title). Found in the first test run: WebKit's WebExtensionTab::redactIfNeeded blanks url/title whenever permissionState(url) is not granted, and permissionState answers Unknown for any scheme outside the match-pattern schemes, so an about: tab is redacted even with tabs + <all_urls>. A chrome://newtab/ reported via url(for:) would be redacted the same way, so reporting it was rejected (no effect, plus a second URL to keep in step). Leaving the tab with no URL was rejected too (a path no other extension call takes).
Out of scope, seen: windows.create opens on the profile's most recently used space and reports all its tabs, so tabs[0] is the new blank tab only when that space was empty (TASK-132.23, one window per space).

Tests: ExtensionWindowsCreatePrivateTests +2 (testTheChromeURLRule; testChromeNewTabOpensABlankTabAndOtherChromeURLsAreRefused - windows.create both forms from worker+page, tabs.create both forms x both transports x both forms, tabs.update navigation from both transports followed by id via tabs.get, chrome://settings / extensions/ / newtab/x refused by all three APIs in every transport/form with nothing opened or loaded, tabs.update chrome://newtab/ blanks). First run: 18 tests, 14 failures (expected url 'about:blank', got '' - the redaction above; and the tabs.update wait assumed creation order). After fixing the test: 18 tests, 0 failures.
API Explorer: Create Tab gets a 'chrome://newtab' button (background tab, shows id and the reported url).

Review (/code-review --fix): no correctness bug in the change. Fixed: folded the ChromeURLMapping enum into ExtensionManager.loadableExtensionURL (url / about:blank / nil), and windows.create maps its URL list in one loop. Reported, not changed (outside this task): (1) pre-existing: BrowserTab.loadURL (tabs.update) calls webView?.load and reports success when the tab has no web view - a slept background agent tab would silently not navigate; (2) the side panel's window.open / links still reach addTab(in:url:) with a chrome:// URL unmapped; (3) the detour:// / javascript: / chrome: checks repeat in three call sites; (4) windows.create({}) shows the command palette and opens no tab, unlike windows.create({url:'chrome://newtab'}); (5) chrome://new-tab-page/ (Chrome's real NTP host) is refused; (6) about:blank literals duplicated elsewhere. Suite after the review: ExtensionWindowsCreatePrivateTests 18 tests, 0 failures (re-run by me on the final code). Neighbouring suites (InternalPageTests, ExtensionPageRehostTests, BrowserTabWakeTests, WKExtensionIntegrationTests, ExternalAppLaunchPolicyTests): 73 tests, 0 failures (run before the review's refactor; the refactor changed no behaviour).

/verify (runtime, isolated DETOUR_DATA_DIR=DetourVerify-task1325b, final build): seeded a probe extension (tabs, storage, <all_urls>) whose worker at start calls the APIs and logs to the unified log (-ExtensionConsoleLogPublic YES). Observed: tabs.create chrome://newtab and chrome://newtab/ (active false) -> tabs 51/77, url '' ; tabs.create chrome://settings, windows.create chrome://extensions, tabs.update chrome://settings -> each refused with 'Invalid call to <api>(). Cannot open <url>: the only chrome: URL Detour opens is chrome://newtab.'; tabs.update(51, https://example.com/) -> tabs.get reports url https://example.com/, title Example Domain, complete; windows.create chrome://newtab/ (focused) -> a second window whose tabs[0] is the new active blank tab (the window also lists the space's two earlier tabs - TASK-132.23). Session DB rows: about:blank, about:blank, https://example.com/. Window capture: the new window shows a white content area, the sidebar lists the blank rows titled 'about:blank', no error page, no external-app prompt. Not checked at runtime: the real Claude extension (TASK-132.20, signed build). Cosmetic, not changed: a blank tab's sidebar title reads 'about:blank' (as for any tabs.create({}) tab), where Chrome shows 'New Tab'. Data dirs and the window/split-view defaults keys of both verify runs were deleted afterwards.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome://newtab, with or without its trailing slash (any case, query/fragment ignored), now opens Detour's blank tab (about:blank, the same tab tabs.create({}) opens) from tabs.create, windows.create and tabs.update; every other chrome: URL is refused before anything opens or loads ('Cannot open <url>: the only chrome: URL Detour opens is chrome://newtab'; one in a windows.create list refuses the call). Before, WebKit passed chrome: URLs through and Detour sent them down the external-application path, leaving an empty tab. One rule, ExtensionManager.loadableExtensionURL, used in openNewTabUsing, openNewWindowUsing and BrowserTab.loadURL.

What the extension sees: url '' and no title, because WebKit redacts the URL of any tab whose scheme is not a match-pattern scheme (about: and chrome: alike), whatever the permissions; reporting chrome://newtab/ would be redacted the same way. The Claude extension (1.0.105) treats '', about: and chrome:// alike, and only writes chrome://newtab/ into tab lists it builds itself.

Tests: ExtensionWindowsCreatePrivateTests +2 (the rule; real contexts from worker and extension page, promise and callback: blank tabs from both URL forms, navigation by tabs.update, windows.create with one blank tab, refusals in all three APIs) - 18 tests, 0 failures; neighbouring suites 73/0. Runtime check in an isolated profile with a probe extension confirmed the same behaviour in the app. API Explorer: Create Tab has a chrome://newtab button. Wiki: tab-and-window-bridge 'chrome: URLs'.

Follow-ups worth filing (not done): tabs.update on a slept tab silently does nothing (pre-existing, loadURL uses webView?.load); side panel window.open/links do not map chrome://newtab; chrome://new-tab-page/ is refused; windows.create({}) opens no tab; windows.create lists every tab of the space it opens on (TASK-132.23).
<!-- SECTION:FINAL_SUMMARY:END -->
