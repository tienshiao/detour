---
id: TASK-337
title: >-
  Content blocking: a setting for the AdGuard URL Tracking list, so Detour does
  not fetch it when it is off
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T07:37:00Z'
labels:
  - links
  - content-blocker
  - settings
dependencies: []
references:
  - TASK-329
  - Detour/Browser/ContentBlocker/TrackingParameterList.swift
  - Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
  - wiki/features/copy-url.md
priority: low
type: feature
ordinal: 411000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-329. Since TASK-329 every launch contacts filters.adtidy.org to refresh the AdGuard URL Tracking filter used by Copy URL, Copy Link and Share…, and there is no way to turn it off or to see that it is there. TASK-329 left the Settings row out while TASK-328 was changing the Settings panes. The content blocker lists already have rows with switches in the Content Blocking pane; this list is app-wide and only affects copied links, not blocking.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Content Blocking pane shows the tracking-parameter list with a switch (on by default), its last update and its rule count, worded so it is clear it affects copied and shared links, not blocking
- [x] #2 With the switch off, Detour makes no request to the list's host (at launch, Update Now or Clear Cache) and Copy URL uses the built-in names only; turning it on fetches the list
- [x] #3 The setting is stored per data directory like the other content blocker settings; tests cover the off state and the fetch gate; checked at runtime with /verify
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TrackingParameterList owns the setting: isEnabled (defaults key ContentBlocker.adguard-url-tracking.enabled in the data directory's content blocker suite, on when absent) and setEnabled(_:). Off: stored, tickets taken so far superseded (a response in flight is dropped), install(nil) so Copy URL uses the built-in names only; the cached text and bookkeeping stay. On: turnedOn() installs the cached rules and fetches (conditional when there is a cache, in full when not).
2. Gate inside the list, so the tests reach it: loadAtLaunch reads nothing and fetches nothing while off; refresh returns .off without a request; clearCacheAndRedownload deletes the cache and bookkeeping but downloads only when on; installIfNewest refuses while off.
3. ContentBlockerManager: setTrackingParameterListEnabled(_:) (the test host only stores the flag), status posted after each list outcome so the pane follows.
4. Content Blocking pane: a 'Copied Links' section under the buttons with a SettingsSwitchRow (TASK-336 naming) and help saying it affects copied and shared links, not blocking, and a status line with the rule count and last update (a pure status-text function); identifiers for the switch, the status and the two buttons.
5. Tests: TrackingParameterListTests (off at launch: no request, nothing installed, cache kept; refresh and Clear Cache while off: no request; turning off uninstalls and drops an in-flight response; turning on uses the cache offline and fetches; default on); the status text; the pane's switch writes the setting. SettingsSwitchRowTests' sweep covers the new switch.
6. Runtime: docs/harness script with a local server logging requests via DETOUR_TRACKING_FILTER_URL: on at launch (request = control), off then Update All Now, relaunch, Clear Cache (no requests), on (request), Copy URL clean/built-in only at each step.
7. PROVISIONAL: keep the cache when off (turning on works offline); Clear Cache while off deletes it without downloading. Wiki copy-url.md, content-blocking.md, settings.md; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: TrackingParameterList.isEnabled (defaults key ContentBlocker.adguard-url-tracking.enabled in the data directory's content blocker suite, on when absent), setEnabled(_:) and turnedOn(). The gate is in the list (the manager's own gate is the test host's): loadAtLaunch reads and fetches nothing while off; refresh returns the new .off outcome without a request; clearCacheAndRedownload deletes the cache and bookkeeping and downloads only when on; turning off installs nil at once and supersedes every ticket so a response in flight is neither installed nor cached; turning on installs the cached rules then fetches (conditional with a cache, in full without). ContentBlockerManager.setTrackingParameterListEnabled (the test host only stores) and a status post after each list outcome. Settings > Content Blocking: a 'Copied Links' section under the buttons, SettingsSwitchRow 'Remove tracking parameters with the AdGuard URL Tracking filter' (identifier trackingParameterListEnabled, named per TASK-336), help saying it changes only copied and shared links and blocks nothing, a status line (rule count and last update / Not downloaded yet / Off: not downloaded or used). Identifiers on Update All Now and Clear Cache & Redownload for Accessibility-driven checks.
PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): turning the list off keeps its cached text and bookkeeping on disk but does not use them, so turning it on again works offline (and costs a 304); Clear Cache & Redownload while off deletes the cached text (as the button says) without downloading. Alternative: delete the cache when it is turned off (one line in setEnabled).
Tests: TrackingParameterListTests +9 (default on and stored, off at launch, refresh while off, Clear Cache while off, turning off, a response in flight when turned off, turning on offline with the cache, turning on without a cache, the status line); SettingsSwitchRowTests +1 (the pane's switch shows and writes the setting, named by its label; the TASK-336 sweep now counts it). Run: TrackingParameterListTests, SettingsSwitchRowTests, CopyURLTests, ContentBlockerTests, SettingsPaneColumnsTests, SettingsPaneHeightTests, SettingsGuideLinkTests: 106 tests, 0 failures.
Runtime (/verify, docs/harness/task337-tracking-list-setting-checks.py, Debug build, one isolated data directory over two launches, a local server logging requests via DETOUR_TRACKING_FILTER_URL, the switch and buttons pressed through Accessibility, Shift-Cmd-C read with pbpaste): 25/25 checks passed, twice (before and after the review fixes). On at launch: 1 request, cached, Copy URL drops the list's site parameters, switch named, status '32 rules, updated 3s ago'. Off: Copy URL keeps them (built-in names only); Update All Now: no request; cache kept. Relaunch while off: no request; switch off; cache on disk. Server 503, on: 1 request, cached rules in use again. Off, Clear Cache & Redownload: no request, cache deleted. On: 1 full request, cached again. Total 3 list requests, each from a step that should make one. Pane checked in light and dark (screenshots): the section sits under the buttons, help wraps, real list showed 2,665 rules.
Review (code-review medium --fix): stub's held reply now times out (applied); status line read 'Not downloaded yet' during the cache read after turning on (fixed: falls back to the recorded rule count); 'updated in 0s' when the fetch is a moment ahead of the clock (fixed, tested). Not changed: toggling on/off/on very fast can queue two turnedOn fetches (two requests, nothing wrong installed); the isEnabled check in installIfNewest duplicates the ticket gate on purpose; the test teardown stores the setting explicitly.

2026-11-14 user decision: keep the downloaded copy, unused, while the list is off (as built).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings > Content Blocking has a 'Copied Links' switch for the AdGuard URL Tracking list (on by default, stored in the data directory's content blocker defaults) with help saying it affects copied and shared links only and a status line with its rule count and last update. Off, TrackingParameterList fetches nothing at launch, on Update Now or on Clear Cache & Redownload, and Copy URL uses the built-in names only; a download in flight when it is turned off is dropped; turning it on uses the cache (offline too) and fetches. Proved at runtime with a local server's request log through DETOUR_TRACKING_FILTER_URL across two launches (25 checks; the 3 requests logged all came from steps that should make one). 10 new tests; 106 tests in the affected suites pass. PROVISIONAL: the cache is kept while off (turning on works offline); Clear Cache while off deletes it without downloading.
<!-- SECTION:FINAL_SUMMARY:END -->
