---
id: TASK-186.4
title: >-
  Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network
  tabs
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 21:01'
labels:
  - dev-mode
  - webkit
  - feature
dependencies:
  - TASK-186.2
parent_task_id: TASK-186
priority: medium
ordinal: 212000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fourth part of TASK-186. Buttons in the dev toolbar that open/close the docked Web Inspector on the Console and on the Network tab (Arc also has an element picker; optional).

WebKit gives no public API for this. Today the Develop menu opens the inspector through the private `_inspector` object's `show` (BrowserWindowController.showWebInspector). The private _WKInspector also has `showConsole`, `hide`/`close`, `isVisible` and `toggleElementSelection`; there is no Network-tab call, so opening Network needs research (WebKit source: _WKInspector.h / WebInspectorUIProxy; possibly the frontend's own API). Record what works on the shipped macOS and what was rejected, and guard every private selector with respondsToSelector so a WebKit change hides the button instead of crashing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Console button opens the inspector on the Console tab and closes it when it is already showing that tab
- [x] #2 Network button opens the inspector on the Network tab, or the finding that it cannot be done is recorded and the button is left out
- [x] #3 Private API use is guarded and documented in the wiki (platform page)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built (2026-10-24, Opus subagent): Detour/Browser/DevMode/WebInspectorControl.swift is the only place touching private API: _WKInspector isVisible/show/showConsole/close/inspectorWebView/toggleElementSelection/isElementSelectionActive (all present on macOS 26.7 25G229, WebKit 21624.5.1.11.3), each checked with responds(to:) (also _inspector before KVC), BOOL getters read through their IMP; frontend JS in inspectorWebView: WI.showNetworkTab()/WI.showConsoleTab() and WI.tabBrowser.selectedTabContentView.type, every script try-wrapped. Capabilities read once; a button whose calls are missing is left out (no group at all if none). Pure rule InspectorToggle.action(isVisible:currentTab:requested:) -> show/switch/close; an unknown tab or unanswering frontend means switch, never close. DevToolbarInspectorGroup: Console (terminal), Network (globe), Select Element (scope); addTrailingGroup(_:order:) orders link | capture (186.3) | inspector. Buttons act on their own pane's web view (focus is best effort; the call names its web view so it cannot hit the other pane).

Decisions: press calls show, not attach (attach forces the bottom dock and overwrites the saved side), so the inspector opens where WebKit last had it, or in its own window below WebKit's 500 pt docking minimum; close, not hide (hide keeps the frontend process alive); Console/Network buttons are stateless (tab switches inside the inspector are not reported to the app), the picker tints while on (polls isElementSelectionActive). Canary test testThisWebKitSupportsEveryButton fails if a macOS update drops a selector, deliberately.

TDD: WebInspectorControlTests red 10/22 failing (the 12 passing are cases default stubs satisfy and UI group tests), green 22/22. Stated reason (CLAUDE.md TDD rule): WebInspectorToggler (open/retarget/timeout around the async frontend load) has no unit test because it needs a live inspector frontend (a separate WebContent process over private SPI) in the test host, where WebKit traps are a known risk; it is covered by the runtime harness instead.

/code-review --fix: 9 findings, 6 fixed: picker start grace 1 s -> 5 s; picker tint re-synced when the toolbar is re-wired and the timer cleared on leaving the window; an inspector closed while loading ends the wait; the open-inspector branch decides on the answer's arrival using the current isVisible (two quick presses no longer act on stale state); ready check needs only WI.tabBrowser; init cleanup. Skipped: _WKInspectorDelegate inspectorFrontendLoaded: instead of polling (design change, another SPI protocol); isAttached kept (harness diagnostics); toggler tests (reason above).

Tests after review: 163/163 (WebInspectorControlTests 22, DevToolbarLayoutTests 21, DevToolbarHostingTests 11, DevModeTests 31, DevModeSiteOverrideTests 15, SplitTabTests 63).

Runtime (docs/harness/task186-4-harness.patch; final run after the review, screen unlocked, log identical to the pre-review run except the app-active state at step 6d): Console from closed opens docked on console; again closes; Network from closed opens on network (~0.1-0.4 s); Console while on Network switches; Network on Network closes; after the user picks Elements, Console switches rather than closes; two presses in one turn open on the second's tab; reopened after docking right stays right; picker on a closed inspector turns on (tint) and off again; in a split the unfocused pane's buttons focus it and dock the inspector in that pane only, Network switches, again closes; a pane under 500 pt opens the inspector in its own window. A run attempted while the screen was locked was discarded. Defaults: only WebKit2InspectorStartsAttached existed before; the added WebKit2InspectorAttachmentSide was deleted. Not verified: actually picking an element (synthetic events don't reach WebKit's selection overlay; needs a real click), dark captures of the new buttons, a second window's snapshot with an inspector open.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dev toolbar Console, Network and Select Element buttons: open the inspector on that tab, switch to it, or close it when already there, through guarded _WKInspector SPI plus the inspector frontend's own WI.show*Tab calls, all in one documented type; missing SPI hides a button. 163 tests pass; runtime harness clean after review (pick-an-element itself needs a real click).
<!-- SECTION:FINAL_SUMMARY:END -->
