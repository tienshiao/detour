---
id: TASK-140
title: >-
  Docs: bring docs/ back in line with the code (stale statements found while
  building the wiki)
status: Done
assignee: []
created_date: '2026-10-04 01:58'
updated_date: '2026-10-04 02:10'
labels: []
dependencies: []
priority: medium
ordinal: 163000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Writing the wiki from the code turned up places where docs/*.md and CLAUDE.md describe behaviour, symbols or schema that no longer exist. Each wiki page records the disagreement it found; this task corrects the documents so the two stop disagreeing, and then removes those notes from the wiki.

Known stale areas: docs/webview-ownership.md (ownsWebView is computed; the claiming window takes the snapshot; when the notification is posted; when tab.webView is nil; no snapshot on in-window tab switch), docs/data-model.md (migration v17 and the extension columns; appState keys; download save debounce; palette search sources), docs/architecture.md (launch order; singleton table; closed-tab stack load), docs/tab-lifecycle.md (no-parent insertion index; closing a pinned tab), docs/split-tabs-design.md (assertSplitInvariants, divider and focus border, split row context menu, helper names, drag kinds and commands in §6), docs/extensions.md (missing symbols, content-script polyfill injection, permission prompts, background start, tab close source, extensionStorage, chrome.extension, test extension count, update deferral and popups), docs/command-palette.md (suggestion types, top hit, debounce scope, didSubmitSearch), docs/content-blocking.md (which web views re-apply rules; Settings buttons), docs/1password-integration-plan.md (dated status; offscreen-close claim; relay keep-alive scope; storage migration claim), docs/chrome-runtime-patching.md (opening claim about own-property precedence), CLAUDE.md (macOS 14+ vs the 15.4 deployment target).

Out of scope: code comments that are stale, the /verify skill and the release scripts' app-path resolution, and any behaviour change.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each stale statement listed in the wiki pages' doc-versus-code notes is corrected in the document, checked against the code on main
- [x] #2 Design documents keep their record of what was decided; where the implementation diverged, the document says what shipped instead of being rewritten as if it had always said so
- [x] #3 The wiki pages no longer report those disagreements, and wiki-lint is clean
- [x] #4 CLAUDE.md states the real minimum macOS version
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Three agents, one per document group (architecture docs; split/palette/content-blocking; extension docs), each confirming every reported disagreement against the code before editing.
2. Descriptive docs are corrected in place; design docs keep their record and gain 'As shipped' notes.
3. The same agents remove the now-obsolete doc-versus-code notes from the wiki pages.
4. Lint, review the diff, log the change in wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Three agents, one per document group, confirmed each reported disagreement in the Swift sources before editing. Descriptive documents (architecture, data-model, tab-lifecycle, webview-ownership, extensions, command-palette, content-blocking) were corrected in place; the records (split-tabs-design, chrome-runtime-patching, 1password-integration-plan) keep their text and gained marked 'As shipped' / 'Corrected' / 'Superseded' / 'Current state' notes. CLAUDE.md's Architecture line now says macOS 15.4+ (project.yml deployment target).

Beyond the reported list: docs/extensions.md had its architecture block, provider and injection tables, install / enable / uninstall steps, delegate table and schema brought up to date; docs/command-palette.md gained the real pipeline order, threading, Escape staging and positioning behaviour; docs/data-model.md now says in-progress downloads are never written and that extensionStorage is unused (only tests call storageGet/storageSet).

Leads that did not hold: the externalAppPermission migration is registered as v14 and the doc already said so. Left unchanged: the plan document's 'roughly an hour' log-retention figure (cannot be settled from code; the wiki still records both figures); the webNavigation 'main-frame only' claim was replaced by what TASK-4 measured rather than confirmed or refuted.

Wiki: the doc-versus-code sections and notes were removed from 20 pages, keeping the facts about the code; two stale source titles and two statements that contradicted extensions/storage.md about extensionStorage were fixed by hand. wiki-lint: 0 errors, 0 warnings. No build or tests: documentation only.

Not done, out of scope (stale code comments, noted on the wiki pages): updateSplitPaneFocus 'hairline border'; 'Split with Next Tab' called temporary; searchHistory / localSuggestions 'synchronous on main'; the content polyfill 'registered via scripting.registerContentScripts'; the offscreen-close claim on restartUnresponsiveBackground and in nativePortKeepAliveJS; the keeper's storage-migration header comment. Code oddities seen and not filed: DownloadManager.saveNow rewrites completedAt on every save and has no flush on quit; Cmd+L then Return activates the first recent-history row because row 0 is selected after every rebuild (read from code, not run); the /verify skill and both scripts pick the first Detour-* DerivedData directory.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Corrected ten docs/ files and one line of CLAUDE.md against the code on main, keeping design records intact with marked as-shipped notes, and removed the matching doc-versus-code notes from the wiki. Verified by reading the code for each correction and by wiki-lint (0 errors, 0 warnings); documentation only, no tests run.
<!-- SECTION:FINAL_SUMMARY:END -->
