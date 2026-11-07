---
id: TASK-287
title: 'Command palette: site search (keyword shortcuts that search a specific site)'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T09:35:00Z'
updated_date: '2026-11-07T10:17:00Z'
labels:
  - command-palette
  - search
dependencies: []
references:
  - Detour/Browser/CommandPalette/CommandPaletteView.swift
  - Detour/Browser/CommandPalette/AddressInputClassifier.swift
  - Detour/Browser/CommandPalette/SuggestionProvider.swift
  - Detour/Browser/Profile.swift
  - Detour/Browser/Settings/ProfilesSettingsViewController.swift
  - wiki/features/command-palette.md
  - wiki/features/suggestion-pipeline.md
priority: medium
type: feature
ordinal: 334000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-07.

Today a search can only go to the profile's one search engine (`SearchEngine` in Profile.swift: six built-in engines, picked per profile in Settings > Profiles). Chrome ("Site search" under Search engines), Arc and Safari let you type a keyword such as `yt` or `gh`, then a query, and land on that site's own search results. That is faster than searching the web and clicking through, and it covers sites with good internal search (YouTube, GitHub, Wikipedia, Amazon, documentation sites).

Things to decide while planning (record the decisions in the task): how a site search is triggered in the palette (keyword + space or Tab, Chrome-style chip in the field), whether entries are global or per profile, which defaults ship, whether a site's OpenSearch description is picked up automatically, and how a site search interacts with inline URL completion and the "Go to"/"Search" rows.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Typing a configured keyword followed by the trigger in the command palette switches the palette into that site's search, shown visibly in the field, and Return opens the site's results URL with the query percent-encoded
- [x] #2 Tab also enters a site search without a keyword: when the field completes to (or is) the site's host, or, with no inline completion, when the typed text starts the site's name or host; a completion to a host with no site search keeps Tab's completion behaviour
- [x] #3 Backspace on an empty query leaves site-search mode and returns to normal input
- [x] #4 A keyword that is not configured, or one typed as part of a longer word, is treated as normal input (URL or default-engine search)
- [x] #5 Settings has a place to add, edit and remove site searches (name, optional keyword, URL template with a %s placeholder); invalid templates and duplicate keywords are refused
- [x] #6 Site searches persist across relaunch, and the Private profile's use of them records no history
- [x] #7 Tests cover keyword matching, URL building (encoding, %s placement), mode entry and exit, and storage
- [x] #8 The command-palette and suggestion-pipeline wiki pages describe the feature
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions (user, 2026-11-07): Tab or Space enters site-search mode when the field is exactly a keyword (Chrome); one app-wide list edited in a new Settings > Search pane; a starter set seeded once (YouTube yt, Wikipedia w, GitHub gh, Google Maps maps, Amazon amz, Reddit r). Not in scope: OpenSearch auto-discovery, site-specific network suggestions.

