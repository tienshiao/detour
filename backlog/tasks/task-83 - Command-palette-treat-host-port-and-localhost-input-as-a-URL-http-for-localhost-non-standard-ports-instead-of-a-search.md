---
id: TASK-83
title: >-
  Command palette: treat host:port and localhost input as a URL (http for
  localhost/non-standard ports) instead of a search
status: To Do
assignee: []
created_date: '2026-09-15 18:40'
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
- [ ] #1 localhost, localhost:4000 and localhost:4000/path navigate to http://localhost… instead of searching
- [ ] #2 An explicit non-standard port on a dotless or dotted host (e.g. myhost:8080, example.com:8443) navigates, defaulting to http:// unless the port is 443
- [ ] #3 IPv4 literals (127.0.0.1:3000, 192.168.1.10) navigate over http://
- [ ] #4 Plain words and phrases (e.g. swift, 'foo bar', note:todo) still search
- [ ] #5 Input classification lives in a pure function with unit tests covering the cases above
<!-- AC:END -->
