---
id: TASK-302
title: >-
  Link Routes: an app-only route is flagged invalid until its URL condition is
  switched to Any URL
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T08:41:00Z'
updated_date: '2026-11-08T19:42:00Z'
labels:
  - link-routes
  - ui
dependencies: []
references:
  - TASK-292.7
priority: low
ordinal: 363000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while checking the Quarantine guide page at runtime (TASK-292.7, v0.4.0): in Settings › Links, a new route starts with the URL condition "Domain is" and an empty pattern. Choosing an app in "From app" (to send, say, every link from Mail to Quarantine) still leaves the route flagged invalid, because the empty "Domain is" pattern counts as a broken condition. The user has to know to switch the URL condition to "Any URL". The Quarantine page currently tells people to do that. (A route needs at least one condition: LinkRoute.swift ~113-115; editor in LinksSettingsViewController.)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A route with an app chosen and an empty URL pattern is treated as app-only (any URL from that app), or the editor otherwise makes app-only routes possible without a hidden step (approach agreed with the user)
- [x] #2 A route with neither an app nor a URL pattern is still refused with a clear message
- [x] #3 LinkRoute validation tests cover app-only, URL-only and both
- [ ] #4 The website's Quarantine and Link Routes pages drop the Any URL workaround
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Validation (LinkRouteValidation): an empty/blank pattern with a source app is no problem (app-only); with no app it stays emptyPattern (Any URL + Any App stays noCondition); a non-empty invalid pattern stays invalid even with an app.
2. Matching: the resolver already treats an empty match as no URL condition (linkRoute(_:matches:)); add tests that prove it for every kind.
3. Editor: warning for emptyPattern names both fixes ('…, or choose an app.'); the pattern placeholder says 'Any URL from this app, or …' when an app is chosen (pure linkRoutePatternPlaceholder).
4. Storage: no migration (store keeps kind + empty pattern + app; round-trip test).
5. Tests: app-only / URL-only / both / neither in LinkRouteStoreTests, resolver and editor tests; runtime check of the Links pane; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: default approach confirmed: a route with an app chosen and an empty URL pattern is app-only (any URL from that app).

Implemented (Nov 8 2026, agent-links):
- LinkRouteValidation: emptyPattern only when the pattern is empty/blank AND there is no app; with an app the route is app-only. Any URL + Any App stays noCondition. A non-empty invalid pattern is still refused with an app.
- Matching needed no change: linkRoute(_:matches:) already read an empty match as 'no URL condition' (any http/https URL from that app); hasCondition already counted the app. New resolver tests prove it for each kind (and: other app, no sender, clicks, non-web URLs never match).
- Editor: the route row keeps 'Domain is' with the empty field (no auto-switch to Any URL, which would hide the field just as the user may be about to type a domain). The empty field's placeholder becomes 'Any URL from this app, or a domain such as example.com' (Contains: '…, or text in the address'; Is equal to: '…, or https://example.com/page'). The neither-warning now reads 'Enter a domain, such as example.com, or choose an app.' (per kind); Any URL + Any App still 'Choose a URL condition or an app.'
- Migration: none needed. Storage already round-trips (matchKind, matchPattern '', sourceApp). Before TASK-191.3 the store accepted app + empty pattern (hasCondition was true) and the resolver already treated it as app-only; since 191.3 the store refused saving one. So any stored row of that shape simply stops being flagged; behaviour of saved routes is unchanged.
- Accepted consequence (per the decision): emptying the field of a route with both an app and a domain widens it to every link from that app (saved, no warning).
- Tests: LinkRouteStoreTests, LinkRouteEditorTests, LinkRouteResolverTests: 104 tests, 0 failures (plus SettingsPaneColumnsTests 22/0 and ExternalLinkRoutingTests 20/0 in an earlier run of the same change).
- Runtime (/verify, harness kept out of the repo: scratch agent-links/Task302Harness.swift; DETOUR_DATA_DIR=DetourB8-302-1; real posted clicks and real pop-up menus): New Route -> draft warns 'Enter a domain, such as example.com, or choose an app. Not saved yet.'; choosing Finder in From app with nothing typed saved the route at once (store: 'Links from com.apple.finder'), no warning, placeholder 'Any URL from this app, or a domain such as example.com'; a second draft with Any App warned as above; switching it to Any URL warned 'Choose a URL condition or an app. Not saved yet.'; after relaunch the saved row showed Domain is / empty / Finder unchanged and the DB row is (domainIs, '', com.apple.finder). Captures in the scratchpad (out302/*.png). Cleaned: defaults keys NSWindow Frame/NSSplitView for DetourB8-302-1, the com.detourbrowser.mac.DetourB8-302-1 suite, App Support/DetourB8-302-1. WebKit stores under ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore created by that run were left (UUID-named).
- Website facts for AC #4 (not edited here): Settings › Links: to send every link from an app (e.g. Mail) somewhere, click New Route and choose the app in From app; leave the URL field empty — it then reads 'Any URL from this app, or a domain such as example.com'. No need to switch the URL condition to Any URL (it still exists and means the same). Typing a domain as well limits the route to that domain from that app. A route with no URL and no app is not saved: 'Enter a domain, such as example.com, or choose an app.' Drop the 'switch to Any URL' step from the Quarantine and Link Routes pages.
Website AC pending (held for release).

Website: updated Link Routes, Quarantine and Quick Detour (Any URL workaround removed: choose the app and leave the URL field empty; Link Routes quotes the placeholder and the neither-condition warning) on website branch next-release (128af13), held for the release

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).

Nov 8 2026 (user): re-capture the Link Routes still (it shows v0.4.0's 'Any URL' workaround for TextEdit) when website branch next-release ships with the release.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An app with an empty URL pattern is now an app-only route (user decision Nov 8 2026): validation no longer flags it, matching already read it as any web URL from that app (now tested per kind), and the Links pane says so in the empty field's placeholder ('Any URL from this app, or …'). A route with neither condition is still refused, with 'Enter a domain, such as example.com, or choose an app.' (or 'Choose a URL condition or an app.' for Any URL + Any App). No migration: storage round-trips the empty pattern; pre-191.3 rows of that shape just stop being flagged. Tests: Store/Editor/Resolver suites 104/0. Runtime: the Links pane drove New Route + From app Finder (saved immediately, no warning), the neither warnings, and a relaunch round-trip. Website AC #4 pending (facts in notes).
<!-- SECTION:FINAL_SUMMARY:END -->
