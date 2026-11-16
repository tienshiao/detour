---
id: TASK-373
title: 'Tests: guard that a Quick Detour window still cannot show an extension page'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T18:29:00Z'
labels:
  - extensions
  - quick-detour
  - tests
dependencies: []
references:
  - wiki/extensions/extension-pages.md
priority: low
type: chore
ordinal: 454000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13). TASK-352 established (WebKit source + a probe) that WebKit refuses a main-frame extension page unless the configuration's _requiredWebExtensionBaseURL names the extension, so Quick Detour windows never show one and extensionPageLocations need not walk them. The probe (session scratchpad task-352/QuickDetourExtensionPageProbeTests.swift) printed rather than asserted. A guard test would catch a WebKit change that relaxes the gate.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test asserts a Quick Detour page refuses an extension page (and fails if WebKit ever loads it)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. New suite DetourTests/QuickDetourExtensionPageGateTests.swift from the TASK-352 probe's cells, asserting instead of printing; the space-tab comparison cell is left to ExtensionPageProvenanceTests.
2. Each cell waits for a terminal state (Detour's error page, or the extension's document) and asserts the web view: error page naming the refused URL, document not the extension's, webView.url not an extension URL; plus showsExtensionPage false and tab.url as it is now (measured per cell, TASK-381 rules). The error code (-1008 NSURLErrorResourceUnavailable) is read from a bare WKWebView built from the Quick Detour tab's own configuration with a recording delegate (no production hook).
3. Cells: fresh Quick Detour (options, web-accessible page); a web page in it navigating itself (script and link, both pages); tabs.update (loadURL(_:for:)); window.open child; a quarantine (fresh via openQuarantine, and a web page navigating to the web-accessible page). Positive control: the context's own configuration shows both pages, in the normal and the Private profile.
4. Prove teeth once (uncommitted): open the Quick Detour with openedWith: context.webViewConfiguration; the document asserts must fail.
5. Remove docs/harness/task352 (only the Backlog task references it); wiki extension-pages: point 'Where an extension page cannot be' at the test, re-measured table rows, Where it lives; log; lint; code-review.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The TASK-352 probe (prints, does not assert) is kept at docs/harness/task352/QuickDetourExtensionPageProbeTests.swift; copy it into DetourTests and turn its prints into assertions.

Done: DetourTests/QuickDetourExtensionPageGateTests.swift (6 tests), from the TASK-352 probe's cells, asserting. Each cell waits for a terminal state (Detour's error page or the extension's document; the document check falls back to document.title because WKWebView.title lagged a loaded extension page once in the control) and asserts: the error page names the refused URL, the document is not the extension's, webView.url is not an extension URL, showsExtensionPage false, tab.url as measured. -1008 (NSURLErrorResourceUnavailable, NSURLErrorDomain) is read from a bare WKWebView on the Quick Detour tab's own configuration with NavigationWaiter (no production hook). Cells: fresh Quick Detour (options, war: tab.url nil), a web page navigating itself (script -> war, script -> options, link -> war: tab.url stays the web page), tabs.update via loadURL(_:for:) (war, options: stays the web page), window.open child (war: nil, -1008 on the child's configuration), quarantine via openQuarantine (options, war: nil, -1008) and a quarantine web page script -> war (stays the web page). Positive control: both pages load in context.webViewConfiguration in a normal and a Private profile. The space-tab comparison cell was dropped (ExtensionPageProvenanceTests').

Teeth (uncommitted experiment, then reverted): opening the Quick Detour with openedWith: context.webViewConfiguration made both fresh-load cells fail on the document, the error page, the URL named and the -1008 check (10 failures), while tab.url stayed nil and showsExtensionPage false — so the document assertions are what catch a relaxed gate (servedExtensionOriginHost is nil in a Quick Detour, mayAdopt refuses whatever WebKit does). The other cells could not be teeth-tested this way: in the extension's configuration the web page itself never loads (TASK-382's rule), so their setup timed out; they share the same assertRefused helper.

Tests (sandbox off): QuickDetourExtensionPageGateTests 6/0, QuickDetourExtensionTests 18/0, ExtensionPageProvenanceTests 11/0 (35 tests, 0 failures). No /verify: test-only change.

Removed docs/harness/task352/QuickDetourExtensionPageProbeTests.swift (only this task referenced it; the wiki did not link it). Wiki: extension-pages 'Where an extension page cannot be' points at the guard, table re-measured with tab.url per cell plus quarantine rows; quick-detour-tests and quick-detour-window rows; log.

Review (/code-review medium --fix, forked): no correctness findings. Fixed: the 'content script' wording in the doc comment and wiki row (not run in the test). Reverted the review's (11)->(18) change to the QuickDetourExtensionTests row in quick-detour-tests.md: that table counts later additions as separate (+4)/(+3) rows. Not done: teeth for the non-fresh cells (see above); folding the quarantine loop into the fresh loop and dropping a redundant isExtensionPageURL assertion (cosmetic).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added QuickDetourExtensionPageGateTests: a guard that a Quick Detour and a quarantine window never show a webkit-extension:// page, web-accessible or not, through a fresh load, a page navigating itself, tabs.update and a window.open child. Each cell asserts Detour's error page naming the URL and not the extension's document, plus -1008 read from the tab's own configuration; a positive control loads both pages in the context's configuration. Shown to fail when the window is built from the extension's configuration. The TASK-352 probe copy in docs/harness is removed; the wiki points at the test. 35 tests across the three related suites pass.
<!-- SECTION:FINAL_SUMMARY:END -->
