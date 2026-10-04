---
type: Playbook
title: Runtime verification
description: How to build, launch and observe Detour in an isolated profile (the /verify skill), including how to be sure the app you launched is the build you just made.
tags: [playbook, verify, runtime, isolation]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:23:52Z }
sources:
  - id: verify-skill
    resource: ../../.claude/skills/verify/SKILL.md
    title: The /verify skill
  - id: claude-md
    resource: ../../CLAUDE.md
    title: CLAUDE.md ("Before committing a code change")
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (detourDataDirectory, session schema)
  - id: storage-scope
    resource: ../../Detour/Browser/WebKitStorageScope.swift
    title: WebKitStorageScope.swift
  - id: defaults-scope
    resource: ../../Detour/Browser/UserDefaultsScope.swift
    title: UserDefaultsScope.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift
  - id: history-db
    resource: ../../Detour/Storage/HistoryDatabase.swift
    title: HistoryDatabase.swift
  - id: notes-stale
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: Session notes on launching a stale DerivedData build
  - id: notes-harness
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on the runtime debug harness
  - id: notes-probes
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Session notes on hit-test and resize probes
  - id: notes-updates
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on verifying the extension update UI
---

`/verify` is the project's runtime check: build the Debug app, launch it
against a throwaway data directory, and observe what it does. The skill
file is [.claude/skills/verify/SKILL.md](../../.claude/skills/verify/SKILL.md);
[CLAUDE.md](../../CLAUDE.md) says when it is required. This page adds what
sessions learned on top of the skill, above all how not to launch the wrong
binary.

# When to use

Before committing any code change (policy in CLAUDE.md), and whenever a
change touches something tests cannot see: layout, hosting, focus,
animation. In that case the check must exercise the UI, not stop at "it
launches"; the tools for that are the [debug harness](./debug-harness.md)
and [in-process UI automation](./in-process-ui-automation.md).

# Steps

## 1. Build and resolve the product

```bash
xcodebuild -scheme Detour -configuration Debug build > "$OUT/build.log" 2>&1
APP="$(xcodebuild -scheme Detour -configuration Debug -showBuildSettings \
        | grep -m1 ' BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Detour.app"
```

Pass the same `-derivedDataPath` to both commands if you built into a
private directory ([build and test](./build-and-test.md)).

Never glob DerivedData for the app
(`ls -d ~/Library/Developer/Xcode/DerivedData/Detour-*/… | head -1`). A
machine that has had several checkouts or worktrees has several `Detour-*`
directories, the first one in glob order can hold a weeks-old build, and
sorting by directory mtime (`ls -td`) picked a stale one
too.[^notes-stale][^notes-harness] The skill file resolved the app that way
until 2026-10-04; the release and deploy scripts still do (see
[release and website](./release-and-website.md)).

## 2. Launch against an isolated data directory

```bash
# direct: stderr is yours
DETOUR_DATA_DIR=DetourVerify "$APP/Contents/MacOS/Detour" 2> "$OUT/stderr.log" &

# through Launch Services: no stderr, but -g keeps it from taking focus
open -n -g "$APP" --env DETOUR_DATA_DIR=DetourVerify --env DETOUR_VERIFY_DIR="$OUT"
```

`open` does not capture stderr, so a harness launched that way must append
to its own log file.[^notes-harness] `open -n -g` starts a new instance
without activating it.[^notes-probes]

Use a fresh directory name for a fresh profile (`DetourVerify121`, …)
rather than deleting an old one.

What `DETOUR_DATA_DIR=<name>` isolates:

| Thing | Isolated? | How |
|---|---|---|
| `browser.db`, `history.db`, installed extension files | yes | everything under `~/Library/Application Support/<name>/` (`detourDataDirectory()`) |
| Profile website data stores and extension controllers | yes | `WebKitStorageScope` derives a different WebKit identifier per data directory; the files still live in the shared `~/Library/WebKit/com.detourbrowser.mac/` |
| Window frame and split view autosave | yes | `UserDefaultsScope` suffixes the autosave names |
| Sparkle | not started | `AppDelegate.startsUpdater` is false outside the default directory; the launch logs `Sparkle updater not started` |
| The rest of the `com.detourbrowser.mac` defaults domain | **no** | e.g. `ExtensionConsoleLogPublic` is shared with the installed app |
| WebKit's default (non-identifier) website data store | **no** | keyed by bundle id |

