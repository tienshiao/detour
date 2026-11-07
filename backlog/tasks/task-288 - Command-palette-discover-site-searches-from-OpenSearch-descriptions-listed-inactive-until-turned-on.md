---
id: TASK-288
title: >-
  Command palette: discover site searches from OpenSearch descriptions (active
  at once, no keyword)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T09:43:00Z'
updated_date: '2026-11-07T11:26:00Z'
labels:
  - command-palette
  - search
dependencies:
  - TASK-287
references:
  - wiki/features/command-palette.md
priority: low
type: feature
ordinal: 335000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-07 while TASK-287 (manual site search and Settings > Search) was being built; split out to keep that change reviewable.

Sites advertise their search through an OpenSearch description: a `<link rel="search" type="application/opensearchdescription+xml" href=…>` in the page head, pointing at an XML document whose `<Url type="text/html" template="…{searchTerms}…">` is the results URL. Chrome uses these to add site searches without the user typing a URL template. Decided with the user: discovered entries follow Chrome's current behaviour, listed in Settings > Search as inactive (keyword = the site's host) until the user turns them on, so no keyword starts taking Tab/Space by surprise.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Visiting a page in a normal profile whose head links an OpenSearch description adds a site search for that site with no keyword, named from the description, template converted from {searchTerms} to the site-search placeholder; it works at once through host matching (Tab when the palette completes to that site)
- [x] #2 Nothing is discovered or fetched from a Private window, Quick Detour quarantine or a non-http(s) page; a description is fetched at most once per site per launch, with a size and time limit
- [x] #3 A description whose template is not http(s), has no {searchTerms}, or points to another host than the page is ignored; a site already in the list (same host) is not added again, and one the user removed is not re-added
- [x] #4 Discovered entries are marked as discovered in Settings > Search and can be edited (given a keyword) or removed
- [x] #5 Tests cover parsing (valid, malformed, missing template), the add/skip rules and the Private refusal; the site-search wiki page describes discovery
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. OpenSearch parsing (pure, nonisolated): XMLParser with namespaces, external entities off; root OpenSearchDescription, its own GET <Url type=text/html rel=results> children, the first whose template converts; ShortName (whitespace collapsed, 64 chars; else the host) as the name. siteSearchTemplate(fromOpenSearch:): {searchTerms} -> %s, encodings -> UTF-8, {language} -> *, required count/startIndex/startPage -> 20/1/1, other optional params -> empty; unknown required params, no {searchTerms}, stray braces or an existing %s refused.
2. Rules (SiteSearchDiscovery): mayLook (not Private, not quarantined, the web view's URL http(s)); isSameSite (http(s), no credentials, same displayHost, no https->http downgrade, port not compared) for the description, its redirects and its template; the first same-site description link wins.
3. Storage: migration v22 adds siteSearch.isDiscovered and siteSearchRemovedHost. Every removal records the host (same transaction), and so does an edit that moves an entry to another host. addDiscovered refuses a listed or removed host; an edit that changes a field clears the mark.
4. Palette: an untouched discovered entry is left out of siteSearchForTab's prefix rule (rule 3).
5. SiteSearchDiscoverer (TabStore.siteSearchDiscoverer, set on the shared store): on a load's end, checks eligibility, listed/removed/attempted host and the 3-pages-per-site-per-launch cap before a lookup in the DetourSiteSearch content world; fetches with OpenSearchFetcher (ephemeral, cookieless, 10 s, 64 KB, same-site redirects; CappedDataFetcher moved from MediaArtworkLoader to Shared and given a redirect policy).
6. Settings > Search: 'From site' in the Keyword column with a tooltip; one sentence in the pane description.
7. Tests in SiteSearchDiscoveryTests.swift (+ a pane test); wiki site-search page, session-database page, log; /code-review --fix, /verify with a loopback site.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision changed 2026-11-07 (user): TASK-287 gained Arc-style host and name matching, so a discovered site only takes Tab when the field completes to that same site. Discovered entries are therefore active at once with no keyword (Arc), not listed inactive (Chrome) as first decided.

Decisions made while building (recorded in wiki/features/site-search.md > Decisions): the description and its template must be on the page's own host (subdomains are other hosts), so discovery never contacts or adds a third site; every removal is remembered, not only a discovered entry's (a deleted starter entry must not come back; removals before v22 were not recorded); an edit adopts the entry (the mark goes) and moving it to another host records the old host as removed; untouched discovered entries are left out of Tab's prefix matching; at most 3 pages per site per launch are asked for a link.
/code-review --fix: 7 findings. Fixed: unused import (by the review), edit moving an entry to another host now records the old host, first same-site link instead of first link, per-site page cap and corrected comment, marking/rules no longer duplicated between SiteSearchDiscovery.entry and the store. Not fixed: port ignored in isSameSite (intended: a site search names a host; documented), cancel handle unused (no caller cancels).
Targeted suites after the fixes: 105 tests, 0 failures (OpenSearchDescription, SiteSearchDiscoveryRule/Store, SiteSearchDiscoverer, OpenSearchFetcher, SiteSearchDiscoveryTab, SiteSearchRule/Store/Palette, SearchSettingsPane, MediaArtworkLoader).
/verify (docs/harness/task288-harness.patch, isolated DetourVerify288): loopback site added as 'Fixture Docs', no keyword, discovered; description fetched once (not for a second page); a Private window's page fetched nothing; second launch kept the entry and fetched nothing; Settings > Search shows 'From site' (first label 'Added from site' truncated, shortened). Not verified at runtime: Tab in the palette on a discovered entry (a loopback site has a port, which displayHost of the field keeps, so host matching cannot be shown on it; covered by siteSearchForTab unit tests and TASK-287's runtime check of keyword-less entries); a quarantine window (covered by the pure gate's tests).

Full suite (caffeinate, .derived): 3762 tests, 18 skipped, 2 failures (1 expected XCTExpectFailure in WaitUntilTests, 1 unexpected: ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction timed out waiting for WebKit's ITP purge). That suite run alone: 7/7 pass, so a full-run-only timing failure, unrelated to this change.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Pages that link an OpenSearch description now add their site as a site search, active at once with no keyword (Arc's way), reached by Tab when the field is or completes to that site.

What changed: OpenSearchDescription (XMLParser, no external entities; first GET text/html results template; {searchTerms} -> %s and the other parameters converted or refused); SiteSearchDiscovery rules (normal profile and http(s) only; the description, its redirects and its template on the page's own host, no downgrade); SiteSearchDiscoverer, called from TabStore when a load ends, which checks the host (listed, removed, fetched this launch, 3 pages asked) before a lookup in a private content world, then fetches with a cookieless 10 s / 64 KB session (CappedDataFetcher moved to Shared, given a redirect policy). Migration v22: siteSearch.isDiscovered and siteSearchRemovedHost; any removal, or an edit moving an entry to another host, keeps the site from being re-added. Untouched discovered entries are left out of Tab's prefix matching; an edit adopts them. Settings > Search shows 'From site' in the Keyword column.

Verification: 37 new tests plus a pane test; targeted suites 105/0; full suite 3762 with one unrelated full-run-only ITP timeout (passes alone). /verify in an isolated profile with a loopback site: added once, not refetched, nothing from a Private window, kept across relaunch, Settings marker visible. Not shown at runtime: Tab in the palette on a discovered entry (a loopback port defeats host matching; unit-tested) and a quarantine window (pure gate tested).

Risks / follow-ups: a site on a non-default port never host-matches in the palette (pre-existing: the field's host keeps the port, the entry's does not); removals made before v22 were not recorded, so a starter entry deleted earlier can be re-discovered once; there is no setting to turn discovery off.
<!-- SECTION:FINAL_SUMMARY:END -->
