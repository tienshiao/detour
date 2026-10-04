---
name: verify
description: Build, launch, and observe the Detour browser app for runtime verification of changes.
---

# Verifying Detour changes at runtime

## Build & launch (isolated profile)

```bash
xcodebuild -scheme Detour -configuration Debug build
APP="$(xcodebuild -scheme Detour -configuration Debug -showBuildSettings \
        | grep -m1 ' BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Detour.app"
DETOUR_DATA_DIR=DetourVerify "$APP/Contents/MacOS/Detour" &   # isolated data dir
```

Resolve `$APP` from the build settings, as above. **Never glob DerivedData for
it** (`ls -d …/DerivedData/Detour-*/… | head -1`, or `ls -td`): a machine with
several checkouts or worktrees has several `Detour-*` directories, and both
forms have launched a weeks-old build. If you built with `-derivedDataPath`
(a worktree, or Xcode has the project open), pass the same flag to
`-showBuildSettings`. In a fresh worktree run `xcodegen generate` first.

Before trusting what you observe, confirm the app is the build you just made:
compare the modification time of `$APP/Contents/MacOS/Detour.debug.dylib` with
your build. A stale build launches normally, runs none of your changes, and
can rewrite the isolated profile (an old build recreated the space, so seeded
history rows keyed by `spaceID` listed as empty).

`DETOUR_DATA_DIR` (see `detourDataDirectory()` in Storage/Database.swift) redirects
the databases and installed extension files to
`~/Library/Application Support/<name>/`, scopes the profiles' WebKit data stores
and the window autosave names to that name, and keeps Sparkle from starting —
the user's real profile is never touched. The rest of the `com.detourbrowser.mac`
defaults domain is still shared with the installed app. Use a new name for a
fresh start.

**Never `tell application "Detour" to quit` or `pkill Detour`** — the user's
production Detour (/Applications) is usually running. Match the path you
launched: `pgrep -f "$APP/Contents/MacOS/Detour"` and kill that PID only.

More recipes (harness, in-process input, log reading, traps) are in the wiki:
`wiki/playbooks/runtime-verification.md` and the playbooks it links.

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
