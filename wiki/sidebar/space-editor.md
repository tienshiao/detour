---
type: Feature
title: Space editor
description: "Making and editing a space in the sidebar itself: the editor that replaces the page area, the draft it previews on the real tint and switcher, the curated colours and emoji, and the toss-and-catch moment on Create Space / Done."
tags: [sidebar, spaces, animation, accessibility]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T01:09:15Z }
sources:
  - id: appearance
    resource: ../../Detour/Browser/Spaces/SpaceAppearance.swift
    title: SpaceAppearance.swift (presets, SpaceDraft, name rule, emoji suggestion, switcher entries)
  - id: grid
    resource: ../../Detour/Browser/Spaces/SpaceChoiceGridView.swift
    title: SpaceChoiceGridView.swift
  - id: editor
    resource: ../../Detour/Browser/Spaces/SpaceEditorView.swift
    title: SpaceEditorView.swift
  - id: celebration
    resource: ../../Detour/Browser/Sidebar/SpaceCelebration.swift
    title: SpaceCelebration.swift (the ripple, the sparkle; the toss is shared, Toss.swift)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (Space editor section)
  - id: window-sidebar
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift (create / edit)
  - id: settings
    resource: ../../Detour/Browser/Settings/SpacesSettingsViewController.swift
    title: SpacesSettingsViewController.swift
  - id: tests-appearance
    resource: ../../DetourTests/SpaceAppearanceTests.swift
    title: SpaceAppearanceTests.swift
  - id: tests-flight
    resource: ../../DetourTests/TossPathTests.swift
    title: TossPathTests.swift
  - id: task-289
    resource: backlog:TASK-289
    title: "Spaces: a delightful UI for creating and editing a space"
  - id: task-324
    resource: backlog:TASK-324
    title: The download animation shares the toss and starts at the triggering click
---

# What it does

The sidebar's **+** and a space button's **Edit Space…** open the space
editor in the window's own sidebar (before TASK-289 both opened Settings ›
Spaces). The page area gives way to the editor: an emoji tile and a name
field where the space header goes, then **Color** (11 curated colours and
Custom…), **Icon** (18 curated emoji and All Emoji…), **Profile**, and
Cancel / Create Space (Done when editing). Nothing exists or changes in
`TabStore` until Create Space or Done; Cancel and Escape leave everything as
it was.

While the editor is open the real sidebar previews the draft: the tint
follows the chosen colour (and the colour under the pointer), and the
switcher shows the new space waiting at the end of the row, or the edited
space with its new emoji. Typing a name suggests an emoji ("Reading" → 📚)
until the user picks one.

Create Space adds the space (one Add Space undo) and switches the window to
it; Done saves name, emoji, colour and profile in one `updateSpace` (one Edit
Space undo). Then the emoji is tossed into its switcher button (below).

The design was chosen from three directions shown to the user on
2026-11-13: A, the sidebar becomes the editor (chosen); B, a popover from the
switcher (it covers the page and feels like a utility); C, a sheet with a
stage (modal, the most code, two previews that can drift).[^task-289]

# How it works

| Piece | Role |
|---|---|
| `SpaceDraft` | Name, emoji, colour, profile being chosen. `forNewSpace` takes the first preset colour and emoji no space uses (least used, earliest first, once all are taken) and the window's profile. `setName(_:emojiPickedByUser:)` applies the suggestion. |
| `SpaceNameRule` | One line, trimmed, 64 characters at most (whole characters: a flag is never cut); blank is refused, so Create / Done stay disabled. |
| `SpaceEmojiSuggestion` | First word of the name that matches a keyword; short keys (`art`, `cat`, `pet`, `lab`…) only as whole words. |
| `SpaceEditorPreview` | `.creating(draft)` or `.editing(spaceID:, draft)`. `stripEntries` gives the switcher row with the draft in it; `highlightedIndex` keeps the highlight on that button. |
| `SpaceChoiceGridView` | The colour and emoji grids, shared with Settings › Spaces. One keyboard stop: arrows move the selection (selection follows focus, except onto Custom…), Space activates. VoiceOver sees a radio group of named radio buttons with 1/0 values. Hover reports the colour under the pointer. |
| `SpaceEditorView` | The editor itself; reports every change through `onChange`, commits through `onCommit`. Return commits, Escape cancels (`control(_:textView:doCommandBy:)` in the name field, `keyDown` / `cancelOperation` elsewhere). |
| `TabSidebarViewController` | `beginSpaceEditor` / `endSpaceEditor`. The editor sits over the page clip below the address bar; the page strip fades out and is hidden. `previewTintColor` wins over the window's `tintColor` while open, so a store update cannot undo the preview. The switcher builds from `spaceStripEntries`. |
| `BrowserWindowController` | `beginCreatingSpace` / `beginEditingSpace` (a collapsed sidebar is shown first); the create and edit delegate calls; the editor holds a hover-revealed sidebar open like a popover (`refreshSidebarPopoverHold`). |

