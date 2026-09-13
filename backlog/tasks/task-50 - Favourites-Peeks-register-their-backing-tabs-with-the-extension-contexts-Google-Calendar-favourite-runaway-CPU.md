---
id: TASK-50
title: >-
  Favourites/Peeks: register their backing tabs with the extension contexts
  (Google Calendar favourite runaway CPU)
status: Done
assignee:
  - '@tma'
created_date: '2026-09-13 07:36'
updated_date: '2026-09-13 08:28'
labels:
  - bug
  - extensions
  - favourites
dependencies: []
priority: high
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A favourite's backing tab (TabStore.activateFavorite -> makeTab -> BrowserTab.init(configuration:)) and a Peek tab (BrowserWindowController openPeek -> BrowserTab(configuration:)) are created with the profile's WKWebViewConfiguration, so the WKWebExtensionController injects content scripts into them, but they are never reported to the profile's WKWebExtensionContexts: didOpenTab only fires from ExtensionTabObserver.tabStoreDidInsertTab (normal tabs), BrowserTab.wake() (sleeping tabs) and ExtensionManager.notifyExistingTabs (pinned + normal tabs only). BrowserWindowController.tabs(for:) (WKExtensionWindowConformance) and ExtensionTabObserver.dispatchActivated also skip favourite tabs, TabStore.subscribeToTab's notify closure drops their property changes (no tabStoreDidUpdateTab, so no didChangeTabProperties), and deactivateFavorite/removeFavorite/teardown never call didCloseTab.

Consequence: every runtime.sendMessage from a content script in such a tab fails inside WebKit with the Extensions-category log 'Tab not found for message for content script message' (getCurrentTab cannot map the page to an open tab) and rejects with 'tab not found'. Observed 2026-09-13 on the Work profile's Google Calendar favourite (https://calendar.google.com/calendar/u/0/r?pli=1) with 1Password enabled: 1Password's content script has an unhandledrejection reporter that serializes the DOM (outerHTML, URL credential scrubbing) and reports via runtime.sendMessage; that report itself rejects with 'tab not found', firing another unhandledrejection, so the WebContent process spun at ~120% CPU and grew to 5 GB RSS while the page never finished loading. The same page opened as a normal tab in the same profile works because tabStoreDidInsertTab registers it. sample(1) of the WebContent showed RejectedPromiseTracker::reportUnhandledRejections -> JS listener -> JSWebExtensionAPIRuntime::sendMessage; the Detour host sat at ~40-50% CPU in WebExtensionContext::runtimeSendMessage -> getCurrentTab -> openTabs, with 117 'Tab not found' errors in 6 minutes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Activating a favourite (activateFavorite) reports the new backing tab to every WKWebExtensionContext of the favourite's profile via didOpenTab, and selecting it reports didActivateTab (dispatchActivated resolves favourite tabs)
- [x] #2 Deactivating or removing a favourite (deactivateFavorite, removeFavorite) and the extension-manager dormant-tile teardown report didCloseTab before the web view is released
- [x] #3 Peek tabs are reported with didOpenTab when created and didCloseTab when torn down (closePeekOverlay, orphan teardown, host teardown)
- [x] #4 BrowserWindowController.tabs(for:) includes the live favourite tabs of the window's active profile alongside pinned and normal tabs, and notifyExistingTabs reports live favourite tabs when a context loads
- [x] #5 URL/title/loading changes on a favourite backing tab reach ExtensionTabObserver (didChangeTabProperties), i.e. TabStore.subscribeToTab no longer drops updates for tabs that live only on Profile.favorites
- [ ] #6 A content script in a favourite tab can call runtime.sendMessage and the background receives sender.tab; the Extensions-category log no longer shows 'Tab not found for message for content script message' when loading the Google Calendar favourite with 1Password enabled, and the WebContent process idles after load
- [x] #7 Unit tests cover favourite activation/deactivation and peek open/close registration (a recording fake for the context notifications, or the ExtensionTabObserver seam) with positive and negative cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a single seam, ExtensionTabLifecycle (Detour/Extensions/Runtime/ExtensionTabLifecycle.swift): static notifier (protocol ExtensionTabLifecycleNotifying: didOpen/didClose/didActivate/didChangeProperties(tab, profile)) defaulting to a WK forwarder over profile.extensionContexts (optional contexts subset for notifyExistingTabs). didOpen stores the profile on BrowserTab (weak extensionRegisteredProfile); didClose uses it and is a no-op when nil, so teardown-time close is symmetric and idempotent.
2. Route every existing notification through the seam: ExtensionTabObserver (insert/remove/update/dispatchActivated), BrowserTab.wake(), BrowserWindowController.wakeIfNeeded, ExtensionManager.notifyExistingTabs.
3. Favourites: TabStore.activateFavorite and addFavorite(from:) call didOpen; BrowserTab.teardown() calls didClose (covers deactivateFavorite, removeFavorite, profile removal, dormant-tile teardown, peek teardown paths); TabStore.subscribeToTab notify gains a favourites branch firing a new TabStoreObserver hook tabStoreDidUpdateFavoriteTab(_:in:) (default no-op) that ExtensionTabObserver maps to didChangeProperties; ExtensionTabObserver.dispatchActivated resolves favourite tabs; notifyExistingTabs reports live favourite tabs.
4. Peeks: showPeekOverlay registers the new peek tab (didOpen with space.profile); expandPeekToNewTab closes the old peek BrowserTab before the web view is adopted by the new tab; closePeekOverlay/orphan/host teardown close via teardown(); notifyExistingTabs reports live peek tabs; BrowserTab.window(for:) resolves a peek to the window whose selected tab hosts it.
5. Window model: BrowserWindowController.tabs(for:) = pinned + normal + live favourite tabs of the active profile + live peeks of those, built by a pure helper (extensionWindowTabs) so it is unit-testable.
6. Tests: ExtensionTabLifecycleTests with a recording notifier on a TabStore(appDB:) instance — favourite activate/deactivate/remove, detach+addFavorite reopen, property change → didChangeProperties, dispatchActivated for a favourite, teardown idempotence and never-opened negative case; pure-helper ordering test for tabs(for:). Keep WK forwarder thin.
7. Verify: xcodegen generate, build, DetourTests; then /code-review --fix, backlog finalization, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Diagnosis 2026-09-13: see description. Verification tip: /usr/bin/log show --predicate 'process == "Detour" AND category == "Extensions"' surfaces the 'Tab not found' errors; sample the hot WebContent and look for RejectedPromiseTracker::reportUnhandledRejections above JSWebExtensionAPIRuntime::sendMessage. The 1Password reporter loop is outside our control; the fix is making every extension-controller web view a known tab.

