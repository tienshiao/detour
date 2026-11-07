---
type: Feature
title: Site search
description: "Keyword shortcuts in the command palette that search one site (TASK-287): typing a keyword then Tab or Space enters a mode with the site's name as a chip, Return opens the site's results URL; the app-wide list in the siteSearch table (migration v21, a starter set seeded once), its rules, and the Settings > Search pane that edits it."
tags: [command-palette, search, settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-07T10:30:00Z }
sources:
  - id: task-287
    resource: backlog:TASK-287
    title: "Command palette: site search (keyword shortcuts that search a specific site)"
  - id: task-288
    resource: backlog:TASK-288
    title: "Command palette: discover site searches from OpenSearch descriptions"
  - id: model
    resource: ../../Detour/Browser/SiteSearch/SiteSearch.swift
    title: SiteSearch.swift (the entry, URL building, siteSearchProblems, the starter set)
  - id: store
    resource: ../../Detour/Browser/SiteSearch/SiteSearchStore.swift
    title: SiteSearchStore.swift
  - id: palette
    resource: ../../Detour/Browser/CommandPalette/CommandPaletteView.swift
    title: CommandPaletteView.swift (MARK Site search)
  - id: pane
    resource: ../../Detour/Browser/Settings/SearchSettingsViewController.swift
    title: SearchSettingsViewController.swift (the pane and SiteSearchForm)
  - id: tests
    resource: ../../DetourTests/SiteSearchTests.swift
    title: SiteSearchTests.swift
  - id: palette-tests
    resource: ../../DetourTests/SiteSearchPaletteTests.swift
    title: SiteSearchPaletteTests.swift
---

# What it does

A site search is a name, a keyword and a URL template with `%s` where the
query goes (`YouTube`, `yt`, `https://www.youtube.com/results?search_query=%s`).
In the [command palette](./command-palette.md), typing the keyword and then
Tab or Space switches the field to searching that site: a chip with the
site's name sits before the field, the field is emptied for the query, and
Return opens the site's results page. A keyword is optional: as in Arc, Tab
also searches the site the field completes to (`you` → `youtube.com`), or
whose name you have started (`wiki`). This is Chrome's "Site search" (and
its trigger) with Arc's keyword-free entry, Safari's Quick Website Search
without the automatic part.

The list is **app-wide**, like [Link Routes](./link-routing.md): one list
for every profile, edited in Settings > Search. Each profile's default engine
stays in Settings > Profiles.[^task-287]

# How it works

## The entries and their rules

`SiteSearch` (`Browser/SiteSearch/SiteSearch.swift`) is the entry; the rules
are pure and tested in `SiteSearchRuleTests`:

- **URL building.** `url(for:)` replaces every `%s` with the query
  percent-encoded down to RFC 3986's unreserved characters, a space as `%20`.
  That works in a path (`/wiki/%s`) as well as a query (`?q=%s`): `&`, `=`,
  `+`, `/`, `?`, `#` and `%` in the query can never end a parameter or the
  path. `SearchEngine.searchURL` uses `.urlQueryAllowed`, which leaves `&`
  and `+` alone; site search does not share it.
- **Keyword matching** is the whole word, ignoring case (`matches(keyword:)`).
  `yt` matches `YT`, not `y`, `ytx` or `yt ` with a space.
- **What is refused** (`siteSearchProblems`, one `SiteSearchProblem` each):
  an empty name, a keyword with whitespace (the space after it is the
  trigger), a keyword another entry has (ignoring case; an entry is not its
  own duplicate; entries without a keyword never clash), a template that does not make an `http`/`https` URL
  with a host (`javascript:` and `ftp:` are refused), and one without `%s`.
  Fields are trimmed before they are checked and saved.
- **`displayHost`** is the template's host lowercased without `www.`, the
  form `SuggestionProvider.displayHost` gives history rows.

## Storage

`siteSearch` table, migration **v21**: `id`, `name`, `keyword`,
`urlTemplate`, `sortOrder`, no profile column. The migration also seeds
`SiteSearch.starterSet` (YouTube `yt`, Wikipedia `w`, GitHub `gh`, Google
Maps `maps`, Amazon `amz`, Reddit `r`), in SQL, so a later change to the
struct cannot change what the migration did. Google Maps uses
`maps.google.com`, not `www.google.com/maps`: host matching would otherwise
send Tab on a completed `google.com` to Maps. Seeding in the migration rather
than at launch is what makes a deleted starter entry stay deleted.

`SiteSearchStore.shared` caches the rows, writes every change through and
posts `didChangeNotification`. `add` and `update` refuse an entry with a
problem, so nothing that reaches the table breaks the rules.

## In the palette

The mode is `CommandPaletteView.activeSiteSearch`; the palette reads
`siteSearches` (the shared store, a test store in tests).

