---
id: TASK-306
title: 'History: record pages viewed in a Peek'
status: To Do
assignee: []
created_date: '2026-11-08T09:55:00Z'
labels:
  - history
  - peek
dependencies: []
references:
  - TASK-292.6
priority: medium
ordinal: 367000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Pages opened in a Peek never reach History, however long they stay up (confirmed at runtime by TASK-292.6, Nov 8 2026). Arc records Peek pages in history (the user, who used Arc), and so do browsers generally outside private browsing: History is how people find a page again, and a page glanced at in a Peek is a typical one to want back.

Cause: a Peek is a BrowserTab held in its host's `peekTab`, with no `spaceID`, not in `space.tabs` and not subscribed by TabStore (wiki/tabs/peek.md, "The Peek is a tab that is in no list"). History is recorded from TabStore's per-tab `$isLoading` subscription (TabStore ~5345-5352 → recordHistoryVisit with `tab.historySpaceID`), which Peeks never get. recordHistoryVisit's own rules (no Private space, no Private Quick Detour, http/https only, error pages skipped, title correction and dedup) should apply unchanged, keyed to the host tab's space.

The website's Peek and History guide pages (TASK-292.6) currently say Peek pages are not recorded; they change when this ships.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A page that loads in a Peek in a normal window is recorded in History under the host tab's space and profile, with its title, like a page loaded in a tab; navigations inside the Peek are recorded too
- [ ] #2 Peeks in Private windows, Private Quick Detours and Quarantine are never recorded
- [ ] #3 Expanding a Peek into a tab (Open in New Tab / Open in Split View) does not record the same visit twice
- [ ] #4 Tests cover Peek recording in a normal space, the Private exclusions and the expand path
- [ ] #5 Checked at runtime with /verify: a Shift-clicked link's page appears on the History page
- [ ] #6 The website's Peek and History pages and wiki/tabs/peek.md are updated
<!-- AC:END -->
