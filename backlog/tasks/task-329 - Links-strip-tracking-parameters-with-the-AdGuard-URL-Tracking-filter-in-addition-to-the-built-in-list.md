---
id: TASK-329
title: >-
  Links: strip tracking parameters with the AdGuard URL Tracking filter in
  addition to the built-in list
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14T20:17:00Z'
updated_date: '2026-11-14T21:50:00Z'
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
- [x] #1 Copy URL (every entry point TASK-326 strips) removes parameters matched by the AdGuard URL Tracking filter, global and per-site (domain=, including wildcard TLDs such as amazon.*), in addition to TrackingParameters.names, and honours the list's @@ exceptions
- [x] #2 The list is downloaded and refreshed through the existing filter-list update path, not bundled; before the first download, offline, or after a failed download or parse, Copy URL falls back to the built-in list with no error shown
- [x] #3 Which rule forms are supported (plain names, per-site, exceptions, regex) and how unsupported rules are counted or logged is recorded in the task and the wiki
- [ ] #4 Whether quarantine navigations also use the downloaded rules is decided and recorded, and the shipped behaviour matches
- [x] #5 Unit tests cover parsing and matching: global and per-site rules, wildcard TLD domains, negated domains (~domain), exceptions, case, repeated keys, and a fixture of real-world links that must survive unchanged
- [x] #6 Checked at runtime with /verify: with the list loaded from a local fixture server, Copy URL on a page with a site-specific tracking parameter copies the clean link
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rule: TrackingParameterFilter (nonisolated, Sendable) parses filter 17's $removeparam rules: URL patterns (||host, |, ^, *, open-ended host prefixes, wildcard-TLD hosts like ||audible.*/), domain= include/~exclude with entity.* wildcards (bounded public-suffix approximation, no PSL in the app), plain names, bare $removeparam (remove all), ~name (keep only), @@ exceptions (named and bare). Skips and counts: regex values, regex patterns, rules limited to non-document request types, $app / unknown options, non-$removeparam lines. Indexed by global names / host-suffix dictionary / linear rest so a menu click is cheap.
2. TrackingParameters.removing(from:using:) takes the rule set; copy paths (copyableString, Share…) use the downloaded set via TrackingParameterFilterStore (main actor); quarantine keeps the built-in-only entry point (AC #4 PROVISIONAL). Exceptions from the list also keep built-in names once the list is loaded (PROVISIONAL).
3. Download/refresh: TrackingParameterListLoader driven by ContentBlockerManager.initialize / forceRefreshAll / clearCacheAndRedownload (same ETag/lastFetch/24h bookkeeping, cache file, per data dir), parsed off main, installed on main only when it yields rules; not in filterLists (no Settings row: a switch/row is a follow-up). Not started in the test host. DEBUG env override DETOUR_TRACKING_FILTER_URL for /verify.
4. Tests: parser/matcher (global, per-site, wildcard TLD, ~domain, exceptions, case, repeated keys, real-world links unchanged) from a trimmed attributed fixture; loader tests with a URLProtocol session (first download, 304, failure keeps fallback, garbage keeps previous, clear drops); copy entry point with an installed set; TEST_RUNNER_-gated full-list check.
5. Wiki (copy-url, content-blocking, quarantine), /verify via local fixture server + Shift-Cmd-C, code review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: Detour/Browser/TrackingParameterFilter.swift (pure, nonisolated, Sendable: parses the list's $removeparam rules and returns a per-address Verdict; rules indexed by host), Detour/Browser/ContentBlocker/TrackingParameterList.swift (download, cache, conditional refresh, Clear Cache & Redownload, tickets so older text never replaces newer), driven by ContentBlockerManager.initialize / forceRefreshAll / clearCacheAndRedownload. TrackingParameters.removing(from:using:) takes the rule set; cleanLink(for:) (Copy URL entry points via copyableString, and Share…) passes TrackingParameters.downloadedFilter; quarantine keeps removing(from:) (built-in only). Not one of ContentBlockerManager.filterLists: no Settings row, no switch, never compiled into a WKContentRuleList. The test host never downloads it (AppDelegate.isRunningUnitTests). Debug-only env seam DETOUR_TRACKING_FILTER_URL for runtime checks.

List: the uBlock Origin build of filter 17 (https://filters.adtidy.org/extension/ublock/filters/17.txt), GPL-3.0, downloaded at runtime, never bundled. Compared with AdGuard's chromium build: that one adds global utm_*/_ga/oly_enc_id/elq* rules (the built-in names cover most) and ~14 more exceptions; the uBO build keeps those rules' exceptions without the rules. Tests use a trimmed, attributed excerpt (DetourTests/TrackingParameterFilterFixture.swift, header + licence lines kept).

AC #3, rule forms. Supported: Adblock URL patterns (||host, | anchors, ^, *, substrings, open-ended host prefixes like ||read.amazon., wildcard TLD ||amazon.*/… where .* ends the host), domain= with includes, ~excludes and name.* wildcards, $removeparam=name (compared exactly, raw or percent-decoded, as AdGuard's plain removeparam is case-sensitive), bare $removeparam (remove all), $removeparam=~name (all but name), @@ exceptions named (compared without case) and bare, $document / $~xhr / $~3p apply. A page address is a document request: its own host is both the pattern target and the domain= context. Skipped and counted (TrackingParameterFilter.Counts, logged with .public counts under content-blocker as 'Installed adguard-url-tracking from cache|download: …'): regex values and /…/ patterns (regex), rules limited to other request types or 3p (notForPages), block rules with unknown options ($app, $match-case, …) or remove-all/all-but with no pattern and no included domain (unsupported), non-$removeparam lines (other). An exception is never dropped for an unknown option: kept without it (widenedExceptions); a regex exception keeps every parameter of its addresses. $important is accepted and ignored (exception still wins; the list has none). Whole list of 2026-11-13: 2,665 rules used (96 exceptions, 1 widened), skipped 42 regex, 46 not for pages, 0 unsupported, 1 other; parsed in ~40 ms, ~2 ms per address in a Debug build (TEST_RUNNER_TRACKING_FILTER_FILE leg). Wildcard TLDs use isPublicSuffixLike, a bounded approximation (one letter label, or a common second-level label over a 2-letter ccTLD) since Detour has no public suffix list: amazon.evil.com is not amazon.*; a rarer real suffix is missed (under-stripping).

Decision (Claude, not confirmed by the user): once the list is loaded, an exception as written and limited to some addresses (pattern or included domain) also keeps a built-in name (archive.* query strings, utm_source sites need); a widened exception or one for every site cancels only the list's rules, so the built-in names stay the floor. Alternative: exceptions never touch built-in names; one line in TrackingParameters.removing.

AC #4 decision — PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): quarantine navigations (Quarantine.trackingFreeURL, openQuarantine) keep the built-in list only; the downloaded rules apply to Copy URL / Copy Link / Share… only. Reason: stripping a parameter a page needs on navigation breaks the page; stripping on copy only changes the copied text. Alternative: use TrackingParameters.cleanLink(for:) in those two call sites (two lines). QuarantineTests/QuarantineWindowTests unchanged; TrackingParameterFilterTests.testQuarantineNavigationsUseTheBuiltInListOnly pins it.

Tests (xcodebuild DetourTests, final run after review fixes): TrackingParameterFilterTests 36 (incl. the whole-list leg with TEST_RUNNER_TRACKING_FILTER_FILE pointing at a downloaded copy), TrackingParameterListTests 10, TrackingParametersTests 13, CopyURLTests 11, QuarantineTests 24, QuarantineWindowTests 22, QuickDetourWindowTests 16, ContentBlockerTests 11 = 143 tests, 0 failures. Full suite not run (the lead runs it).

Runtime (/verify, docs/harness/task329-tracking-filter-checks.py through the automation endpoint, Debug build of this branch, dylib 13:42 after the review fixes, fresh isolated DETOUR_DATA_DIR per launch, cleaned up after): A) the excerpt plus rules for 127.0.0.1 served locally via DETOUR_TRACKING_FILTER_URL: list fetched and cached; Shift-Cmd-C (key equivalent) and Edit > Copy URL copied …/article.html?id=42&ref=home#c from ?id=42&ref_=nav&asc_campaign=fall&pjclid=7&utm_source=news&gclid=x&ref=home#c (host pattern, domain=, global list name, built-in names); an exception kept utm_source under /keep/; tabs kept their tracked URLs. B) list URL answering 404: nothing cached, Shift-Cmd-C fell back to the built-in names (ref_/asc_campaign/pjclid kept), no alert (screenshot checked). Found: a pattern matches the address as written, port included (||127.0.0.1/keep/ does not match 127.0.0.1:64903/keep/). Not checked at runtime: Share… and the sidebar menu with the filter (CopyURLTests), Quick Detour's copy (same copyableString), Update Now / Clear Cache from Settings (TrackingParameterListTests cover the loader; the manager hooks are three call lines).

Code review (/code-review medium --fix): 9 findings. Fixed by the review: cache written only after the ticket check (superseded text could overwrite or resurrect a cleared cache); no second download when Clear ran during the launch cache read; storage resolved once; hand-written byte search replaced with firstRange(of:). Fixed after: widened exceptions (regex, ~name, unknown option) and global exceptions no longer override the built-in names (test added); a trailing-dot host now matches (test added). Kept: $important ignored (documented; the list has none); the ruleCount defaults key (parity with the other lists' bookkeeping); wiki (done in this commit).

Follow-ups for the lead: a Settings row / switch for the list (Settings > Content Blocking: status, rule count, on/off) — not built, the TASK-328 agent is in that pane; whether quarantine should use the list (AC #4); possibly switch to AdGuard's chromium build for its extra exceptions.

Follow-up after the final check: case sensitivity confirmed in tsurlfilter's remove-param-modifier.ts (a plain value becomes the regex ^name=[^&#]*$ with no i flag), which also needs a name= pair: list names now only remove a pair with '=' (a bare ?name is kept; built-in names unchanged). Test testAListNameNeedsAValue. Correction to the AC #3 note above: a regex exception keeps its addresses' parameters from the list's rules only, not from the built-in names (changed after the review). Known difference: patterns are matched against the whole address including its #fragment, which a content blocker never sees (no list rule is affected). Data point on over-stripping: the whole list removes Amazon's th= (||amazon.*$removeparam=th), so a link chosen as 'ordinary' changed under it. Tests rerun after this change: TrackingParameterFilterTests 37 (1 skipped: the whole-list leg without its env var; it passed in the earlier run), TrackingParametersTests 13, CopyURLTests 11, DevToolbarHostingTests 13, QuarantineTests 24 = 98, 0 failures. This change had no separate code review; the runtime check ran on the build before it (its pairs all carry values).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Copy URL, Copy Link and Share… now also remove the parameters AdGuard's URL Tracking filter (filter 17, uBO build, downloaded at runtime, never bundled) names for the page's site, on top of the built-in TrackingParameters.names, and honour the list's @@ exceptions. A pure TrackingParameterFilter parses the $removeparam rules (Adblock URL patterns, domain= with ~ and name.* wildcards, remove-all/all-but, exceptions; regex rules, other request types and unknown block options skipped and counted: 2,665 of the real list's rules used, 42 regex and 46 other-type rules skipped). TrackingParameterList downloads, caches and refreshes it from the content blocker's launch / Update Now / Clear Cache paths; every failure keeps the built-in names with nothing shown. Quarantine navigations stay on the built-in list (AC #4, PROVISIONAL decision by Claude, not confirmed by the user; left unchecked, task left In Progress). Tests: 143 across 8 suites, 0 failures; runtime check through the automation endpoint passed (list served locally: site parameters stripped by Shift-Cmd-C and Edit > Copy URL, exception honoured; list 404: built-in fallback, no alert). Follow-ups: a Settings row/switch for the list; confirm AC #4 and the exceptions-over-built-in-names choice.
<!-- SECTION:FINAL_SUMMARY:END -->
