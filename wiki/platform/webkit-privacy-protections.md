---
type: Platform Quirk
title: WebKit privacy protections
description: What the shipped macOS WebKit (macOS 26.7) offers an embedder against fingerprinting and link tracking — the _networkConnectionIntegrityPolicy SPI on WKWebpagePreferences and its obfuscated bit names, what each bit measurably does (canvas and audio noise, screen reported as the window, WebKit's own click-ID stripping that keeps utm_*), why it must be called through its IMP and not key-value coding, and what no API changes (IP, fonts, hardware concurrency, the OS version in Detour's own user agent).
tags: [webkit, privacy, fingerprinting, spi, quarantine]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T09:30:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: prefs-private
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebpagePreferencesPrivate.h
    title: WKWebpagePreferencesPrivate.h (_WKWebsiteNetworkConnectionIntegrityPolicy)
  - id: prefs-impl
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebpagePreferences.mm
    title: WKWebpagePreferences.mm (the SPI bits mapped to AdvancedPrivacyProtections)
  - id: protections
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/network/AdvancedPrivacyProtections.h
    title: AdvancedPrivacyProtections.h
  - id: document
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/dom/Document.cpp
    title: Document.cpp (noiseInjectionPolicies)
  - id: spike
    resource: "Agent session notes, 2026-10-26: a standalone swiftc WKWebView spike against a loopback server, macOS 26.7 (not in the repository)"
    title: TASK-194 privacy SPI spike
  - id: quarantine
    resource: ../../Detour/Browser/QuickDetour/Quarantine.swift
    title: Quarantine.swift (privacyProtectionPolicy, applyPrivacyProtections, the tracking-parameter rule)
---

Safari's Advanced Tracking and Fingerprinting Protection is built on WebKit
options an embedder can reach only through SPI. Detour turns them on for
[Quarantine](../features/quarantine.md) pages (TASK-194).[^task-194] This page
records what the shipped WebKit offers, what each option did when measured,
and what nothing in WebKit changes.

# Behavior

## The SPI

`WKWebpagePreferences._networkConnectionIntegrityPolicy` (getter) and
`_setNetworkConnectionIntegrityPolicy:` (setter), an
`NS_OPTIONS(NSUInteger, _WKWebsiteNetworkConnectionIntegrityPolicy)`. It is
per navigation: the preferences handed back from
`decidePolicyFor:navigationAction:preferences:` carry it into that document.
The bit names are deliberately vague; `WKWebpagePreferences.mm` maps them to
WebCore's `AdvancedPrivacyProtections`:[^prefs-private][^prefs-impl][^protections]

| Bit | SPI name | WebCore protection |
|---|---|---|
| 1 << 0 | `Enabled` | `BaselineProtections` |
| 1 << 1 | `HTTPSFirst` | `HTTPSFirst` |
| 1 << 2 | `HTTPSOnly` | `HTTPSOnly` |
| 1 << 4 | `FailClosed` | `FailClosedForUnreachableHosts` |
| 1 << 5 | `WebSearchContent` | `WebSearchContent` (a debugging flag) |
| 1 << 6 | `EnhancedTelemetry` | **`FingerprintingProtections`** |
| 1 << 7 | `RequestValidation` | `EnhancedNetworkPrivacy` |
| 1 << 8 | `SanitizeLookalikeCharacters` | **`LinkDecorationFiltering`** |
| 1 << 9, 1 << 10 | `FailClosedForAllHosts`, `StrictFailClosed` | (macOS 26) |

WebCore also has `ScriptTrackingPrivacy` and `OverrideHardwareConcurrency`,
which no bit of this SPI sets.

## Calling it

`responds(to:)` is true for both selectors on macOS 26.7. **Key-value coding
does not reach it**: `setValue(_:forKey: "_networkConnectionIntegrityPolicy")`
throws `NSUnknownKeyException` (KVC looks for `set_networkConnectionIntegrityPolicy:`,
which does not exist), and an uncaught exception in a navigation delegate
takes the app down. Detour calls both through `method(for:)` cast to a
`@convention(c)` function (`Quarantine.applyPrivacyProtections`), OR-ing its
bits into what is already set, behind a `responds(to:)` check for both
selectors.[^spike][^quarantine]

## What each bit did, measured

A standalone `WKWebView` per case, each on its own non-persistent store,
loading a loopback page that draws a canvas, renders an `OfflineAudioContext`
and reports `screen`, `navigator` and the URL it landed on (macOS 26.7,
2026-10-26):[^spike]

