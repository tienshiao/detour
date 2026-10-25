---
id: TASK-198
title: >-
  Tabs: navigating to an IPv6 literal URL (http://[::1]:3000/) crashes Detour in
  the optimistic favicon fetch
status: Done
assignee:
  - '@claude'
created_date: '2026-10-25 00:17'
updated_date: '2026-10-25 01:15'
labels:
  - bug
  - crash
  - tabs
  - dev-mode
dependencies: []
priority: high
ordinal: 234000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-195 subagent 2026-10-24. Loading an IPv6-literal URL programmatically (e.g. http://[::1]:8895/) kills Detour at Detour/Browser/BrowserTab.swift:1191: the optimistic favicon fetch builds URL(string: "\(scheme)://\(host)/favicon.ico")! from url.host, which is ::1 without brackets, so URL(string:) returns nil and the force unwrap traps. The branch runs for any non-error-page navigation with page == nil, so typing [::1] in the command palette likely crashes too (not yet checked). Dev mode treats [::1] as local (TASK-186.1), so this hits local development directly.

Fix direction: build the favicon URL with URLComponents from the page URL (keeping the brackets and the port; check whether the port should be kept), never force-unwrap; search for other places that rebuild a URL from url.host the same way (favicon loader, hover card, dev-mode labels, AddressInputClassifier).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Navigating to http://[::1]:<port>/ (typed in the palette and programmatically) loads the page without crashing, and its favicon is requested from the right URL
- [x] #2 A test that would have crashed before covers the favicon URL for an IPv6 host (with and without a port)
- [x] #3 Other URL rebuilds from url.host checked and fixed where they lose IPv6 brackets
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Built (2026-10-24, Opus subagent; resumed once after a session restart, work intact): Detour/Browser/Shared/URLHost.swift: faviconFallbackURL(for:) copies the page URL's URLComponents, path /favicon.ico, drops query/fragment/credentials (keeps brackets, punycode, port); URL.authorityHost (url.host bracketed for IPv6); URL.nonDefaultPort; faviconSiteKey(for:) (lowercased authorityHost + non-default port); securityOriginHost(_:isHostOf:). Verified: URL.host / host() / host(percentEncoded: false) all give bare ::1; URLComponents.host, WKSecurityOrigin.host and JS location.host give [::1]; URLComponents.host decodes IDN to Unicode, so it is not a drop-in.

Port decision: keep it (the icon belongs to the origin). previousHost -> previousFaviconSite (faviconSiteKey), so localhost:3000 -> localhost:5173 now refetches instead of keeping the first server's icon; the old guess asked localhost on the default port.

Sites fixed: BrowserTab optimistic favicon guess (crash; now one guessFavicon helper for load and the URL observer, no force unwrap); pageDidReportFaviconLink sender check (compared ::1 with [::1]: every IPv6 page's declared icon was dropped); HistoryDatabase.faviconURL same-host fallback (built http://::1); BrowserTab.displayHost (showed ::1). Checked and correct: devModeHostLabel/devModeSiteKey/isLocalDevelopmentURL (now share nonDefaultPort/authorityHost), HoverCardRules, palette displayHost/rootURL, history_display_host, AddressInputClassifier (already treats [::1]:8898 as a URL), ExternalAppLaunchPolicy.origin, WKUIDelegate originString, polyfill origin key, PeekAnchor, PinnedEntry host checks, history page JS. Bare but consistent, unchanged: content-blocking and PiP site keys (url.host for write and read; changing needs a migration), and the site popover header / external-app 'Always allow' label read ::1 (cosmetic).

TDD: red 17 of 37 failing (26 assertions; URLHostTests 12/16, FaviconLinkBridgeTests 4/8, FaviconLookupScopeTests 1/13; displayHost 1 red); a stall://[::1]:3000 integration test would have crashed the host before.

/code-review --fix: 7 findings, 3 fixed: one default-port/bracket rule (nonDefaultPort shared by faviconSiteKey and devModeHostLabel), the duplicated optimistic fetch merged into guessFavicon, a double faviconSiteKey computation. Skipped: the history same-host favicon fallback is port-blind (pre-existing; a restored localhost:5173 tab with no icon of its own can borrow localhost:3000's; worth a decision), zone IDs (WebKit rejects them; host(percentEncoded: true) would break IDN), other bare-::1 display labels (cosmetic, outside the diff), a redundant scheme check.

Tests after review: 408/408 across 20 suites (URLHost, FaviconLinkBridge, FaviconLookupScope, FavoriteFavicon, ExtensionFaviconScope, BrowserTabWake, BrowserTabUnclaimedNavigation, CommittedLoadFailure, DevMode, DevModeSiteOverride, AddressInputClassifier, SuggestionProvider, TabStore, InternalPage, InternalPageIntegration, ExtensionPageRehost, DataURLTab, HistoryDatabase, PaletteTabScope, PaletteRows).

Runtime (docs/harness/task198-harness.patch, server on [::1]:8898; re-run after the review with an identical log): programmatic load of http://[::1]:8898/ stays alive (before the fix it trapped), favicon from http://[::1]:8898/favicon.ico, row shows the dev-mode border and host line [::1]:8898, address bar [::1]; Cmd+T typing [::1]:8898 + Return opens it in a new tab; Cmd+L in place to /declared.html takes the declared /green.png through the bridge with no second guess. Not verified: IPv6 cookie domains in the WebSocket relay, link-local zone IDs, a slow favicon completion on a busy first launch (not IPv6-specific).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
IPv6-literal URLs (http://[::1]:3000/) no longer crash Detour: the favicon guess is built from the page URL's components, keeping brackets and port, with no force unwrap. Also fixed: IPv6 pages' declared favicons were dropped, the history favicon fallback and the address bar lost the brackets, and favicon guesses ignored the port. 408 tests pass; runtime harness clean after review.
<!-- SECTION:FINAL_SUMMARY:END -->
