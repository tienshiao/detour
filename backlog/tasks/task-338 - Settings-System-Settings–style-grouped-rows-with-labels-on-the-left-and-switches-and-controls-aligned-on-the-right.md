---
id: TASK-338
title: >-
  Settings: System Settings–style grouped rows, with labels on the left and
  switches and controls aligned on the right
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T02:08:00Z'
updated_date: '2026-11-15T04:43:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - TASK-328
  - TASK-336
  - TASK-292.11
  - Detour/Browser/Settings/SettingsPaneViewController.swift
  - Detour/Browser/Settings/SettingsMetrics.swift
  - Detour/Browser/Settings/ProfileSettingsLayout.swift
  - wiki/features/settings.md
priority: medium
type: feature
ordinal: 413000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user after TASK-328, with a screenshot of macOS System Settings (Apple Intelligence & Siri) as the reference: "the alignment of the switches and organization of some of the settings can still be improved ... rows and the toggles being placed on the right side".

The reference layout: a bold section header above a rounded, inset group box. Inside it, one row per setting, separated by hairlines; the setting's name sits on the left and its control on the right (switch, pop-up, value plus button). Explanatory text sits under the name inside the row, in secondary text, with "Learn more…" style links. A footnote can close the group, and buttons that act on the whole group sit below it on the right.

Today (after TASK-328) General and Quick Detour put a sentence-length label and then a switch right after it, so the switches do not line up across rows. Help text sits outside any group. Profiles uses a right-aligned label column with controls after it, plus bordered boxes for filter lists and extensions. The panes do not share one form layout.

