---
type: Feature
title: "Automation endpoint: capture staging"
description: The automation endpoint's test-run tools for website captures (TASK-228.3), covering seed_world and its fixture format, list_displays and set_window_frame with exact placement read back from the window server, open_ui for Debug UI on demand, the test-run guard on Arc's folder, and the traps met (a window's open animation, who takes the focus, the connected-agent capsule, dev-mode pages).
tags: [automation, mcp, capture, website]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: task-228-3
    resource: backlog:TASK-228.3
    title: "Automation: capture tooling on the MCP endpoint"
  - id: staging
    resource: ../../Detour/Automation/AutomationTools+Staging.swift
    title: AutomationTools+Staging.swift and AutomationWorldFixture.swift (seed_world, displays, placement, open_ui)
  - id: capture-kit
    resource: ../../docs/capture/README.md
    title: docs/capture (the website capture kit, capture.py, demo-world.json)
  - id: tests
    resource: ../../DetourTests/AutomationStagingTests.swift
    title: AutomationStagingTests
---

What TASK-228.3 adds to the [automation endpoint](./automation-endpoint.md)
so a release's website media is one script (`docs/capture/capture.py`,
[capture kit](../../docs/capture/README.md)) instead of a harness pasted
into AppDelegate (DemoStage, now retired).[^task-228-3][^staging][^capture-kit]
The virtual display, the wallpaper, screencapture and the encoder stay
outside the app. Once a client has seeded a world or placed a window in a
run, the [agent pointer](./automation-endpoint-agent-pointer.md) (off in a
test run until turned on; the capture kit turns it on) glides in 600 ms
instead of 150, so a recording can follow it.

# Seeding a world

`seed_world {fixture_path}` (test runs only) reads a JSON file, checks all
of it, and only then changes the store, so a malformed fixture changes
nothing; every error is `invalid_fixture` naming the field
(`spaces[1].pinned[2].url`, in `details.path`), and unknown fields are
refused so a misspelling fails. Only into an empty data directory: one
profile, one space, nothing pinned, no favourites, no tab with a page (a
fresh window's blank New Tab is allowed), no Link Routes or changed
Default, no history visits; anything else is `not_empty` with the list in
`error.details`. Fixtures are read as regular files with a bounded read.
The format (version 1, `docs/capture/demo-world.json` is the full example):

```json
{"version": 1,
 "profiles": [{"name": "Work", "favorites": [{"url": "https://slack.com/", "title": "Slack"}]}],
 "spaces": [{"name": "Work", "emoji": "🍊", "color": "FF7600", "profile": "Work",
   "pinned": [{"url": "…", "title": "…", "favicon_url": "…"},
              {"folder": "Design", "collapsed": false, "items": [ …pages, folders, splits… ]},
              {"split": [{"url": "…"}, {"url": "…"}], "fraction": 0.5}],
   "tabs": [{"url": "…", "title": "…", "selected": true}, {"split": [ …two pages… ]}]}],
 "history": [{"url": "…", "title": "…", "space": "Work", "ago": ["2h", "3d", 600], "typed": false}],
 "link_routes": [{"match": "domain_is", "pattern": "github.com", "target": "space:Work"},
                 {"source_app": "com.apple.TextEdit", "target": "quarantine"}],
 "active_space": "Work"}
```

- Profiles and spaces are named, and named once each (case-insensitive);
  spaces, history and routes refer to them by name. The first profile is the
  data directory's existing one, renamed (a profile with spaces is never
  deleted, and a new one would leave the default behind); the existing
  space is deleted after the new ones exist, and the undo stack is cleared.
- Pages are http(s) with a host; the title defaults to the host, the icon to
  the site's `/favicon.ico` (`favicon_url` overrides it: any http(s) URL,
  a local server's too). Folders nest up to 16 deep; a split is exactly two
  pages, `fraction` (0.1–0.9) the first one's share. `selected` picks one
  tab per space for the window to show on entry.
- History ages are seconds or `s`, `m`, `h`, `d`, `w` strings, within the 90
  days history keeps; visits are written with
  `HistoryDatabase.importVisits`. Routes take `match` (`is_equal_to`,
  `contains`, `domain_is`) with `pattern`, and/or `source_app`, and a
  `target` (`space:<name>`, `most_recent_space`, `private_window`,
  `quarantine`, `quick_detour`), checked with `linkRouteProblems` against
  the fixture's spaces.
- It is carried out by `TabStore.applyArcImport`, the Arc import's one-pass
  apply (the plan's entries gained `faviconURL` and folders `isCollapsed`):
  pinned entries and favourites come in dormant, tabs asleep, with the
  file's titles, so nothing has to load first (DemoStage opened every page
  and waited 20 s for titles and icons before pinning). Saved at once
  (`saveNow`), so the world is there after a relaunch (tested by reloading a
  `TabStore` from the same databases).

# Placing windows

`list_displays` (read-only, whenever the endpoint is on) lists displays
with `display_id` (CGDirectDisplayID), `frame` and `visible_frame`, `scale`,
`main`, `name` and pixel size, virtual displays included.
`set_window_frame` (test runs only) moves and sizes a window from
`list_windows` (`window_id`, any kind) or another Detour window
(`window_number`: the Arc import window), relative to `display_id` or
global; a sheet, the approval panel, and a Private window unless allowed,
are refused. `activate` brings Detour to the front with the window key.

