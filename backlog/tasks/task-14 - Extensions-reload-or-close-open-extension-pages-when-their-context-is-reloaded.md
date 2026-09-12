---
id: TASK-14
title: >-
  Extensions: reload or close open extension pages when their context is
  reloaded
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 03:50'
updated_date: '2026-09-12 19:04'
labels:
  - extensions
  - webkit
dependencies: []
priority: low
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When a WKWebExtensionContext is unloaded and reloaded mid-session (Profile.recoverFromBackgroundLoadFailure from TASK-2, disable/enable, update), WebKit assigns the new context a fresh webkit-extension://<UUID>/ base URL. Any extension page still open in a tab (options page, an extension tab opened via TabStore.addExtensionTab, a pinned popup) keeps the old UUID origin: its native chrome.* bindings die with the old context, and since TASK-10 every polyfill call from it is rejected with 'Unrecognized extension origin' (the bridge no longer trusts the body's extensionID). Nothing currently reloads or closes such tabs, so the user is left with a dead page until they navigate manually. Found by the 2026-09-11 code review of TASK-10 (skipped there as intended behaviour of the fix). Fix: on context reload, find tabs whose URL host is the old context's base URL host and re-navigate them to the same path under the new base URL (or close them if the extension is being disabled/removed). Consider doing this alongside TASK-11, which handles the other reload consequence (site-access grants).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a context reload via the recovery path, an open options/extension tab is re-navigated to the equivalent page under the new base URL and its polyfill and native APIs work again without user action
- [x] #2 Disabling or uninstalling an extension closes its open extension tabs (or navigates them away) instead of leaving dead pages
- [x] #3 Tabs of other extensions and ordinary web pages are untouched; a unit test covers the URL rewrite from old to new base URL including path and query
- [x] #4 Tabs whose old-origin page is a snapshot in a non-owning window are handled the same way (no reliance on an attached webView)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. New pure helpers in Detour/Extensions/Runtime/ExtensionPageURL.swift: rewriteExtensionPageURL(_:from:to:) (same path/query/fragment under the new base when scheme+host match the old base, case-insensitive host; nil otherwise) and isExtensionPage(_:ofOriginHost:). Unit tests in DetourTests/ExtensionPageURLTests.swift.
2. BrowserTab: wake() picks the configuration — a webkit-extension:// URL resolves its profile via the space, the extension id via Profile.extensionID(forOriginScheme:host:), and wakes from that context's webViewConfiguration (falling back to the space config). Fixes the pre-existing gap that a slept extension tab could never wake. New retarget(to:): releases the web view like sleep(force: true) but DISCARDS cachedInteractionState (it would restore the dead URL), sets url/lastAttemptedURL, clears favicon state, leaves the tab sleeping so the display path rebuilds it against the new origin.
3. Profile: unloadExtension(id:removeData:) returns the unloaded context's baseURL (@discardableResult). New extensionPageTabs(forOriginHost:) (space tabs + pinned tabs + favourite backing tabs + their peek tabs, across every space of this profile) and retargetExtensionPages(from:to:), which retargets each match and posts one rehost notification per affected space. recoverFromBackgroundLoadFailure captures the old base, and after the replacement context is in extensionContexts retargets to its baseURL (before didReloadExtensionContext, so the sleeping tabs announce themselves once on wake instead of twice). If the reload failed, the tabs are left alone and it is logged.
4. Rename .spaceProfileDidSwap -> .spaceTabsNeedRehost (6 sites) since it now serves both the profile swap and the context reload; same {spaceID} payload and same window handler.
5. Disable/uninstall (AC #2): ExtensionManager.setEnabled (both overloads) and uninstall capture each profile's old base from unloadExtension and close that origin's pages through TabStore — closeTab for space tabs, closePinnedTab for pinned entries, deactivateFavorite for favourites — so selection, splits and the closed-tab record stay consistent. install() over an existing extension retargets instead (the context comes back).
6. Tests: ExtensionPageURLTests (pure) plus ExtensionPageRehostTests in the style of ExtensionPermissionRestoreTests (real Profile + real extension fixture): open an extension tab via addExtensionTab, run the unload/load/retarget sequence, assert the tab is on the NEW base host with the same path, sleeping with no cached interaction state, and that waking it yields a web view on the new context's configuration; assert an https tab and another extension's tab are untouched (AC #3) and that disable closes the tab (AC #2).
7. Build the Detour scheme, run ExtensionPageURLTests + ExtensionPageRehostTests + ExtensionPermissionRestoreTests, self-review for lifecycle bugs (retain cycles, mid-close tabs, peek tabs, TabStore split invariants, windows on other spaces, incognito), then finalize in Backlog and commit in one commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation

New pure helpers in `Detour/Extensions/Runtime/ExtensionPageURL.swift`: `rewriteExtensionPageURL(_:from:to:)` and `isExtensionPage(_:ofOriginHost:)`, plus `ExtensionPageURL.scheme`. Path/query/fragment are carried over in their **percent-encoded** form so an extension page's query (which routinely holds a URL of its own) is not decoded and re-encoded differently.

`BrowserTab`:
- `wake()` now picks its configuration via a new `wakeConfiguration(in:)`: a `webkit-extension://` URL resolves the profile from the space, the extension id from `Profile.extensionID(forOriginScheme:host:)`, and wakes from that context's `webViewConfiguration`. This also fixes a pre-existing gap: before this, ANY slept extension tab woke into the space configuration, which cannot load the scheme, so it came back dead. Falls back to the space config when no loaded context claims the origin.
- New `retarget(to:)`: pauses media, releases the web view, DISCARDS `cachedInteractionState` (it would restore the dead URL), sets `url`/`lastAttemptedURL`, and leaves the tab sleeping so the display path rebuilds it.

`Profile`: `unloadExtension(id:removeData:)` is now `@discardableResult -> URL?` (the unloaded context's baseURL). New `extensionPageTabs(forOriginHost:)` (space tabs + pinned tabs + favourite backing tabs + each of their peek tabs, over every space referencing this profile) and `@MainActor retargetExtensionPages(from:to:)`, which retargets each match and posts one rehost notification per affected space. `recoverFromBackgroundLoadFailure` captures the old base and retargets to the replacement context's baseURL — deliberately BEFORE `didReloadExtensionContext`, because `notifyExistingTabs` skips sleeping tabs, so each rehosted tab is announced exactly once (on wake) instead of twice. If the reload produced no context, the pages are left alone and it is logged.

`.spaceProfileDidSwap` renamed to `.spaceTabsNeedRehost` (6 sites) — it now serves both the profile swap and the context reload; same `{spaceID}` payload, same window handler (`handleSpaceTabsNeedRehost`).

`ExtensionManager`: new private `closeExtensionPages(in:from:)` closes that origin's pages through TabStore — `closeTab` for space tabs, `closePinnedTab` for pinned entries, `deactivateFavorite` for favourites — so selection, split groups, the closed-tab stack and the sidebar stay consistent, and the close is undoable like any Cmd+W. Wired into `uninstall` and both `setEnabled` overloads.

## Deviations from the plan (deliberate)

1. **Title and favicon are kept, not cleared.** The plan said `retarget` should clear favicon state "as `load` does". It does not: this is the same page arriving from a new internal origin, not a navigation elsewhere. Clearing would flash a raw `webkit-extension://<uuid>/…` string as the sidebar title, and would drop an icon that cannot be fetched again (an extension page's icon lives at an extension URL, which `FaviconLoader`'s URLSession cannot load). `previousHost` is set to the new host so the host-change observer in `setupObservers` does not clear them either. Locked in by a test assertion.
2. **`install()` over an existing extension also retargets** (the task description mentions update as a third trigger). The old bases are captured before the unload and the pages are moved once the replacement context is loaded.
3. **`retargetExtensionPages` is not conditioned on the two origins differing.** Even in the (WebKit-impossible) equal-host case the open pages' web views still belong to the unloaded context and must be rebuilt.
4. **Peek tabs are retargeted but not closed.** They are included in `extensionPageTabs`, so a reload rehosts them; the disable/uninstall path does not touch them (a peek whose host tab is closed is torn down with it). A peek showing an extension page is not reachable today anyway: `showPeekOverlay` builds its web view from `space.makeWebViewConfiguration()`, which cannot load `webkit-extension://`. The overlay is also not re-presented after a rehost — peek tabs are not in the wake path — so the user reopens it.

## Validation

`xcodebuild -scheme Detour -configuration Debug build` — BUILD SUCCEEDED. Full suite green: `env TEST_RUNNER_DETOUR_DATA_DIR=DetourTests-task14 xcodebuild -scheme DetourTests -configuration Debug test` -> ** TEST SUCCEEDED ** (confirmed the isolated data directory). New suites: `ExtensionPageURLTests` (10 tests) and `ExtensionPageRehostTests` (10 tests, real Profile + real WKWebExtension fixtures, driving `recoverFromBackgroundLoadFailure`, `addExtensionTab`, `wake`, `setEnabled`, `uninstall`). `ExtensionPermissionRestoreTests` still green.

One unrelated flake seen once: `ExtensionPolyfillIntegrationTests` reported 1 failure in a full run, then passed in isolation and in three subsequent full runs. Not touched by this change.

## What the harness could not exercise

- AC #4's literal setup (two real windows, one showing a snapshot) needs an NSApp UI session. It is covered structurally instead: nothing in the rehost path reads or requires an attached web view (`extensionPageTabs` falls back to `tab.url`, `retarget` no-ops on a missing view), and `testRehostMovesATabWithNoWebView` asserts a tab with no web view is rehosted identically. Re-hosting then goes through the same `claimWebView` -> `wakeIfNeeded` -> `wake()` path a non-owning window uses when it gains ownership.
- That the rehosted page's `chrome.*` and polyfill calls actually work again is not asserted end-to-end (it needs a loaded extension page with a live bridge); the test asserts the mechanism instead — the tab is on the new context's origin and wakes from that context's `webViewConfiguration` (compared by user-script set against `context.webViewConfiguration`, and shown not to be the space configuration).

## Out-of-scope findings (not changed)

- **A persisted extension tab cannot survive a relaunch.** Base URLs are minted per context load, so a restored tab's `webkit-extension://<old-uuid>` host matches nothing and falls back to the space config (dead page). Fixing it needs the extension id + path to be persisted instead of the origin.
- **A pinned entry or favourite for an extension page keeps a dead `pinnedURL`/`url`.** Closing makes the tile dormant (the standard behaviour), but reactivating it later loads the stale origin. Same durable fix as above.
- **The window registers its owned-pane script message handlers (`linkHover`, `editableFieldFocus`, blocked-resource tracker) on the extension configuration's `userContentController`, which is shared across every extension page of the profile and the controller's own configuration.** Pre-existing (any `addExtensionTab` tab does this today); `wireOwnedWebView` removes before adding, so there is no duplicate-registration crash, but the handlers leak onto pages that never asked for them.

## Code review fixes (post-implementation)

- **Disable/uninstall closes are no longer undoable** (`TabStore.closeTab`/`closePinnedTab` gained `undoable: Bool = true`; `closeExtensionPages` passes `false`). The earlier note that the close was 'undoable like any Cmd+W' was wrong: undo and the closed-tab stack rebuild the tab from the space configuration on the dead `webkit-extension://<old-uuid>` URL, which can never load.
- **`install()` over an existing extension** now closes the pages of any profile that gets no replacement context (per-profile-disabled, or `WKWebExtension` init throws); before, those pages were stranded on a dead origin with no retarget and no close.
- **Favourite-backed pages**: `closeExtensionPages` moves each space's `selectedTabID` off the favourite's tab before `deactivateFavorite` and posts `.spaceTabsNeedRehost` for every space of the profile (same precedent as the profile swap in `TabStore.updateSpace`); `retargetExtensionPages` likewise notifies every space of the profile for a favourite or peek, since a favourite's backing tab's `spaceID` is only the space it was first activated in.
- **`pinnedURL` / `Favorite.url` are rewritten on retarget** (dormant entries included), so a later reactivation loads the live origin. The relaunch case remains out of scope.
- **Rehost notification** now carries `tabIDs` and is posted on the next main-queue turn: `handleSpaceTabsNeedRehost` ignores windows whose displayed tab/split partner was not retargeted (`selectTab` is not a no-op for a live tab), falls back to `deselectAllTabs()` when nothing resolves, and the deferral makes the 'announced once, on wake' ordering actually hold (a synchronous post woke the displayed tab before `didReloadExtensionContext` ran).
- `retarget(to:)` saves + sleeps a peek like `sleep(force:)`; `releaseWebView` resets `isPlayingAudio` (its KVO writer is async, so a forced release mid-playback pinned it true — pre-existing for the profile swap too).
- Cleanup: `Profile.extensionPageLocations(forOriginHost:)` (typed `ExtensionPageLocation`) replaces the bare-tab walk and the duplicate in `closeExtensionPages`; `BrowserTab.showsExtensionPage(ofOriginHost:)` owns the `webView?.url ?? url` rule; `rewriteExtensionPageURL` reuses `isExtensionPage`.
- Four new tests in `ExtensionPageRehostTests` (no closed-tab record/undo, pinned+favourite URL rewrite incl. dormant, displayed-favourite selection settle + profile-wide notification, `tabIDs` payload). Full suite green (706 tests).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
On a mid-session context reload, open extension pages are moved to the reloaded context's origin instead of being left dead; on disable/uninstall they are closed.

New pure `rewriteExtensionPageURL`/`isExtensionPage` (Detour/Extensions/Runtime/ExtensionPageURL.swift) carry path, query and fragment (percent-encoded, so an embedded URL survives) from the old base to the new, and reject anything that is not that origin. `Profile.unloadExtension` now returns the unloaded context's baseURL; `Profile.extensionPageTabs(forOriginHost:)` finds the pages open on it across space tabs, pinned tabs, favourite backing tabs and peek tabs, and `retargetExtensionPages(from:to:)` retargets each and posts one rehost notification per space. `BrowserTab.retarget(to:)` releases the web view and discards the cached interaction state (which would restore the dead URL), leaving the tab sleeping so the existing display path (claimWebView -> wakeIfNeeded -> wake) rebuilds it — which is what makes this work for a tab whose web view another window owns, or none does. `BrowserTab.wake()` now resolves a `webkit-extension://` tab's configuration from its owning context, also fixing the pre-existing gap that any slept extension tab woke dead. `.spaceProfileDidSwap` became `.spaceTabsNeedRehost`, now shared by the profile swap and the context reload. `ExtensionManager` closes that origin's pages through TabStore on disable and uninstall (undoable, splits and selection consistent) and retargets them on install-over-existing.

Verified: Detour builds; full DetourTests suite green, including new ExtensionPageURLTests (10) and ExtensionPageRehostTests (10), the latter driving the real recovery, disable and uninstall paths against real Profile and WKWebExtension fixtures.
<!-- SECTION:FINAL_SUMMARY:END -->
