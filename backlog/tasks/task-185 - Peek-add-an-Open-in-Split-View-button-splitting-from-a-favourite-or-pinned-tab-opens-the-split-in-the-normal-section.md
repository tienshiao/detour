---
id: TASK-185
title: >-
  Peek: add an Open in Split View button; splitting from a favourite or pinned
  tab opens the split in the normal section
status: To Do
assignee: []
created_date: '2026-10-24 09:02'
labels:
  - peek
  - split
  - feature
dependencies: []
priority: medium
ordinal: 207000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24.

**Peek button.** The Peek panel has two buttons today (close; expand = `expandPeekToNewTab`, which hands the Peek's live web view to a new normal tab). Add a third, Open in Split View: the Peek's page becomes the right pane of a split, its host page the left pane, and the right pane is focused.
- Host is an ungrouped normal tab: split the host itself with the Peek's page (like Option-click's `addTabInSplit`, but handing over the Peek's web view the way expand does, so the Peek's navigation history and state survive).
- Host is a favourite or a pinned tab: the split opens in the **normal tab section**. Left pane: a **new normal tab loading the parent's current URL** (decision 2026-10-24: a copy; the favourite or pinned tab stays where it is, untouched, and its page state is not carried over). Right pane: the Peek's page.
- Host is already a pane of a split (normal or pinned): **no button** (decision 2026-10-24).

**Option-click and the context menu.** The same normal-section split is what opening a split from a lone favourite or pinned tab does:
- Option-click a link in a favourite or a lone pinned tab: today it falls back to a background tab (`BrowserWindowController+Navigation`, because `addTabInSplit` returns nil unless the anchor is an ungrouped normal tab). It should open the split above: a copy of the parent on the left, the link on the right.
- The page's right-click menu has no split item yet (`BrowserWebView` adds only Open Link in New Tab / New Window). Add Open Link in Split View, following the same rules as Option-click in every kind of tab: ungrouped normal tab = new right pane; already split = load into the other pane (today's Option-click rule); favourite or lone pinned tab = new split in the normal section.

Unchanged: Option-click inside a pinned split still loads into the other pane; Peek stays out of splits as a member (it hands its page over and closes).

Where the new split lands in the normal section, and its undo, follow the existing new-tab insertion rule (`TabInsertion`) and `addTabInSplit`'s undo; record what was chosen. Design context: docs/split-tabs-design.md, wiki/tabs/split-tabs.md, wiki/tabs/peek.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Peek panel shows Open in Split View next to close and expand, except when the host tab is already a pane of a split
- [ ] #2 On an ungrouped normal host, it makes the host the left pane and the Peek's page (same web view, history kept) the right pane, focused
- [ ] #3 On a favourite or pinned host, it creates a split in the normal section: a new tab with the parent's current URL on the left, the Peek's page on the right; the favourite or pinned entry is unchanged
- [ ] #4 Option-click in a favourite or a lone pinned tab opens the same normal-section split instead of a background tab
- [ ] #5 The link context menu gains Open Link in Split View with Option-click's rules for every kind of tab
- [ ] #6 TabStore mutation(s) for the normal-section split are test-first (contiguity, insertion point, undo) and the Peek hand-off keeps the web view; checked at runtime with a harness
<!-- AC:END -->