1. Model + rules (pure, tested): SiteSearch {id, name, keyword, urlTemplate, sortOrder}; keyword matching (case-insensitive, exact, whitespace-free); URL building (%s replaced by the query percent-encoded to unreserved chars, works in path or query); validation (http/https template with %s, non-empty name, keyword without whitespace, unique case-insensitively).
2. Storage: migration v21 adds siteSearch table and seeds the starter set; SiteSearchStore (cached, write-through, change notification) like LinkRouteStore.
3. Palette: mode state in CommandPaletteView (chip at the field's leading edge); Tab/Space on an exact keyword enters it; a hint row while the field is exactly a keyword; in mode the rows are the site row plus history matches on that site's host; Backspace on an empty query leaves the mode and restores the keyword; Escape leaves the mode; Return submits the site URL through a new required delegate method (window, Quick Detour launcher, Quick Detour window).
4. Settings > Search pane: list with name / keyword / URL, add and remove, refusals shown inline.
5. Tests: rules, store + migration, palette mode entry/exit/submit; wiki command-palette, suggestion-pipeline, settings; /verify in an isolated profile.

Revised 2026-11-07 (user: Arc works without a fixed keyword): keywords become optional. Tab picks a site by (1) the typed text being its keyword, else (2) the field's completed or typed host being the site's host, else (3) with no inline completion, the typed text (2+ characters) starting the site's name or host; a completion to a host with no site search still takes Tab as before. Space stays keyword-only. The keyword row appears for all three. Google Maps template moves to maps.google.com so it does not claim google.com.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation notes (2026-11-07):
- Model and rules in Detour/Browser/SiteSearch/SiteSearch.swift (SiteSearch, siteSearchProblems, siteSearchForTab, starterSet); SiteSearchStore (write-through, change notification); siteSearch table, migration v21 seeding the starter set once in SQL (frozen from now on: a new starter entry needs a new migration).
- Palette: CommandPaletteView MARK Site search (mode, chip, Space/Tab/Backspace/Escape/Return, hint row via PaletteRows.insertingSiteSearchHint, site history via SuggestionProvider.siteSearchHistory); new required delegate method didSubmitSiteSearch implemented by the browser window, the Quick Detour launcher and the Quick Detour window.
- Settings > Search: SearchSettingsViewController + SiteSearchForm (NSAlert sheet, Save off while the store would refuse; the problem text appears once the user types).
- Mid-task change (user): keywords optional and Arc-style matching for Tab (keyword, then the field host, then name/host prefix with no completion); Google Maps moved to maps.google.com so google.com stays a completion.
- Two /code-review --fix passes: 7 + 4 fixes (Space only when typed, de-duplicated rows, declined keyword scope, trimmed Tab check, chip accessibility label, page-vs-host in Tab matching, the offer kept while arrowing, field focus after clicking the row, store entry at Return).
- Accepted, not fixed: siteSearchHistory filters the top 30 history matches by host (a host filter belongs in the searchHistory SQL); Escape in a Cmd+L palette dismisses even in the mode (existing behaviour); a site deleted or renamed in Settings while its mode is open still searches/shows the old one until the mode is left; displayHost recomputed per keystroke (small at expected sizes).
Tests: 18 suites, 298 tests, 0 failures (SiteSearchRuleTests, SiteSearchStoreTests incl. the v20→v21 upgrade, SiteSearchHistoryTests, SiteSearchPaletteTests, SearchSettingsPaneTests, PaletteReturnKeyTests, PaletteSelectionTests, PaletteRowsTests, SuggestionProviderTests, AppDatabaseTests, LinkRouteStoreTests, CommandPaletteFocusTests, QuickDetourLauncherTests, PaletteTabScopeTests, SettingsPaneHeightTests, SettingsPaneColumnsTests, InPageLinkRoutingTests, QuickDetourTitleBarTests). Full suite not run.
Runtime (/verify, isolated DETOUR_DATA_DIR=DetourVerify287/287b via the launch guard, harness docs/harness/task287-harness.patch, reverted): starter set seeded; "you" completed to youtube.com with the Search YouTube row; Tab entered YouTube mode (chip shown); "cats" + Return loaded https://www.youtube.com/results?search_query=cats; "w " entered Wikipedia mode and Backspace left it with "w"; Settings > Search and its add sheet captured (light mode). Not checked at runtime: dark mode, VoiceOver, a real typed (HID) session. Defaults keys and data folders of both runs removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Site search in the command palette: type a site keyword then Tab or Space, or (Arc-style) Tab on the site the field completes to or whose name you have started, and the palette searches that site, with its name as a chip, its results URL on Return and your history on the site listed. One app-wide list, stored in a new siteSearch table seeded once with YouTube, Wikipedia, GitHub, Google Maps, Amazon and Reddit, and edited in a new Settings > Search pane whose add/edit sheet refuses what the store would. Verified by 298 tests in 18 suites and an in-app run; follow-ups: a host filter in the history SQL for site rows, OpenSearch discovery (TASK-288).
<!-- SECTION:FINAL_SUMMARY:END -->