Settings › Spaces uses the same grids for colour and emoji, and its **+**
opens the editor in the frontmost normal browser window (with none open, it
makes a space with the editor's defaults). Changing the profile in the
sidebar editor shows a note under the pop-up instead of the Settings pane's
alert.

## Create Space / Done: toss and catch

`SpaceCelebration` runs in a click-through overlay over the sidebar:

1. The emoji leaves the editor's tile (its frame is taken before the editor
   closes) and is **tossed**: `TossPath.toss` (shared with downloads since
   TASK-324, `Toss.swift`) is a real parabola, a
   hop of 8 pt then constant gravity (6000 pt/s²) and constant sideways
   speed, sampled at 60 fps and played linearly. A sidebar-tall fall takes
   about 0.6 s and speeds up into the landing. The emoji shrinks to the
   switcher's size and turns a little the way it travels.
2. The target button stays hidden (`celebratingSpaceID`) until the emoji
   lands, then is **caught** with `SpringCatch` (a `CASpringAnimation`): squashed 1.35 × 0.65,
   springing back through a small overshoot.
3. A soft ripple of the space's colour spreads over the sidebar from the
   button, and a ring of six to eight dots sparkles around it.

Done celebrates only when something changed. With Reduce Motion nothing
flies: the button fades in. A Debug build reads `SpaceTossHop` and
`SpaceTossGravity` from the data directory's defaults suite, to tune the feel
without a rebuild.

What the feel went through with the user, 2026-11-13:[^task-289]

| Tried | Why it went |
|---|---|
| Fade only | "A little anti-climactic." |
| Confetti from the button (with the space's emoji) | "A bit much"; became the dot sparkle. |
| Quadratic Bézier arc, eased out | Landed ~8° off vertical, and slowing into the button read as floaty. |
| Cubic Bézier sweep | Replaced before shipping by physics, at the user's suggestion. |
| Toss with a 50 pt hop, then 16 pt | Read as thrown up; the user chose 8 pt. |

The download animation shares this toss and catch since TASK-324 ([downloads](../features/downloads.md)).[^task-324]

# Edge cases

- Another space becoming active in the window (a click on a space button,
  a keyboard space switch) ends the editor without changes; so does the
  edited space disappearing (deleted elsewhere).
- Swipes are ignored while the editor is open; the archive page is
  dismissed when it opens.
- Clicking the waiting new space's button focuses the name field.
- A colour that is no preset (an older space's, or Custom…) shows in the
  custom swatch with the colour in its middle.
- `Space.presetColors` is now the curated list, so the Arc import's
  fallback colours follow it.

# Tests

- `SpaceAppearanceTests`: presets (valid, unique, named), new-space
  defaults including wraparound, the name rule (trim, one line, length by
  character, blank), suggestions (first word, whole-word short keys,
  diacritics), the suggestion stopping once an emoji is picked, and the
  switcher entries for create, edit, a vanished space and no editor.
- `TossPathTests`: the toss starts and ends on its points, hops and
  stays below the sidebar's top, speeds up while falling, keeps a constant
  sideways speed, takes under a second for a sidebar-tall fall, mirrors in a
  flipped space, and falls from rest with no hop.
- The views and the animation are checked at runtime (TASK-289 notes and
  `docs/task-289/`).

# Related

- [Sidebar space paging](./space-paging.md) — the page strip the editor
  replaces while open, and the switcher it previews on.
- [Sidebar visibility and auto-hide](./visibility-and-auto-hide.md) — the
  hold that keeps a hover-revealed sidebar open while the editor is up.
- [Keyboard focus](./keyboard-focus.md) — the editor takes the keyboard
  while open and hands it back to the page on close.
- [Profiles and spaces](../architecture/profiles-and-spaces.md) — what a
  space is, and what changing its profile does to its tabs.

[^task-289]: TASK-289
[^task-324]: TASK-324
