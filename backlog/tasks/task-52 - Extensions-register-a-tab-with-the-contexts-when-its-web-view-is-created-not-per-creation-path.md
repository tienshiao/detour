---
id: TASK-52
title: >-
  Extensions: register a tab with the contexts when its web view is created, not
  per creation path
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 08:36'
updated_date: '2026-09-13 10:41'
labels:
  - extensions
  - refactor
dependencies:
  - TASK-50
priority: low
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-50 fixed favourite and Peek tabs never being reported to the WKWebExtensionContexts by adding ExtensionTabLifecycle.didOpen calls at each creation path (TabStore.activateFavorite, addFavorite(from:), BrowserWindowController.showPeekOverlay, plus the pre-existing insert observer, wake() and wakeIfNeeded). The invariant we actually want is 'every web view built from a profile's configuration is a known tab', and the natural place to enforce it is where the web view is created: BrowserTab.init(configuration:) / makeWebView, resolving the profile from configuration.webExtensionController (TabStore.profiles.first { $0.extensionController === … }) or an explicit profile parameter. TASK-50's code review recommended this but deferred it because registering before the tab is wired (spaceID, host.peekTab, profile.favorites.insert) reproduces the ordering hazards that review fixed: didOpenTab fires tabs.onCreated, whose parameters call window(for:) and the window's tab list, so the tab must already be placeable. Design a creation-time registration that either defers the notification until the tab is placed (e.g. a 'registered but unplaced' state flushed by the first placement, or a two-phase create/attach on BrowserTab), or restructures creation so placement precedes web-view creation. Then remove the per-path didOpen calls, keeping teardown() as the close point, and add a debug assertion or test that no web view carrying an extension controller is unregistered.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A BrowserTab whose web view carries a profile's extension controller is reported open exactly once by construction, with no per-call-site didOpen in TabStore or BrowserWindowController (wake/notifyExistingTabs replay excepted)
- [x] #2 The onCreated parameters observed by a recording notifier show the tab already placeable (window(for:) non-nil, listed by that window's extensionTabs) for normal, pinned, favourite and peek creation
- [x] #3 ExtensionTabLifecycleTests still pass and gain a negative case: a web view created with a configuration that has no extension controller (incognito/nonPersistent, test configurations) is not reported
- [x] #4 A test or debug assertion fails when a live web view with an extension controller has extensionRegisteredProfile == nil
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Rule: a tab is registered with the contexts the moment it becomes enumerable by extensionWindowTabs — i.e. when it enters one of the containers that enumeration reads (Space.tabs, Space.pinnedEntries / PinnedEntry.tab, Profile.favorites / Favorite.tab, BrowserTab.peekTab) and has a web view carrying an extension controller — and again when a placed tab builds a web view (wake). The profile is resolved from the web view's configuration.webExtensionController through a weak controller→Profile registry populated where Profile.extensionController is created, so private TabStores in tests resolve too.
2. ExtensionTabLifecycle gains didPlace(_:) / didPlace(added:) (no-op for a tab already registered or without a controller) and didCreateWebView(for:) (wake: idempotent re-open with the new web view, profile from the registry). didOpen(_:in:contexts:) stays for notifyExistingTabs replay. Six one-line didSet hooks call didPlace; comments in ExtensionTabLifecycle document the rule and the ordering guarantee (a container hook fires only once the tab is placeable, so tabs.onCreated can resolve window(for:) and the window's tab list).
3. Remove the per-path calls: TabStore.activateFavorite, addFavorite(from:) (create the Favorite dormant and assign fav.tab after it is in profile.favorites, or rely on the favorites didSet), BrowserWindowController.showPeekOverlay, ExtensionTabObserver.tabStoreDidInsertTab, and wakeIfNeeded's redundant didOpen (wake registers). expandPeekToNewTab keeps its explicit didClose of the old peek; teardown() stays the close point.
4. Debug assertion in BrowserWindowController.claimWebView / presentPeekWebView: a hosted web view whose configuration has an extension controller must have extensionRegisteredProfile set.
5. Tests: ExtensionTabLifecycleTests record whether the tab was listed (in a space's tabs/pinned tabs, a profile's favourites, or a peek of one) at didOpen time for normal, pinned, favourite and peek creation, each reported exactly once; negative: a BrowserTab built from a configuration without a controller placed in a space reports nothing; the existing detach/re-add and profile-swap sequences keep passing.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: a tab is reported open the moment it becomes enumerable by extensionWindowTabs — one-line didSet hooks on Space.tabs, Space.pinnedEntries, PinnedEntry.tab, Profile.favorites, Favorite.tab and BrowserTab.peekTab call ExtensionTabLifecycle.didPlace, which registers a still-unregistered tab whose web view carries an extension controller; wake() calls didCreateWebView(for:) to re-open a placed tab with its new web view. The profile is resolved from the web view's configuration.webExtensionController through a weak controller→Profile registry filled where Profile.extensionController is built, so private test stores resolve too. Because a didSet runs after the mutation the tab is already listed when tabs.onCreated resolves window(for:) — the ordering hazard TASK-50's review deferred on. Removed the per-path didOpen calls (insert observer, activateFavorite, addFavorite(from:), showPeekOverlay, wakeIfNeeded); teardown() stays the close point; notifyExistingTabs keeps its replay. Debug assertion assertExtensionRegistered in claimWebView and presentPeekWebView. Tests: ExtensionTabLifecycleTests records whether the tab was listed at didOpen for normal, pinned, favourite, peek and wake creation (each once), a controller-less configuration reports nothing, and a cross-space move keeps today's close/open sequence; ExtensionPageRehostTests asserts an extension page tab is registered when placed.

Review fixes folded in: TabStore.spaces gained a didSet that re-announces a newly inserted space's live tabs (session restore and Undo Delete Space fill space.tabs while the space is detached, so those tabs were reported before any window could list them); the controller registry also covers a controller assigned from outside the lazy initializer; didOpen closes a tab's previous registration when it is re-reported under a different profile; updateSpace's profile swap closes every tab of the space, asleep or not; the container hooks pass their whole list (didPlace is a no-op for a registered tab) instead of diffing oldValue; ExtensionManager.profile(for:) uses the registry instead of scanning (and force-building) every profile's controller; the debug assertion uses the same predicate as the rule; docs/extensions.md describes the placement rule. Full suite after the fixes: 1000 tests, 0 failures, 1 pre-existing skip.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extension-context registration now follows placement instead of creation paths: entering any container the window enumeration reads registers a live extension-controller tab exactly once, wake re-announces the new web view, and the profile comes from the web view's own controller. No per-call-site didOpen remains in TabStore or BrowserWindowController, and a debug assertion guards hosted web views. Verified with ExtensionTabLifecycleTests (21), the extension-page suites and the full suite.
<!-- SECTION:FINAL_SUMMARY:END -->
