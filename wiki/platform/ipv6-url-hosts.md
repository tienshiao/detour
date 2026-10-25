---
type: Platform Quirk
title: IPv6 hosts in URL APIs
description: "Foundation's URL.host returns an IPv6 literal without its brackets (::1 for http://[::1]:3000/) while URLComponents.host, WKSecurityOrigin.host and JavaScript keep them, so a URL rebuilt from URL.host does not parse and hosts read two ways never compare equal; the helpers Detour uses instead."
tags: [foundation, webkit, url, ipv6, favicons, dev-mode]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T00:38:52Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: url-host
    resource: ../../Detour/Browser/Shared/URLHost.swift
    title: URLHost.swift (authorityHost, faviconFallbackURL, faviconSiteKey, securityOriginHost)
  - id: url-host-tests
    resource: ../../DetourTests/URLHostTests.swift
    title: URLHostTests.swift
  - id: task-198
    resource: backlog:TASK-198
    title: "Tabs: navigating to an IPv6 literal URL (http://[::1]:3000/) crashes Detour in the optimistic favicon fetch"
  - id: harness
    resource: ../../docs/harness/task198-harness.patch
    title: TASK-198 runtime harness
---

The URL APIs Detour uses disagree about whether an IPv6 literal host keeps its
brackets. Code that reads a host one way and rebuilds or compares it another
way breaks only on IPv6 pages, which in practice means `http://[::1]:<port>/`
local dev servers.

# Behavior

Measured on macOS 26.6 (Darwin 25.6) with a `swiftc` probe and a standalone
`WKWebView` loading `http://[::1]:8898/`:[^task-198]

| API | `http://[::1]:3000/` | `https://äö.de/` |
|---|---|---|
| `URL.host`, `URL.host(percentEncoded: false)` | `::1` | `xn--4ca0b.de` |
| `URL.host()` (percent-encoded) | `::1` | `%C3%A4%C3%B6.de` |
| `URLComponents.host` | `[::1]` | `äö.de` |
| `URLComponents.encodedHost` / `percentEncodedHost` | `[::1]` | `xn--4ca0b.de` / `%C3%A4%C3%B6.de` |
| `WKSecurityOrigin.host` (a frame's origin) | `[::1]` (port separate: 8898) | — |
| JavaScript `location.host` / `hostname` | `[::1]:8898` / `[::1]` | — |
| `webView.url.absoluteString` | `http://[::1]:8898/` | — |

A zone ID comes back as `fe80::1%en0` from `URL.host` and `[fe80::1%25en0]`
from `encodedHost`.

Consequences:

- `URL(string: "\(scheme)://\(url.host!)/…")` is `nil` for an IPv6 page
  (`http://::1/…` does not parse). A force unwrap of it crashed Detour on every
  IPv6 page load, in `BrowserTab.load` and in the `webView.url` observer.[^task-198]
- `url.host == securityOrigin.host` is never true for IPv6, so a check that a
  message came from the tab's own page silently refuses it.
- A SQL or string match built from `url.host` (`http://::1…`) matches no
  stored URL, which WebKit writes with brackets.
- `URLComponents.host` is not a drop-in replacement either: it decodes an IDN
  to Unicode, while stored URL strings hold punycode.

# Why it matters here

[Dev mode](../features/dev-mode.md) treats `[::1]` as local development, so
these pages are exactly the ones a developer opens. `isLocalDevelopmentURL`
and `devModeHostLabel` already knew `URL.host` strips the brackets and add
them back; the favicon code did not.

# Workaround

Rules, all in [URLHost.swift](../../Detour/Browser/Shared/URLHost.swift):

- **Rebuild a URL from the page URL's own components**, never from a host
  string: `faviconFallbackURL(for:)` copies `URLComponents(url:)`, replaces the
  path and drops query, fragment and credentials. The host keeps whatever
  encoding the page URL had (brackets, `%25` zone, punycode).
- **Compare hosts as they are written in a URL**: `URL.authorityHost` is
  `url.host` with an IPv6 literal bracketed (any host containing `:`), so it
  equals `WKSecurityOrigin.host` and the host part of stored URL strings, and
  keeps punycode for an IDN.
- `securityOriginHost(_:isHostOf:)` is the origin-versus-page check
  (`BrowserTab.pageDidReportFaviconLink`).

Sites checked for TASK-198 and their verdicts:[^task-198]

| Site | Verdict |
|---|---|
| `BrowserTab.load` and the `webView.url` observer: optimistic `/favicon.ico` | **Crashed.** Now `faviconFallbackURL`; keeps the port too |
| `BrowserTab.pageDidReportFaviconLink` (FaviconLinkBridge sender check) | **Refused every IPv6 report** (`::1` vs `[::1]`). Now `securityOriginHost` |
| `HistoryDatabase.faviconURL(for:…)` same-host fallback | **Matched nothing** (`http://::1`). Now `authorityHost` |
| `BrowserTab.displayHost` (faux address bar) | **Showed `::1`.** Now `[::1]` |
| `devModeHostLabel`, `devModeSiteKey`, `isLocalDevelopmentURL` | Correct: brackets added back by hand |
| Hover card URL line (`HoverCardRules`) | Correct: reads `URLComponents.host` |
| Palette `displayHost`/`rootURL`, `history_display_host` | Correct: string-based on the URL text |
| `AddressInputClassifier` | Correct: `[::1]:8898` and `[::1]` are URLs (`http://`) |
| `ExternalAppLaunchPolicy.origin`, the WKUIDelegate origin strings, the extension polyfill origin key | Correct: built from `WKSecurityOrigin.host`, which keeps the brackets |
| Content blocking whitelist, picture-in-picture site keys | Consistent but bare: keyed by `url.host` (`::1`) on both write and read; the site popover's header reads `::1`. Not changed (a key change needs a migration) |
| External-app "Always allow" label (`URL(string: origin)?.host`) | Cosmetic: reads `::1` |
| `PeekAnchor`, `PinnedEntry.isNavigatedWithinPinnedHost` | Correct: compare `url.host` with `url.host` |
| WebSocket relay cookie matching (`url.host` vs `HTTPCookie.domain`) | Not checked: what `HTTPCookie.domain` holds for an IPv6 cookie is unverified |
| Extension tab URL matching, downloads | No host rebuilding: WebKit matches patterns natively; downloads keep URLs whole |

# Related

- [Favicons](../features/favicons.md) - the pipeline whose optimistic guess crashed.
- [Dev mode](../features/dev-mode.md) - why `[::1]` pages are common.
- [AppKit gotchas](./appkit-gotchas.md) - other platform behaviour that cost debugging time.

[^task-198]: TASK-198
