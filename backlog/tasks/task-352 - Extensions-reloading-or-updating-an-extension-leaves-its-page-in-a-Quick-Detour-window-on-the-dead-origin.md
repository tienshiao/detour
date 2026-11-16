---
id: TASK-352
title: >-
  Extensions: reloading or updating an extension leaves its page in a Quick
  Detour window on the dead origin
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
updated_date: '2026-11-16T07:29:00Z'
labels:
  - extensions
  - quick-detour
dependencies: []
references:
  - Detour/Browser/Profile.swift
  - wiki/extensions/extension-pages.md
priority: low
type: bug
ordinal: 432000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint. Profile.extensionPageLocations (used by retargetExtensionPages on a context reload and by the update path's open-pages count) walks the profile's spaces' tabs, pinned entries, favourites and their Peeks, but not TabStore.quickDetourTabs. If an extension page can be shown in a Quick Detour window (e.g. an options page opened there, or a link to chrome-extension:// followed in one), a reload or update would leave it on the old base URL and a deferred update would not count it as busy. Not reproduced: first establish whether a Quick Detour window can show an extension page.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether a Quick Detour (or quarantine) window can show an extension page is established and recorded
- [x] #2 If it can: such a page is rehomed on a context reload and counted as an open page by the deferred-update check, with a test
- [x] #3 wiki/extensions/extension-pages.md lists every place a page can be
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Investigation (AC #1): every way a URL reaches a Quick Detour/quarantine web view (launcher/palette typing, sidebar copy, Opt-Cmd/menu links, Cmd-click inside, window.open child, tabs.update, archive restore) and whether WebKit loads a webkit-extension:// main frame in a web view built from the profile configuration (no requiredWebExtensionBaseURL). Static reading + a probe XCTest on a real Quick Detour (fresh frame vs from a loopback page; web-accessible vs not; tabs.update; window.open child).
2. If unreachable: record evidence, update wiki/extensions/extension-pages.md (list + correct the 'no handler for the scheme' claim), no code change.
3. If reachable: cover TabStore.quickDetourTabs in extensionPageLocations / retarget / close paths and the deferred-update count, with tests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Investigation (2026-11-15): a Quick Detour or quarantine window cannot show an extension page.
- WebKit (WebExtensionController::addPage) installs the extension scheme handler on every page of the controller, so the old wiki claim 'the space configuration has no handler' was wrong; the gate is in WebExtensionURLSchemeHandlerCocoa.mm: a main-frame load needs the configuration's _requiredWebExtensionBaseURL to be the extension's, else NSURLErrorResourceUnavailable (-1008), web_accessible_resources or not. Only WKWebExtensionContext.webViewConfiguration sets it.
- Every Quick Detour web view is built from Space.makeWebViewConfiguration(for:inSpace:false) (quarantine: same with its own store) or WebKit's copy of a Quick Detour opener's configuration; openQuickDetourTab(adopting:) has test callers only; wakeConfiguration has no space for a Quick Detour tab, so never returns a context configuration; browser-window entry points (Opt-Cmd-click, Open Link in Quick Detour, routed links, sidebar copy) open a fresh window with a URL. Typed webkit-extension:// is a search (AddressInputClassifier).
- Probe XCTest on a real QuickDetourWindowController (test extension with options.html and a web-accessible war.html, loopback page), 1 test, 0 failures: fresh load of options/war (= sidebar copy path), location.href and link click from a web page to war, location.href to options, tabs.update (loadURL(_:for:)) to war and options, window.open child to war, and a space tab for comparison: every cell ended on the browser-error page with -1008, showsExtensionPage false. Probe not committed (kept as scratch).
- So extensionPageLocations / retarget / the deferred-update count lose nothing by not walking quickDetourTabs. No code change. Wiki: extension-pages.md (new section 'Where an extension page cannot be', summary and Peek gotcha corrected), quick-detour-window.md (row in the no-space table), log.md.
- Not run: /code-review and /verify (docs and Backlog only, per CLAUDE.md).
- Side observation (out of scope): after a script/link/tabs.update navigation fails in a page, Detour's error page names the previous page's URL as failedURL (seen in Quick Detour and space tabs), so its Reload goes back to that page rather than retrying the failed URL.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Established that a Quick Detour or quarantine window cannot show a webkit-extension:// page: WebKit refuses an extension main frame in any web view whose configuration lacks that extension's _requiredWebExtensionBaseURL (-1008, even for web_accessible_resources), and no Quick Detour web view is built from a context configuration. Probed every entry path on a real Quick Detour window (fresh load as the sidebar copy does, script and link navigation, tabs.update, window.open child): all ended on the error page. AC #2 does not apply (no such page exists to rehome or count), so no code change. Wiki extension-pages.md now lists where a page can and cannot be and corrects the 'no handler for the scheme' claim; quick-detour-window.md notes extensionPageLocations does not walk Quick Detour tabs.
<!-- SECTION:FINAL_SUMMARY:END -->
