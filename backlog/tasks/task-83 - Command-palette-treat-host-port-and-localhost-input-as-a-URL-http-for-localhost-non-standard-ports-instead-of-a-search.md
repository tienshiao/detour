---
id: TASK-83
title: >-
  Command palette: treat host:port and localhost input as a URL (http for
  localhost/non-standard ports) instead of a search
status: Done
assignee: []
created_date: '2026-09-15 18:40'
updated_date: '2026-09-15 19:04'
labels:
  - command-palette
  - navigation
dependencies: []
priority: medium
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Typing localhost:4000 in the command palette runs a web search. BrowserWindowController.directURL(from:) (BrowserWindowController.swift ~1881) only treats input as a URL when it has an http(s):// prefix or contains a dot with no spaces, so dotless hosts like localhost, localhost:4000, or an intranet host:port fall through to the search engine (also used by urlFromInput and CommandPaletteDelegate didSubmitInput). Expected: such input navigates. Scheme: localhost, loopback/private IPs and inputs with an explicit non-standard port should default to http:// (dev servers rarely serve TLS); dotted hosts without a port keep defaulting to https://. Watch for false positives: a single word with no port (e.g. 'swift') must still search, and 'foo:bar' style text should not become a URL unless the part after the colon is a valid port. Pull the classification into a pure, unit-tested function.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 localhost, localhost:4000 and localhost:4000/path navigate to http://localhost… instead of searching
- [x] #2 An explicit non-standard port on a dotless or dotted host (e.g. myhost:8080, example.com:8443) navigates, defaulting to http:// unless the port is 443
- [x] #3 IPv4 literals (127.0.0.1:3000, 192.168.1.10) navigate over http://
- [x] #4 Plain words and phrases (e.g. swift, 'foo bar', note:todo) still search
- [x] #5 Input classification lives in a pure function with unit tests covering the cases above
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. New pure enum AddressInputClassifier (Detour/Browser/CommandPalette/AddressInput.swift): classify(_ input) -> URL? returning the URL the typed text denotes, nil for a search.
   - Trimmed; any whitespace -> search.
   - Explicit http:// / https:// (case-insensitive) -> URL(string:).
   - Otherwise split host[:port] from the rest at the first / ? #; host:port where port is all digits 1-65535 counts, otherwise a colon means search (note:todo, foo:bar).
   - Host kinds: 'localhost' / *.localhost, IPv4 literal (4 dotted octets 0-255), bracketed IPv6 literal, dotted hostname (current rule: contains a dot), or any dotless host WITH a valid port (myhost:8080). A dotless word with no port (swift) -> search.
   - Scheme: http for localhost, IPv4/IPv6 literals, and any explicit port other than 443; https otherwise (dotted host with no port, or :443).
2. BrowserWindowController.directURL(from:) delegates to the classifier (used by urlFromInput and CommandPaletteDelegate didSubmitInput).
3. CommandPaletteView's 'Go to' vs 'Search' row label uses the same classifier so the suggestion row matches what Enter does.
4. Unit tests AddressInputClassifierTests covering every AC case plus false positives (note:todo, foo:99999, 1.2 words, trailing path/query on localhost).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented AddressInputClassifier.directURL(from:) (CommandPalette/AddressInputClassifier.swift); BrowserWindowController.directURL delegates to it and CommandPaletteView's Go-to/Search row label uses it. Behaviour change beyond the ACs: the dotted-name rule now looks at the host only (text before / ? #), so 'foo/bar.html' searches instead of becoming https://foo/bar.html; user@ prefixes are skipped when reading the host. Tests: AddressInputClassifierTests.

Code review fix: an all-digit dotless host with a 'port' (10:30, 16:9) searches instead of loading http://10:30.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Typed palette input is now classified by the pure AddressInputClassifier: localhost, IP literals, dotted hosts and non-numeric hosts with a valid port navigate (http:// for localhost/IPs/non-443 ports, https:// for dotted hosts without a port); words, note:todo, 10:30 and phrases search. The palette's Go to/Search label shares the rule. Verified by AddressInputClassifierTests (+ SuggestionProviderTests); not exercised in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