Implementation 2026-09-13 (TASK-50):

Seam: new Detour/Extensions/Runtime/ExtensionTabLifecycle.swift.
- protocol ExtensionTabLifecycleNotifying { didOpen(_:in:contexts:), didClose(_:in:), didActivate(_:in:contexts:), didChangeProperties(_:in:) }
- WKExtensionTabLifecycleNotifier forwards to (contexts ?? profile.extensionContexts.values); didChangeProperties sends .URL/.title/.loading as ExtensionTabObserver used to.
- enum ExtensionTabLifecycle { static var notifier; didOpen(tab,in:contexts:) sets BrowserTab.extensionRegisteredProfile then notifies (re-notify on an already-registered tab is deliberate — didOpenTab is idempotent and a newly loaded context must be re-told); didClose(tab) reads that weak profile, clears it BEFORE notifying (idempotent, no-op when never opened); didActivate/didChangeProperties are pass-throughs }
- free func extensionWindowTabs(pinned:normal:favorites:) -> [BrowserTab]: pinned + normal + favourites, each followed by its peekTab when the peek has a web view.

Not @MainActor: BrowserTab/TabStore/ExtensionTabObserver are not actor-isolated, and annotating the seam would not compile at those call sites.

Routing: ExtensionTabObserver (insert/remove/update/dispatchActivated + new tabStoreDidUpdateFavoriteTab), BrowserTab.wake(), BrowserWindowController.wakeIfNeeded, ExtensionManager.notifyExistingTabs (passes the contexts subset; now also reports profile.favorites tabs and every reported tab's live peek). No direct context.didOpenTab/didCloseTab loops remain outside the notifier (ExtensionTestSupport's probe aside).

ExtensionTabObserver.init(store: TabStore? = nil) with a lazy 'injectedStore ?? .shared' getter rather than a '= .shared' default argument, so building the observer as an ExtensionManager stored property does not force TabStore.shared to initialize.

Favourites: activateFavorite and addFavorite(from:) call didOpen; BrowserTab.teardown() calls didClose after peekTab?.teardown() and before releaseWebView() — the single close point for deactivateFavorite, removeFavorite, the profile-swap deactivation, tile teardown and every peek path. subscribeToTab's notify closure gained a favourites branch (searches self.profiles after the pinned/normal searches) firing the new TabStoreObserver hook tabStoreDidUpdateFavoriteTab(_:in:) (default no-op).

