---
id: TASK-132.8
title: 'Extensions: host an extension''s per-tab side panel beside the tab''s content'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 23:08'
updated_date: '2026-10-04 20:06'
labels: []
dependencies:
  - TASK-132.1
parent_task_id: TASK-132
priority: high
ordinal: 140000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Show an extension side panel (chrome.sidePanel) as a trailing pane of the content area. The Claude extension sets a tab-specific panel (sidepanel.html?tabId=N) and opens it from its toolbar action and from the toggle-side-panel command (Cmd+E). Reuse the split view's hosting approach (frame-based NSSplitView, divider, remembered fraction; Auto Layout breaks the docked Web Inspector) but not the split-tab model: the panel is not a BrowserTab, has no sidebar row and is never selectedTabID. Whether the web view comes from WebKit's _WKWebExtensionSidebar or a Detour-built one follows the spike's decision. API surface: setOptions, getOptions, open, close, setPanelBehavior, getPanelBehavior.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Clicking the Claude toolbar action, or pressing its command shortcut, opens the panel beside the current tab; the shortcut pressed again closes it
- [x] #2 A tab-specific panel shows only with its tab: switching tabs swaps or hides it, and switching back restores it without reloading the panel page
- [x] #3 The panel does not appear in tabs.query, the sidebar, the Control+Tab switcher or closed-tab records, and Cmd+W closes the tab rather than the panel
- [x] #4 A split tab with a panel shows both panes plus the panel, and the Web Inspector still docks
- [x] #5 The divider can be dragged, has a minimum width, and the width is remembered
- [x] #6 The user can close the panel from Detour's UI, and closing its tab or disabling the extension tears it down
- [x] #7 A tab shown in two windows shows its panel only in the window that owns the web view
- [x] #8 In a Private window the panel appears only when the extension is allowed in Private
- [x] #9 An extension without the sidePanel permission gets no chrome.sidePanel; tests cover both, and API Explorer has a side panel section
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision from TASK-132.1 (2026-10-03): polyfill. Released WebKit compiles its sidePanel implementation out, so chrome.sidePanel is a Detour own-property module (setOptions / getOptions / open / close / setPanelBehavior / getPanelBehavior, state kept natively per profile + extension + tab/window) and the panel is a Detour-built WKWebView made from context.webViewConfiguration, the way OffscreenDocumentHost builds its page. WebKit will not grant activeTab on panel interaction, will not report the panel anywhere, and does not know the sidePanel permission (it is absent from WKWebExtension.requestedPermissions), so gate the module on the manifest's permission list. Because the panel web view is not a tab, tabs.getCurrent() in it must answer undefined — confirm when built.

Built (2026-10-04). chrome.sidePanel is a polyfill module gated on the manifest's sidePanel permission; state is native per profile + extension (ExtensionSidePanelState, pure; Profile.sidePanels). The panel is a WKWebView from context.webViewConfiguration, hosted by SidePanelLayoutView (frames, not an NSSplitView: one remembered width in points for all panels, not a fraction as the description says). ExtensionSidePanelController.reconcile decides for all windows at once which panel each shows; a tab panel follows the tab's live web view. Also added because the Claude toggle needs it: BrowserWindow.performKeyEquivalent -> ExtensionCommandDispatch (nothing called performCommand(for:) before, so no extension shortcut ever fired). docs/extensions.md has "Side panel" and "Command shortcuts"; wiki pages extensions/side-panel, extensions/command-shortcuts, decisions/polyfilled-side-panel, playbooks/side-panel-runtime-check.

