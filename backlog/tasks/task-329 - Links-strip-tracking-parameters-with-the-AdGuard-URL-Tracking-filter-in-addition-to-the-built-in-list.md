---
id: TASK-329
title: >-
  Links: strip tracking parameters with the AdGuard URL Tracking filter in
  addition to the built-in list
status: To Do
assignee: []
created_date: '2026-11-14T20:17:00Z'
labels:
  - links
  - content-blocker
dependencies: []
references:
  - TASK-326
  - TASK-194
  - Detour/Browser/TrackingParameters.swift
  - Detour/Browser/ContentBlocker/ContentBlockerManager.swift
  - Detour/Browser/ContentBlocker/EasyListParser.swift
  - wiki/features/copy-url.md
  - wiki/features/quarantine.md
  - https://github.com/AdguardTeam/AdguardFilters/tree/master/TrackParamFilter
  - https://filters.adtidy.org/extension/ublock/filters/17.txt
priority: low
type: feature
ordinal: 403000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user after TASK-326. Copy URL, and quarantine navigations (TASK-194), strip tracking parameters using TrackingParameters.names. That list is hand-kept, global and about 30 names long, so it misses most site-specific tracking (for example Amazon's ref_ / pd_rd_* or a newsletter tool's own ids) and it only grows when someone notices a gap.

AdGuard's URL Tracking filter (filter 17, AdguardFilters/TrackParamFilter) is an actively maintained list of $removeparam rules in Adblock syntax. It has global rules ($removeparam=utm_source), per-site rules ($removeparam=ref_,domain=amazon.*), regex rules ($removeparam=/^__s=/) and @@ exceptions. It is the same syntax family as the EasyList lists that ContentBlockerManager already downloads and EasyListParser already reads; the parser currently drops $removeparam rules. Licence GPL-3.0, while Detour is MIT, so the list is downloaded at runtime like EasyList rather than bundled in the app.

Constraints:
- The built-in list stays as the floor. Copy URL must work before the first download, offline, and when a download or parse fails.
- Over-stripping is the main risk: a shared link that breaks for its recipient is worse than one that keeps a utm tag. The list's exceptions must be honoured.
- Navigation-time stripping can break pages, while copy-time stripping cannot. Whether quarantine navigations use the downloaded rules is a decision to make and record when the task is picked up.
- Regex rules may be skipped in a first cut if they are recorded as unsupported.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Copy URL (every entry point TASK-326 strips) removes parameters matched by the AdGuard URL Tracking filter, global and per-site (domain=, including wildcard TLDs such as amazon.*), in addition to TrackingParameters.names, and honours the list's @@ exceptions
- [ ] #2 The list is downloaded and refreshed through the existing filter-list update path, not bundled; before the first download, offline, or after a failed download or parse, Copy URL falls back to the built-in list with no error shown
- [ ] #3 Which rule forms are supported (plain names, per-site, exceptions, regex) and how unsupported rules are counted or logged is recorded in the task and the wiki
- [ ] #4 Whether quarantine navigations also use the downloaded rules is decided and recorded, and the shipped behaviour matches
- [ ] #5 Unit tests cover parsing and matching: global and per-site rules, wildcard TLD domains, negated domains (~domain), exceptions, case, repeated keys, and a fixture of real-world links that must survive unchanged
- [ ] #6 Checked at runtime with /verify: with the list loaded from a local fixture server, Copy URL on a page with a site-specific tracking parameter copies the clean link
<!-- AC:END -->
