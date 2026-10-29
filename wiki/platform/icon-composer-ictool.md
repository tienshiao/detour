---
type: Platform Quirk
title: Icon Composer's ictool
description: How to render Detour.icon in every macOS appearance and size from the command line with Icon Composer's ictool, and the traps — the wrong ictool, the sandbox crash, ignored image specializations, and the icon cache after a rebuild.
tags: [platform, icon, tooling, branding]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-29T08:22:20Z }
stale_after: 2027-06-01T00:00:00Z
sources:
  - id: task-196
    resource: backlog:TASK-196
    title: "Branding: improve the Detour app icon"
  - id: icon
    resource: ../../Detour/Detour.icon
    title: Detour.icon
---

Icon Composer ships a command-line renderer that draws a `.icon` bundle the
way macOS does, glass and all, in each appearance. It is the quickest way to
review an icon change without building and launching the app. Measured with
Xcode 26 on macOS 26.7.[^task-196]

# Behavior

```bash
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" Detour/Detour.icon --export-image --output-file out.png --platform macOS \
  --rendition Default --width 256 --height 256 --scale 2
```

* Renditions: `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight`,
  `ClearDark`. Tinted takes `--tint-color <hue 0…1> --tint-strength <0…1>`.
* `--width/--height` are points; `--scale 2` doubles the pixels. Render 16
  and 32 pt to judge Finder list and Dock sizes.
* `--design-generation 26|27` picks the design generation.

# Traps

| Trap | What happens | Do instead |
|---|---|---|
| `xcrun ictool` / `Developer/usr/bin/ictool` | A different tool (an ibtoold front end); rejects `--export-image` as an unknown argument | Use the binary inside Icon Composer.app above |
| Running inside the agent sandbox | Every render dies with `IconComposerKit/SwiftAdditions.swift:15: Assertion Failure: Unreachable code has been reached` and writes nothing | Run it with the sandbox off |
| A missing layer file | `actool` fails naming it; `ictool` exits 0 and renders an empty background | Build (or run actool) before trusting a render |
| `image-name-specializations` with an `appearance: dark` entry | Ignored by ictool: the dark render keeps the default SVG | A per-layer `fill-specializations` with `{"appearance": "dark", "value": {"solid": "srgb:…"}}` recolours the layer and is honoured |
| macOS fills | The bundle's `fill` is replaced with dark grey in the Dark renditions; layers keep their colours | Put a colour that must survive Dark in a layer, not the fill (see [app icon design](../decisions/app-icon-design.md)) |
| Finder / Dock after a rebuild | `NSWorkspace.icon(forFile:)` returned the old icon at 256 and 64 pt and the new one at other sizes for the same freshly built app | `touch` the .app and `lsregister -f` it (`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`); the built `Detour.icns` (extract with `iconutil -c iconset`) shows what was actually compiled |

# Why it matters here

The icon has no tests; these renders, the extracted `.icns` and a look at
the Dock with the debug build running are how an icon change is checked
(TASK-196 did all three).[^task-196]

# Related

* [App icon design](../decisions/app-icon-design.md) - the icon's layers and why.
* [Runtime verification](../playbooks/runtime-verification.md) - launching the debug build in an isolated profile.

[^task-196]: TASK-196
