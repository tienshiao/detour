---
id: TASK-186.5
title: 'Dev mode: turn dev mode on or off per site from the address bar popover'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:19'
updated_date: '2026-10-24 18:53'
labels:
  - dev-mode
  - feature
dependencies:
  - TASK-186.1
  - TASK-187
parent_task_id: TASK-186
priority: medium
ordinal: 213000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24. Dev mode must be toggleable for any site, not only local development URLs; Arc remembers the choice per domain.

**Toggle.** Add a Dev Mode switch to the popover the faux address bar's button opens (`SettingsPopoverViewController`; today: Content Blocking with "Block content on this site", then Extensions — screenshot docs/dev-mode/site-popover-today.png). Proposed: a "Dev mode for this site" row under Content Blocking.

**Storage.** Follow content blocking, which is tracked per site already: `ContentBlockerWhitelist` keeps a per-profile host set in the session DB table `contentBlockerWhitelist(profileID, host)`, lowercased, and a stored host also covers its subdomains. Dev mode needs an override in **both** directions (on for a normal site, off for a local URL that is on by default), so a per-profile table of `(profileID, siteKey, enabled)`; the effective state is the override, else `isLocalDevelopmentURL` (TASK-186.1). Test-first: the rule, the store, and the migration.

**Decide and record:** the site key (proposed: host plus a non-default port, so two local apps on different ports are separate; the host alone for normal sites) and whether a stored site covers its subdomains (content blocking: yes; proposed for dev mode: exact only); whether Private windows keep overrides (content blocking's behaviour there is the reference).

**Icon.** The popover is now per-site settings, not only extensions: the button's `puzzlepiece.extension` symbol (and its "Settings" accessibility label) should change, e.g. `slider.horizontal.3` or `switch.2`; pick one and check it next to the link button at runtime.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The address bar popover has a dev-mode switch for the current site that turns dev mode on for any site and off for a local one
- [x] #2 The choice persists per profile and per site key, and the sidebar row and toolbar follow it immediately
- [x] #3 Effective-state rule, store and migration are covered by tests written first
- [x] #4 The popover button's icon and accessibility label are updated and checked at runtime
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 (user): store dev mode in the shared per-site settings table (TASK-187, setting devMode) instead of a table of its own; content blocking moves there too.

From TASK-187's review (2026-10-24): SiteSettingsStore persists every profile's rows, the Private profile's included (content blocking always did: the Private profile row is saved under its fixed id). ExternalAppPermissionStore by contrast keeps Private decisions in memory only. Decide here whether this setting's choice made in a Private window should outlive the session.

Decisions (user, 2026-10-24): Private: a dev-mode choice made in a Private window is kept in memory only (SiteSetting.persistsInPrivate = false), as for picture in picture (TASK-188). Proposed and taken: site key = host plus a non-default port, exact match (no subdomain coverage); stored in the siteSetting table (TASK-187) as a devMode setting with overrides in both directions; popover icon slider.horizontal.3.

Implementation (2026-10-24, Opus subagent): SiteSetting.devMode in the siteSetting table (no migration: setting is stored as text). Site key = devModeSiteKey(for:) (host + non-default port, http/https only; scheme not part of the key; nil for detour:/file:/extension pages, which disables the switch). Exact match for devMode; contentBlocking/pictureInPicture keep host-and-parent matching. Effective state = override ?? isLocalDevelopmentURL, per space profile. The switch stores an override only when it differs from the default and otherwise clears the row. SiteSettingsStore posts didChangeNotification on a change; each window's sidebar re-marks visible rows and favourite tiles. Store label renamed forHost: -> forSite:. Popover button: slider.horizontal.3, label 'Site Settings'. AC2 'toolbar follows it': the toolbar arrives in TASK-186.2 and reads the same DevMode.isActive rule.

TDD: red step with empty stubs failed 12 of 15 DevModeSiteOverrideTests (the 3 that passed are guards an empty stub satisfies) and 10 DevModeTests assertions.

/code-review --fix: 9 findings, 5 fixed: the active page's favourites bar kept the old profile after the space's profile changed; the toggle now writes to the profile the popover opened with; a misplaced doc comment; profileID hoisted out of the applyState loops; set() posts only when the value changes. Skipped: the unused isActive(for: BrowserTab) overload (uses owningProfile), an exact-match dictionary lookup for devMode (lists are tiny), duplicated split-pane marking in the view controller (refactor), tiles rebuilding their Combine sink on refresh (cheap, rare).

Tests after review: 243/243 pass (DevModeSiteOverrideTests 15, DevModeTests 31, SiteSettingsStoreTests 10, AutomaticPictureInPictureTests 11, ContentBlockerWhitelistTests 19, SidebarLayoutTests 41, SplitTabTests 63, FavoriteTileBadgeTests 9, TabStoreTests 40, FavoriteFaviconTests 4).

Runtime (docs/harness/task186-5-harness.patch, run before and again after the review fixes, both clean): two windows on one space plus a Private window. ON for a non-local site (kubernetes.docker.internal:8865) wrote one row, and both windows' rows gained the border and host line in the same run-loop turn; OFF for localhost:8865 wrote a false row and both windows' rows lost the marking; switching each back to the default removed its row (db empty); a Private window's ON marked its row with 0 rows written and window 1 unaffected. Popover and new button captured in light and dark. Not verified at runtime: a favourite tile, a pinned row, a split half or a second page of the same profile following the switch (same refresh path; covered only by code).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Per-site dev-mode switch in the address bar popover: the devMode site setting (host + non-default port, exact match) overrides the local-URL rule in both directions, per profile, memory-only in Private windows; sidebar rows and favourite tiles in every window follow at once; the popover button is now slider.horizontal.3 'Site Settings'. 243 tests pass; runtime harness clean before and after review.
<!-- SECTION:FINAL_SUMMARY:END -->
