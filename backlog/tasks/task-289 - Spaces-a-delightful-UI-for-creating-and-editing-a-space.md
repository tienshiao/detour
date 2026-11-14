---
id: TASK-289
title: 'Spaces: a delightful UI for creating and editing a space'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-07T10:12:00Z'
updated_date: '2026-11-14T00:37:00Z'
labels:
  - spaces
  - ui
  - design
dependencies: []
references:
  - Detour/Browser/Settings/SpacesSettingsViewController.swift
  - Detour/Browser/Sidebar/TabSidebarViewController.swift
  - Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
priority: medium
type: feature
ordinal: 336000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-07: the current UI is functional but "very boring and uninspired", "lacks whimsy and doesn't impress".

Today, as of 2026-11-07:
- **Starting a space:** the sidebar's + (`addSpaceClicked` → `tabSidebarDidRequestAddSpace`) and a space's "Edit Space…" menu item both just open Settings > Spaces (`SettingsWindowController.showSpacesPane`). You leave the window you were in to make or change a space.
- **Adding:** the pane's + immediately creates a space named "Space" with ⭐️, the first preset color and the first profile (`SpacesSettingsViewController.addSpaceClicked`). There is no moment of choosing anything before it exists.
- **Editing:** a plain label/field grid: a Name field, an Emoji button that opens the system character picker, a Profile pop-up and an expanded `NSColorWell`. Nothing shows what the space will look like (its tint, its header, its icon in the space switcher) while you change it.

