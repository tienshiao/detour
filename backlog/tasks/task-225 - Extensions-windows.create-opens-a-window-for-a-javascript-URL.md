---
id: TASK-225
title: 'Extensions: windows.create opens a window for a javascript: URL'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-28T07:56:00Z'
updated_date: '2026-10-28T11:48:00Z'
labels:
  - extensions
  - security
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-214
priority: low
ordinal: 261000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-214 (2026-10-28) while reviewing the URL checks in openNewWindowUsing: the installed WebKit (seen on Darwin 25.6) passes javascript: URLs in windows.create's url list through to the delegate, and Detour opens a window for them. WebKit's current source refuses javascript: URLs in windows.create, so this may go away with an OS update, but until then Detour should refuse them itself, as Chrome does. tabs.create and tabs.update may have the same gap; check them too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 windows.create with a javascript: URL (alone or among other URLs) is refused with an error and opens no window, as a promise rejection and as runtime.lastError
- [x] #2 tabs.create and tabs.update are checked for the same gap and, if they have it, refuse javascript: URLs too, with tests
- [x] #3 wiki/extensions/tab-and-window-bridge.md records the behaviour and which WebKit versions pass the URL through
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Probe first (real contexts, ExtensionWindowsCreatePrivateTests gains a generic worker 'call' message): windows.create with a javascript: URL alone and among other URLs; tabs.create({url: javascript:}); tabs.update(tabId, {url: javascript:document.title=...}) on a loaded http tab. Record which ones WebKit passes through to Detour's delegates.
2. Red tests for each that has the gap: refused with an error, no window/tab, page untouched; both transports, promise and callback.
3. Green: refuse javascript: in openNewWindowUsing (any URL in the list), openNewTabUsing and BrowserTab.loadURL (tabs.update), before anything opens or loads, with one shared predicate next to the detour:// check.
4. Wiki tab-and-window-bridge (behaviour + WebKit build that passes it through), log; API Explorer only if it has a javascript: case.
5. /code-review --fix, /verify with a probe extension, suites, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Probe/red (real contexts, worker and page x promise and callback): windows.create with ['javascript:void(0)'] and [http URL, javascript:...] opened a normal window each time (16 assertion failures); tabs.create({url: javascript:...}) opened 4 tabs with the javascript: URL; tabs.update(tabId, {url: javascript:document.title='ran'}) succeeded and ran the script in the tab's page (title went from 'Looked Up' to '', tab.url became the javascript: URL). So all three have the gap on macOS 26.7 (25G229). Green after the change. Messages: WebKit prefixes 'Invalid call to <api>().' and capitalises the first letter, so the message starts 'Cannot load a javascript: URL'.
Test-suite notes: (a) the three probes were folded into one test (one profile) because with three more profile-loading tests in this suite, QuickDetourExtensionTests run after it in the same process timed out on page loads (3/3; the stuck Quick Detour tab stays isLoading with no title; its windows report occluded; not the open-file limit: soft limit 2560, ~250 used). HEAD's pair also failed once in two runs. (b) Fixed a test-only identity bug in create(): it compared ObjectIdentifiers of the window controllers before the call, so a closed controller freed during the call could hand its address to the new one (seen as 'opened 0 windows' with no error).

Code review (/code-review --fix, 6 findings): fixed - the wiki section had split 'Opening a window' (moved after the TASK-223 paragraph); the isJavaScriptURL comment wrongly said URL lower-cases schemes (Foundation keeps 'JavaScript'); added testTheJavaScriptURLRule (case-insensitive, not fooled by 'javascript:' in a path or data: URL); the worker 'call' handler now returns synchronous throws. Not taken: the fixed 500 ms wait before reading the page title (the tab URL check is the deterministic one: in the red run tab.url became the javascript: URL at once); one shared refusal function for detour:// and javascript: (the detour:// messages differ per API; follow-up candidate).
Tests after review: ExtensionWindowsCreatePrivateTests 15/15, InternalPageTests 17/17, ExtensionPrivateDefaultTests 13/13 (45, 0 failures); BrowserTabWakeTests 7/7 + QuickDetourExtensionTests 18/18 (25, 0 failures).
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify225a, Debug build in .derived, probe extension seeded in the Default profile, local page on 127.0.0.1:18225): the worker logged 'windows.create rejected Invalid call to windows.create(). Cannot load a javascript: URL; use chrome.scripting.executeScript instead.', the same for tabs.create, and for tabs.update on an http tab both the rejection and the callback lastError; no window or tab opened for the javascript: URLs and the tab's window kept the page title 'Probe Page'. Not verified: the callback forms of windows.create/tabs.create at runtime (covered by tests); the API Explorer has no javascript: case and was not changed. Seen in passing: in the probe worker a setTimeout(3000) and a tabs.onUpdated listener added after awaits never fired; not investigated.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
windows.create (a javascript: URL alone or among others), tabs.create and tabs.update now refuse javascript: URLs before anything opens or loads (ExtensionManager.isJavaScriptURL, case-insensitive; checked in openNewWindowUsing, openNewTabUsing and BrowserTab.loadURL), with 'Cannot load a javascript: URL; use chrome.scripting.executeScript instead', as Chrome MV3 does. The probing tests showed all three had the gap on macOS 26.7 (25G229, Darwin 25.6): a window, a tab, and for tabs.update the script ran in the tab's page. Tests: one real-context test over the three APIs (both transports, both forms) plus a pure-rule test; red before, 15/15 green after; runtime probe confirmed the refusals. Test fix: create() now holds the pre-call window controllers so a freed controller's address cannot hide a new window. Wiki: tab-and-window-bridge 'javascript: URLs', extension-manager, log. Follow-ups: a shared refusal helper for extension-supplied URLs; cross-suite page-load stalls when QuickDetourExtensionTests runs after this suite (more retained profiles, occluded windows on a loaded machine).
<!-- SECTION:FINAL_SUMMARY:END -->
