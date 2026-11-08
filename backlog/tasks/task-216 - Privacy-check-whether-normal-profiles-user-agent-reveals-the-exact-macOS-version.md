---
id: TASK-216
title: >-
  Privacy: check whether normal profiles' user agent reveals the exact macOS
  version
status: To Do
assignee: []
created_date: 2026-10-27 22:21
updated_date: '2026-11-08T21:28:00Z'
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
- [ ] #1 The user agent each profile kind sends is recorded, with Safari's for comparison
- [ ] #2 The decision is recorded; if changed, a test covers the user agent a normal profile's web view gets
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, code reading (not yet measured at runtime). Default mode (.detour, every normal profile unless changed) sends: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 26_7_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15 Detour/0' (Profile.resolvedUserAgent + UserAgentMode.safariUserAgent/detourAppName). Differences from Safari's 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15': (1) the real OS version with patch (26_7_0; Safari freezes 10_15_7 and never sends a patch for it), also in the 'Safari' mode; (2) the 'Detour/0' token (major of 0.4.1, so 0 not 1 as comments say). Quarantine (Quarantine.userAgent) already matches Safari. Other places: chromeUserAgent (Chrome Web Store spoof, extension updater, a navigation fetch) has the real OS version and a hard-coded Chrome/131; FaviconLoader, FaviconPNGLoader, ContentBlockerManager list downloads and SearchSuggestionsService use URLSession.shared with CFNetwork's default UA ('Detour/<build> CFNetwork/<v> Darwin/<v>', app name + build + Darwin version) and the app-wide cookie jar, so favicon requests to every site carry that UA. Unchecked: the UA of web-page service worker fetches, extension pages/workers (WebKit's default for WKWebExtension views may lack Version/ Safari/), navigator.platform/vendor (expected WebKit defaults, as Safari).
<!-- SECTION:NOTES:END -->
