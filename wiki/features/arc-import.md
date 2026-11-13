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
  - id: planner
    resource: ../../Detour/Import/Arc/ArcImportPlanner.swift
    title: ArcImportPlanner.swift
  - id: apply
    resource: ../../Detour/Browser/TabStore+ArcImport.swift
    title: TabStore+ArcImport.swift
  - id: task-293-2
    resource: backlog:TASK-293.2
    title: "Import from Arc: turn a snapshot into Detour profiles, spaces, pinned entries, favourites and history"
  - id: window
    resource: ../../Detour/Import/Arc/ArcImportWindowController.swift
    title: ArcImportWindowController.swift
  - id: task-293-3
    resource: backlog:TASK-293.3
    title: "Import from Arc: File menu import window, first-run offer, and what is not imported"
  - id: offer-sheet
    resource: ../../Detour/Import/Arc/ArcImportOfferSheetController.swift
    title: ArcImportOfferSheetController.swift
  - id: task-293-5
    resource: backlog:TASK-293.5
    title: "Import from Arc: a launch offer that shows the user's own Arc setup"
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
| `User Data/Local State` | `profile.info_cache[<folder>].name`. A profile with `is_using_default_name: true` has Chromium's placeholder ("Person 1"), which is not shown: the default profile is called "Default", others by folder name. Arc's own hidden profile (`__ARC_SYSTEM_PROFILE`, "Profile 2" on the Mac checked; any name starting with `__`) is not listed. |
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

## Into Detour

`ArcImportPlanner.plan(_:options:existing:)` is pure: it sees Detour only as
`ArcImportExistingState` (normal profiles with their favourite URLs, normal
spaces with their folders, pinned URLs and tab URLs, and the `importLink`
rows) and returns an `ArcImportPlan`. `TabStore.applyArcImport` carries the
plan out; `TabStore.importArcHistory` then writes the history.

| Arc | Detour |
|---|---|
| Profile | A **new** profile named after it (user, 2026-11-12), `"<name> (Arc)"` when the name is taken, unless the window points it at an existing profile, or an earlier import's link names a profile that still exists. A new profile is made only when it receives a space or a favourite. |
| Space | The space an earlier import's link names (even renamed) **when it is in this import's target profile**, else a same-named space (case-insensitive) in the target profile, else a new space: Arc's title, emoji (`⭐️` for a symbol icon), colour (else a preset by position). |
| Folder | A same-named folder under the same parent in that space, else a new one; nesting kept to any depth. |
| Pinned tab | A dormant `PinnedEntry`, appended after the level's highest `sortOrder` (folders and entries share one order per level). |
| Split (pinned) | The first two panes become a pinned split (both entries consecutive, one `splitGroupID`), with Arc's width share for a two-pane split; further panes plain entries after it. If either of the first two is already pinned there, every pane comes in plain. |
| Today tab | A sleeping normal tab appended to the space's list, `lastDeselectedAt` = import time, so the profile's archive threshold counts from the import. A Today split's first two panes become a normal split when both are new, with Arc's width share for a two-pane split. A Today tab whose URL is pinned anywhere in the space is left out: an export lists top-level pinned tabs among the Today tabs, so without this an export imported after a direct import duplicated them (seen in the TASK-293.3 runtime check). |
| Favourite | A dormant `Favorite` on the target profile, after its existing ones. |
| History | The visits of the last `HistoryDatabase.visitRetention` (90 days), filed under the first imported space of that Arc profile, else the first space of its Detour profile, else not imported (`historyWithoutSpace`). |

Every new tile and tab shows the site's `/favicon.ico` guess until a page
reports its own icon.

### Re-importing

Dedupe is **by content only** (user, 2026-11-12): a pinned URL already in
the same folder of the matched space, a tab URL already in the space's list,
a favourite URL already on the profile, or a visit with the same URL, space
and time is left out; everything else comes in, including what the user
deleted since the last import. The only memory kept is the `importLink`
table (session database, migration v25): source (`arc`) + source key →
Detour profile or space id, written after the save, and only for spaces the save wrote (a space unit the database refused gets its link at a later import). A link to
something that no longer exists is ignored and replaced.

### Applying

`applyArcImport` first checks that every id the plan names is in the store
or in the plan (`.staleTarget` otherwise, nothing changed), then adds
profiles (each profile row is written as `addProfile` writes it: profiles are
not in the session snapshot), spaces, folders, entries, tabs and favourites
in one main-actor pass, assigning each space's `pinnedEntries` and `tabs`
once (each assignment reports to the extension contexts), notifies the
observers once per touched space, and calls `saveNow()` once. There is no
undo (user, 2026-11-12). `HistoryDatabase.importVisits` writes one profile's
visits in a single background transaction; `historyURL.title` changes only
when an imported visit is newer than the URL's last visit, so an old import
never renames a page Detour has seen since.

## The window and the offer