Both use global points with a top-left origin (what `screencapture -R`
takes; the main display's top-left is 0,0), flipped from AppKit by the main
display's height. After the move the tool waits up to 2 s for the window
server's bounds (`CGWindowListCopyWindowInfo`) to equal the frame and
returns both, with `settled`, `is_key`, `app_active` and `window_number`.
`list_windows` reports `screen_bounds` too. A recording region must come
from those bounds, not from the frame asked for (see Traps).

# UI on demand and Arc's folder

`open_ui quick_detour_launcher` (TASK-409) shows the launcher panel for
`profile_id` (default: the frontmost window's, as the menu item picks),
types `text` into its field, waits for the history pass, and returns its rows
(kind, title, url and the profile each names) with the panel's
`window_number` for `screencapture -l`. The global hotkey and the panel are
otherwise out of the endpoint's reach.

`open_ui` (Debug builds and test runs only; absent from Release) replaces
DemoStage's `spaceeditor`, `arcoffer` and `settings*` commands and returns
the window the UI is in. `space_editor` calls
`beginCreatingSpace(draft:)` / `beginEditingSpace(id:draft:)`; the editor
focuses (and selects) its name field, so `type_text window_id=… interval_ms=…`
types into it at a pace (tested: the characters arrive in order, paced).
`settings` uses `SettingsWindowController.showPane(named:)` and selects the
row in the pane's first table. The Arc ones read only a folder inside the
data directory or a temporary folder, compared after `realpath`, never
`ArcSidebarReader.userDataDirectory`: never in or under Arc's own folder,
in any case spelling, and with no symbolic or extra hard link inside it,
which the reader would follow to Arc's files.

A test run never reads the user's Arc folder, patch or no patch:
`AppDelegate` skips the launch offer when `AutomationGate.isTestRunRequested`
(`DETOUR_MCP=1` with an isolated data directory, whether or not the endpoint
started), and points `ArcSidebarReader.dataDirectoryOverride` (a `Mutex`,
read off the main thread) at `<data dir>/Arc`, so File › Import from Arc
finds nothing either. `open_ui arc_offer`/`arc_import` point it at the given
fixture folder for the rest of the run, so Choose… reads the fixture too.
See [Arc import](./arc-import.md).

# Traps

- **A new window is still growing.** Right after `showWindow`, AppKit's
  open animation scales the window up from its centre for a moment, so the
  window server's bounds were 698 × 478 at 41,61 while the frame said
  700 × 480 at 40,60 (in a test). That is most likely the ~9 pt shift of
  TASK-110's first loops, whose region came from the frame asked for.
  `set_window_frame` waits for the bounds to settle and returns
  them.[^task-228-3]
- **`resolvingSymlinksInPath` drops `/private`.** It turned
  `/private/tmp/x` into `/tmp/x` for some paths and not others, so a
  temporary folder failed the "inside a temporary folder" check. The Arc
  folder check compares `realpath` results.
- **A capture takes the keyboard focus.** A recording shows an active window
  (traffic lights in colour) only while Detour is the active app with that
  window key, so the capture script asks for `set_window_frame
  activate=true`, which takes the focus from the app in use until the run
  ends. screencapture itself records without touching focus. `open_ui
  settings` and `arc_import` bring their windows forward too (Settings'
  `showWindow` activates the app, the Arc window makes itself key). All are
  test-run only, so the user's own endpoint never takes the front. On
  2026-11-14 Detour lost the front mid-take in most of four capture runs (to
  Google Chrome, then Mimestream, with the Mac in use: 22 s since the last
  input) and kept it in three diagnostic runs; the script now stops naming
  the app in front instead of fighting for the focus or keeping a grey take.
- **The connected-agent capsule shows in captures.** It is in every window
  while a client is connected, so the capture script hides it with the
  Debug override `automation_indicator off` (test runs only, `gate_closed`
  on the user's own endpoint); Release cannot hide it.
- **Local pages are dev-mode pages.** A fixture rewritten to a 127.0.0.1
  server (`capture.py --offline`) gets dev mode's host line, hazard border
  and toolbar: good for a dry run, not for the site's media (see [dev
  mode](./dev-mode.md)).

# Tests

`AutomationStagingTests` (a seeded world round trip through a relaunch, a
malformed fixture refused with nothing applied, the fixture's field errors,
refusal outside a test run and in a data directory with content, sort
orders per pinned level; the test-run request and the Arc folder override;
displays, a window placed and read back, by `window_id` and
`window_number`, and the placement errors; `open_ui` only in Debug, the
space editor with a draft and paced typing into its name field, the Arc
offer from a fixture folder and its refusals, a Settings pane with a row,
`open_ui`'s errors and its refusal outside a test run).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Release and website](../playbooks/release-and-website.md): website
  captures with `docs/capture/capture.py`.
- [Screenshots](./automation-endpoint-screenshots.md): pictures taken by
  the endpoint itself.

[^task-228-3]: Automation: capture tooling on the MCP endpoint
[^staging]: AutomationTools+Staging.swift and AutomationWorldFixture.swift (seed_world, displays, placement, open_ui)
[^capture-kit]: docs/capture (the website capture kit, capture.py, demo-world.json)
[^tests]: AutomationStagingTests
