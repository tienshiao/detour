---
type: Playbook
title: Release and website
description: How a signed, notarized Detour DMG is built and published through Sparkle, and how the website's screenshots and feature loops are captured from a staged demo profile.
tags: [playbook, release, sparkle, notarization, website, capture]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:44:19Z }
sources:
  - id: build-release
    resource: ../../scripts/build-release.sh
    title: build-release.sh
  - id: deploy-script
    resource: ../../scripts/deploy-1password-test.sh
    title: deploy-1password-test.sh
  - id: info-plist
    resource: ../../Detour/Resources/Info.plist
    title: Info.plist (version, SUFeedURL, SUPublicEDKey)
  - id: project-yml
    resource: ../../project.yml
    title: project.yml (signing settings, Sparkle package)
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (startsUpdater)
  - id: task110-readme
    resource: ../../docs/task-110/README.md
    title: TASK-110 website capture kit
  - id: task110-demo
    resource: ../../docs/task-110/demo.sh
    title: demo.sh (commands, shots, wallpaper)
  - id: task110-encode
    resource: ../../docs/task-110/encode.sh
    title: encode.sh (constant frame rate, colour, H.264 and poster)
  - id: task-110
    resource: backlog:TASK-110
    title: Website — replace the HTML feature mockups with real screenshots and loops
  - id: task-111
    resource: backlog:TASK-111
    title: Website — next-release update
  - id: task-112
    resource: backlog:TASK-112
    title: Favicons — some sites never get their favicon
  - id: notes-capture
    resource: "Agent session notes, 2026-09-23 (not in the repository)"
    title: Session notes on screen capture for UI verification
---

Two procedures that share tools: making a release
([scripts/build-release.sh](../../scripts/build-release.sh)) and capturing
real screenshots and short video loops for the website
([docs/task-110](../../docs/task-110/README.md)). The website itself is a
separate repository; only the capture kit lives here.

# When to use

- Cutting a release: version bump, signed and notarized DMG, appcast.
- The website needs new or refreshed captures (TASK-111 lists what the
  next release adds).

# Release

## Prerequisites (once per machine)

From the script's header:

1. A Developer ID Application certificate in the keychain. The signing
   identity and team are set in the script and in `project.yml`.
2. Notarization credentials stored under the keychain profile name the
   script expects:

   ```bash
   xcrun notarytool store-credentials "detour-notary" --apple-id <id> --team-id <team> --password <app-specific password>
   ```

3. Sparkle's EdDSA key pair. `generate_keys` is in the Sparkle package
   artifacts under DerivedData (`…/SourcePackages/artifacts/sparkle/Sparkle/bin/`);
   the public key is `SUPublicEDKey` in `Info.plist`. The private key
   stays in the keychain of the machine that signs updates.

## Steps

```bash
./scripts/build-release.sh 1.2.3     # set the version, increment the build number, build
./scripts/build-release.sh           # rebuild the version already in Info.plist
```

What it does, in order:

| Step | Detail |
|---|---|
| Version | with an argument: sets `CFBundleShortVersionString` and increments `CFBundleVersion` in `Detour/Resources/Info.plist` (an edit you then commit) |
| Project | `xcodegen generate` |
| Build | `xcodebuild -scheme Detour -configuration Release clean build` |
| Locate | the first `Detour.app` under `DerivedData/Detour-*/Build/Products/Release` whose bundle id is `com.detourbrowser.mac` |
| Sign | `codesign --force --deep --timestamp -o runtime` with the entitlements file, then `codesign --verify --deep --strict` |
| Package | a DMG with the app and an `/Applications` symlink, at `build/Detour-<version>.dmg` |
| Notarize | `xcrun notarytool submit … --wait`, then `xcrun stapler staple` |

Success ends with `Release artifact: build/Detour-<version>.dmg` and the
two remaining manual steps:

```bash
~/Library/Developer/Xcode/DerivedData/Detour-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast build/
```

then upload the DMG and `appcast.xml`. The running app looks for updates
at `SUFeedURL` in `Info.plist`.

## Traps

- **It is not a script for an agent to run unprompted.** It needs the
  signing identity and the notary credentials, edits `Info.plist`, and
  submits to Apple's notary service.
- **The app it signs may not be the one it just built.** The lookup takes
  the first matching `Detour-*` directory in glob order. With several
  checkouts or worktrees there are several such directories, and an older
  Release product in an earlier one would be picked. This follows from
  reading the script; the same lookup has launched stale Debug builds
  ([runtime verification](./runtime-verification.md)). Before a release,
  check that only one DerivedData directory holds a Release product, or
  compare the signed app's version and build number with `Info.plist`.
- **The version edit is uncommitted.** A release built from a dirty tree
  cannot be reproduced; commit the bump.
- **`--timestamp` needs the network.** The local-test workaround
  (`--timestamp=none`) must never be used for a release: notarization
  requires a secure timestamp.
- **Sparkle does not run in isolated or test runs.** `AppDelegate.startsUpdater`
  is false outside the default data directory and in the XCTest host, and
  the "Check for Updates…" item is left out. Update checks can only be
  tried in a normal run of the app. See
  [app shell](../architecture/app-shell.md).
- **The other signing script.** `scripts/deploy-1password-test.sh` builds
  and signs a Release app too, but installs it over `/Applications/Detour.app`
  and does not notarize. It is for
  [signed-build verification](./signed-build-verification.md), not for
  distribution.