A space is the most personal object in the browser (its name, emoji and color tint the whole sidebar), so creating one should feel like an occasion. References worth looking at: Arc's space creation (theme picker with live gradient, emoji grid), macOS Focus mode and Home app room setup, Apple's Freeform and Journal onboarding moments.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Before building, two or three design directions (sketches or mockups) are shown to the user and one is chosen; the choice and the rejected directions are recorded in the task
- [x] #2 Creating a space starts from the sidebar in the current window and lets the user pick name, emoji, color and profile before the space exists; cancelling creates nothing
- [x] #3 Editing a space from the sidebar happens in the same window, and every change previews live on the real sidebar (tint, header, switcher icon) before or as it is applied; undo still undoes the edit as one action
- [x] #4 Emoji and color are chosen from curated, good-looking options (with a way to reach any emoji and any color), not only the system picker and a raw color well
- [ ] #5 The flow has at least one moment of delight (for example the new space arriving with an animation, or the sidebar re-tinting as colors are tried), and honours Reduce Motion
- [x] #6 Fully usable from the keyboard and with VoiceOver; looks right in light and dark mode
- [x] #7 Settings > Spaces stays consistent with the new flow (shares its controls or opens it) rather than keeping a second, older editor
- [x] #8 Rule logic (defaults for a new space, name validation, preset lists) has tests; the UI is checked at runtime with /verify in light and dark, with captures attached to the task notes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Direction A: the sidebar becomes the editor.
1. Pure rules in Detour/Browser/Spaces/SpaceAppearance.swift: 11 curated colour presets (replacing Space.presetColors) and 18 curated emoji with spoken names; SpaceDraft (name, emoji, colorHex, profileID); defaults for a new space (the first preset colour and emoji no space uses yet, the active space's profile); the name rule (trimmed, single line, 64 characters at most, blank refused); the emoji suggested by a typed name until one is picked; the bottom strip's entries with a draft (a waiting new space appended, or an edited space's look replaced).
2. SpaceChoiceGridView: one focusable grid for colours or emoji. Arrow keys move the selection (radio-group semantics for VoiceOver), hovering reports the colour under the pointer, and a trailing Custom… / All Emoji… cell.
3. SpaceEditorView: an emoji tile, a name field, Color, Icon, a Profile pop-up, then Cancel and Create Space (Done when editing). Return commits, Escape cancels.
4. TabSidebarViewController: beginSpaceEditor(create or edit). The page strip slides out and the editor slides in below the address bar. The sidebar tint follows the draft (and the hovered colour) through a preview override. The bottom strip shows the waiting space, or the edited space's new look. Swipes are blocked while it is open. It cancels if the active space changes or the edited space disappears. Focus goes back to the page on close. Reduce Motion gives a fade instead of a slide or pop.
5. BrowserWindowController: + and Edit Space… open the editor. Create = TabStore.addSpace (one Add Space undo) + setActiveSpace, and the new switcher button pops in. Done = one updateSpace (one Edit Space undo), with the existing profile-change confirmation. A hover-revealed sidebar is held open while the editor is up.
6. Settings › Spaces: colour and emoji use the shared grids instead of the colour well and the emoji button; + opens the sidebar editor in the frontmost browser window.
7. Tests: SpaceAppearanceTests (presets, defaults, name rule, suggestions, strip entries).
8. /verify in light and dark (create, cancel, edit, keyboard, VoiceOver labels), captures in the notes; wiki page; /code-review --fix; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-13: AC #1 in progress. Three interactive directions on a design canvas (https://claude.ai/artifact/5pLjj2mYtcKc4KovhY1cP5): A, the sidebar becomes the editor (in place, Arc-like); B, a popover from the space switcher with the real sidebar previewing behind it; C, a sheet with a stage (big emoji on its colour, plus Shuffle). Shared by all three: 11 curated colours plus Custom…, 18 curated emoji plus All Emoji…, the name suggests an emoji until one is picked, Cancel creates nothing, and the new switcher button pops in. Waiting for the user to choose.

2026-11-13: The user chose direction A, the sidebar becomes the editor. Rejected: B, the popover from the switcher (it covers the page and feels like a utility), and C, the sheet with a stage (modal, the most code, two previews that can drift). C's Shuffle is not part of the choice.

2026-11-13: Implemented direction A (uncommitted).
- New: Detour/Browser/Spaces/SpaceAppearance.swift (presets, SpaceDraft, name rule, emoji suggestion, switcher entries), SpaceChoiceGridView.swift (shared colour/emoji grid, radio group), SpaceEditorView.swift (the in-sidebar editor).
- Sidebar: beginSpaceEditor / endSpaceEditor; a preview tint overrides the window's tint while open; the switcher builds from SpaceEditorPreview.stripEntries (a waiting button for a new space, an edited space's new look); swipes blocked; closes on a space switch or if the edited space disappears; the new space's switcher button pops in (a fade with Reduce Motion).
- Window: + / Edit Space… open the editor (a hidden sidebar is shown first); Create = addSpace + setActiveSpace; Done = one updateSpace; the editor holds a hover-revealed sidebar open. Profile change: an inline note instead of the Settings alert.
- Settings › Spaces: the colour well and emoji button are replaced by the shared grids (+ All Emoji…); + opens the sidebar editor in the frontmost normal window (with none open, it makes a space with the editor's defaults).
- Space.presetColors is now the 11 curated colours (the Arc import's fallback colours follow).
Tests: SpaceAppearanceTests 19/19; with the sidebar, settings, space and Arc import suites, 320 tests, 0 failures.
Runtime (DETOUR_DATA_DIR=DetourVerify289a; keys posted to the pid, clicks via System Events):
- + opened the editor; the tint followed the draft; the switcher showed the waiting 💼.
- Typing 'Reading' suggested 📚. Clicking Grape re-tinted. Tab went into the colour grid; the arrows moved the selection and the focus ring.
- Return created Reading 📚 Indigo (DB), switched the window to it, and the button popped in.
- Edit Space… from the button's menu showed Done. Library + Sage previewed live; Done saved them; Cmd+Z restored Reading + Indigo in one step.
- + then Escape created nothing (2 spaces).
- Dark mode capture OK (Night owl → 🌙).
- Settings › Spaces shows the grids (a non-preset colour sits in the custom swatch); its + opened the editor in the browser window.
- AX tree: a 'New Space' group, the 'Space name' field, Color/Icon radio groups with named radio buttons and 1/0 values, and the Profile pop-up.
Not checked at runtime: hover re-tint (it needs the real pointer; the user was using the machine); Custom Color… panel; All Emoji… popover; a hover-revealed (auto-hidden) sidebar; Reduce Motion; VoiceOver speech itself (only the AX tree).
Captures: docs/task-289/ (create-light, keyboard-color-grid, created, edit-preview, create-dark, settings-spaces).

2026-11-13: The user found Create/Done anti-climactic. Added SpaceCelebration (Detour/Browser/Sidebar/SpaceCelebration.swift):
- The editor's emoji lifts off its tile and flies in an arc into the space's switcher button (hidden until it lands), which pops.
- A soft ripple of the space's colour spreads over the sidebar, and a small ring of dots sparkles around the button. Done gets the same, with a smaller ring, and only when something changed.
- Reduce Motion: the button fades in; nothing flies.
A first version threw confetti (with the space's emoji); the user found it too much, so it became the sparkle ring.
Runtime: Create captured frame by frame (docs/task-289/create-celebration-frames.png). Clicks were AXPress, keys were posted to the pid, so the user's pointer was untouched. Not captured: the flight itself (too quick for screencapture), the edit version, and Reduce Motion.

2026-11-13: Flight reworked twice on user feedback.
- The quadratic arc (control point halfway up the drop, 70 pt to the side) landed only ~8° off vertical. Its ease-out timing also slowed the emoji into the button, which reads as floaty.
- The user asked whether something physics-based would look more natural. The flight is now a real toss (SpaceFlightPath.toss): a 50 pt hop, then constant gravity (6000 pt/s²) and constant sideways speed. Positions are sampled at 60 fps and played linearly, so a sidebar-tall fall takes ~0.7 s and speeds up into the landing.
- The button catches it with a CASpringAnimation squash (1.35×0.65 → rest; stiffness 420, damping 11). The emoji turns a little the way it travels.
- A cubic-Bézier sweep was written in between and dropped for the toss.
Tests: SpaceFlightPathTests 8/8 (start/end, hop height and ceiling clamp, accelerating fall, constant sideways speed, duration, flipped). With SpaceAppearanceTests: 27, 0 failures.
Runtime: the flight was recorded with screencapture -v and split with ffmpeg; docs/task-289/create-toss-frames.png shows the hop, the accelerating fall and the catch.

2026-11-13: The user asked for less hop or none. The default hop is now 16 pt (from 50); a sidebar-tall toss takes ~0.64 s, and ~0.57 s with no hop. Zero hop is handled: no apex keyframe; the emoji only shrinks on the way down. The Debug build reads SpaceTossHop / SpaceTossGravity from the data directory's defaults suite, to tune without a rebuild; release always uses the defaults. Tests: SpaceFlightPathTests 10/10 (+ no hop, stronger gravity), with SpaceAppearanceTests 29, 0 failures. Runtime: both recorded (docs/task-289/create-toss-frames.png at 16 pt, create-toss-no-hop-frames.png at 0).

2026-11-13: The default hop is now 8 pt, at the user's choice; SpaceFlightPathTests 10/10.

2026-11-14: /code-review --fix found 9 issues and fixed all of them:
- Settings + with no normal window selected the old last row (a shadowed local).
- The colour panel had no single owner and was not released when the editor's window closed (now SpaceColorPanel).
- Show Archived Tabs did not close the editor.
- currentSpaceButtonIndex built the switcher entries every strip frame.
- Every colour-panel tick recreated every grid cell.
- The edit celebration compared the raw draft (a spacing-only edit celebrated).
- Duplicate colour-choice code in Settings.
- Settings ignored SpaceNameRule.
- A clamped toss jumped onto the button in its last frame.
Left as is (noted by the review): while the editor is open, each keystroke rebuilds the switcher buttons; fixing that means restructuring the switcher, outside this change.
Tests after the fixes: 350 across the space, flight, sidebar, settings, Arc import and window-close suites, 0 failures.
Runtime after the fixes (DetourVerify289e/f; AXPress and keys posted to the pid):
- Show Archived Tabs with the editor open closes the editor and shows the archive.
- Edit Space… → rename → Done saved Garden 🏠, with the toss and the edit sparkle (recorded).
- All Emoji… opens the picker popover; choosing 🦊 sets the tile (no grid cell selected).
- Custom… opens the Colors panel (only while Detour is active: AppKit hides it in an inactive app), and Cancel closes it.
Not verified at runtime: Reduce Motion (needs the system setting); VoiceOver speech (the AX tree was checked); hover re-tint with a real pointer.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Spaces are now made and edited in the window's own sidebar (design direction A, chosen from three on 2026-11-13).
- **The editor:** + and Edit Space… open SpaceEditorView in place of the page area. It has an emoji tile and a name field, 11 curated colours plus Custom…, 18 curated emoji plus All Emoji…, a Profile pop-up, and Cancel / Create Space (Done when editing).
- **Live preview:** the real sidebar previews the draft. The tint follows the chosen or hovered colour, and the switcher shows the waiting new space or the edited space's new emoji. A typed name suggests an emoji until one is picked.
- **Committing:** Create Space is one Add Space undo and switches the window to the new space. Done is one Edit Space undo. Cancel and Escape change nothing.
- **Celebration:** the emoji is tossed under real gravity (8 pt hop, 6000 pt/s²) into its switcher button. The button catches it with a spring; a colour ripple and a small dot sparkle follow. Reduce Motion: a fade only.
- **Settings › Spaces:** shares the colour and emoji grids (SpaceChoiceGridView, a radio group for VoiceOver), and its + opens the sidebar editor.
- **Rules:** pure and tested in SpaceAppearance (presets, defaults, name rule, suggestions, switcher entries) and SpaceFlightPath (the toss).
Tests: 350 across the space, flight, sidebar, settings, Arc import and window-close suites, 0 failures. /code-review --fix: 9 findings, all fixed.
Runtime: create, cancel, edit + undo, keyboard, dark mode, Settings, AX tree, All Emoji…, Custom…, archive interplay, and the create and done celebrations (recorded); captures in docs/task-289/.
Not verified at runtime: Reduce Motion, VoiceOver speech, hover re-tint with a real pointer.
Follow-up: TASK-324 (the download animation shares the toss and starts at the click). Noted: the switcher rebuilds its buttons on each keystroke while the editor is open.
<!-- SECTION:FINAL_SUMMARY:END -->
