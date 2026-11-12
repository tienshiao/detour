---
type: Feature
title: Import from Arc
description: "What the Arc importer reads and how: Arc's own files on this Mac (StorableSidebar.json's live sidebar container, not its stale sync shadows; profile names from Local State; each profile's Chromium History, copied before reading) and the Markdown file Arc's Export Data writes (URLs only; a Favorites list that runs favourites, top-level pinned tabs and Today tabs together, and the shared-lead rule that splits it); the source-neutral snapshot both readers produce, source keys for re-imports, and what is skipped. Checked against Arc 1.172.1."
tags: [import, arc, storage, history]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-12T10:56:40Z }
stale_after: 2027-01-31T00:00:00Z
sources:
  - id: snapshot
    resource: ../../Detour/Import/Arc/ArcImportSnapshot.swift
    title: ArcImportSnapshot.swift
  - id: sidebar-reader
    resource: ../../Detour/Import/Arc/ArcSidebarReader.swift
    title: ArcSidebarReader.swift
  - id: history-reader
    resource: ../../Detour/Import/Arc/ArcHistoryReader.swift
    title: ArcHistoryReader.swift
  - id: export-reader
    resource: ../../Detour/Import/Arc/ArcExportReader.swift
    title: ArcExportReader.swift
  - id: task-293
    resource: backlog:TASK-293
    title: Import from Arc (epic, with the format survey and Arc's sunset dates)
  - id: task-293-1
    resource: backlog:TASK-293.1
    title: "Import from Arc: read Arc's files and the Arc Data Export file"
---

Arc stops working on 2026-12-22.[^task-293] Detour imports from it in two
ways: straight from Arc's files on this Mac, which knows everything but only
works while those files exist, and from the Markdown file Arc's
**Settings › Advanced › Export Data** writes, which survives the shutdown but
carries only links. Both readers produce one `ArcImportSnapshot`, so the
mapping into Detour and the import window never care which source it was.

Everything below was checked against Arc 1.172.1 (build 90370) on one Mac
with four Arc profiles, a split view and two real exports.[^task-293-1]

# What it does

| | Direct (Arc on this Mac) | Export file |
|---|---|---|
| Reader | `ArcSidebarReader.read(dataDirectory:)` | `ArcExportReader.read(file:)` |
| Profiles | Every Arc profile, named from Local State | One stand-in profile, `.export`, named "Arc" |
| Spaces | Title, emoji, theme colour, profile | Title only |
| Pinned tabs and folders | Exact, any depth, with titles | Folders only (`##`, `###`); top-level pinned tabs are indistinguishable from Today tabs |
| Split views | `ArcSplit` with every pane and the first pane's width share | Flattened into the Favorites list |
| Favourites | Exact, per profile | Inferred (the shared-lead rule) |
| Today (unpinned) tabs | Exact | What is left of each Favorites list |
| History | Last N days per profile (`ArcHistoryReader`) | None |
| Titles | The user's rename, else the saved page title, else the host | The host (`[title](url)` is read if present) |

# How it works

## Arc's data folder

`~/Library/Application Support/Arc/`:

| File | What the importer takes from it |
|---|---|
| `StorableSidebar.json` | Spaces, items, favourites. |
| `User Data/Local State` | `profile.info_cache[<folder>].name`. A profile with `is_using_default_name: true` has Chromium's placeholder ("Person 1"), which is not shown: the default profile is called "Default", others by folder name. |
| `User Data/<Default \| Profile N>/History` | Browsing history (Chromium). |
| `StorableArchive*.json`, `StorableArchiveItems.json` | Not read: archived tabs. |
| `StorableSidebar.<date>.json` | Not read: Arc's own dated backups. |

## StorableSidebar.json

Top level: `version` (1), `sidebar`, `firebaseSyncState`, `sidebarSyncState`.
**Only `sidebar.containers` is live.** The two sync blocks are shadows of
Arc's old Firebase and CloudKit sync; on the Mac checked, `sidebarSyncState`
was last synced in November 2024 and shared only 12 of its 57 items with the
live sidebar's 24. Reading them would import long-gone tabs.

`sidebar.containers` is `[{global: {}}, {spaces, items, topAppsContainerIDs}]`;
the reader takes the first container that has `spaces` and `items`. All three
are Swift-encoded ordered maps: one flat array alternating key and value
(`[id, object, id, object, …]`), read by `ArcSidebarReader.orderedMap`.

**Space** (`spaces` values):

| Field | Meaning |
|---|---|
| `id`, `title` | `title` is absent on the space Arc creates for every user (`thebrowser.company.defaultPersonalSpaceID`); the reader calls it "Personal". |
| `profile` | `{default: true}` or `{custom: {_0: {directoryBasename: "Profile 1", machineID}}}`. |
| `containerIDs` | `["unpinned", <item id>, "pinned", <item id>]`. `newContainerIDs` says the same with tagged keys (`{"pinned": {}}`); read only when the plain form is missing. |
| `customInfo.iconType` | `{emoji_v2: "🏠", emoji: <code point>}`, or `{icon: <symbol name>}` (no emoji). |
| `customInfo.windowTheme.primaryColorPalette` | `shaded`, `midTone`, `tintedLight`, `shadedDark`, each `{red, green, blue, alpha, colorSpace: "extendedSRGB"}`. The reader uses `shaded` (else `midTone`), clamped to 0…1, as `RRGGBB`. |

**Item** (`items` values): `id`, `parentID`, `childrenIds` (order),
`title` (the user's rename, else null), `createdAt` (seconds since 2001),
and `data`, keyed by kind:

| `data` key | Is | Children |
|---|---|---|
| `tab` | `savedURL`, `savedTitle`, `timeLastActiveAt`, `savedMuteStatus`, … | none |
| `list` | A folder; folders nest | tabs, folders, splits |
| `splitView` | A split: `itemWidthFactors` (ordered map pane id → width share, 0.5 when untouched), `layoutOrientation`, `focusItemID` | its panes, as tab items |
| `itemContainer` | `containerType: {spaceItems: {_0: <space id>}}` (a space's pinned or unpinned root) or `{topApps: {_0: <profile>}}` (a profile's favourites) | the root's items |
| `welcomeToArc` | Onboarding; dropped silently | |
| anything else (`easel`, `arcDocument`, …) | Reported as `ArcSkippedItem(.unsupportedKind)` | |

`topAppsContainerIDs` pairs each profile with its favourites container. A
tab whose URL is not http(s) with a host (`arc://`, `chrome://`,
`chrome-extension://`, `file:`) is reported as `.unusableURL`, not dropped.
The tree walk keeps a visited set and stops at depth 64, so a cyclic
`childrenIds` chain ends.

## History

Chromium history schema version 70: `urls(id, url, title, visit_count,
typed_count, last_visit_time, hidden)` and `visits(id, url → urls.id,
visit_time, transition, …)`. Times are **microseconds since 1601-01-01 UTC**
(`ArcHistoryReader.unixTime(chromiumMicroseconds:)`). Titles exist only per
URL. `ArcHistoryReader`:

- copies `History` (and any `-journal` / `-wal` beside it) into a temporary
  folder and opens the copy read-only. Copying works while Arc runs; the
  import never opens or locks Arc's own file.
- returns visits newer than a cutoff, oldest first, skipping `hidden` URLs,
  subframe transitions (core type 3 and 4, the low byte of `transition`) and
  non-web URLs; `isTyped` is core type 1.

The cutoff matters: Detour keeps 90 days of history (`expireOldVisits`), and
the Mac checked had 142,000 visits in its default profile going back six
years.[^task-293-1]

## Arc Data Export.md

```
# <space title>

## Favorites
- <url>
- <url>

## <folder title>
- <url>

### <folder inside that folder>
- <url>
```

Measured against the live sidebar it came from:[^task-293-1]

- one `#` section per space, in sidebar order; only URLs, `arc://` ones
  included, no titles, profiles, ids or split views;
- **`## Favorites` runs three lists together with nothing between them**: the
  space's profile's favourites, then the space's top-level pinned tabs, then
  its Today tabs (a split view's panes flattened in place);
- each pinned folder is a `##` section after Favorites, its links first and
  then a `###` section per folder inside it.

### The shared-lead rule

The export cannot say which Favorites links are favourites. The rule (user,
2026-11-12): **a run of links that opens the Favorites list of two or more
spaces, in the same order, is favourites**; the rest of each list becomes
that space's Today tabs. With a single space nothing is a favourite.
`ArcExportReader.sharedLeadLength(at:in:)` computes it.

Known misses, both seen on the real export: a favourite of a profile with
only one space becomes a Today tab, and so does every top-level pinned tab.
The import window has to say favourites from an export are a best guess.

### Lenient parsing

Beyond what Arc was seen to write, `ArcExportReader` also accepts `*` and `+`
bullets, `[title](url)` and `<url>` links, deeper headings (each nests under
the nearest shallower one) and a non-link bullet as a folder for the bullets
indented below it.

## Source keys

Every space, folder and tab in the snapshot has a `sourceKey`, stable across
reads of the same data, so a second import can recognise what it brought
over before:

| Source | Key |
|---|---|
| Direct | `space:<Arc id>`, `item:<Arc id>`, `profile:default` / `profile:dir:<folder>` |
| Export | `export:space:<title>`, then the folder path and URL below it (`export:space:Home/pinned/News/<url>`, `…/today/<url>`), `export:favorite:<url>`; a repeated link in the same place gets `#2`, `#3` |

Export keys change when a space or folder is renamed in Arc; direct keys
never do.

# Edge cases

- No `StorableSidebar.json` → `ArcImportError.arcNotFound`; unreadable →
  `.unreadable`; not JSON or no sidebar container → `.unrecognizedFormat`.
  An export with no `#` heading is `.unrecognizedFormat`.
- A profile with no space and no favourite is still listed (from Local
  State): its history can come over.
- A split whose panes are all missing or unusable disappears; one usable
  pane becomes a plain tab.

# Tests

`ArcSidebarReaderTests` (synthetic `StorableSidebar.json`, Local State and a
GRDB-built History) and `ArcExportReaderTests` (fixtures in the shape of the
real exports). Real Arc data is never committed.

# Related

- [Profiles and spaces](../architecture/profiles-and-spaces.md) — what an Arc profile and space map onto.
- [History database](../architecture/history-database.md) — where imported visits go, per space.

[^task-293]: TASK-293
[^task-293-1]: TASK-293.1
