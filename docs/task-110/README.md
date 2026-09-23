# TASK-110 website capture kit

Temporary tooling used to capture the website's feature loops and stills from a
staged demo profile. Nothing here is compiled into Detour.

- `DemoStage.swift.txt` — env-gated (DEBUG) harness: seeds a demo world into an
  isolated `DETOUR_DATA_DIR` and runs commands appended to `<dir>/cmd`
  (`seed`, `to2x W H`, `space <name> [animate]`, `select <url|title>`,
  `folder <name>`, `split <a> <b>`, `visitall`, `renamepinned <url>|<name>`,
  `settings <spaces|profiles>`, `settingsrow N`, `deleteprofile <name>`, ...).
  To use: copy to `Detour/App/DemoStage.swift`, `git apply appdelegate-hook.patch`,
  `xcodegen generate`, build Debug.
- `vdisplay.m` — adds a 1600x1000 @2x virtual display (private CGVirtualDisplay API)
  so captures are Retina on a 1x monitor. `clang -fobjc-arc -framework Foundation
  -framework CoreGraphics vdisplay.m -o vdisplay`; the display lives until the
  process is killed.
- `demo.sh` — `cmd "<command>"`, `shot <name>` (screencapture -l of the demo window),
  `wallpaper <hex>` / `wallpaper-restore` (snapshot and restore the wallpaper store).
- `encode.sh` — screencapture -v writes variable-frame-rate video: convert to
  30 fps first, then trim, then H.264 + WebP poster.
- `wins.swift` — list a process's CGWindow IDs.

Launch: `open -n <BUILT_PRODUCTS_DIR>/Detour.app --env DETOUR_DATA_DIR=DetourDemo
--env DETOUR_DEMO_STAGE=<dir>`, then `demo.sh cmd "to2x 1280 680"`, `demo.sh cmd seed`.
Background tabs must be shown once (`visitall`) before capture — see TASK-112.
Record loops with `screencapture -x -v -V <secs> -R<x>,<y>,<w>,<h>` (global
top-left coordinates of the window on the virtual display).

Gotcha: the first loops were recorded with the region computed from the frame
`to2x` requested, but the window sat ~9 pt further right by recording time, so
the video's left edge showed the virtual display background and a neighbouring
window. Take the region from `wins <pid>` (live CGWindow bounds) right before
recording; the shipped loops were fixed by cropping 20 px off the left
(`encode.sh ... "crop=1100:1360:20:0"`).

Second pass (user feedback: cropped windows + CSS rounding lacked concentricity):
record the WHOLE window, sized to the shot (560x700 pt for Spaces/Pinned,
760x480 for Favorites), placed mid-display away from the Dock (the Dock also
lives on the virtual display's left edge — that was the old dark strip), with
the wallpaper set to the site background (`demo.sh wallpaper F7F2EA`; macOS applies it to
every display and Space, so the script snapshots the wallpaper store first and
`demo.sh wallpaper-restore` must be run when capturing is done)
and a margin of 70 pt left/right, 60 top, 120 bottom so the native shadow
fades to background inside the frame. The page adds no radius/shadow.
Colour: screencapture's video records #F7F2EA as 246,241,230; encode.sh applies a
tone curve and an accurate BT.709 conversion so the loop background decodes to
248,241,234 (same as encoding a solid #F7F2EA). Measure with
`flags=accurate_rnd+full_chroma_int` — ffmpeg's default RGB conversion reads 2-3 low.
