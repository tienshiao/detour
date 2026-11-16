---
type: Playbook
title: Settings layout traps and runtime checks
description: "AppKit layout traps met while building the Settings panes (wrapped text measurement, soft stack-view insets, NSBox, CGColor borders, window capture, shell launches) and the harnesses that check the panes at runtime: the TASK-189 survey, the TASK-211 column harness and the gated capture test."
tags: [settings, appkit, layout, verification]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: layout-notes
    resource: "Agent session notes, 2026-09-25 and 2026-09-26: Settings pane layout (not in the repository)"
    title: Settings pane layout lessons
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: survey-harness
    resource: ../../docs/harness/task189-survey-harness.patch
    title: TASK-189 survey harness (every pane and state, light and dark, plus the sizing checks)
  - id: task211-harness
    resource: ../../docs/harness/task211-harness.patch
    title: TASK-211 harness (columns scrolled by wheel events, frames logged, light and dark, a small screen)
  - id: capture-tests
    resource: ../../DetourTests/SettingsCaptureHarnessTests.swift
    title: SettingsCaptureHarnessTests.swift
---

# When to use

When changing the layout of a [Settings window](./settings.md) pane, or
checking one at runtime. The panes have no UI tests beyond the layout
assertions in their suites; what only shows on screen is checked with the
harnesses below. The traps tied to the window's height and its resize
animation are on [Settings window height](./settings-window-height.md#applying-a-fit).

# Steps

1. **Capture every pane.** `SettingsCaptureHarnessTests`, skipped unless
   `TEST_RUNNER_SETTINGS_CAPTURE_DIR` names a folder, draws every pane in
   light and dark, and again with Increase Contrast forced through
   `SettingsGroupStyle.increaseContrastOverride` (a process cannot turn the
   real setting on).[^capture-tests]
2. **Survey states and sizes** with the TASK-189 survey harness: every
   pane and state, light and dark, frames measured; pane switches, drags,
   the cap and a real second screen; uninstalling the only extension
   through the pane; a run with `-AppleShowScrollBars Always`.[^survey-harness]
3. **Check the columns** with the TASK-211 harness: every list pane at its
   minimum with 18 spaces, 15 profiles, 14 extensions and 12 routes;
   scroll-wheel events over the details and over the list, frames and
   offsets logged to show the other did not move; a list scrolled to its
   end kept there when the window shrinks by 50 pt; Links' Default and
   caption unmoved by a wheel over the routes; a 520 pt screen capping the
   panes at 352; the Quick Detour pane; light and dark.[^task211-harness]
4. **Read the Accessibility tree** with the reader in
   `docs/harness/task336/axsettings.swift`; see
   [Settings accessibility](./settings-accessibility.md).

# Traps

- **Measure wrapped text with a wrap width.** `fittingSize` does not do
  the two-pass layout a wrapping `NSTextField` needs: a wrapping label
  without `preferredMaxLayoutWidth` measures as one line. A constant wrap
  width goes wrong when the column's width does (legacy scrollers), so
  bodies use `SettingsWrappingLabel`, which takes its own width at layout
  and refits the pane when it changes; only the pane description, outside
  the scroll view, keeps a constant.[^task-189] See
  [Settings pane container](./settings-pane-container.md#settingswrappinglabel).
- **`NSStackView.edgeInsets` on the cross axis are soft.** They act at
  hugging priority only; in a height-constrained column the bottom inset
  collapses silently while the top one survives. Use your own required
  constraints for insets that must hold, pin the content's bottom to the
  container, and give the content required vertical compression
  resistance.[^layout-notes]
- **`NSBox` does not grow to an Auto Layout content view's fitting
  height.** The pending-permissions banner (`TintedBannerView`) and the
  bordered groups (`SettingsGroupBoxView`) were custom views for that
  reason, until the grouped form replaced them (TASK-338).[^layout-notes]
- **A colour set as a `CGColor` keeps its appearance.**
  `NSColor.separatorColor.cgColor` resolved once at creation stayed the
  light colour and vanished in dark mode (29,30,30 on 32,33,33, measured
  on the old list border); resolve it in `updateLayer`, as
  `SettingsListContainerView` does for its fill and its Increase Contrast
  border (54,55,55 for the old border once fixed).[^task-189]
- **Measure, do not eyeball.** Log `convert(bounds, to: nil)` gaps and
  search the log for "Unable to simultaneously satisfy".[^layout-notes]
  See [AppKit gotchas](../platform/appkit-gotchas.md).
- **Capturing the window**: `cacheDisplay` works in light mode; after
  forcing a dark appearance the window background rendered transparent in
  captures.[^layout-notes] The TASK-189 harness shoots the window with
  `screencapture -l <windowNumber>` from a watcher instead. See
  [in-process UI automation](../playbooks/in-process-ui-automation.md).
- **Driving and measuring the window at runtime.** Posted
  `leftMouseDown/Dragged/Up` events at the window's bottom edge (y = 1)
  resize it as a person's drag does, and respect `contentMin/MaxSize`. An
  animated resize cannot be sampled from a main-thread timer;
  `CGWindowListCopyWindowInfo` on a background thread sees every
  frame.[^survey-harness]
- **Scroll-wheel events for a harness: leave out the gesture phases.** A
  `CGEvent` scroll with `.began`/`.changed`/`.ended` phases, turned into an
  `NSEvent` and handed to the hit view's `scrollWheel(with:)`, left a
  column whose content fits overscrolled by 400 pt (the rubber band never
  sprang back); a phase-less event (a mouse wheel's) scrolls and clamps as
  a person's would.[^task211-harness]
- **A shell-launched instance never becomes the key app**, so anything
  that depends on `NSApp.keyWindow` cannot be driven that way.[^layout-notes]
- **Accessibility presses are not clicks.** TASK-338's runtime checks
  pressed every control through Accessibility; real mouse clicks on the
  mini switch, the recorder and the pop-up were not tried.[^task-338]

# Related

- [Settings window height](./settings-window-height.md) - the bounds, bottom-pin and superseded-animation traps.
- [AppKit gotchas](../platform/appkit-gotchas.md) - the same traps in general form.
- [In-process UI automation](../playbooks/in-process-ui-automation.md) - driving the app from inside.
- [UI probes](../playbooks/ui-probes.md) - Accessibility readers and capture recipes.

[^layout-notes]: Settings pane layout lessons
[^task-189]: TASK-189
[^task-338]: TASK-338
[^survey-harness]: TASK-189 survey harness
[^task211-harness]: TASK-211 harness
[^capture-tests]: SettingsCaptureHarnessTests.swift
