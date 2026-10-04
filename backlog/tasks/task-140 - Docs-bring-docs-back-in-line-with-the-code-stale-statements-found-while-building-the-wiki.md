---
id: TASK-140
title: >-
  Docs: bring docs/ back in line with the code (stale statements found while
  building the wiki)
status: To Do
assignee: []
created_date: '2026-10-04 01:58'
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
- [ ] #1 Each stale statement listed in the wiki pages' doc-versus-code notes is corrected in the document, checked against the code on main
- [ ] #2 Design documents keep their record of what was decided; where the implementation diverged, the document says what shipped instead of being rewritten as if it had always said so
- [ ] #3 The wiki pages no longer report those disagreements, and wiki-lint is clean
- [ ] #4 CLAUDE.md states the real minimum macOS version
<!-- AC:END -->