| Input | Result |
|---|---|
| The field becomes exactly `keyword` + one space (typed; it replaces a selected inline completion) | enters the mode |
| Tab when `siteSearchForTab` names an entry: the typed text is its keyword; else the field (the pending completion, or the typed text) is just its host, not a page on it (`github.com/t` completing to `github.com/tma/repo` accepts the completion); else, with no completion pending, two or more typed characters start its name or host | enters the mode, **before** the inline completion is accepted: `w` completing to `wikipedia.org` enters Wikipedia, as in Chrome; `you` completing to `youtube.com`, or `wiki` with no history, as in Arc. Keywords are optional |
| `siteSearchForTab` names an entry | a row "Search *name*" with a Tab badge goes right after the verbatim row (`PaletteRows.insertingSiteSearchHint`); choosing it (or clicking it, which gives the field focus back) enters the mode. The top hit and the verbatim row keep their places, so Return on `w` still submits `w`. Arrowing drops the inline completion the row may rest on, so while the user has moved the selection the row and Tab keep the offer the rows were built with (`siteSearchOffer`) |
| Return in the mode | the selected row (the search row, built from the store's current entry so an edit in Settings since the keystroke counts, or a history row arrowed to); with none selected, the site's results for the query; nothing for an empty query. Through `didSubmitSiteSearch(url)`, which every palette owner implements and loads as a search (not typed) |
| Backspace with the caret at the start of the query | leaves the mode with the text it was entered from (the keyword, or the host or name Tab took it from; plus a space and the query, if any) in the field, caret after that text. A keyword is then *declined*: a space typed after it is a space, so `w`, Backspace, ` foo` searches the default engine for "w foo". The decline ends when the field no longer starts with it |
| Escape in the mode | leaves it and clears the field; the next Escape dismisses. A prefilled palette (Cmd+L) still dismisses at once |
| Cmd+T over an open palette (`switchToCentered`) | leaves it |

Rows in the mode: `.siteSearch(name, query, url)` first and selected, then
the profile's history on the site (`SuggestionProvider.siteSearchHistory`:
`searchHistory` for the query, kept when the URL's host is `displayHost` or a
subdomain of it, at most 5), read on the palette's history queue like the
normal pass, then the default list as filler (the list is a fixed six rows,
TASK-184). No inline completion and no network suggestions in the mode:
both belong to the default engine. A Private window's palette has no history
scope, so it shows the search row and filler only; nothing about a site
search is recorded anywhere, and the visit itself follows the window's own
rules.

The chip (`SiteSearchChipView`) sits between the magnifying glass and the
field; the field's leading constraint swaps between the icon and the chip.
The placeholder becomes "Search *name*" and is put back on leaving.

## Settings > Search

`SearchSettingsViewController`, after Profiles in the toolbar. One bordered
list fills the pane (a list pane: `scrollsBodyAsWhole` false, minimum 400 pt)
with Name, Keyword and Address columns and a +, −, pencil bar. + and the
pencil (or a double-click) open `SiteSearchForm` in an `NSAlert` sheet: its
Save button is off while `store.problems(for:)` is non-empty, and the first
problem's sentence shows under the fields once the user has typed (a new
form does not open on "Enter a name."). `save()` goes through the store,
so the sheet cannot save what the store refuses. − removes the selected
entry without asking, as a link route's remove does. The list follows the
store's notification, so a change from anywhere shows at once.

# Decisions

- **Tab or Space**, Chrome's default, chosen with the user. The cost is that
  a short keyword takes the space after it (`w something` enters Wikipedia),
  which the decline after Backspace softens. Tab-only and Safari's
  row-only form were the alternatives.
- **Keywords optional, host and name matching** (the user, after comparing
  with Arc): Tab takes a keyword first, then the site the field is or
  completes to, then, with no completion, the start of a name or host.
  Space stays keyword-only, so typing a site's name and a space is still a
  search. Host-only matching (a never-visited site needs a keyword) and
  dropping keywords (pure Arc) were the alternatives.
- **App-wide**, not per profile (Chrome's is per profile): one list to set
  up, as with Link Routes.
- **Seeded once** in the migration.
- **OpenSearch discovery** is a separate task (TASK-288): with host
  matching, a discovered site takes Tab only when the field completes to
  that site, so discovered entries are to be active at once with no
  keyword (Arc), not listed inactive (Chrome) as first planned.[^task-288]

# Tests

- `SiteSearchRuleTests`: encoding in the path and query, every placeholder,
  UTF-8, the host, keyword matching, each problem, the starter set, where the
  keyword row goes.
- `SiteSearchStoreTests`: the starter set on a new database, a deleted
  starter entry staying deleted, write-through, refusals, notifications.
- `SiteSearchHistoryTests`: the site's pages and subdomains, not a lookalike
  host, nothing without a scope.
- `SiteSearchPaletteTests`: a real palette driven through its field editor:
  Space and Tab entry, Tab over an inline completion, words that are not a
  keyword, the keyword row, Backspace and Escape, the site's history rows, a
  Private palette.
- `SearchSettingsPaneTests`: the pane following the store, the form's
  refusals, add and edit.

# Related

- [Command palette](./command-palette.md)
- [Suggestion pipeline](./suggestion-pipeline.md)
- [Settings window](./settings.md)
- [Session database](../architecture/session-database.md)

[^task-287]: TASK-287, 2026-11-07.
[^task-288]: TASK-288, filed 2026-11-07.