Details: [persistence](../architecture/persistence.md),
[profile data removal](../architecture/profile-data-removal.md).

## 3. Confirm it is your build

Before trusting any observation:

- check the modification time of `Detour.debug.dylib` inside the app you
  launched against the time of your build;[^notes-stale]
- if a harness was supposed to run, look for its first log line.

A stale binary launches normally, runs no harness, and can rewrite the
isolated profile: an old build recreated the session's space, after which
seeded history visits (keyed by `spaceID`) listed as empty.[^notes-stale]
If a list comes back empty in an isolated profile, compare `space.id` in
`browser.db` with the `spaceID` of the seeded rows.

## 4. Seed state (optional)

Quit the app first; it overwrites the database on save. Schema via
`sqlite3 browser.db '.schema tab'`. Conventions, from the skill:

- normal tabs: `sortOrder` 0…n per space;
- pinned and favorite backing tabs: `tab.sortOrder` of -1 / -2, referenced
  by `pinnedTab.tabID` / `favorite.tabID`;
- a split: two adjacent rows sharing `splitGroupID` (in `tab` for a normal
  split, in `pinnedTab` for a pinned one);
- `space.selectedTabID` decides what launch selects, so seeding it drives
  `selectTab`, wake and hosting at startup with no input at all.

History is different: `history.db` has triggers that call the SQL function
`history_fold`, which only the app registers, so inserting titled visits
from the `sqlite3` command line fails. Seed history from a harness inside
the app. Visits whose space does not exist are deleted about five seconds
after launch (`TabStore.sweepHistoryOfDeletedSpaces`), so seed under a real
space.

Extensions: [seeding extensions](./seeding-extensions.md).

## 5. Observe

| Channel | Good for | Needs |
|---|---|---|
| Poll `browser.db` with `sqlite3` while the app runs | state transitions; saves are debounced, so a change shows up shortly after the mutation | nothing |
| `CGWindowListCopyWindowInfo` from a small `swiftc` tool | window titles and bounds (the title is the selected tab's page title) | nothing |
| A harness log file and in-app PNG captures | anything in-process | a [debug harness](./debug-harness.md) |
| stderr of a directly launched binary | `NSLog`, Auto Layout complaints | direct launch |
| Unified log | `Logger` output | [reading runtime logs](./reading-runtime-logs.md) |
| `screencapture`, Accessibility reads, posted `CGEvent`s | pixels, real external input | macOS privacy grants for the process that runs the shell; see [in-process UI automation](./in-process-ui-automation.md) |

## 6. Stop it

Find the process by its build path and kill that PID only:

```bash
pgrep -f "$APP/Contents/MacOS/Detour"
```

# Traps

- **Never `pkill Detour`, `killall Detour` or
  `tell application "Detour" to quit`.** An installed Detour from
  `/Applications` has the same name and may be someone's running browser.
- **`pgrep`, `ps`, `open` and `log show` may be blocked** when the agent's
  shell is sandboxed. Run those with the sandbox off; `open` may not be
  available to the agent at all, in which case launch the binary directly.
- **Wait loops.** A shell that blocks foreground `sleep` needs the whole
  "launch, wait, read the log, kill" sequence as one background command.
- **A locked screen** makes WebKit stop painting and drops posted events;
  check before every harness run
  ([in-process UI automation](./in-process-ui-automation.md)).
- **The isolated app is not the key application** when launched from a
  shell, so behaviour keyed on `NSApp.keyWindow` cannot be driven that
  way.[^notes-updates]
- **Write outputs to a directory you can read back later.** A sandboxed and
  an unsandboxed command can see different `$TMPDIR` values; use one
  absolute path for everything.

# Related

- [Build and test](./build-and-test.md) — build directories and the one-build-at-a-time rule.
- [Debug harness](./debug-harness.md) — driving the app from inside.
- [In-process UI automation](./in-process-ui-automation.md) — clicks, keys and captures without external input.
- [UI probes](./ui-probes.md) — hit-test maps and focus dumps.
- [Seeding extensions](./seeding-extensions.md) — an extension in an isolated profile.
- [Session database](../architecture/session-database.md) — the tables you seed.

[^notes-stale]: Session notes on launching a stale DerivedData build
[^notes-harness]: Session notes on the runtime debug harness
[^notes-probes]: Session notes on hit-test and resize probes
[^notes-updates]: Session notes on verifying the extension update UI
