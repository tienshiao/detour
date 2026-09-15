---
id: TASK-81
title: >-
  Extensions: chrome.windows.getCurrent from a background worker reports 'Window
  not found' when that profile has no key window, so 1Password's sign-in-with
  setup throws
status: To Do
assignee: []
created_date: '2026-09-15 03:43'
labels:
  - extensions
  - 1password
  - bug
dependencies: []
priority: low
ordinal: 81000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-09-14 in the signed build with 1Password 8.12.37.1 (TASK-80 diagnosis), on every worker start in each profile: 'Error: Unchecked runtime.lastError: Invalid call to windows.get(). Window not found.' followed by '[uncaught exception] background.js:77:469521 TypeError: undefined is not an object (evaluating A.id)'. The code is 1Password's sign-in-with setup (js/b5x/background/src/background/sign-in-with/events.ts): chrome.windows.getCurrent(A => setSourceWindowId(A.id ?? WINDOW_ID_NONE)) — it assumes a window always comes back and never checks lastError. (The stack location _detour_polyfill_module.js:645 is only the console bridge's console.error wrapper, not the source.) Not blocking: the popup and the desktop-app connection work; the throw leaves 1Password's sourceWindowId at WINDOW_ID_NONE, which may affect where sign-in-with / popup-window flows return. Likely cause: WebKit resolves getCurrent in a background context through ExtensionManager's webExtensionController(_:focusedWindowFor:), which returns a window only when NSApp.keyWindow is a BrowserWindowController whose active space belongs to the controller's profile. At launch (no key window yet) and for every profile other than the key window's (Default/Work/Private each run a worker), that is nil. Chrome answers getCurrent from a service worker with the last focused window of that browser profile, and only errors when the profile has no window at all. Confirm first with API Explorer from a background context in a non-focused profile and at launch, then decide on the fix (e.g. focusedWindowFor falls back to the most recently focused window for that profile; check what else WebKit uses focusedWindow for — windows.getLastFocused, tabs.query currentWindow, onFocusChanged — so a fallback does not misreport focus).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documented: what chrome.windows.getCurrent and getLastFocused return from a background worker at launch, in the key window's profile, and in a profile without the key window, before and after the change
- [ ] #2 From a background context, getCurrent answers with the most recently focused window of the calling context's profile when one is open, and reports an error only when that profile has no open window
- [ ] #3 Focus-specific answers stay truthful: windows.onFocusChanged, getLastFocused(focused state) and tabs.query({currentWindow/lastFocusedWindow}) are unchanged or deliberately matched to Chrome, with tests for each
- [ ] #4 Tests cover the profile-scoping positive and negative cases (a window from another profile is never returned) and API Explorer exercises getCurrent/getLastFocused from the background
- [ ] #5 1Password's worker no longer logs the A.id TypeError on start in any profile (signed build)
<!-- AC:END -->