/code-review --fix (high), 10 findings. Fixed: (1) a panel page that focuses a field made its web view first responder with no gesture -> _setShouldSuppressFirstResponderChanges: (SPI, guarded) + ExtensionSidePanelWebView takes the keys on mouse down; (2) a tab panel closed when its selected tab moved to another space (TabStore removes, notifies, then inserts) -> closeIfStillUnlisted re-checks one main-queue turn later; (3) ExtensionPopoverController.show never called onClose when it put up no popover, leaving the address bar buttons stuck visible; (4) a window panel kept showing beside a tab the extension disabled it for -> sidePanelToDisplay(isDisabledForTab:), hidden not closed. Skipped, with reason: _execute_action shortcut does not toggle the panel under openPanelOnActionClick (new behaviour, needs its own fixture; Claude has no such command); getContexts omits POPUP while the popup page loads (docs define POPUP as showing); recency is dead state since open() replaces a same-scope panel (cleanup only); reconcile() walks the windows on every selection change even with no panel (small cost); a tab's options outlive a move to another profile (low impact); sidePanelOp is duplicated in API Explorer's popup.js and background.js.

Found by the full suite, not side panel code: closing a window's selected tab through TabStore.closeTab (tabs.remove, another window) released the web view before the window heard of it, so the window's linkHover / editableFieldFocus handlers stayed on the dead web view's content controller and kept the closed window's controller alive (leaks --traceTree: held by a ScriptMessageHandlerDelegate). BrowserTab.releaseWebView now removes them; regression test testAWindowWhoseSelectedTabTheStoreClosedIsReleased.

Tests: full DetourTests run 2090 tests, 9 skipped (env-gated), 4 failed test cases — the same 4 ExtensionPolyfillProfileWiringTests background-page onInstalled cases fail on the unmodified parent commit 303519d in a full run (1987 tests there) and pass when the suite runs alone, so they predate this task. New suites: ExtensionSidePanelStateTests 27, ExtensionSidePanelTests 35, ExtensionSidePanelPolyfillTests 22 (+ ExtensionManifestTests, ExtensionUpdateDeferralTests additions).

Runtime (isolated profiles, native messaging hosts blocked, never signed in; harness kept as .claude/task132.8-harness.patch, not committed). API Explorer: Side Panel section from popup and worker; tab panel shows only with its tab and the same web view and page state come back after a tab switch (JS marker); window panel beside other tabs; divider drag, 280 pt minimum, width remembered across a relaunch; split + panel with the inspector docked when the pane is >= 500 pt (a 437 pt pane and the panel's own page got a detached inspector); window resize; window.close(), close(tab), disable for tab, tab close and extension disable all tear down; a click in the panel takes the keys and typing lands in its field, the page's own focus() does not; Option+Shift+E reached commands.onCommand. Real Claude extension 1.0.98: a real click on the pinned toolbar action opened sidepanel.html?tabId=N beside the tab (chrome.sidePanel object, tabs.getCurrent undefined); tab switch hid and restored it without reload; Cmd+E reached the worker.

NOT verified: (a) AC #1 "pressed again closes it" end to end with the real extension. Signed out, getContexts returned the panel, the worker sent close_side_panel and the panel page received it, but the listener that calls window.close() is only mounted by the extension's signed-in screens; with a stand-in listener of the same body Cmd+E closed the panel and the next press opened a fresh one. The real listener needs a signed-in run (TASK-132.20). (b) AC #7 and #8 (two windows, Private) are covered by integration tests only, not at runtime. (c) chrome.runtime.reload() with a panel open; a window panel across a space switch; a tab made a favourite keeping its panel. (d) A signed build.

Correction to the counts above: ExtensionSidePanelTests has 34 tests, so the three new suites are 83 tests (27 + 34 + 22).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.sidePanel (setOptions, getOptions, open, close, setPanelBehavior, getPanelBehavior) is a Detour polyfill gated on the sidePanel permission, and an extension's panel is a Detour-hosted web view beside the tab's content: per-tab panels that follow the tab's live web view, a window panel, a draggable divider with a remembered width, a close button, and teardown with the tab, window or extension. Extension command shortcuts now fire (ExtensionCommandDispatch). Verified by 83 new tests, the full suite (only 4 failures, which also fail on the parent commit) and runtime passes with API Explorer and the real Claude extension signed out; the Claude toggle's closing half depends on the extension's signed-in listener and was checked with a stand-in.
<!-- SECTION:FINAL_SUMMARY:END -->
