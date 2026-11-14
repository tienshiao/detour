# Website capture kit

Loops and stills for detourbrowser.com, taken from a staged demo world with
no patch to the app (TASK-228.3; it replaced TASK-110's DemoStage harness,
which was pasted into AppDelegate and rebuilt for every session). Detour
stages the world through its automation endpoint (`DETOUR_MCP=1`); what
stays outside the app is here: the 2x virtual display, the wallpaper,
screencapture and the encoder.

```bash
xcodebuild -scheme Detour -configuration Debug build      # Debug: open_ui and the indicator override
APP="$(xcodebuild -scheme Detour -configuration Debug -showBuildSettings \
        | grep -m1 ' BUILT_PRODUCTS_DIR' | sed 's/.*= //')/Detour.app"
docs/capture/capture.py "$APP" --out ~/Desktop/captures            # every shot, real sites
docs/capture/capture.py "$APP" --out /tmp/c --shots split --offline \
    --favicons ../detour-website/public/assets/favicons            # local pages, a dry run
```

What `capture.py` does, in order, and undoes at the end (also on failure or
Ctrl-C): builds and starts `vdisplay` (a 1600 × 1000 pt @2x display), launches
the app with a fresh `DetourCapture-<random>` data directory and the endpoint
on, seeds `demo-world.json` (`seed_world`), sets light appearance, hides the
connected-agent capsule (`set_debug_override automation_indicator off`), sets
the wallpaper to the site's background (`demo.sh wallpaper F7F2EA`), then for
each shot places the window mid virtual display (`list_displays`,
`set_window_frame … activate`), stages it and records. Cleanup: SIGTERM to
its own Detour, `demo.sh wallpaper-restore`, the virtual display killed, the
data directory, its WebKit stores, preferences domain and window keys
removed. Output goes to `--out` (never the repository): `<shot>.mov` and the
encoded `.mp4` with its `-poster.png/.webp` for loops, `.png` and `.webp`
for stills, `world.json` (the fixture as seeded) and `app.log`.

Shots (add one as a `shot_<name>` method and a `SHOTS` entry):

| Shot | Output | Window | Staging |
|---|---|---|---|
| `spaces` | `spaces.mp4` + poster, 1400 × 1760 px | 560 × 700 pt | Work, then Next Space ×3, Previous Space ×3 (`run_menu_item`); refused if Detour lost the front during the take |
| `split` | `split.webp`, 2784 × 1584 px | 1280 × 680 pt | the Personal space's split |
| `space-editor` | `spaces-editor.webp`, 1400 × 1760 px | 560 × 700 pt | over Reading: `open_ui space_editor` (🍳, Sage, Personal), "Recipes" typed at 110 ms a character |

Margins around the window: 70 pt left and right, 60 top, 120 bottom (the
split still: 56, 38, 74, as the site's), so the native shadow fades out on
the wallpaper inside the frame. Region and stills come from the window
server's bounds (`screen_bounds`), read after `set_window_frame` reports
`settled`.

## Files

- `capture.py` — the script above. Standard library only; uses
  `scripts/detour-mcp`'s `Session`.
- `demo-world.json` — the demo world (four spaces on three profiles,
  favourites, pinned folders, a split, history, Link Routes) as the site's
  media show it. The format is in `wiki/features/automation-endpoint.md`
  ("Seeding a world"). With `--offline` every page is rewritten to a local
  server (titles kept, icons from `--favicons/<site>.png` or a coloured
  square); those pages are on 127.0.0.1, so Detour marks them as dev-mode
  pages (host line, hazard border, dev toolbar): fine for checking the
  pipeline, not for the site.
- `vdisplay.m` — the 2x virtual display (private CGVirtualDisplay API); lives
  until killed. `capture.py` builds it into `--out`.
- `demo.sh` — `wallpaper <RRGGBB> [displayID]` / `wallpaper-restore`. macOS
  applies a desktop picture to every display and Space, so `wallpaper`
  snapshots the wallpaper store first (in `$CAPTURE_STATE`, default
  `~/Library/Caches/detour-capture`) and `wallpaper-restore` puts it back and
  restarts WallpaperAgent. Run the restore by hand if a run was killed hard.
- `wallpaper.swift` — the helper `demo.sh` compiles to set the picture.
- `encode.sh` — screencapture -v writes variable-frame-rate video: convert to
  30 fps first, then trim, then H.264 + WebP poster, into `$CAPTURE_OUT`.
  Colour: screencapture's video records #F7F2EA as 246,241,230; a tone curve
  and an accurate BT.709 conversion bring the loop background back to
  248,241,234 (measure with `flags=accurate_rnd+full_chroma_int`; ffmpeg's
  default RGB conversion reads 2-3 low).
- `make_fake_arc.py <dir>` — a fake Arc data folder for the Arc import offer
  and window (`open_ui arc_offer` / `arc_import`, which refuse any folder
  outside the data directory or a temporary one). A test run never reads the
  real Arc folder: Detour looks for Arc's data in its own data directory and
  skips the launch offer.
- `axwin.swift` — places another app's window (TextEdit for the Link Routes
  shots) through Accessibility. `wins.swift` — a process's CGWindow IDs.

