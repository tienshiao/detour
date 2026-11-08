---
id: TASK-216
title: >-
  Privacy: check whether normal profiles' user agent reveals the exact macOS
  version
status: Done
assignee: []
created_date: 2026-10-27 22:21
updated_date: '2026-11-08T22:15:00Z'
labels:
  - privacy
  - question
dependencies: []
priority: low
ordinal: 252000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-194: quarantine windows send Safari's standard user agent, but normal profiles appear to send one that includes the exact macOS version, which makes Detour easier to fingerprint than Safari. Confirm what each profile kind sends (navigator.userAgent and the request header), compare with Safari on the same Mac, and decide whether normal profiles should send the standard Safari user agent too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The user agent each profile kind sends is recorded, with Safari's for comparison
- [x] #2 The decision is recorded; if changed, a test covers the user agent a normal profile's web view gets
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, code reading (not yet measured at runtime). Default mode (.detour, every normal profile unless changed) sends: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 26_7_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15 Detour/0' (Profile.resolvedUserAgent + UserAgentMode.safariUserAgent/detourAppName). Differences from Safari's 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15': (1) the real OS version with patch (26_7_0; Safari freezes 10_15_7 and never sends a patch for it), also in the 'Safari' mode; (2) the 'Detour/0' token (major of 0.4.1, so 0 not 1 as comments say). Quarantine (Quarantine.userAgent) already matches Safari. Other places: chromeUserAgent (Chrome Web Store spoof, extension updater, a navigation fetch) has the real OS version and a hard-coded Chrome/131; FaviconLoader, FaviconPNGLoader, ContentBlockerManager list downloads and SearchSuggestionsService use URLSession.shared with CFNetwork's default UA ('Detour/<build> CFNetwork/<v> Darwin/<v>', app name + build + Darwin version) and the app-wide cookie jar, so favicon requests to every site carry that UA. Unchecked: the UA of web-page service worker fetches, extension pages/workers (WebKit's default for WKWebExtension views may lack Version/ Safari/), navigator.platform/vendor (expected WebKit defaults, as Safari).

Nov 8 2026, implemented. User decision: plain Safari string only when the user chooses Safari; keep Detour/ when the user chooses Detour. Both modes (and quarantine) now freeze the macOS version at 10_15_7 (UserAgentMode.safariUserAgent(safariVersion:)); Detour mode = that + ' Detour/<major>'; Chrome spoof frozen too. Detour's own GETs (favicons, search suggestions; review added Media Session artwork + OpenSearch via CappedDataFetcher and filter-list downloads) send Safari's plain string via URLRequest.withSafariUserAgent: one shared favicon cache serves every profile, so it must not carry the token a Safari-mode profile must never send. Runtime (/verify: Debug build, DETOUR_DATA_DIR=DetourVerify216, local server logging User-Agent): Detour mode -> page headers, navigator.userAgent, SW script, a fetch inside the SW and the SW's navigator.userAgent all 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15 Detour/0'; Safari mode (profile.userAgentMode=1) -> the same without ' Detour/0', favicon fetches too (after the fix); platform MacIntel, vendor 'Apple Computer, Inc.'. Safari's string for comparison is its fixed format with the installed Safari 27.0 (Safari itself not driven). Tests: new UserAgentTests (4) + QuarantineTests, UpdateManifestTests, ContentBlockerTests, MediaArtworkLoaderTests, SuggestionProviderTests, favicon suites: 123/0. /code-review medium --fix: 5 findings, 2 fixed (CappedDataFetcher, filter lists), 3 left: a blank Custom string falls back to WebKit's default UA with Detour/0 and no Version/Safari (pre-existing; user's call), two cosmetic. Not measured: extension pages/workers. Cleaned: defaults keys, the DetourVerify216 suite and data dir.

Nov 8 2026 follow-up (user: Settings should refuse an empty field, clean up the other two review findings, measure extension pages and workers): validatedCustomUserAgent refuses blank, line breaks and control characters (tab allowed); Settings reverts the field and beeps; Profile.selectUserAgentMode seeds Custom from the previous user agent; a stored blank Custom sends the Detour mode's string; resolvedUserAgent is non-optional; Quarantine.userAgent is UserAgentMode.safariUserAgent; dead test branch removed. Measured (Debug, DETOUR_DATA_DIR=DetourVerify216b, seeded MV3 probe extension, local logging server): the background worker sent WebKit's bare 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)' (no Version/Safari) -> fixed by applicationNameForUserAgent = 'Version/<Safari> Safari/605.1.15' on the extension controller's webViewConfiguration; re-measured: worker header and navigator.userAgent are Safari's exact string; an extension page opened with tabs.create sends the profile's (Detour/0 in Detour mode). Not measured: popups, options pages. Also fixed two Settings notes that said Private extension data 'is discarded when Detour quits' (since TASK-298: cleared when the last Private window closes). /code-review medium --fix: 6 findings, 5 fixed. Tests: UserAgentTests, QuarantineTests, SettingsPaneColumnsTests, UpdateManifestTests 69/0. Not runtime-checked: the Settings field's refusal (revert + beep) by hand; the rule is tested in Profile.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Normal profiles no longer send the real macOS version: the Safari mode sends Safari's exact string (macOS frozen at 10_15_7, as Safari does), the Detour mode the same plus Detour/<major>, and Detour's own background requests (favicons, suggestions, media artwork, OpenSearch, filter lists) send Safari's string instead of CFNetwork's app/build/Darwin identifier. Measured in page headers, navigator and a service worker; 123 tests pass. Open: blank Custom user agent falls back to WebKit's default.
<!-- SECTION:FINAL_SUMMARY:END -->