Peeks: showPeekOverlay reports the new peek tab against space.profile right after its web view exists (no spaceID is set — that would change user-agent resolution); expandPeekToNewTab closes the old peek BrowserTab before clearPeekState so two tabs never share one adopted web view; BrowserTab.window(for:) resolves a peek to the window whose selectedTab hosts it, before the spaceID fallback.

Tests: DetourTests/ExtensionTabLifecycleTests.swift (12 cases) with a RecordingNotifier installed in setUp/restored in tearDown, on a private TabStore(appDB:) with an ExtensionTabObserver(store:) attached. Full suite: 939 tests, 0 failures.

Not verified here: AC#3 has no window-level test (peek open needs a BrowserWindowController; covered by code + the teardown-idempotence test) and AC#6 needs a live run with 1Password on the Google Calendar favourite.

Code review (--fix) 2026-09-13, changes on top of the implementation above:
- Property observation moved onto the seam: ExtensionTabLifecycle.didOpen installs $url/$title/$isLoading sinks on the tab (per-property TabChangedProperties), didClose removes them. This covers peeks and pinned tabs as well as favourites, so the favourites-only TabStoreObserver hook tabStoreDidUpdateFavoriteTab and ExtensionTabObserver.tabStoreDidUpdateTab were removed (the notes above describing that hook are superseded).
- BrowserWindowController.extensionTabs is the single enumeration (extensionWindowTabs over pinned + normal + profile.favoriteTabs, each followed by its live peek) used by tabs(for:), by BrowserTab.window(for:) membership (selected owner → any listing window → spaceID fallback), and by notifyExistingTabs — a listed tab always resolves to a window.
- BrowserTab.close(for:) now handles favourites (deactivateFavorite), peeks (closePeekOverlay when presented, else teardown + clearPeekState) and pinned tabs (closePinnedTab); added TabStore.favorite(backedBy:) and tab(hostingPeek:), Profile.favoriteTabs.
- TabStore.updateSpace closes tabs before sleep(force:) so the old profile's contexts do not keep a phantom tab; showPeekOverlay tears down whatever peek object the host still holds (a parked one is still registered) before replacing it.
- Ordering: didOpen fires after tab.peekTab = newPeekTab and after profile.favorites.insert, so the contexts can place the tab when onCreated fires.
- ExtensionTabObserver simplified to init(store: TabStore = .shared) (no init-order cycle: TabStore.init never touches ExtensionManager).
- Skipped by decision: a presented peek is never the active tab (activeTab(for:) returns the host) — deferred in docs/split-tabs-design.md; and registering at BrowserTab.init(configuration:) instead of per path (recommended follow-up).
- Tests: ExtensionTabLifecycleTests now 17 cases (adds peek/pinned property changes, changes stop after close, profile-swap close, addFavorite listed-before-open, lookup helpers).

Final gate 2026-09-13: xcodebuild -scheme Detour build → BUILD SUCCEEDED; xcodebuild -scheme DetourTests test → Executed 944 tests, 1 skipped, 0 failures, TEST SUCCEEDED. AC #6 (live check of the Google Calendar favourite with 1Password: no 'Tab not found' in the Extensions log, WebContent idles after load) is left for a relaunch of the app; not verified in-session.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Favourite backing tabs and Peek tabs were built from the profile's WKWebViewConfiguration (so extension content scripts ran in them) but were never reported to the profile's WKWebExtensionContexts, so every content-script runtime.sendMessage failed with WebKit's 'Tab not found' and 1Password's rejection reporter looped the Google Calendar favourite's WebContent process to ~120% CPU / 5 GB. Added a single seam, ExtensionTabLifecycle (didOpen/didClose/didActivate/didChangeProperties, with a test-swappable notifier), and routed every existing notification through it; favourites report open on activateFavorite/addFavorite, peeks on showPeekOverlay, and BrowserTab.teardown() is the one close point (also fixing pinned tabs, profile swaps and parked peeks that were never closed). Property observers are installed per registration so favourites, peeks and pinned tabs now emit tabs.onUpdated. tabs(for:), window(for:) and notifyExistingTabs share one enumeration (extensionWindowTabs), and close(for:) handles favourites, peeks and pinned tabs. Verified by 17 ExtensionTabLifecycleTests with a recording notifier plus the full suite (944 tests, 0 failures) and a clean app build; live check with 1Password pending an app relaunch.
<!-- SECTION:FINAL_SUMMARY:END -->
