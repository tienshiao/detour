---
id: TASK-214
title: >-
  Extensions: an extension allowed in Private can open a normal-profile window
  with windows.create
status: Done
assignee:
  - '@claude'
created_date: 2026-10-27 22:21
updated_date: '2026-10-28T15:15:00Z'
labels:
  - extensions
  - security
  - private
dependencies: []
references:
  - Detour/Extensions/Runtime
priority: high
ordinal: 250000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the second high review of TASK-194 (Quarantine). An extension that is allowed to run in Private (and so also in quarantine windows) can call windows.create without incognito: true. That opens a normal window on the default profile, with the profile's cookies and history, at any URL the extension passes, including the address of the Private or quarantine page it is running in. This predates Quarantine and affects Private windows too.

Decide the rule (for example: a call from a Private/quarantine context opens a Private window unless the extension also has normal-profile access, matching Chrome's split/spanning incognito modes) and enforce it in the native windows.create handler.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A windows.create call from an extension context running in a Private window or a quarantine window cannot open a window on a normal profile unless the decided rule allows it
- [x] #2 Calls from a normal-profile context behave as today
- [x] #3 Tests in a real extension context (ExtensionPolyfillIntegrationTests style) cover both transports, both the promise and callback lastError forms, Private and quarantine sources, and a normal-profile source
- [x] #4 The API Explorer extension and the extensions wiki describe the rule
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decided with the user 2026-10-27: every windows.create from an extension context in an incognito profile (its Private windows' and its quarantines' — they share the Private profile's controller) opens a Private window, whatever incognito says. WebKit hands the delegate `incognito ?? false` (WebExtensionContextAPIWindowsCocoa.mm windowsCreate), so an explicit false cannot be told from an omitted one; the 'unless the extension has normal-profile access' exception would have kept the leak for every plain call. Normal-profile callers unchanged.
1. Red: ExtensionWindowsCreatePrivateTests (real contexts via Profile.extensionController + ExtensionManager delegate): Private source with incognito omitted / false / true, from the worker and an extension page, promise and callback forms (lastError null, window.incognito true, the new BrowserWindowController incognito, no normal window opened, URL in the incognito space); quarantine source (a quarantine window key); normal source opens a normal window, incognito:true a Private one. Plus a unit test of the pure rule.
2. Green: ExtensionManager.opensPrivateWindow(requested:callerIsIncognito:) used by openNewWindowUsing; unknown caller profile refused.
3. API Explorer: windows.create buttons (normal / incognito) in the Windows section.
4. Wiki: tab-and-window-bridge + private-profile-extensions rule; log line; lint.
5. /code-review --fix, tests, /verify.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-27 implementation.
- Rule (user's decision): ExtensionManager.opensPrivateWindow(requested:callerIsIncognito:) = requested || callerIsIncognito, used by openNewWindowUsing. WebKit sets shouldBePrivate = creationParameters.privateBrowsing.value_or(false) (WebExtensionContextAPIWindowsCocoa.mm windowsCreate, read on main 2026-10-27), so an explicit false and an omitted key look the same; the proposed 'unless the extension has normal-profile access' exception would have kept the leak for every plain call and was dropped. A caller whose profile cannot be resolved is refused.
- Code review (high, --fix): windows.create now refuses detour:// URLs before a window exists (it used to drop them and report an empty window as a success, unlike tabs.create, TASK-86); an error-case test added; pageEval moved into ExtensionTestSupport; .fragmentsAllowed on the callback decode. javascript: URLs are not refused by the installed WebKit (a window opens), left as is.
- Red before the fix: the Private, quarantine and incognito:false cases opened a normal window (window.incognito false, a tab in a normal space).
- Behaviour kept as before: a normal context asking for incognito:true gets a Private window but WebKit resolves with undefined (no Private-data access).
- Tests: ExtensionWindowsCreatePrivateTests 8/8, 3 iterations (24/24); QuickDetourExtensionTests, ExtensionPrivateDefaultTests, ExtensionPrivateStoreTests, WKExtensionIntegrationTests 56/56. The reviewer saw one failure of testFromPrivateWithoutIncognitoOpensAPrivateWindow (worker callback, no window) right after a since-removed javascript: experiment left windows open; not reproduced in 4 later runs.
- Runtime (/verify, Debug build in .derived, DETOUR_DATA_DIR=DetourVerify214): a seeded probe allowed in Private called windows.create at worker start. Log: normal context -> {incognito:false}; Private context, incognito omitted -> {incognito:true}; incognito:false -> {incognito:true}; detour://history -> rejected 'Cannot open a detour:// URL'. browser.db persisted only the normal call's tab (in Home); 3 page windows on screen (1 normal, 2 Private). Defaults keys and data dir of the run removed. Not checked at runtime: a quarantine window in front (covered by the test), the API Explorer buttons (markup only).
- Not in scope (follow-up candidates): a normal caller's window lands on the key window's space, which can be another profile's (tabs.create uses the caller's profile); a normal context without Private access can open Private windows (Chrome refuses); javascript: URLs open a window.

Runtime re-check 2026-10-28 (screen unlocked): (E) API Explorer seeded in DetourVerifyRTE, popup opened from the pinned button, Windows buttons pressed with real HID-tap clicks. The Windows section is below the 600 pt fold and the popup cannot scroll (TASK-150), so the section was moved to the top of the popup's DOM from script before clicking; the buttons and handlers are unchanged. Create: a normal window opened on Home with example.com, explorer showed {id, incognito:false, type:normal}. (H) Quarantine in front (opened by the harness on https://example.com/?rt=wincreate&h=1), the Private context of a probe allowed in Private saw the quarantine tab and called windows.create({url}): resolved {incognito:true}, a new Private window with a new Private space opened with the URL; nothing persisted to browser.db. Data dirs and their defaults keys removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
windows.create from an extension context in the Private profile (Private windows and quarantines share it) always opens a Private window, whatever incognito says, so an extension allowed in Private can no longer carry a Private or quarantined page's address into a normal profile's cookies and history. WebKit passes incognito ?? false, so the rule cannot follow an explicit false; decided with the user. Normal-profile calls unchanged. Review added: detour:// URLs in windows.create are refused instead of giving an empty window. Tests: ExtensionWindowsCreatePrivateTests (8, both transports, promise and callback, Private/quarantine/normal sources, the internal-URL error), related extension suites 56/56; runtime-checked with a seeded probe extension in an isolated profile. API Explorer gained Create / Create Private; wiki: tab-and-window-bridge 'Opening a window', private-profile-extensions, extension-manager, quarantine. Follow-up candidates (not filed): cross-profile placement for normal callers, normal contexts opening Private windows, javascript: URLs.
<!-- SECTION:FINAL_SUMMARY:END -->
