---
name: verify
description: Build, launch, and observe the Detour browser app for runtime verification of changes.
---

# Verifying Detour changes at runtime

The usual way: launch the build you made against an isolated data directory
with the **automation endpoint** on, and drive and observe it through
`scripts/detour-mcp`. That replaces pasting a harness into AppDelegate for
most checks. Detour stays in the background and the person's pointer never
moves, so you can do this while they work.

## 1. Build & launch (isolated profile, endpoint on)

```bash
xcodebuild -scheme Detour -configuration Debug build
APP="$(xcodebuild -scheme Detour -configuration Debug -showBuildSettings \
        | grep -m1 ' BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Detour.app"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/detour-verify.XXXXXX")"   # logs and screenshots
DETOUR_DATA_DIR=DetourVerify DETOUR_MCP=1 "$APP/Contents/MacOS/Detour" > "$OUT/app.log" 2>&1 &
export DETOUR_DATA_DIR=DetourVerify          # for scripts/detour-mcp below
```

- `DETOUR_MCP=1` turns the endpoint on **only** with an isolated
  `DETOUR_DATA_DIR`; never launch without `DETOUR_DATA_DIR` (a bare launch
  writes into the user's real profile). The endpoint writes
  `~/Library/Application Support/DetourVerify/mcp-endpoint.json` (URL, port,
  token) once it listens: wait for that file before calling it.
- Resolve `$APP` from the build settings, as above. **Never glob DerivedData
  for it** (`ls -d …/DerivedData/Detour-*/… | head -1`, or `ls -td`): a machine
  with several checkouts or worktrees has several `Detour-*` directories, and
  both forms have launched a weeks-old build. If you built with
  `-derivedDataPath` (a worktree, or Xcode has the project open), pass the
  same flag to `-showBuildSettings`. In a fresh worktree run
  `xcodegen generate` first.
- Before trusting what you observe, confirm the app is the build you just
  made: compare the modification time of `$APP/Contents/MacOS/Detour.debug.dylib`
  with your build. A stale build launches normally, runs none of your
  changes, and can rewrite the isolated profile.
- `DETOUR_DATA_DIR` (see `detourDataDirectory()` in Storage/Database.swift)
  redirects the databases and installed extension files to
  `~/Library/Application Support/<name>/`, scopes the profiles' WebKit data
  stores and the window autosave names to that name, and keeps Sparkle from
  starting. The rest of the `com.detourbrowser.mac` defaults domain is still
  shared with the installed app: delete your run's
  `NSWindow Frame BrowserWindow-<name>` and
  `NSSplitView Subview Frames BrowserSplitView-<name>` keys afterwards. Use a
  new name for a fresh start.
- **Never `tell application "Detour" to quit` or `pkill Detour`**: the user's
  production Detour (/Applications) is usually running. Stop yours by the
  `pid` in its `mcp-endpoint.json` (check the command path first), with
  SIGTERM, which also removes the endpoint file.
- Running the app, `log`, `screencapture` and loopback HTTP need the sandbox
  off.

## 2. Drive and observe it

```bash
scripts/detour-mcp tools                                   # what there is
scripts/detour-mcp call list_windows                       # window_id 1, its tab, app_active
scripts/detour-mcp call open_url window_id=1 url=http://127.0.0.1:8765/
scripts/detour-mcp call list_tabs window_id=1              # ids; tab_id is a page's context
scripts/detour-mcp call click context=<tab_id> selector='#link'            # trusted click in the page
scripts/detour-mcp call click context=<tab_id> selector='a' button=right   # its context menu
scripts/detour-mcp call list_menu                          # the open menu's items
scripts/detour-mcp call choose_menu_item title='Download Linked File'
scripts/detour-mcp call type_text context=<tab_id> selector='#field' text='hello'
scripts/detour-mcp call run_menu_item window_id=1 'path=["View","Toggle Sidebar"]'   # or key=cmd+s
scripts/detour-mcp call hit_test window_id=1 x=208 y=1076  # what a native click there would reach
scripts/detour-mcp call click window_id=1 x=208 y=1076     # a native control by window point
scripts/detour-mcp call screenshot window_id=1 save_to="$OUT/after.png" include_image=false
scripts/detour-mcp call set_appearance appearance=dark
scripts/detour-mcp call set_debug_override name=reduce_motion value=on   # Debug builds
```

- Points are in the window's content, top-left origin, in points (what
  `hit_test`, `click` and screenshots use). Selectors are CSS in the page's
  top document.
- Errors come back with a stable code (`selector_no_match`, `no_open_menu`,
  `unknown_tab`, …) and exit status 1; check them rather than retrying.
- `scripts/detour-mcp batch` runs JSON lines in one session; for anything
  longer, write a Python script that imports `scripts/detour-mcp`'s `Session`,
  as `docs/harness/task324-endpoint-checks.py` does (launch, fixture server,
  checks, cleanup, exit status).
- Many effects finish after the call returns (Next Space animates, a page
  loads, a download starts): poll the state (`list_windows`, `list_tabs`,
  the DB, a log line) instead of reading it once.
- **Screenshots:** the default `source app` draws inside Detour (no grant,
  works in the background) but cannot draw window-server glass: the sidebar
  comes out light in dark mode, and the command palette, find bar and toasts
  come out blank. `source=screen` gives the exact picture through
  ScreenCaptureKit when the shell's host has Screen Recording. Look at the
  PNG (Read it) before calling a visual check passed.
- **Logs:** `/usr/bin/log show --info --start "<time>" --predicate
  'processIdentifier == <pid> AND subsystem == "com.detourbrowser.mac"'` (the
  `pid` is in `mcp-endpoint.json`). A change worth checking at runtime can add
  a `.public` Logger line saying what happened (the download flight's start,
  end and catcher, for instance).

Full reference: `wiki/features/automation-endpoint.md` (every tool, how input
is delivered, the traps).

## 3. When the endpoint is not enough

Still a harness (`wiki/playbooks/debug-harness.md`) or the person:

- **Local event monitors** (`NSEvent.addLocalMonitorForEvents`) do not see
  the endpoint's input, which is handed to views directly. The window's
  web-click monitor also listens for `AutomationInput.didDeliverEventNotification`;
  others do not yet (Control-Tab's switcher, sidebar swipes, the hover
  card).
- Drags and drops (use a stub `NSDraggingInfo`), swipes, hover tracking
  areas, frame-by-frame animation, and anything in a window that is not a
  browser window (Settings: open it with `run_menu_item`, see it with
  `screencapture -l <window id>`).
- A locked screen: WebKit neither paints nor takes events. Check
  `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked` before a run;
  report blocked checks as not run.

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

## Other observation channels

- `CGWindowListCopyWindowInfo` (a small swiftc CLI) works without any TCC
  grant: window titles, bounds and numbers (to find a Settings or menu
  window for `screencapture -l`).
- `screencapture` returns black without Screen Recording for the shell's
  host; check with one capture before planning on pixels.
- CGEvent posting (HID-level clicks) needs Accessibility, brings Detour to
  the front and moves the person's pointer: use the endpoint's input tools
  instead.
- App stderr: redirect the launch to a file.

More recipes and traps are in `wiki/playbooks/runtime-verification.md` and
the playbooks it links.