The toolbar-tab Settings window stays; only the pane content changes. TASK-336's accessibility naming (the label names its control, read once) and every accessibility identifier must survive. So must TASK-292.11's Learn more links and the automation endpoint's restrictions on the General pane's Automation section (TASK-228.7). The user's reference screenshot is in the lead's scratchpad (not committed: it shows the user's account).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A reusable grouped-form component (section header, inset group, rows with label left and control right, row help text, separators, footnote, trailing buttons) is used by every pane's settings, and pane-specific layout code for those rows is removed
- [x] #2 General, Quick Detour, Search, Links (default browser and routes options), Content Blocking, Shortcuts, Profiles (detail side) and Extensions (detail side) use it; list + detail panes keep their list and use the form on the detail side
- [x] #3 Controls in a group share one right edge; labels share one left edge; long labels and help text wrap without overlapping the control, at the minimum and maximum pane widths
- [x] #4 Light and dark appearance, Increase Contrast and Reduce Transparency look right (captured and checked)
- [x] #5 Accessibility names and identifiers are unchanged (TASK-336 tests pass), Learn more links still open their guide pages, pane heights still fit (SettingsPaneHeight), and the automation endpoint still refuses the Automation section
- [x] #6 Before/after captures of every pane are attached to the task notes for the user to review
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Phase 1 (pilot, user approves before phase 2):
1. New Detour/Browser/Settings/SettingsForm.swift: SettingsFormSection (13 pt semibold header, inset group, footnote row, trailing buttons below on the right), the group view (rounded fill about 3% label tint, hairline separators inset 10 between visible rows, a border under Increase Contrast), SettingsFormRow (title 13 pt and help 11 pt secondary on the left with optional detail lines and Learn more links; accessory on the right: switch (mini, as System Settings), pop-up, value with optional button, shortcut recorder, custom view), SettingsForm (sections 30 pt apart). Metrics measured from a SwiftUI grouped Form rendered on this macOS and from the user's reference screenshot. SettingsSwitchRow/SettingsGroupBoxView unchanged (General, Profiles, Extensions keep them until phase 2).
2. Accessibility built in: a row names its control by its title (or an explicit name, e.g. the recorder's 'Quick Detour shortcut') and takes the title out of the tree (TASK-336 helper generalised); help and status text stay.
3. Convert Quick Detour and Content Blocking; keep every identifier, stored value, dependency and Learn more link.
4. Tests: SettingsFormTests (shared right edge and left edge, wrapping without overlap at 443 and 700 pt, naming read once, row and section heights, cold natural height equals laid-out height); update SettingsSwitchRowTests' Quick Detour cases and the Quick Detour height bound; pure text function for the filter-list rows.
5. Before/after captures (light, dark) of both panes, pixel-probed against the reference; iterate.
6. Wiki settings page + log, backlog notes, code review, commit on followups-a. Stop; task stays In Progress.

Phase 2 (approved 2026-11-14): groundwork in the component (lists drawn as groups, 13 pt titles, 44 pt button rows, header accessory, row enabled/highlight, hidden button rows, SettingsGroupStyle with an Increase Contrast override); General, Spaces detail, Links' Default, Search and Shortcuts lists by the lead; Profiles and Extensions details by a subagent in worktree task-338-pe, cherry-picked; dead code removed; before/after/compare captures of every pane plus Increase Contrast captures from a gated test-host harness; full Settings, automation and TASK-336 suites; code-review medium --fix; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Phase 1 (pilot), 2026-11-14 — the component and two panes; phase 2 (General, Search, Links, Shortcuts, Profiles detail, Extensions detail) waits for the user's approval of the pilot.

Component (Detour/Browser/Settings/SettingsForm.swift): SettingsForm(sections:estimatedWidth:) > SettingsFormSection(title:rows:footnote:buttons:) > SettingsFormGroupView > SettingsFormRow(title:help:accessory:accessibilityName:) or SettingsFormRow(footnote:). Accessories: .toggle (mini switch), .popUp, .button, .value(text, button:), .shortcut, .custom. Rows: setHelp, addDetail (status lines), setWarning (orange triangle line), addLink (Learn more); setHelp/setWarning refit the pane. Panes put a form in their body with formBody(_:). Metrics in SettingsMetrics.form… were measured from a SwiftUI grouped Form rendered on this Mac (macOS 26) and checked against the user's screenshot: 13 pt semibold header 10 pt above the group, sections 30 apart, group fill 3.1% label tint (247 on 255 light, 37 on 30 dark), radius 12, hairline separators inset 10, rows 36 pt (switch) / 38 pt (pop-up), name 13 pt, help 11 pt secondary 3 pt under it, text column 16 pt before the control, buttons 10 pt under the group on its right edge. An AppKit form rendered the same way gave the same header, first-row text, fill, separator colour and corners, drifting by 1 to 2 pt further down (separators overlay the rows instead of taking a pixel; button rows are 38 pt where SwiftUI gives 40 and System Settings about 44, an open difference no pilot row shows); the app captures probe 247/235 light and 40/50 on 33 dark, header cap 23 pt above the group, text 11 pt in, switch 10 pt from the edge, as in the screenshot.

Accessibility (TASK-336 built in): a row names its switch, pop-up, recorder or custom control by its title (or accessibilityName: the recorder keeps 'Quick Detour shortcut') and hides the title; buttons and values keep their own text; the row orders its AX children so the control comes right after its name and before the help (AppKit's subview order read the help first; caught with docs/harness/task336/axsettings.swift in the running app and fixed).

Found: a mini NSSwitch reports 54 x 24 until it is in a window and keeps its first size, so the row reads the real size once from a switch in an unshown window (SettingsFormRow.switchSize) and pins it; NSStackView ignores content hugging (a value and its button stretched). Both in wiki/platform/appkit-gotchas.md.

PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user):
- Mini switches (36 x 16) as System Settings uses; alternative: regular (54 x 24) switches on the right.
- Pop-ups stay the bordered NSPopUpButton: System Settings' borderless value with a round chevron is SwiftUI's private cell, no AppKit API (borderless, every bezel style and macOS 26 border shapes tried); alternative: a custom cell, later.
- Content Blocking's five-column table became one row per list (name; status on the right, Active in green; rules, active rules and last update under the name; total and activity in a footnote; Clear Cache & Redownload and Update All Now under the group); alternative: keep the table inside the group as a custom row.
- Quick Detour has two titled sections, Opening and Closing; the hotkey help was split between the switch row (the launcher) and the Shortcut row (the menu item, 'also when the switch above is off'); alternative: one untitled group with the old paragraph.
- A form starts 20 pt under the pane's Learn more link (12 + 8) so the link does not read as the first section's.

Heights: Quick Detour 457 (was 317), Content Blocking 554 (was 379); both fixed panes.

Tests (DetourTests, -only-testing): SettingsFormTests (13, new), SettingsSwitchRowTests, SettingsPaneColumnsTests, SettingsGuideLinkTests, SettingsPaneHeightTests, TrackingParameterListTests, ProfileSettingsLayoutTests, ShortcutsSettingsPaneTests: 134 tests, 0 failures. Changed: SettingsSwitchRowTests' Quick Detour cases (mini switches, the form's right edge, the Shortcut row right under the switch's, labels found through the form row) with General's assertions unchanged; SettingsPaneColumnsTests' Quick Detour bound (< 600, the form is roomier). Full suite not run (the lead runs it).

Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-338 and -338b, removed afterwards): before and after captures of both panes in light and dark; Accessibility reading of both panes with the TASK-336 reader (every identifier present: quickDetourHotKeyEnabled, quickDetourHotKeyShortcut, quickDetourOptionCommandClick, quickDetourIdleTimeout, learnMore.quick-detour, contentBlockerClearCache, contentBlockerUpdateAll, trackingParameterListEnabled, trackingParameterListStatus, learnMore.content-blocker; switches named, 0 duplicates, 0 unnamed); Update All Now pressed through Accessibility; docs/harness/task337-tracking-list-setting-checks.py ALL PASS on the new pane. Captures: /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/before-*.png, /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/after-*.png, /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/compare-*.png.

Clear Cache & Redownload pressed through Accessibility in a fresh data directory (DetourVerify-338c, removed): every list row read Updating…, the footnote "No active rules. Updating 4 lists…", Update All Now disabled, then "74,719 active rules. Updating 3 lists…" as lists came back (captured: activity-clearing.png). Not verified: real mouse clicks on the mini switch, the recorder and the pop-up (every runtime action was an Accessibility press); Increase Contrast and Reduce Transparency (needs the system settings; the group draws a border under the high-contrast appearances, untested on screen); a Learn more click at runtime (the link is the pane container's, unchanged; SettingsGuideLinkTests pass); minimum and maximum widths checked by tests, not on screen (the window is fixed at 740). code-review (medium --fix) ran: 6 of 9 findings fixed (stale Updating… after the pane reappears, refit when row text changes, status width estimate, shared warning gap, shared date clamp, Quick Detour's manual refit); custom-container naming fixed by me afterwards; double width estimate left (harmless).

2026-11-14: the user reviewed the phase 1 captures (Quick Detour, Content Blocking; light and dark) and approved the pilot as is, including its provisional choices: mini switches, bordered pop-ups, Quick Detour's Opening/Closing sections, Content Blocking's table as rows, the form 20 pt under the Learn more link, and the taller panes. Phase 2 converts the remaining panes.

Phase 2, 2026-11-14 (approved pilot; commits 660482b groundwork, 830f4f0 General/Spaces/Links/Search, 5811338 + 9d7bd44 Profiles/Extensions by a subagent in worktree task-338-pe, cherry-picked, a1f26a9 cleanup and wiki, 11f150e review fixes).

What changed:
- Component: lists drawn as form groups (SettingsListContainerView: 12 pt fill, rows clipped, Increase Contrast border; SettingsBorderedView folded into it), section titles 13 pt semibold on the rows' text edge, button rows 44 pt (10 pt above and below the button, as System Settings' Voice row), header accessory (Learn more), row isEnabled (control off, name dimmed; re-enables only what it disabled), row isHighlighted, section setRows and isButtonRowHidden (both refit the pane), SettingsFormRow(content:), SettingsGroupStyle with increaseContrastOverride.
- General: Default Browser (the app that opens links and Set as Default Browser, off while it is Detour), Peek, Automation (switches, Disconnected agents [Allow Again] row, status footnote, copy buttons under the group), Allowed Clients (row per client with Revoke). Both automation sections carry AutomationWindows.automationSettingsIdentifier (TASK-228.7).
- Spaces detail: one group (Name, Emoji, Profile, Color), grids named by their rows (read once now).
- Links: Routes header on the text edge, list as a group; Default a form section (row with warning line, highlighted for the blocked deletion; caption + Quarantine guide as footnote). LinkRouteHighlightView removed.
- Search: list as a group under the Site Search header.
- Shortcuts: kept as a list inside a group (decision below).
- Profiles detail: a section per ProfileSettingsSection, Learn more as header accessory, Name field, Private note as footnote, every switch a row (filter lists and extensions as rows; filter lists off while blocking is off; extension rows off with help while off globally), isolation warning as the row's warning line, UA preview as help, custom string field, Saved permissions value + Clear. ProfileSettingsLayout keeps visibility only (spacing removed with its tests).
- Extensions detail: top group (header row: icon, name, version, description, Settings…; source row with Reload / Check for Updates; staged update row), pending permissions as a row in its own group, Enabled / Profiles (Turn On in All Profiles) / Allow in Private, Permissions / Optional Permissions / Requested Sites / Site Access sections of switch rows.
- Removed: SettingsGroupBoxView (+ switchRow), SettingsSwitchRow.make, TintedBannerView, LinkRouteHighlightView, ProfileSettingsLayout.spacing/isHelpText, SettingsMetrics labelColumnWidth, sectionTitleToRows, listCornerRadius, groupInset*, groupRowGap.

PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user):
- Shortcuts stays a table inside a group (about a hundred commands under floating menu headers, filtered by the search field); alternative: a form section per menu.
- Search's list drawn as a group with a header rather than form rows (a list to add/edit/remove, filling the pane).
- General: 'Default web browser' row shows the current browser's name; 'Disconnected agents' row with an 'Allow Again' button (was a full-width 'Allow Disconnected Agents Again' button); status line as the Automation group's footnote; Allowed Clients its own section.
- Links: the Default's caption is the group's footnote (full width) instead of help under the pop-up.
- Profiles: Private note as the first section's footnote; custom user-agent string as a 260 pt field on the right; the UA preview as Identify as's help.
- Extensions: header as the top group's first row (Wi-Fi pane style); pending permissions as a row of their own group with a warning line 'Turned off until you accept them.' (was an orange banner); 'Optional:', 'Requested sites:', 'Site access:' became titled sections; new wording 'Profiles', 'Turned off for all profiles in Extensions settings.', 'Folder not recorded', 'Version X is downloaded' / 'It installs when the extension is idle.'; header name 13 pt bold; permission names 13 pt primary; description no longer selectable.

Tests: 552 tests, 0 failures, in SettingsFormTests (18), SettingsPanesFormTests (8, new), SettingsProfilesExtensionsFormTests (15, new), SettingsSwitchRowTests (TASK-336), SettingsPaneColumnsTests, SettingsGuideLinkTests, SettingsPaneHeightTests, SettingsCaptureHarnessTests (run with the capture folder), ProfileSettingsLayoutTests, ShortcutsSettingsPaneTests, TrackingParameterListTests, LinkRouteEditorTests, LinkRouteResolverTests, LinkRouteStoreTests, ExtensionPermissionRestoreTests, ExtensionProfileScopeTests, MCPServerTests and every Automation* suite (AutomationWindowKindsTests included). Full suite not run (the lead runs it).

