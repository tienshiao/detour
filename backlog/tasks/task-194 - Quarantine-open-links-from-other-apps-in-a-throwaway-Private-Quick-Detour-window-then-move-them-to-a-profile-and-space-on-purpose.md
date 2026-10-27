---
id: TASK-194
title: >-
  Quarantine: open links from other apps in a throwaway Private Quick Detour
  window, then move them to a profile and space on purpose
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 10:15'
updated_date: '2026-10-27 06:59'
labels:
  - links
  - privacy
  - window
  - feature
dependencies:
  - TASK-191.1
  - TASK-191.2
  - TASK-193.1
  - TASK-193.3
priority: medium
ordinal: 230000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24.

**What.** A link from another app can be opened in **quarantine**: a Little/Quick Detour window (TASK-193) on a Private, throwaway data store, so the destination does not see or set any of your cookies or site data, and nothing is recorded in history. The window makes the state obvious (a quarantine badge or tint in the title bar, showing where the link redirected to) and offers an explicit move: Open in <Profile / Space>, which loads the current URL fresh in a tab of the chosen space (never carrying the quarantined cookies over, which is the point).

**How it is chosen.** Through Air Traffic Control (TASK-191): Quarantine is an Open in target. Proposed: it can be the **Default** target (every link from another app that no route matches is quarantined, which is what the user described) and a per-route target; routes keep sending trusted sites straight to their space. Only links from other apps are quarantined (typed URLs and in-browser clicks are not); decide whether a route can also quarantine in-browser clicks.

**Decisions to make and record:**
- **Isolation:** the shared Private profile store would let two quarantined links, and any open Private window, share cookies. Proposed: a fresh non-persistent data store per quarantine window (as the profile setting "per-tab isolation" already does per tab), discarded when the window closes or the page moves.
- **Fingerprinting:** an ephemeral store removes cookies and storage only; IP, fonts, canvas, screen and similar still identify you. Research what WebKit can do here, e.g. the SPI behind Safari's Advanced Tracking and Fingerprinting Protection (noise injection, `_networkConnectionIntegrityPolicy`-style policies) and link tracking protection (stripping click IDs such as `gclid`, `fbclid` from the URL). Record what works on the shipped macOS; guard any private API.
- **Extensions:** proposed none run in quarantine (not even those allowed in Private).
- **Downloads:** allowed, blocked or asked; and what the move offers when the page is mid-form.
- **Name:** Quick Detour vs Little Detour (see TASK-193).