`ArcImportWindowController` (File › Import from Arc…) is view code over the
rules above: a source radio (Arc on this Mac, disabled and labelled "not
found" without Arc's data; an export file through an open panel), one row per
Arc profile with a checkbox and an "into" popup (a new profile named as the
planner will name it, or an existing profile; preselected to where an earlier
import went), its spaces as checkboxes with counts (`ArcImportText`), the
Bring switches (History disabled for an export, which has none), and the
not-imported note, the skipped-items note, and for an export the best-guess
note. Import plans against a fresh `arcImportExistingState()`; a profile
picked in a popup that was deleted since rebuilds the list instead of
importing elsewhere; `.staleTarget` says so and imports nothing. The result
view lists `ArcImportText.summary(of:)` and then each profile's history
result; the window cannot be closed while history is being written.

`ArcImportOffer` is due once, 1.5 s after launch, to anyone whose Mac has
`StorableSidebar.json` (user, 2026-11-12: new and current users), never in
the test host. It lives in the data directory's defaults suite
(`UserDefaultsScope.defaults`), so an isolated run never uses up the
production offer.

Since TASK-293.5 the offer is a custom sheet, `ArcImportOfferSheetController`,
not an `NSAlert` (user, 2026-11-13: for many people it is one of the first
things Detour shows). The launch reads Arc's sidebar first, in the
background, and then:

- unreadable: nothing is shown or marked; a later launch tries again;
- nothing worth offering (`ArcImportOffer.isWorthOffering`: no space with a
  tab and no favourite, e.g. an Arc installed and never set up): marked
  shown, nothing on screen;
- otherwise the sheet goes on the launch window (else any open normal
  window) and the offer is marked shown once it is up. Whatever the answer,
  it never comes back.

The sheet shows Arc's app icon (from its bundle id,
`company.thebrowser.Browser`; left out when the app is gone) → Detour's, the
user's spaces as chips in Arc's colours (`ArcImportOfferChipLayout`: two rows
at most, then "+N more"), totals (`ArcImportText.offerTotals`; Today tabs
not counted) and what stays in Arc, with the shutdown date until it passes.
**Import Everything** (the user's choice over opening the window) plans
`ArcImportOptions.everything` against a fresh state, so each Arc profile goes
where an earlier import sent it, else to a new profile; the sheet then shows
`ArcImportText.summary` with the history lines in a card and
`resultNotes` (left out, history with nowhere to go, a failed save) in small
print below, and Done waits for the history write. The window behind moves
to the first imported space **without selecting a tab**: the first runtime
pass selected a Today tab, which woke SoundCloud behind the sheet.
**Choose…** opens the import window; **Not Now** closes the sheet.

**Words.** What the code and this page call Today tabs, the window and the
sheet call **unpinned tabs** (user, 2026-11-13): Arc's own help centre
says Pinned Tabs and Unpinned Tabs ("the Unpinned Section", below the
sidebar's line), and "Today" was early Arc's label, now mostly in 2022–23
reviews; the user, an Arc user, did not know it. Links Arc's reader cannot
use say why they are left out ("aren't web pages, like arc:// pages"), not
"only Arc can open", which read as a Detour limitation.

## Runtime check (TASK-293.3)

Driven through System Events in an isolated profile (`DETOUR_DATA_DIR`),
against this Mac's Arc 1.172.1 data and a real export: the offer appeared,
its button opened the window, Import created 2 profiles, 2 spaces, 4 pinned
tabs in 2 folders (one nested), 3 favourites, 6 Today tabs (a split kept as a
split, width 0.5) and wrote 1,225 + 251 visits; the imported space rendered
in the sidebar with its tint, favourite tile, folder tree and split row. The
export, pointed at the profile the direct import made, added only what was
new. A second pass after the review fixes: declining the offer, then two
relaunches with no offer; Arc's system profile no longer listed (its real
name is `__ARC_SYSTEM_PROFILE`, no trailing `__`, so a "wrapped in `__`" rule
missed it); a Markdown file that is not an export shows "isn't in a format
Detour understands" with Import disabled; History disabled for an export; a
re-opened window preselects where the earlier import went. The window swaps
its content view between the form and the result (two stacks pinned to the
same container fought over the height), and the Bring label is the first
column of its grid so it keeps the first row's baseline. Traps met: a popup inside the window's scroll view is `pop up button 1
of scroll area 1 of window 1`, and while its menu is open System Events
cannot reach the window, so pick an item by typing its name and Return. The open panel is
out of process: after Choose…, wait about 3 s before Cmd-Shift-G and again
before typing the path, or the keystrokes go nowhere and the panel stays open.

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
real exports) cover reading; `ArcImportPlannerTests` the mapping rules;
`ArcImportTabStoreTests` the apply step in a real TabStore (relaunch,
re-import, a stale plan, the history write and its readers);
`ArcImportTextTests` the window's words, the offer rule, and the launch sheet's words, worth-offering rule and chip packing. Real Arc data
is never committed.

# Related

- [Profiles and spaces](../architecture/profiles-and-spaces.md) — what an Arc profile and space map onto.
- [History database](../architecture/history-database.md) — where imported visits go, per space.
- [Session database](../architecture/session-database.md) — the `importLink` table (v25).

[^task-293]: TASK-293
[^task-293-1]: TASK-293.1