## From DemoStage commands to the endpoint

| DemoStage | Now |
|---|---|
| `seed`, `seed2`, `routes`, `archiveseed`'s history, `agehistory` | a fixture for `seed_world` (history with ages, Link Routes) |
| `to2x W H`, `center`, `frame`, `settingsframe`, `qdframe` | `list_displays`, `set_window_frame` (`window_number` for Settings and other windows) |
| `space <name> [animate]`, `select <url>` | `select_tab` (switches the space); `run_menu_item` Spaces › Next/Previous Space animates |
| `type`, `press`, `key`, `ctrl` | `type_text … interval_ms`, `press_key` |
| `settings`, `settingspane`, `settingsrow` | `open_ui settings pane=… row=…` |
| `spaceeditor` | `open_ui space_editor` (with a draft) |
| `arcoffer <dir>` | `open_ui arc_offer arc_folder=…`; `open_ui arc_import` for the window |
| `appearance`, `wallpaper` | `set_appearance`; `demo.sh wallpaper` |
| `js`, `jsrect`, `frames`, `axpress` | `evaluate_js`, `read_page mode=elements`, `hit_test`, `click` |
| `info`, `spaces`, `winfo` | `list_spaces`, `list_tabs`, `list_windows` |
| `shot` | `screencapture -l <window_number>` or a region from `screen_bounds` |

Not ported (add to the endpoint or the fixture when a shot needs them):
`folder` (toggling a pinned folder; a click on its row does it, at a point
`hit_test` can find), `quicklaunch`/`openext` (Quick Detour placement),
`private`, `installcrx` (`install_extension` takes a CRX file), `sqlh`/`sqls`.

## Gotchas

- Take the recording region from the live window-server bounds, never from
  the frame asked for. A window that has just appeared is still scaling up
  from its centre (AppKit's open animation), which is how the first loops
  came out shifted by ~9 pt; `set_window_frame` now waits for the bounds to
  match (`settled`).
- **A capture takes the focus.** Detour must be the active app with the
  window key, or the traffic lights record grey, so the script calls
  `set_window_frame activate=true`, which brings Detour to the front and
  takes the keyboard focus from the app in use until the run ends.
  screencapture itself records without touching focus: only the active look
  needs it (a capture of an inactive window would leave the focus alone and
  show grey traffic lights). `open_ui settings` and `arc_import` bring their
  windows forward too, as those windows always do when shown. All of these
  are test-run only. Observed on Nov 14 2026: Detour lost the front during
  most takes of four runs (to Google Chrome, then Mimestream, while someone
  was using the Mac) and kept it in three diagnostic runs. So capture while
  nobody uses the Mac; the script checks that Detour is in front after
  placing the window and after every step of a loop, and stops, naming the
  app in front, rather than keep a grey take or fight for the focus.
- Loops are trimmed to just after the last step, not to the end of the
  recording, so they end where they start.
- The harness `quit` raised "Quit Detour?"; the script sends SIGTERM to its
  own PID instead. The system Emoji & Symbols viewer popped up mid-take once
  (DemoStage era).
- Never point anything at `/Applications/Detour.app` or the real data
  directory: `capture.py` refuses the former and always uses a fresh
  `DetourCapture-*` directory.
