---
id: TASK-132.9
title: 'Extensions: runtime.getContexts and runtime.ContextType'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 23:09'
updated_date: '2026-10-04 20:06'
labels: []
dependencies:
  - TASK-132.8
parent_task_id: TASK-132
priority: medium
ordinal: 141000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude extension's Cmd+E handler calls chrome.runtime.getContexts({contextTypes: [chrome.runtime.ContextType.SIDE_PANEL]}) and reads each context's documentUrl to see whether a panel for that tab is already open; with ContextType undefined the handler throws. WebKit vends neither. chrome.runtime is patchable in place (pin the wrapper, see docs/chrome-runtime-patching.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 runtime.ContextType has TAB, POPUP, BACKGROUND, OFFSCREEN_DOCUMENT and SIDE_PANEL
- [x] #2 getContexts returns the extension's open contexts with contextType, documentUrl, tabId and windowId, and honours the contextTypes, tabIds, windowIds and documentUrls filters
- [x] #3 An open side panel is reported as SIDE_PANEL with its full URL including the query; a closed one is not reported
- [x] #4 Contexts of another extension or another profile are never returned
- [x] #5 The patch survives garbage collection (rooted wrapper); tests and API Explorer cover it
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built with TASK-132.8 (2026-10-04). runtimeGetContextsJS adds runtime.getContexts and runtime.ContextType to the pinned chrome.runtime wrapper, only when absent, and roots the wrapper a second time in __detourHeldWrappers. ExtensionPolyfillHandler.openContexts (ExtensionOpenContexts.swift) lists the calling extension's contexts in the calling profile: BACKGROUND, TAB, POPUP (ExtensionPopoverController.presentedPopups), OFFSCREEN_DOCUMENT, SIDE_PANEL. Detour answers with tab handles; the polyfill turns them into WebKit's ids. The request leaves in the getContexts call itself, so the Claude handler's getContexts -> setOptions -> open order reads the state from before the open. All of Chrome's filters are honoured. Limits: no documentId, extension frames inside web pages are not listed, the background is always listed, a side panel reports tabId -1 and its window's id. docs/extensions.md "runtime.getContexts", docs/chrome-runtime-patching.md, wiki extensions/runtime-get-contexts.

/code-review --fix (high, same pass as 132.8): one finding here, skipped — POPUP is not listed while the popup page is still loading (docs define POPUP as showing; registering earlier would list popups that never get presented).

Tests: ExtensionRuntimeGetContextsTests 8 (real extension context: worker and page, ids, panel hidden with its tab, offscreen, another extension and another profile never returned, Private = incognito, the patch survives garbage collection, the shortcut opens the panel and pressed again closes it with the fixture's listener), ExtensionRuntimeGetContextsPolyfillTests 9. Full-suite result as recorded on TASK-132.8.

Runtime: API Explorer's "runtime.getContexts" section from the popup and the worker, and from the panel page. Real Claude extension, signed out: getContexts({contextTypes: [SIDE_PANEL]}) returned the open panel with documentUrl sidepanel.html?tabId=N, tabId -1 and the window's id, and the worker's Cmd+E handler then sent close_side_panel for that tab — the handler no longer throws on ContextType. Not verified: a signed build.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
runtime.getContexts and runtime.ContextType are added in place to WebKit's chrome.runtime wrapper (rooted), listing the calling extension's background, tab pages, popup, offscreen document and side panels in its own profile with all of Chrome's filters. Verified by 17 new tests and at runtime with API Explorer and the real Claude extension, whose Cmd+E handler now finds its open panel.
<!-- SECTION:FINAL_SUMMARY:END -->
