---
id: TASK-287
title: 'Command palette: site search (keyword shortcuts that search a specific site)'
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
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
- [ ] #1 Typing a configured keyword followed by the trigger in the command palette switches the palette into that site's search, shown visibly in the field, and Return opens the site's results URL with the query percent-encoded
- [ ] #2 Backspace on an empty query leaves site-search mode and returns to normal input
- [ ] #3 A keyword that is not configured, or one typed as part of a longer word, is treated as normal input (URL or default-engine search)
- [ ] #4 Settings has a place to add, edit and remove site searches (name, keyword, URL template with a %s placeholder); invalid templates and duplicate keywords are refused
- [ ] #5 Site searches persist across relaunch, and the Private profile's use of them records no history
- [ ] #6 Tests cover keyword matching, URL building (encoding, %s placement), mode entry and exit, and storage
- [ ] #7 The command-palette and suggestion-pipeline wiki pages describe the feature
<!-- AC:END -->
