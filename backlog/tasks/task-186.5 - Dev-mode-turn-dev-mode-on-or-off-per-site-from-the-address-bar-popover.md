---
id: TASK-186.5
title: 'Dev mode: turn dev mode on or off per site from the address bar popover'
status: To Do
assignee: []
created_date: '2026-10-24 09:19'
updated_date: '2026-10-24 09:21'
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
- [ ] #1 The address bar popover has a dev-mode switch for the current site that turns dev mode on for any site and off for a local one
- [ ] #2 The choice persists per profile and per site key, and the sidebar row and toolbar follow it immediately
- [ ] #3 Effective-state rule, store and migration are covered by tests written first
- [ ] #4 The popover button's icon and accessibility label are updated and checked at runtime
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 (user): store dev mode in the shared per-site settings table (TASK-187, setting devMode) instead of a table of its own; content blocking moves there too.
<!-- SECTION:NOTES:END -->
