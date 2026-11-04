---
id: TASK-189
title: >-
  Settings: fix the window's spacing and clipping (controls cut off, uneven
  gaps)
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:27'
updated_date: '2026-10-25 03:05'
labels:
  - settings
  - ui
  - bug
dependencies: []
priority: medium
ordinal: 216000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-24: the Settings window is janky: inconsistent spacing, things getting cut off.

What the code and wiki already say (wiki/features/settings.md, Gotchas):
- The window is not resizable (740 wide) and every pane hard-codes its own height in `preferredContentSize` (General 120, Spaces 400, Profiles 580, Extensions 640, Content Blocking 300); `switchToPane` sizes the window to that number, not to the content.
- **A pane that overflows does not scroll** as a whole. On Extensions, an overflowing detail column squeezes the permissions scroll view (low compression resistance). Profiles shows and hides rows by state (Private note, archive row, isolation warning, custom user-agent field and preview, extension switches, external apps), so its real height varies while the pane's height does not.
- `NSStackView.edgeInsets` on the cross axis are soft (hugging priority only), so bottom insets collapse in a height-constrained column; `NSBox` does not grow to an Auto Layout content view's fitting height.
- Spacing is set per pane, with no shared metrics.

Plan:
1. **Survey at runtime first** (harness, isolated profile): capture every pane, light and dark, in the states that change layout: Private vs normal profile, Custom user agent, no / one / many extensions (with long names and many permissions), long space and profile names, content blocking on and off. For each, log the frames (`convert(bounds, to: nil)`) of the rows and the pane edges, and list every clip, overlap and uneven gap. Measure, do not eyeball (wiki/playbooks/ui-probes.md).
2. **Shared layout rules**: one set of spacing metrics (pane margins, section gap, row gap, label column width), each pane's content in a scroll view or sized from its fitting height, and the window height derived from the content (capped to the screen, scrolling beyond that). Decide whether the window becomes resizable.
3. **Fix pane by pane**, re-running the survey; before/after captures go in the task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every pane was captured in the listed states before the change, with each clipping and spacing defect listed in the task
- [x] #2 No control is clipped or overlapped in any surveyed state, light or dark; a pane taller than the window scrolls
- [x] #3 All panes use shared spacing metrics; the window's height follows the pane's content (decision on resizing recorded)
- [x] #4 After captures for every pane and state are attached to the task; the wiki's Settings page is updated
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Phase 1 survey (2026-10-24, docs/harness/task189-survey-harness.patch; 19 states x light/dark, 38 captures, frames measured, screen unlocked). Defects:
1. Extensions, long extension name: window grows to 1104 wide (detail header name label won't truncate).
2. Profiles, extension switches with a long name: window grows to 1008 wide.
3. Extensions, pending-permissions banner: content 688 instead of 640; permissions list squeezed to 96 (holds 124).
4. Profiles, custom UA + isolation warning: right column overflows 68 pt, UA preview cut by 36 pt, External apps out of sight, no visible scroller.
5. Profiles with extensions / everything: overflow 391 / 467 pt (extension box 402 tall); list has 8 pt above and 0 below.
6. Spaces and Profiles: every label sits 4 pt above its control's text.
7. Spaces list, long profile name: space name squeezed to 4 pt (needs 447), profile name cut without ellipsis; ambiguous compression resistance.
8. Profiles list, long name: cut without ellipsis, runs into '7 Spaces' (147 wide, needs 360).
9. Dark mode, all three lists: border colour resolved once at creation, invisible in dark (29,30,30 on 32,33,33).
10. Profiles: help text uses the full 12 pt row gap, detached from its control.
11. Profiles and Spaces: detail column starts 8 pt below the list.
12. Spaces, long profile name: Profile pop-up stretches to a 29 pt right margin (others 20).
13. Spaces, 19 spaces: selection scrolled out of view.
14. General: bottom gap 52 vs top 20.
15. Extensions none/one: mostly empty; a one-line permissions list in a 287-tall box.
16. Content Blocking: 28 pt of empty striped rows; toggling blocking doesn't change the pane.
No control overlaps; no constraint conflicts from the Settings window.

Spacing today: pane heights 120/400/580/640/300; margins 20 (General bottom 52); row gaps 8/12/12/12 (4 and 6 in places)/12; label columns 43 (Spaces) and 124 (Profiles), none in Extensions; Extensions list rows 32 vs 28 elsewhere.

Proposal: SettingsMetrics (20 margins/sections, 12 description->body, 10 rows, 4 control->help, 8 label->control, first-baseline alignment, one 124 label column, lists 220 x 28); pane = fixed description + scroll view, window height = natural content height (pure, tested rule: natural, then minimum ~400 for list panes, then cap at screen height - 80), content pinned to the scroll view's width so it never widens the window; panes report height changes and the window animates keeping its top edge. Structural: Extensions detail column in one scroll view (inner permissions scroll becomes a plain list), truncating header; Profiles truncating extension rows and self-sizing bordered views instead of NSBox; appearance-following list borders; list name labels truncate first; Spaces scrolls to selection and caps the pop-up width. Contact sheets: scratchpad task189/survey/sheets/.

Decisions (user, 2026-10-24): the window becomes resizable in height only (width stays 740); it opens at the pane's natural height capped to the screen, and can be dragged between the pane's minimum and that height. Profiles settings are grouped into titled sections. Plan: implement in two commits: (1) SettingsMetrics, the height rule and window plumbing, General, Content Blocking, Spaces; (2) Profiles with sections, Extensions restructure. Re-run the survey harness after each.

Part 1 built (2026-10-24, Opus subagent): SettingsMetrics (width 740; margins/sections/list-to-detail 20; description->body 12; rows 10; control->help 4; label->control 8; label column 124; field and pop-up cap 260; lists 220 x 28 rows, 24 pt buttons, 29 pt bar; list-pane minimum 400; screen margin 80; cap floor 200). Pure SettingsPaneHeight.fit(natural:minimum:screenUsableHeight:chromeHeight:) -> (initial, minHeight, maxHeight) with cap = max(screen - chrome - 80, 200), initial = max = min(max(natural, minimum), cap), min = min(minimum, cap); refit(current:from:to:) keeps a dragged height clamped, follows when at full height. SettingsPaneViewController: fixed description + scroll view whose document is pinned to its width (content can't widen the window); panes call contentHeightDidChange() (coalesced). Window: titled/closable/resizable, contentMin/MaxSize width 740, no full screen or tabbing; re-fits on pane switch (no stored height), NSWindow.didChangeScreenNotification and NSApplication.didChangeScreenParametersNotification using the window's own screen's visibleFrame; animated with the top edge kept. Small displays (user question): cap from the window's own screen, minimum clamped to the cap (tests for 600 and 520 pt screens), re-fit on screen change.

Fixed in part 1: 14 (General 120 -> 90, bottom 52 -> 20), 16 (Content Blocking table sized to its rows, pane 300 -> 243), 6/7/11/12/13 (Spaces: labels aligned, names truncate with ellipsis - the space name gives way first, profile name capped at 40% - detail column level with the list, pop-up 260, selection visible), 9 (dark list border difference 3 -> 22, all lists). Profiles and Extensions moved into the container: width stays 740 in every state (1, 2), the pending banner no longer squeezes the permissions list (3), overflow scrolls as a whole pane (4, 5). Left for part 2: 8, 10, 15, Profiles grid gaps/labels/NSBoxes/sections, Extensions 32 pt rows and inner list.

TDD: SettingsPaneHeightTests red 13 of 15 failing, green 15/15; 5 small-screen tests added later passed first time (the rule already clamped); 20/20.

/code-review --fix: 8 findings, 5 fixed: the empty extensions state kept the last detail column in the view tree, so the window stayed tall; re-selecting the shown pane threw away a dragged height; NSTableView.allRowsHeight shared by four panes; Profiles/Extensions use SettingsMetrics button/row sizes; a duplicate contentHeightDidChange. Skipped: labels' preferredMaxLayoutWidth assumes overlay scrollers (legacy 'always show' scrollers could cut a wrapped line; part 2), a nested NSScrollView in Content Blocking possibly eating scroll-wheel events when capped (unconfirmed), Spaces re-scrolling to the selection on a screen-parameter refit (minor).

Tests after review: 96/96 (SettingsPaneHeightTests 20, ExtensionOptionsPageEntryTests, ContentBlockerWhitelistTests, ExternalAppPermissionTests, TabStoreTests). No existing tests reference the Settings view controllers.

Runtime (docs/harness/task189-survey-harness.patch, 25 states x light/dark, 50 captures; re-run after the review with the virtual 1000 pt display: analysis identical apart from view ids, path lengths and animation timing samples): opens at natural height; bottom-edge drags clamp to 400-628 on Spaces, side drags leave 740; a pane switch drops a dragged height; switches animate with the top edge kept; a 600 pt screen caps panes at 432 and Profiles/Extensions scroll; moving Settings onto the 1000 pt virtual display caps Profiles at 832 and back restores 944. Sheets: scratchpad task189/part1/after/sheets. Not verified: a real mouse drag, the zoom button (goes to max height), legacy always-show scrollers, the empty-after-uninstall refit at runtime (the survey's 'none' state never had an extension).

Part 2 built (2026-10-24, Opus subagent): pure ProfileSettingsLayout (section/row enums, state, which rows and sections show, space above each row) replaces gridView.row(at: N) addressing; Profiles is one grid per section: (untitled) Name + Private note; Search; Tabs (archive, sleep, per-tab isolation + its warning); Content Blocking ('Block content' + filter-list group); Extensions (switch group; kept in Private when any extension is installed, as its Allow-in-Private opt-in); User Agent ('Identify as', custom string, preview); External Apps ('Saved permissions: None / N [Clear]', hidden in Private). Row labels no longer repeat the section title. New shared views: SettingsBorderedView (border set in updateLayer, follows appearance; SettingsListContainerView subclasses it), SettingsGroupBoxView (self-sizing bordered group replacing both NSBoxes; switchRow helper shared by Profiles and Extensions), SettingsWrappingLabel (wrap width from its own width in setFrameSize, refits the pane when it changes; fixes the legacy-scroller cut), NSTextField.settingsSectionTitle (12 pt semibold). Extensions: one column stack in the pane's scroll view, no inner permissions scroll view (96 pt floor gone), 28 pt rows, truncating header, Uninstall last, a permission-less extension shows one line instead of a box. General's section title now uses the shared title and 8 pt title gap (review follow-up).

Defects after part 2: 3 (banner: no inner scroll, group holds all 6 rows), 4 (natural 775, no clip, help 4 pt below), 5 (natural 1152/1218, groups sized to rows), 6 Profiles (labels 0.0 off their controls, -0.5 on pop-ups), 8 (list name truncates with an ellipsis), 10 (help gap 12 -> 4), 15 (no empty boxes; one permission = a 32 pt group). Width 740 in every state; no hard clips; no overlaps beyond the analyzer's known false positives; no constraint conflicts from Settings; group borders in dark 54 on 32.

TDD: ProfileSettingsLayoutTests red 14 of 15 failing, green 15/15.

/code-review --fix (part 2): no correctness bugs; 4 fixed (Profiles labels truncate instead of clipping at the 124 pt column; one shared switchRow helper, removing a force cast on subview order; the banner's inset/gap declared once; SettingsWrappingLabel takes a weight). Skipped: replacing per-label wrap estimates/refit callbacks with one pane-level width check (redesign), makeSection choosing grid placement by control type (works as verified; data-driven placement would be cleaner). General's 13 pt title fixed by hand afterwards.

Tests after review: 128/128 (SettingsPaneHeightTests 20, ProfileSettingsLayoutTests 15, TabStoreTests 40, ExtensionOptionsPageEntryTests, ContentBlockerWhitelistTests, ExternalAppPermissionStoreTests, ExternalAppLaunchPolicyTests).

Runtime (docs/harness/task189-survey-harness.patch; 27 states x light/dark, 54 captures; final run after the review with the 1000 pt virtual display, analysis identical to the pre-review run except General 90 -> 87 and a 1 pt window origin shift): uninstalling the only extension through the pane's own button shrinks the window 905 -> 400 to the empty state; a full run with -AppleShowScrollBars Always: clip 723 wide, wrapped labels take it, nothing cut; caps 600 pt -> 432, 1000 pt display -> 832, restore 1092. After sheets: scratchpad task189/part2/after/sheets (profiles-before-after.png, extensions-before-after.png), legacy/sheets. Not verified: a real mouse drag; every capture by eye (about four read directly, the rest by measurement).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings window: one SettingsMetrics for spacing, every pane in a container sized to its content (capped to its own screen, scrolling beyond, re-fit on pane and screen changes), height-only resizing at a fixed 740 width; Profiles in titled sections with self-sizing groups; Extensions as one scrolling column with no nested scroll view; long names truncate instead of widening the window; labels aligned; list and group borders follow dark mode. All 16 surveyed defects fixed and re-measured in light, dark, short screens and always-on scrollers; 128 tests pass.
<!-- SECTION:FINAL_SUMMARY:END -->
