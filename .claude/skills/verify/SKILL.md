---
name: verify
description: Build, launch, and observe the Detour browser app for runtime verification of changes.
---

# Verifying Detour changes at runtime

## Build & launch (isolated profile)

```bash
xcodebuild -scheme Detour -configuration Debug build
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Detour-*/Build/Products/Debug/Detour.app | head -1)
DETOUR_DATA_DIR=DetourVerify "$APP/Contents/MacOS/Detour" &   # isolated data dir
```

`DETOUR_DATA_DIR` (see `detourDataDirectory()` in Storage/Database.swift) redirects
all state to `~/Library/Application Support/<name>/` — the user's real profile is
never touched. Delete that dir for a fresh start.

**Never `tell application "Detour" to quit` or `pkill Detour`** — the user's
production Detour (/Applications) is usually running. Match the DerivedData path:
`ps aux | grep "DerivedData.*Detour.app"` and kill that PID only.

## Seeding state via sqlite3

The session DB is `browser.db` in the data dir; schema via `.schema tab` /
`.schema pinnedTab`. Quit the app before seeding (it overwrites on save).
Useful conventions:
- normal tabs: `sortOrder` 0..n per space
- pinned/favorite backing tabs: `tab.sortOrder = -1` / `-2`, referenced by
  `pinnedTab.tabID` / `favorite.tabID`
- splits: two adjacent rows sharing `splitGroupID` (tab table for normal splits,
  pinnedTab for pinned splits)
- `space.selectedTabID` controls what launch selects — seeding it exercises
  selectTab → wake → hosting at startup with zero input.

The app schedules debounced saves on mutations, so you can poll the DB with
sqlite3 WHILE the app runs to observe state transitions (e.g. a dormant pinned
entry gaining a `tabID` proves the activation path ran).

## Observation channels (and permission gotchas)

- `CGWindowListCopyWindowInfo` (see scratchpad helper pattern: a small swiftc
  CLI) works WITHOUT any TCC grant — window titles/bounds are good observables
  (title = selected tab's page title).
- `screencapture` and AX reads (`System Events` windows) return black/empty
  without Screen Recording / Accessibility grants for the shell host — check
  with a full-screen capture (all black = no grant) before planning on pixels.
- CGEvent posting (synthetic clicks/drags) is silently dropped without the
  Accessibility grant. Verify efficacy first with a click whose effect is
  DB-observable before trusting a scripted drag.
- App stderr: redirect the launch to a file; unified log via
  `log show --process Detour` for Logger output.