Runtime (data dirs DetourVerify-338-*, removed with their WebKit stores and defaults keys): seeded world (2 profiles, 3 spaces, 3 routes) + API Explorer installed; every pane captured before and after in light and dark; Accessibility reading of every pane with docs/harness/task336/axsettings.swift: 0 unnamed switches and 0 duplicates on every pane (General 3, Quick Detour 2, Profiles 8, Extensions 23, Content Blocking 1 switches; Spaces' Name/Emoji/Profile/Color each named once); identifiers checked in the code diff (none removed). Native clicks through the automation endpoint: hit-testing lands on the mini switches, the pop-up and the recorder at their drawn places, and a click in the Automation section is refused (gate_closed); the endpoint's click does not toggle an NSSwitch or open a pop-up in Settings, the same on the unconverted Profiles pane's regular switch before conversion, so it is the endpoint's delivery, not the form (not verified with real clicks: those would move the user's pointer).
Increase Contrast: checked with SettingsGroupStyle.increaseContrastOverride in a gated test-host harness (every pane light and dark): every group and list gets its border. Limit: the system colours' high-contrast variants were not seen (a process cannot turn the setting on, and NSAppearance's high-contrast names resolve to plain Aqua while it is off); the system setting was not toggled. Reduce Transparency: no pane draws a material (test; the only NSVisualEffectView is AppKit's scroll pocket under Search's table header, which follows the setting itself), so nothing in the panes changes; not captured with the setting on.

Captures: /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/p2/before-<pane>-<look>.png, /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/p2/after-<pane>-<look>.png, /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/p2/compare-<pane>-<look>.png (QD and Content Blocking compare against the phase 1 before shots), Increase Contrast /private/tmp/claude-501/-Users-tma-Projects-browser-MyBrowser/5d738add-7244-46a9-a428-169317fc928a/scratchpad/task-338/p2/ic/ic-<pane>-<look>.png.

Review (code-review medium --fix over 0b74054..HEAD): 9 findings; fixed 5 (refit on setRows and the button row, re-enabling only what a row disabled, dead General properties, stale Links comment, blank line) and 1 by me (default browser button off instead of hidden); left: description no longer selectable (deliberate), the list container picks up the override on its next updateLayer (tests only).

Found, out of scope: SettingsWindowController refit race on a list pane's first open with open_ui row>0 (a superseded animation's finish clears animationTargetHeight; the subagent saw the window stuck at a mid-animation height); the extension header's icon has no Accessibility name; possibly orphaned WebKit stores from one aborted capture run (DetourVerify-338-before, first try, its folder removed before cleanup).
<!-- SECTION:NOTES:END -->
