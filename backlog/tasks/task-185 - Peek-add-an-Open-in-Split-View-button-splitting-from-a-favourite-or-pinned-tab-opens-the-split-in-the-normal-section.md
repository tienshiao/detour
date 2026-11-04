---
id: TASK-185
title: >-
  Peek: add an Open in Split View button; splitting from a favourite or pinned
  tab opens the split in the normal section
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:02'
updated_date: '2026-10-24 16:44'
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
- [x] #1 The Peek panel shows Open in Split View next to close and expand, except when the host tab is already a pane of a split
- [x] #2 On an ungrouped normal host, it makes the host the left pane and the Peek's page (same web view, history kept) the right pane, focused
- [x] #3 On a favourite or pinned host, it creates a split in the normal section: a new tab with the parent's current URL on the left, the Peek's page on the right; the favourite or pinned entry is unchanged
- [x] #4 Option-click in a favourite or a lone pinned tab opens the same normal-section split instead of a background tab
- [x] #5 The link context menu gains Open Link in Split View with Option-click's rules for every kind of tab
- [x] #6 TabStore mutation(s) for the normal-section split are test-first (contiguity, insertion point, undo) and the Peek hand-off keeps the web view; checked at runtime with a harness
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TabStore, tests first (SplitTabTests style): (a) a Peek hand-off variant of addTabInSplit that takes the Peek's WKWebView instead of a URL (ungrouped normal anchor; the new right pane adopts the web view the way addTab(in:webView:) does); (b) a normal-section split for a favourite or pinned parent: two new normal tabs, left loading the parent's current URL, right either a URL (Option-click, context menu) or the Peek's web view, inserted as one contiguous group where TabInsertion puts a new tab opened from that parent; one undo removing both without archiving. The favourite/pinned entry is untouched.
2. Window: Peek panel third button (Open in Split View), hidden when the host is a pane of a normal or pinned split; hand-off sequencing as expandPeekToNewTab (ExtensionTabLifecycle.didClose before the web view moves, TASK-50/52); the right pane is selected and focused.
3. Option-click in a favourite or lone pinned tab uses 1(b) instead of the background-tab fallback; pinned split unchanged (other pane).
4. BrowserWebView link context menu: Open Link in Split View, same rules as Option-click for every tab kind.
5. Runtime harness (docs/harness/task185-harness.patch): Peek on a normal, pinned and favourite host, Option-click in a favourite, context menu item; web view identity and back list kept; focus on the right pane; captures. Wiki: tabs/split-tabs.md, tabs/peek.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (2026-10-24, Opus subagent): TabStore.splitOpening(from:in:) -> .besideTab / .inNormalSection / nil, the one rule for the Peek button, Option-click and the link menu (nil for split panes incl. a pinned split with a dormant partner, Peeks, tabs outside the space, pinned/favourite tabs on an extension page). addTabInSplit(with:webView:in:) adopts the Peek's WKWebView; addSplitInNormalSection(copying:rightPane:in:) makes a copy of the parent (loadRecordedURL of its current URL) plus the right pane (.url or .webView) as one group. Insertion rule: where tabInsertionIndex puts a new tab opened from that parent (top of the normal section after the parent's existing children), snapped to split boundaries; both panes take the parent as parentID, so a later split or Cmd+click from it lands after. One non-archiving 'Open in Split' undo; the entry or favourite is never touched. Peek: third button (rectangle.split.2x1), hidden on a split host, hand-off in expandPeekToNewTab's order, 0.35 s glide into the right-pane rect, then the pane is selected and focused. Option-click and Open Link in Split View share openLinkInSplit; the menu item is left out of a Peek's menu.
Review (/code-review --fix, 7 findings): fixed the background-tab toast firing per inserted pane while the sidebar is collapsed (suppressed for split openings), undo reporting the right pane at a stale index (selection skipped a tab; new test), a context-menu action flag left set by early returns in createWebViewWith; and (mine) the glide completion overriding a tab the user picked during the glide. Skipped: the split button's visibility is not refreshed while the Peek is up, a link dropped if its tab is gone before WebKit's callback, two API shapes for the right pane.
Known, not fixed (existing behaviour): undo of a split from a pinned tab or favourite selects an adjacent normal tab, not the pinned/favourite; a second window keeps an older full-width snapshot; Option-click in a pinned split with a dormant partner still opens a background tab; expandPeekToNewTab still shows the background toast with the sidebar collapsed.
Tests: SplitOpeningTests 20 (red step: 14/19 failed against nil stubs); 322 tests across SplitOpeningTests, SplitTabTests, SidebarLayoutTests, SidebarDragDropTests, TabStoreTests, SplitDropZoneTests, PeekAnchorTests, PeekStateTests, RecentTabSwitcherPeekTests, FavoritePeekPersistenceTests, ExtensionActiveTabTests, ExtensionTabLifecycleTests, 0 failures. Runtime (docs/harness/task185-harness.patch, local pages, real posted Option-clicks and right-clicks): 70/70 checks, re-run after the review fixes with the screen unlocked — web view identity and back list kept, right pane selected and first responder, both panes hosted, entries unchanged through undo, no button on split hosts, Option-click and the menu item in favourite / pinned / normal / split tabs, two windows (B shows a snapshot). Not driven: a real click on the Peek button (openPeekInSplitView called directly), the glide frame by frame.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Peek panel has an Open in Split View button (not on a split host): on a normal tab the host becomes the left pane and the Peek's own web view (history kept) the right, focused pane; on a pinned tab or favourite a split opens at the top of the normal section with a copy of the parent's current page on the left. Option-click in a favourite or lone pinned tab and the new link menu item Open Link in Split View use the same rule (split panes still load into the other pane). One undo removes the new panes without archiving. Tests 322/322; runtime harness 70/70.
<!-- SECTION:FINAL_SUMMARY:END -->