# Website captures

The site shows real windows: stills as WebP, motion as short muted MP4
loops with a poster. They are produced from a staged demo profile (public
pages only, isolated data directory), driven in-process, and recorded with
`screencapture`. Recording needs the Screen Recording grant for the
process that runs the shell.[^notes-capture]

## Steps

1. **Install the stage harness** (temporary; do not commit):

   ```bash
   cp docs/task-110/DemoStage.swift.txt Detour/App/DemoStage.swift
   git apply docs/task-110/appdelegate-hook.patch
   xcodegen generate && xcodebuild -scheme Detour -configuration Debug build
   ```

   The harness polls `<dir>/cmd` for commands and logs to `<dir>/log.txt`.
   The hook patch applied cleanly to `main` on 2026-10-04
   (`git apply --check`); if it stops applying, add its three lines after
   `observeWindowClose(wc)` by hand.

2. **Create a 2x virtual display** if the physical display is 1x, so
   captures are Retina:

   ```bash
   clang -fobjc-arc -framework Foundation -framework CoreGraphics docs/task-110/vdisplay.m -o vdisplay
   ./vdisplay &        # 1600x1000 @2x; lives until the process is killed
   ```

   It uses the private `CGVirtualDisplay` API.

3. **Launch and stage:**

   ```bash
   open -n <BUILT_PRODUCTS_DIR>/Detour.app --env DETOUR_DATA_DIR=DetourDemo --env DETOUR_DEMO_STAGE=<dir>
   demo.sh cmd "to2x 1280 680"     # move the window to the virtual display at a size
   demo.sh cmd seed                # spaces, profiles, pinned folders, favourites, a split
   demo.sh cmd visitall            # show every background tab once
   ```

   `demo.sh` reads the command file and log from its own directory, so run
   a copy of the kit from the directory you pass as `DETOUR_DEMO_STAGE`.
   Other commands (`space`, `select`, `folder`, `split`, `settings`, …)
   are listed in the README.

4. **Stills:** `demo.sh shot <name>` (`screencapture -x -o -l <window id>`;
   prints the pixel size).

5. **Loops:** record the whole window with a margin, not a crop:

   ```bash
   screencapture -x -v -V <seconds> -R<x>,<y>,<w>,<h> <out.mov>
   ```

   Take the rectangle from the window's live bounds
   (`swift docs/task-110/wins.swift <pid>` prints each window's id, name,
   layer, x, y, width and height) immediately before recording, in global
   top-left coordinates on the virtual display.

6. **Encode:** `encode.sh <in.mov> <name> <start> <end> [crop]` converts to
   30 fps, trims, applies the colour correction and writes an H.264 MP4
   plus a WebP poster. Needs `ffmpeg` and `cwebp`.

7. **Clean up:** `demo.sh wallpaper-restore` if the wallpaper was changed,
   kill the virtual display, delete `Detour/App/DemoStage.swift`,
   `git checkout -- Detour/App/AppDelegate.swift`, `xcodegen generate`.

## Traps

- **Region from the requested frame.** The first loops used the frame the
  harness asked for; by recording time the window sat about 9 points to
  the right, and the video's left edge showed the display background.
  Always use live bounds.[^task-110]
- **Cropped windows look wrong on the page.** A crop plus CSS rounding
  does not match the window's real corners. Record the whole window with
  its native corners and shadow, over a wallpaper set to the page's
  background colour, with enough margin for the shadow to fade (70 points
  left and right, 60 top, 120 bottom were used); the page then adds no
  radius or shadow of its own.[^task-110]
- **The wallpaper command changes every display and Space.** That is how
  macOS applies it. `demo.sh wallpaper <hex>` snapshots the wallpaper
  store first, the harness refuses to change it without that snapshot,
  and `demo.sh wallpaper-restore` puts it back. Run the restore as soon as
  capturing is done.[^task-110]
- **The Dock is on the virtual display too.** Place the window
  mid-display, away from the edge; a dark strip in early captures was the
  Dock.[^task-110]
- **Variable frame rate.** `screencapture -v` writes variable-frame-rate
  video. Convert to a constant rate before trimming (the script's order),
  or trims land on the wrong frames.
- **Colour drift in video.** The recorder stores the page background a few
  values off, and ffmpeg's default RGB conversion reads low. `encode.sh`
  applies a tone curve and an accurate BT.709 conversion so the loop's
  background matches the still and the page; measure with
  `flags=accurate_rnd+full_chroma_int`.[^task-110]
- **Background tabs look unfinished.** A tab that has never been shown may
  not have finished loading (favicon, title). `visitall` shows each one
  once before capture.[^task-112] See
  [hidden web view load stalls](../platform/hidden-webview-load-stalls.md).
- **Captures come from the current branch.** Unreleased UI can appear in
  a screenshot of the released product; check crops against what the
  release contains.[^task-110]

# Related

- [Signed-build verification](./signed-build-verification.md) — the test deployment of a signed build.
- [In-process UI automation](./in-process-ui-automation.md) — driving the app and capturing views.
- [Debug harness](./debug-harness.md) — the pattern DemoStage is an instance of.
- [App shell](../architecture/app-shell.md) — Sparkle wiring and launch switches.
- [Updates](../extensions/updates.md) — extension updates, which are unrelated to Sparkle.

[^task-110]: TASK-110
[^task-112]: TASK-112
[^notes-capture]: Session notes on screen capture for UI verification
