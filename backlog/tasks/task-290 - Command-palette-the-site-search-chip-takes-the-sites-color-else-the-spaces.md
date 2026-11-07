---
id: TASK-290
title: 'Command palette: the site-search chip takes the site''s color, else the space''s'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T10:25:00Z'
updated_date: '2026-11-07T10:37:00Z'
labels:
  - command-palette
  - search
  - ui
dependencies: []
priority: low
type: enhancement
ordinal: 337000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-287, asked by the user on 2026-11-07. The chip naming the site in site-search mode is the system accent color at 20% opacity for every site. Arc colors it per site (seemingly from the site's icon); the user wants that, and otherwise the color of the space the palette belongs to.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 In site-search mode the chip is filled with a color taken from the site's favicon when the profile has one recorded for the site and the icon has a clear dominant color
- [x] #2 Otherwise (no recorded icon, a grey or monochrome icon, a Private window, an icon still loading) the chip is the color of the palette's space; a palette with no space (Quick Detour) uses the accent color
- [x] #3 The chip's text stays readable on any fill (light or dark text chosen by contrast); a change of color on arrival is a short cross-fade, none with Reduce Motion
- [x] #4 No network request is made for a site the profile has not visited, and a Private window reads no history for it
- [x] #5 Tests cover the dominant-color rule (saturated, monochrome, transparent icons), the text-color choice and the fallback order; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. SiteColor (pure): dominant color from a downsampled icon (opaque, saturated pixels, hue buckets weighted by saturation, at least 10% of opaque pixels), text color by WCAG contrast. 2. SuggestionProvider.siteFaviconURL (profile-scoped history lookup for the template host, with and without www) on the palette history queue, then FaviconLoader. 3. Chip: solid fill, contrasting text; space color at once, site color when found, cross-fade unless Reduce Motion. 4. Tests + wiki site-search page.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: SiteColor (Detour/Browser/SiteSearch/SiteColor.swift) — dominant color from a 16×16 drawing (opaque, saturated pixels, 12 hue buckets centred on their hue, weighted by saturation, 10% share, averaged over the hue's saturated core so anti-aliased edges do not turn red pink); white text unless below 3:1 contrast. SiteSearchChipView: solid fill, space color at once (accent with no space), site color cross-faded in 0.3 s (no fade with Reduce Motion), text re-checked on appearance change. SuggestionProvider.siteFaviconURL(forHost:) reads the profile-scoped history (bare host, then www.) on the palette history queue; nothing for Private or unvisited sites. A generation drops stale lookups; a re-scoped palette resets the chip and looks the site up in the new scope.
/code-review --fix: 6 of 7 fixed (profile re-scope leak, red split across the 0° hue seam, stale cross-fade, text not re-checked on appearance change, duplicated host logic, missing lookup tests); not fixed: a second WCAG luminance formula next to NSColor.luminance (kept so SiteColor stays pure over RGB).
Tests: 16 suites, 170 tests, 0 failures (SiteColorTests, SiteSearchChipColorTests, SiteFaviconURLTests, the SiteSearch* suites, SearchSettingsPaneTests, palette suites, SuggestionProviderTests, CommandPaletteFocusTests, QuickDetourLauncherTests, PaletteTabScopeTests, FaviconLoaderTests).
Runtime (isolated DetourVerify290 and 290b, harness docs/harness/task290-harness.patch, reverted; before and after the review fixes): YouTube with its real favicon: the space blue (0.00 0.48 1.00) at once, then red (1.00 0.00 0.00), white text; GitHub never visited, dark mode: the space blue throughout, nothing fetched. Not checked at runtime: Reduce Motion, a space switch with the palette open (covered by a test).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The site-search chip is now filled with the site's own color, read from the favicon the profile has recorded for it (Arc-style), and otherwise with the space's color; text is white unless that would be hard to read. No icon is fetched for Private windows or sites the profile never visited. 170 tests in 16 suites pass; checked in the app with YouTube's real favicon and an unvisited GitHub in dark mode.
<!-- SECTION:FINAL_SUMMARY:END -->
