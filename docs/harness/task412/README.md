# TASK-412 runtime harness: the Quick Detour window over Chrome

Measures whether Return in the launcher panel, shown by the global hotkey over
another app, activates Detour with the new Quick Detour window in front. No
Detour code changes are needed: the debug build registers the hotkey with
`DETOUR_GLOBAL_HOTKEY=1`, and the isolated profile's defaults suite gets the
test shortcut Ctrl-Opt-Cmd-F12 (`QuickDetourHotKeyShortcut`, keyCode 111,
Carbon modifiers 6400).

- `input.swift`: posts keys at the HID event tap (`key <code> <c o t s f>`,
  `type <text>` with US key codes; an F-key needs `f`, the Fn flag).
- `order.swift`: prints the frontmost app and the CGWindowList order, front to
  back; Detour windows by size, the production app's (`QDFRONT_PROD_PID`, set by run.sh) as Dprod.
- `run.sh <app> <tag> <label:App>...`: one Detour process (`DETOUR_DATA_DIR=
  DetourVerifyQDFront`) for every trial, a fixture server on 127.0.0.1:8932, a
  narrow `log stream` (WindowServer SkyLight + LaunchServices `front`). Per
  trial: `osascript` activates the app, hotkey, then it checks that the panel
  (level 3) is in front before typing anything, types the URL, presses Return,
  and records the order 2.5 s later. A trial stops if any other Detour process
  is running, so posted keys never reach another session's app.

Build: `swiftc -module-cache-path ./mc -o input input.swift` (same for order),
sandbox off, into a scratch directory passed as `QDFRONT_DIR` (logs and the
fixture page go there too). On exit, also on Ctrl-C, the script stops what it
started and deletes `com.detourbrowser.mac.DetourVerifyQDFront` and the
`…-DetourVerifyQDFront` window/split keys the run leaves in `com.detourbrowser.mac`.

Results (2026-11-19, macOS 26.7, the user's Mac with ~20 Chrome windows open):

Trials that put Detour in front, by what was in front when the hotkey was
pressed (the first runs launched a fresh Detour per trial; later ones used one
process; the experiments were temporary edits in the launcher, not kept):

| Activation after opening the window | over Chrome | over Ghostty, Chrome in front just before | over Ghostty, no Chrome before |
|---|---|---|---|
| `NSApp.activate()` (shipped until TASK-412) | 0/7 | 0/2 | 3/3 |
| the same, opening first and closing the panel last | 0/4 | 0/2 | 2/2 |
| the same, panel kept key until activated (600 ms timeout) | 0/2 | — | 1/1 |
| `NSApp.activate(ignoringOtherApps: true)` (shipped) | 5/5 | 2/2 (label `viachrome`) | 3/3 |
| `NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)` | 2/2 | — | — |

Refused requests are not logged as refused: the window server reads the
session's activation token for Detour's request (the same token, held for
Chrome, in passing and failing trials) and then nothing follows, where a
granted one logs `SetFrontProcessWithInfo` making Detour the front process.
With `ignoringOtherApps` only the new window came forward: earlier Quick Detour
windows and the browser window stayed behind the other app.

## The other two paths (same day, current code)

`run-paths.sh <app> <tag> <spec>...` (same setup; it also sets the isolated
profile's Link Routes default target to Quick Detour in `browser.db`):

- `link:<App>` / `linkvia:<App>`: `opener` opens a fixture URL in the debug
  build through LaunchServices (`NSWorkspace.open(_:withApplicationAt:)`,
  activating, as a clicked link in another app does; it passes
  `DETOUR_DATA_DIR`, so a second instance could never use the real profile).
  `linkvia` puts Chrome in front just before the app.
- `dock:<App>` / `dockvia:<App>`: `dockclick` right-clicks the debug build's
  Dock tile and clicks Hide All Quick Detour Windows, the app comes forward,
  then Show All. Real HID clicks at the positions in the Dock's accessibility
  tree; the menu is drawn by `DockHelper`, not `Dock`.

| Path | over Chrome | over Ghostty, Chrome just before | over Ghostty |
|---|---|---|---|
| A link routed to Quick Detour (`AppDelegate.openInQuickDetour`, no activation call of its own) | 2/2 | 1/1 | 2/2 |
| Dock menu Show All (`showAllFromDockMenu`, cooperative `NSApp.activate()`) | 2/2 | 2/2 | 1/1 |

Both left unchanged: LaunchServices activates the app a link opens in, and a
choice in Detour's Dock menu is the user picking Detour, so the cooperative
request is granted there. Only the new (or shown) windows came forward.