| Bits | Canvas `toDataURL` hash | Audio sum | `screen` | Click IDs in the URL |
|---|---|---|---|---|
| none (twice) | identical both times | identical | the display (5120 × 1440) | kept |
| `FingerprintingProtections` (twice) | **different each session** | **different** | **the web view's size** (400 × 300) | kept |
| `BaselineProtections` alone | identical | identical | the display | kept |
| `LinkDecorationFiltering` | identical | identical | the display | `gclid`, `fbclid`, `mc_eid` **removed**; `utm_source` **kept** |
| `EnhancedNetworkPrivacy` alone | identical | identical | the display | kept |

- The noise is per session (WebKit salts it per registrable domain and
  page; `Document::noiseInjectionPolicies` turns it on for
  `FingerprintingProtections`),[^document] so two quarantines read the same drawing back differently, and a
  site cannot link them by canvas or audio.
- Link decoration filtering applied to a cross-site click, a same-site click
  and a direct `load(_:)` alike, and the navigation policy already saw the
  stripped URL. Its list comes from WebKit (Safari's list, through the
  WebPrivacy framework); the embedder cannot add to it, and `utm_*` is not on
  it — Safari leaves campaign tags alone by design.
- `navigator.hardwareConcurrency` (8) and `navigator.languages` and the time
  zone were the same with every bit.

# Why it matters here

[Quarantine](../features/quarantine.md) is meant to keep a link's destination
from recognising you. A fresh non-persistent store removes cookies and
storage only; these bits are the rest WebKit offers. Detour sets
`BaselineProtections | FingerprintingProtections | LinkDecorationFiltering`
(`Quarantine.privacyProtectionPolicy`) on every navigation of a quarantine
page.

**Left out, and why:** `EnhancedNetworkPrivacy` (rests on iCloud Private
Relay, which is Safari's, and showed nothing measurable here); the HTTPS-only,
HTTPS-first and fail-closed bits (they change which pages load at all, which
a link opened from another app should not discover by failing).

# Workaround

What WebKit does not cover, Detour adds itself for quarantine pages:

| Gap | Measure |
|---|---|
| `utm_*` and click IDs not on WebKit's list | `Quarantine.removingTrackingParameters`: a fixed list (`gclid`, `fbclid`, `msclkid`, `mc_eid`, `igshid`, `ttclid`, `_hsenc`, `mkt_tok`, …) plus every `utm_` parameter, removed from the link before it loads and from every main-frame GET the page navigates to (cancelled and loaded again without them; back/forward, reloads, POSTs, downloads and anchor jumps untouched; each clean address rewritten once per user navigation, so a page or server that insists on its parameters gets them the second time instead of a loop) |
| Detour's user agent (`… Safari/605.1.15 Detour/1`, with the real OS version) is rarer than Safari's | Safari's own string, the OS version frozen at `10_15_7` as Safari sends it, no Detour token (`Quarantine.userAgent`) |
| Favicons are fetched with the app's `URLSession.shared`, outside the page's store (its cookie jar is the app's) | none fetched for a quarantine page |

Unlike WebKit's own filtering, which rewrites the request in place, Detour's
rule can only cancel a navigation and start another from
`decidePolicyFor`. That costs what a fresh load loses (a download's
`download` attribute and Referer, a same-document jump), so those are left
alone, and it can loop against a page that sends the clean address back
(a client `location.replace` arrives as `.other` with no redirect flag), so
the rewrites are budgeted ([Quarantine](../features/quarantine.md#link-tracking-parameters)).

**What nothing changes** (limits): the IP address and network path, the
fonts installed, `hardwareConcurrency`, languages and time zone, the
window's own size (now reported as the screen), WebGL renderer strings,
timing side channels, and anything a site learns from what the user types or
signs into. Quarantine makes a visit hard to link to your normal browsing
through stored state and the common fingerprinting reads; it does not make
you anonymous. Without the SPI (an older or changed WebKit) the store,
user agent and parameter rule still hold.

# Related

- [Quarantine](../features/quarantine.md) — the feature these protections serve.
- [Content blocking](../features/content-blocking.md) — the other per-navigation `WKWebpagePreferences` SPI Detour sets (the per-site switch).
- [WebKit source lookup](webkit-source-lookup.md) — how the sources above were read.

[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
[^prefs-private]: WKWebpagePreferencesPrivate.h (_WKWebsiteNetworkConnectionIntegrityPolicy)
[^prefs-impl]: WKWebpagePreferences.mm (the SPI bits mapped to AdvancedPrivacyProtections)
[^protections]: AdvancedPrivacyProtections.h
[^spike]: TASK-194 privacy SPI spike
[^document]: Document.cpp (noiseInjectionPolicies)
[^quarantine]: Quarantine.swift (privacyProtectionPolicy, applyPrivacyProtections, the tracking-parameter rule)