Builds on: TASK-191.1 (target model), TASK-191.2 (external link routing), TASK-193.1 (the window), TASK-193.3 (moving the page to a space; here always a reload, since the data store differs).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Quarantine can be chosen as Air Traffic Control's Default target and as a route's target; a link from another app matching it opens in a quarantine window
- [x] #2 The quarantine window uses a fresh ephemeral data store (or the decided alternative), records no history, runs no extensions, and is visibly marked
- [x] #3 Open in <Profile/Space> loads the current URL fresh in a tab of the chosen space and closes the quarantine window; no quarantined cookie or storage reaches the destination (checked with a local fixture that sets a cookie)
- [x] #4 Fingerprinting and link-tracking measures are researched, the ones adopted are implemented with guarded API, and the limits are recorded in the wiki
- [x] #5 Routing and isolation rules have tests written first
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Research (done first): the shipped WebKit's privacy SPI with a standalone spike against a loopback server (canvas/audio/screen readback, link decoration on clicks and loads).
2. Tests first (stubs return empty values): resolver (a Quarantine route catches routable clicks, from normal and Private windows; the Default and typed URLs never), placement (.openInQuarantine), editor (Quarantine offered), tracking-parameter stripping rule, frozen Safari UA, quarantine Open in menu rule; store isolation (fresh non-persistent store per window, never a profile's or the shared Private store, popups share their opener's, Private profile's extension controller, no history, never archived, never auto-closed); windows (opened by routed external links and clicks, marked, Open in reloads in the chosen space and closes, the loopback cookie fixture proving nothing reaches the destination, two windows not sharing, downloads asked); extensions (allowed-in-Private context sees an incognito popup and the content script runs; a normal profile's sees nothing).
3. Model: QuarantineSession (the store, wiped when the last page goes), BrowserTab.quarantine, TabStore.openQuickDetourTab(quarantine:), resolver/placement/editor/Links caption.
4. Window: QuickDetourWindowController quarantine mode (badge + tint, info menu instead of the profile menu, Open in across every profile's spaces always reloading, Cmd+click a fresh quarantine, popups sharing, ask-before-download, guarded privacy SPI per navigation, tracking parameters stripped from the link and main-frame navigations, frozen Safari UA, no favicon fetch); AppDelegate.openInQuarantine.
5. Runtime check with a harness (external link and routed click into quarantine, cookie fixture across Open in, download question, light/dark), code review (high), suites, wiki (new quarantine page + link-routing/quick-detour updates), commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decided (user, 2026-10-24): quarantine applies to links from other apps only. A route never quarantines typed URLs or in-browser clicks (opening a Quick Detour window from a click does not make sense). For sending in-browser clicks to a private context, use the Private window target of Air Traffic Control instead (TASK-191).

Name decided 2026-10-24: Quick Detour (TASK-193).

Decided (user, 2026-10-26; supersedes the 2026-10-24 note on in-browser clicks):
- Isolation: a fresh non-persistent data store per quarantine window, discarded when it closes or the page moves (not the shared Private store).
- Downloads: ask each time (Download / Cancel, naming the file and the site).
- Scope: Quarantine is a Link Routes target (Default and per-route) for links from other apps, AND a route set to Quarantine also catches matching in-browser clicks. Typed URLs are never quarantined.
- Extensions: those allowed in Private run in a quarantine window (same as a Private window).
- Naming: Link Routes (TASK-212, was Air Traffic Control); the window is a Quick Detour (TASK-193).

Decided while implementing (2026-10-26/27, beyond the user's decisions; to confirm):
- Quarantine is a Quick Detour on the Private profile (its extension controller, content rules, no-history and Private-download rules) whose web view uses a fresh WKWebsiteDataStore.nonPersistent() per window (QuarantineSession), never the shared Private store. Windows the page opens (window.open, _blank) share the opener's quarantine (WebKit hands over the opener's store; sign-in popups keep window.opener). Cmd+click / Opt-Cmd-click inside a quarantine opens another quarantine with its own store.
- History: none. Archive: never (no closed-tab record on any close). Idle auto-close: never (the Private exception: nothing would be archived, the timer would only lose the page). Session restore: never.
- The Default set to Quarantine takes links from other apps only; a click is quarantined only by a route that matches it. A Quarantine route also catches matching clicks in a Private window (into a store of its own, so the one-way Private rule holds). Typed URLs never.
- Open in from a quarantine always reloads: every normal space of every live profile is listed (one section per profile), all marked as reloads; the button names the space a routed click came from, else the most recent normal window's space, else the most recently used. No Open in Private Window. A page mid-form reloads fresh and loses the text, without a warning.
- The window: the system appearance (not Private dark), an orange tint on the bar and a Quarantine badge where the profile pill is; the badge's menu explains it and names where the link came from and where the page is now. The profile pill switches nothing in a quarantine.
- Downloads: asked when WebKit asks for a destination (that is when the file name is known), as a sheet naming the file and the host; yes = a Private-scoped download of the window (cancelled with it after the close question), no = cancelled before anything is written; a closing window answers no. A .crx is a download like any other in quarantine (not offered for install).
- The Private session (hasLivePrivateSession) counts a quarantine as a user: the Private site settings (per-site content blocking switch) are shared.
- The launcher (Opt-Cmd-N) ignores a quarantine in front when picking the profile; the routed Quick Detour passes it over like a Private window.
- Fingerprinting: BaselineProtections | FingerprintingProtections | LinkDecorationFiltering through WKWebpagePreferences._setNetworkConnectionIntegrityPolicy: (SPI, called through its IMP: KVC throws), guarded by responds(to:). Not adopted: EnhancedNetworkPrivacy (Private Relay), HTTPS-only/first and fail-closed (change which pages load). Plus Safari's own user agent (OS frozen at 10_15_7, no Detour token), our own tracking-parameter rule (click IDs + utm_*) on the link and on main-frame GET navigations, and no app-side favicon fetch for a quarantine page.

Code review (high, 2026-10-27): 8 findings. Fixed: (1) Open in from a quarantine closed the window without the Private-download question, silently cancelling an allowed download -> it now asks as closing does (confirmClosingWithPrivateDownloads, seam QuickDetourWindowController.runPrivateDownloadCloseAlert); (2) the tracking-parameter rewrite could loop when a server redirects the clean address back to one with utm_* -> a redirect landing back on the address just cleaned is let through once (lastTrackingFreeLoad, cleared on commit; needs WebKit's _isRedirect SPI); (3) a download failing while its question is up could still be handed to DownloadManager on a later yes -> the gate remembers the failure; (4) title bar colour code de-duplicated; (5) installedSafariVersion read once. Tests added after the fix for (1) and (2), each failing with the fix removed; (3) has no test (a WKDownload cannot be made or failed on demand in the test host). Changed after review: a click in a Private window matching a Quarantine route is NOT quarantined (it stays): a quarantine's Open in reaches normal spaces, so it would be one Cmd+O from a normal profile and its history; supersedes the earlier 'from a Private window too' (test-first: 4 failures, then green). Skipped: shared Private site settings (decided above) and external-app permissions (Private never remembers an 'always allow', so a quarantine always asks); the isQuarantine checks spread across the Quick Detour code (a refactor beyond this task).

Validation (2026-10-27): QuarantineTests 27/0, QuarantineWindowTests 15/0, QuickDetourExtensionTests 18/0, ExternalLinkRoutingTests 20/0, InPageLinkRoutingTests 24/0 (alone), LinkRouteResolverTests 42/0, LinkRoutingEligibilityTests 45/0, LinkPlacementTests 20/0, LinkRouteEditorTests 15/0, LinkRouteStoreTests 39/0, QuickDetourTests 28/0, QuickDetourOpenInTests 30/0, QuickDetourOpenInWindowTests 17/0, QuickDetourProfileSwitchTests 23/0, QuickDetourProfileSwitchWindowTests 17/0, QuickDetourSidebarCopyTests 6/0, QuickDetourTitleBarTests 9/0 and QuickDetourWindowTests 15/0 (alone), QuickDetourArchiveTests 17/0, QuickDetourArchiveWindowTests 11/0, QuickDetourEntryPointsTests 21/0, QuickDetourHotKeyTests 22/0, QuickDetourLauncherTests 12/0, DownloadManagerTests 35/0, PrivateDownloadTransferTests 2/0, PrivateDownloadClosePolicyTests 10/0, ArchiveListLayoutTests 18/0, ArchivedTabRestoreTests 20/0, ExtensionPrivateDefaultTests 13/0, Favicon{LinkBridge,LookupScope,Favorite}Tests 8/13/4 /0. Test-host flakiness seen: in long combined runs (machine load 40-100) page loads in the test host start timing out after ~10 web-view suites' worth of loads; the same happens on the unchanged baseline (ExternalLinkRoutingTests + InPageLinkRoutingTests: 3 failures at the end of InPage on main's code too), and every affected suite passes when run in smaller groups. Not a quarantine regression; worth its own task.
Runtime: docs/harness/task194-harness.patch, light and dark, real posted input: external link through a redirect into a quarantine (params stripped, badge, Safari UA, own store), the site's cookie and storage present in the quarantine and absent after a posted Open in click (no Cookie header, Home's cookie store empty), a routed click, a Cmd-click making a second quarantine with another store, a tracked link stripped, the download question (Escape = nothing, Return = saved, Private-scoped), canvas/screen differing from a normal tab, Settings > Links. Not verified at runtime: a real app's link (Mail/Slack), an extension in a quarantine (unit tests only), the badge menu drawn, several displays, VoiceOver.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quarantine shipped: a Link Routes target (Default and per-route; links from other apps, plus clicks a Quarantine route matches outside Private windows; never typed URLs) that opens the link in a Quick Detour on the Private profile whose page has a fresh non-persistent WKWebsiteDataStore of its own (popups share the opener's, Cmd+click makes another), marked by an orange Quarantine badge and tint. Open in lists every profile's spaces and always reloads the address fresh there (a loopback fixture proves no cookie or storage arrives), asking first if an allowed download is running. No history, archive or idle close; extensions allowed in Private run; downloads asked each time (QuarantineDownloadGate). Privacy: WebKit's Baseline/Fingerprinting/LinkDecoration protections via the guarded _networkConnectionIntegrityPolicy SPI (measured: canvas/audio noise, screen = window; WebKit strips gclid/fbclid/mc_eid but not utm_*), our own tracking-parameter rule (click IDs + utm_*) on the link and main-frame GETs, Safari's frozen user agent, no app-side favicon fetch. Wiki: features/quarantine.md, platform/webkit-privacy-protections.md, link-routing/quick-detour/incognito/downloads updated. Tests first for the rules and isolation (43 red against stubs); review (high) fixed 5 findings, Private-window clicks no longer quarantined. Verified at runtime light and dark with real input (harness in docs/harness/task194-harness.patch).
<!-- SECTION:FINAL_SUMMARY:END -->
