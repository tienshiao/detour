---
type: Component
title: Settings window
description: "The Settings window and its nine panes (General, Spaces, Links, Quick Detour, Profiles, Search, Shortcuts, Extensions, Content Blocking): what each one edits, how changes reach TabStore, the shared metrics and pane container (one scrolling body, or since TASK-211 a list and detail column fixed to the pane and scrolling on their own), the System Settings–style grouped form (TASK-338, on Quick Detour and Content Blocking so far), the height rule (natural height, capped to the screen, resizable in height only) and the layout traps met on the way."
resource: ../../Detour/Browser/Settings
tags: [settings, appkit, profiles, spaces, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-15T01:40:00Z }
sources:
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents (and the Quick Detour pane)"
  - id: quick-detour-pane
    resource: ../../Detour/Browser/Settings/QuickDetourSettingsViewController.swift
    title: QuickDetourSettingsViewController.swift
  - id: columns-tests
    resource: ../../DetourTests/SettingsPaneColumnsTests.swift
    title: SettingsPaneColumnsTests.swift
  - id: task211-harness
    resource: ../../docs/harness/task211-harness.patch
    title: TASK-211 harness (columns scrolled by wheel events, frames logged, light and dark, a small screen)
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive (the Links pane's Quick Detour section)"
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app (the Links pane's Quick Detour section)"
  - id: window
    resource: ../../Detour/Browser/Settings/SettingsWindowController.swift
    title: SettingsWindowController.swift
  - id: metrics
    resource: ../../Detour/Browser/Settings/SettingsMetrics.swift
    title: SettingsMetrics.swift
  - id: height
    resource: ../../Detour/Browser/Settings/SettingsPaneHeight.swift
    title: SettingsPaneHeight.swift (the height rule)
  - id: container
    resource: ../../Detour/Browser/Settings/SettingsPaneViewController.swift
    title: SettingsPaneViewController.swift (pane container, list border)
  - id: profile-layout
    resource: ../../Detour/Browser/Settings/ProfileSettingsLayout.swift
    title: ProfileSettingsLayout.swift (the Profiles pane's sections and rows)
  - id: profile-layout-tests
    resource: ../../DetourTests/ProfileSettingsLayoutTests.swift
    title: ProfileSettingsLayoutTests.swift
  - id: height-tests
    resource: ../../DetourTests/SettingsPaneHeightTests.swift
    title: SettingsPaneHeightTests.swift
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: survey-harness
    resource: ../../docs/harness/task189-survey-harness.patch
    title: TASK-189 survey harness (every pane and state, light and dark, plus the sizing checks)
  - id: general
    resource: ../../Detour/Browser/Settings/GeneralSettingsViewController.swift
    title: GeneralSettingsViewController.swift
  - id: spaces
    resource: ../../Detour/Browser/Settings/SpacesSettingsViewController.swift
    title: SpacesSettingsViewController.swift
  - id: links
    resource: ../../Detour/Browser/Settings/LinksSettingsViewController.swift
    title: LinksSettingsViewController.swift (Link Routes, TASK-191.3)
  - id: profiles
    resource: ../../Detour/Browser/Settings/ProfilesSettingsViewController.swift
    title: ProfilesSettingsViewController.swift
  - id: extensions
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift
  - id: content-blocker
    resource: ../../Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
    title: ContentBlockerSettingsViewController.swift
  - id: task-292-11
    resource: backlog:TASK-292.11
    title: "Settings: Learn more links from feature settings to their guide pages"
  - id: guide-link
    resource: ../../Detour/Browser/Settings/SettingsGuideLink.swift
    title: SettingsGuideLink.swift (the Learn more link)
  - id: guide-link-tests
    resource: ../../DetourTests/SettingsGuideLinkTests.swift
    title: SettingsGuideLinkTests.swift
  - id: task-328
    resource: backlog:TASK-328
    title: "Settings: use switches instead of checkboxes on every Settings pane"
  - id: switch-row-tests
    resource: ../../DetourTests/SettingsSwitchRowTests.swift
    title: SettingsSwitchRowTests.swift
  - id: task-336
    resource: backlog:TASK-336
    title: "Settings: switches have one accessible name and VoiceOver reads each setting once"
  - id: task336-axsettings
    resource: ../../docs/harness/task336/axsettings.swift
    title: TASK-336 Accessibility reader for the Settings window (reading order, switch names, duplicates)
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: form
    resource: ../../Detour/Browser/Settings/SettingsForm.swift
    title: SettingsForm.swift (the grouped form)
  - id: form-tests
    resource: ../../DetourTests/SettingsFormTests.swift
    title: SettingsFormTests.swift
  - id: panes-form-tests
    resource: ../../DetourTests/SettingsPanesFormTests.swift
    title: SettingsPanesFormTests.swift (General, Spaces, Links, lists as groups)
  - id: profiles-extensions-form-tests
    resource: ../../DetourTests/SettingsProfilesExtensionsFormTests.swift
    title: SettingsProfilesExtensionsFormTests.swift
  - id: task-340
    resource: backlog:TASK-340
    title: "Settings: the window can stop mid-resize when a list pane first opens on a row other than the first"
  - id: task-337
    resource: backlog:TASK-337
    title: "Content blocking: a setting for the AdGuard URL Tracking list, so Detour does not fetch it when it is off"
  - id: task-327
    resource: backlog:TASK-327
    title: "Keyboard shortcuts: assign and customize the shortcuts of browser commands in Settings"
  - id: shortcuts-pane
    resource: ../../Detour/Browser/Settings/ShortcutsSettingsViewController.swift
    title: ShortcutsSettingsViewController.swift
  - id: layout-notes
    resource: "Agent session notes, 2026-09-25 and 2026-09-26: Settings pane layout (not in the repository)"
    title: Settings pane layout lessons
---

# Role

`SettingsWindowController.shared` is one window with a preference-style
toolbar and nine panes. It holds no settings of its own: each pane reads and
writes model objects directly (`TabStore`, `Profile`, `ExtensionManager`,
`ContentBlockerManager`, `ExternalAppPermissionStore`), and persistence
happens in those owners. The only app-wide setting, the default browser, is
not stored by Detour at all.

There is a second, unrelated "settings" surface: the sidebar's settings
**popover** (`SettingsPopoverViewController`), which holds, under the
page's host, the per-site content-blocking switch, the picture in picture
and dev mode switches (not in a Quick Detour) and the extension list for
the current page. See
[content blocking](./content-blocking.md) and
[popup and options UI](../extensions/popup-and-options-ui.md).

# How it works

## The window

- Style mask `.titled, .closable, .resizable`, resizable **in height only**:
  `contentMinSize.width == contentMaxSize.width == 740`, and every pane's
  root view also holds a required `width == 740`, so no content can widen
  the window (a long extension name used to stretch it to 1104). Full screen
  is off (`.fullScreenNone`), tabbing disallowed.[^task-189]
- The nine view controllers (in toolbar order: General, Spaces, Links,
  Quick Detour, Profiles, Search, Shortcuts, Extensions, Content Blocking;
  `SettingsWindowController.paneOrder`) are created once in `init` and kept in `panes`;
  switching swaps `window.contentViewController` at the current size, then
  `fitWindow` animates to the new pane's height with the top edge fixed (moved
  only as far as needed to stay on the screen).
- `showWindow` fits the current pane before re-centring and activating.

### The height rule

`SettingsPaneHeight.fit(natural:minimum:screenUsableHeight:chromeHeight:)`
is a pure function returning content heights `(initial, minHeight, maxHeight)`:

- `cap` = the window's screen's `visibleFrame` height minus the title bar and
  toolbar minus 80 (`SettingsMetrics.screenMargin`), never below 200.
- `initial = maxHeight = min(max(natural, minimum ?? natural), cap)` and
  `minHeight = min(minimum ?? natural, cap)`. The window opens at the pane's
  natural height; the user drags between the two bounds; past the cap the
  pane scrolls.
- List panes (Spaces, Links, Profiles, Extensions) have a minimum of 400
  (`listPaneMinimumHeight`); General, Quick Detour and Content Blocking use
  their natural height, so they are fixed. A list pane shorter than 400 is
  fixed at 400.
- `refit(current:from:to:)` is for a change while the pane is shown: a window
  still at its old full height follows to the new one; one the user dragged
  shorter keeps its height, clamped into the new bounds.
- A pane switch always re-fits (no height is stored per pane). The window also
  re-fits on `NSWindow.didChangeScreenNotification` and
  `NSApplication.didChangeScreenParametersNotification`, so moving it to a
  shorter display, a resolution change or an unplugged display never leaves it
  taller than its screen.
- `screenUsableHeightOverride` replaces the screen height in the rule; it is
  an injection point for a harness, nil in the app.

Tested by `SettingsPaneHeightTests` (20 cases, including short laptop
screens where the 400 minimum comes down to the cap).

### The pane container

`SettingsPaneViewController` is the base of every pane. A fixed
**description** sits at the top (`paneDescription`, wrapped at
`740 - 2 * 20`), with the pane's Learn more link (`guidePage`) 4 pt under
it; Extensions and Quick Detour have no description, so their link sits 20
pt below the toolbar (see [Learn more links](#learn-more-links)), and a pane
with neither starts its body 20 pt below the toolbar. Below this header the
pane's **body** (`makeBody()`)
takes one of two forms, chosen by `scrollsBodyAsWhole`:[^task-211]

- **One scrolling body** (the default: General, Quick Detour, Content
  Blocking). The body is the document of an `NSScrollView` (flipped clip
  view) that fills the rest of the pane, inset by 20 on the sides and
  bottom. The document is pinned to the clip view's width, and is at least
  as tall as the visible area (a `>=` plus a priority-49 `==`). `scrollView`
  is that scroll view.
- **Fixed columns** (`scrollsBodyAsWhole == false`: Spaces, Links,
  Profiles, Search, Shortcuts, Extensions). The body is pinned to the pane's edges, 12 below
  the description (or its link) and 20 from the sides and bottom; `scrollView` is nil.
  The master list (its bordered box, table and +/- bar) fills the body's
  height, and so does the detail column, which is a
  `makeColumnScrollView(document:estimatedWidth:)`: a
  `SettingsColumnScrollView` (flipped clip view, autohiding scroller) whose
  document is pinned to its top and width and is as tall as its content (a
  pane pins its content's bottom to the document with `==`; a priority-1
  zero height defines an empty column). Each scrolls only its own contents,
  so scrolling the details never moves the list, and the other way round.
  When the details show another item than before (tracked by id:
  `shownSpaceID`, `shownProfileID`, `shownExtensionID`, so a click, an add,
  a delete, an uninstall or `showSpacesPane(selectSpaceID:)` all count) the
  pane calls `scrollColumnsToTop()`, so they start at the top; a rebuild for
  the same item (an extension's switch toggled, an update) keeps the
  offset. Links has no detail column: its route list is the scrolling
  column, and the Default with its caption are fixed below it (see
  [Links](#links)).
- `SettingsColumnScrollView` is the scroll view of every master list and
  detail column. In `tile()`, a column scrolled to its end (and long enough
  to scroll) is put back at its end after the clip view is resized, so
  dragging the window shorter or a refit never slides the last rows out of
  view; anywhere else the offset is kept, and content that fits stays at
  its top. The sidebar's `SpacePageView` does the same in its
  `layout()` (TASK-192).
- `naturalContentHeight` = margin + description (+ 4 + link) + 12 + the
  body's height + margin. The body's height is its `fittingSize` at its width (the clip
  view's in a scrolling body, narrower with legacy scrollers). In a column
  pane each visible column scroll view is held, for the measurement, at the
  full `fittingSize` of its document (measured at its clip view's width, its
  `estimatedWidth` before the first layout), so the body's fitting height
  counts the whole column plus anything above or below it (Extensions'
  Uninstall button). The stretch constraints are switched off while
  measuring, so the window's current height never feeds back into it.
  `idealBodyHeight(fittingHeight:)` lets a list pane ask for the height
  that shows every row (rows + the 29 pt button bar).
- A pane calls `contentHeightDidChange()` when rows appear or disappear or a
  list's length changes (Spaces add/delete, Profiles selection and the
  rows it hides, Extensions rebuilds and selection, Content Blocking's table
  height); calls in one run-loop turn are coalesced and the window controller
  refits if the pane is the shown one. Spaces' height does not depend on its
  selection, so it does not report it.
- `paneDidFit()` runs after each fit (Spaces scrolls its selection into view there).
- `SettingsListContainerView` holds a list (the master lists, Search's site
  searches, Links' routes, the Shortcuts list) and draws it as a form group
  in `updateLayer`, so it follows the appearance: the 12 pt rounded fill,
  its rows clipped, a border under Increase Contrast. Until TASK-338 it was a
  `SettingsBorderedView` with a 1 pt separator-coloured border, shared with
  `SettingsGroupBoxView`, the bordered box of switch rows (Profiles' filter
  lists and extension switches, an extension's permissions) that grew with
  its rows where an `NSBox` does not;[^task-189] the form's groups replaced
  both.
- `SettingsWrappingLabel` is the wrapping label of every body (help text,
  descriptions, the pending banner, an extension's name): its wrap width
  (`preferredMaxLayoutWidth`) is its own width, taken in `setFrameSize`, and
  when that changes it re-measures and calls the enclosing pane's
  `contentHeightDidChange()` (found through the responder chain). Its
  `estimatedWidth` (the column's width with overlay scrollers) is used until
  the first layout, so the first `fittingSize` measurement is already right in
  the usual case. Its owner gives it a definite width (both edges pinned or a
  width constraint). The wrap width used to be a constant, the column's width,
  which with "always show scroll bars" (a clip view 17 pt narrower) would cut
  the last line.[^task-189]

### SettingsMetrics

| Metric | Value |
|---|---|
| Window width | 740 |
| Pane margins, section gap, list to detail column | 20 |
| Description to body | 12 |
| Between rows | 10 |
| Control to its help text | 4 |
| Label to control | 8 |
| Text field width, cap on a detail pop-up | 260 |
| Master list | 220 wide, 28 pt rows, 24 pt +/- buttons |
| List pane minimum height | 400 |
| Screen margin for the cap | 80 |

The detail column starts level with the top of the list. Until TASK-338 a
right-aligned 124 pt label column (Profiles, Spaces), 8 pt from a section
title to its first row and bordered groups with 10 / 8 pt insets set the
details; the grouped form's metrics (below) replaced them.

### The grouped form (TASK-338)

System Settings' look, at the user's request (Nov 14 2026, with a
screenshot of System Settings > Apple Intelligence & Siri as the
reference): a bold header over an inset rounded group, one row per
setting with its name on the left and its control on the right, hairlines
between the rows, help text under the name, a footnote row closing the
group and buttons for the whole group under it on the
right.[^task-338] `SettingsForm.swift` holds it. Quick Detour and Content
Blocking were the pilot (approved by the user on Nov 14 2026, with its
provisional choices); phase 2 put every pane's settings in it: General,
Spaces' and Profiles' and Extensions' detail columns, Links' Default. The
lists (the master lists, Search's site searches, Links' routes, the
Shortcuts list) stay lists, drawn as groups: `SettingsListContainerView`
(a `SettingsBorderedView`) has the group's fill, radius and Increase
Contrast border and clips its rows, and a list's title is a 13 pt semibold
header on the rows' text edge (`settingsSectionTitle`, 12 pt before).

- `SettingsForm(sections:estimatedWidth:)`: the sections in a vertical
  stack 30 pt apart (a hidden section leaves no gap). A pane hands it to
  `formBody(_:)`, which pins it to the body's top and sides with `<=` plus
  `bottomHug` at the bottom, as every scrolling body must. Under the pane's
  description or Learn more link it starts 8 pt lower (20 pt under the
  link), so the link does not read as the first section's.
- `SettingsFormSection(title:headerAccessory:rows:footnote:buttons:)`: the
  header (13 pt semibold, on the rows' text edge) with an optional
  accessory 8 pt after it on its baseline (Profiles' "Learn more"), 10 pt,
  the group, and the buttons 10 pt under it, ending on the group's right
  edge (not the rows' inset: that is where System Settings puts them).
  `isButtonRowHidden` takes the buttons and their room away (General's
  copy buttons while automation is off); `group.setRows` replaces the rows
  (General's allowed clients).
- `SettingsFormGroupView`: the rows in a stack with no spacing (a hidden row
  leaves no gap and no separator). It draws in `draw(_:)`, so its colours
  follow the appearance: a 12 pt rounded fill of black or white at 3.1%
  (247 on the light window's 255, 37 on the dark one's 30, as measured;
  `quaternarySystemFill` is 2.7% and comes out a level lighter), and between
  the visible rows a hairline inset 10 pt on each side, one device pixel of
  the separator colour at half strength on a 1x screen and full on a 2x one
  (System Settings draws half a point). Under Increase Contrast (the
  appearance's high-contrast variants, or the workspace's flag) it adds a
  1 pt separator-coloured border, and it clips its rows to its shape.
  `SettingsGroupStyle` holds the fill and the contrast rule for it and the
  lists, with `increaseContrastOverride` for tests and capture harnesses: a
  process cannot turn Increase Contrast on for itself, and
  `NSAppearance(named: .accessibilityHighContrastAqua)` resolves to plain
  Aqua while the setting is off (measured: same name, same colours).
- `SettingsFormRow(title:help:accessory:accessibilityName:)`, or
  `SettingsFormRow(footnote:)`: a text column (the 13 pt name, 11 pt
  secondary help, `addDetail` lines such as a status, a `setWarning` line
  with the orange triangle, `addLink` Learn more links; 3 pt apart, hidden
  ones collapse) ending 16 pt before the control, which ends 10 pt from the
  group's edge. Text keeps 10 pt from the row's top and bottom and the
  control at least 7 (a push button, or a value with one, 10), and the row
  hugs its content (a priority-740 zero height, above a body's stretch), so
  a one-line switch row is 36 pt, a pop-up row 38 and a button row 44, as
  in System Settings. `isEnabled` off disables the control and dims the
  name (Profiles' filter lists while blocking is off); `isHighlighted`
  tints the row with the accent colour (Links' Default). The accessory is `.toggle` (made
  mini, 36 × 16, centred on the name's first line), `.popUp`, `.button`,
  `.value(text, button:)`, `.shortcut` (all on the name's first baseline)
  or `.custom` (centred). Help text under a control taller than the name's
  line starts below the control (System Settings' Keyboard shortcut row).
- **Accessibility, built in.** A row names a switch, pop-up, shortcut
  recorder or custom control by its title, or by `accessibilityName` where
  that says more ("Quick Detour shortcut" beside "Shortcut"), through
  `SettingsSwitchRow.name(_:by:as:)`, and the title leaves the tree, so
  VoiceOver reads the setting once. A button keeps its own title, a value
  is text of its own and a custom container is not an element, so those
  rows keep their title. The row orders its Accessibility children so the
  control comes right after its name (first when the name is hidden) and
  before the help: AppKit lists them in subview order, which read the help
  before the switch (seen with the TASK-336 reader in the running app).
- **Refits.** `setHelp` and `setWarning` call the pane's
  `contentHeightDidChange()` when they change something
  (`NSView.enclosingSettingsPane`), since a wrapping label reports only
  width changes; Content Blocking's details and footnote and Quick Detour's
  warning rely on it.
- **Widths.** A row reads its control's `fittingSize` when it is built, so
  a `.custom` field gets its width constraint first (Spaces' and Profiles'
  260 pt fields); rows added to a built form go through the section's
  `setRows`, which wraps them at the group's width. A row's help is not
  selectable unless the pane turns it on (Profiles' user-agent preview).
  `SettingsFormRow(content:)` is a row of one view across its insets
  (Extensions' header), whose subview order is VoiceOver's. The rows wrap at
  `estimatedWidth` (the body's 700 pt by default; a detail column passes its
  own) less the control until they are laid out, so the pane's first natural-height measurement is the laid-out
  height (`testTheFirstMeasurementIsTheLaidOutHeight`, at 443 and 700 pt).

The numbers come from a SwiftUI `Form` with `.formStyle(.grouped)` (what
System Settings is built with) rendered on macOS 26 and measured pixel by
pixel, checked against the user's screenshot. An AppKit form rendered the
same way gave the same header, first-row text, fill, separator colour and
corners; further down it drifts by 1 or 2 pt, because its separators
overlay the rows instead of taking a pixel of their own. Button rows were 38
pt in the pilot (SwiftUI's render: 40); phase 2 made them 44, as System
Settings' Voice and history rows measure.

| Metric (`SettingsMetrics.form…`) | Value |
|---|---|
| Header | 13 pt semibold, 10 pt above the group |
| Between sections | 30 (group or its buttons to the next header) |
| Group | the body's width, corner radius 12 |
| Row insets | 10 at the sides (text, control and separators), 10 above and below the text, 7 at least for a control, 10 for a push button |
| Name, help | 13 pt, 11 pt secondary, 3 pt apart |
| Text column to control | 16 |
| Buttons under a group | 10 below it, 8 apart |

Two things AppKit does not give. **Pop-ups** stay the standard bordered
`NSPopUpButton`: System Settings' borderless value with a round chevron
button is SwiftUI's own cell (`SwiftUIPopupButtonCell`), with no AppKit API
(borderless, every bezel style and the macOS 26 border shapes were tried).
**A mini `NSSwitch` reports its regular size (54 × 24) until it is in a
window, and keeps the size it first reported**; the pane is built and
measured before it is in one. The row reads the real size once from a
switch in a window that is never shown (`SettingsFormRow.switchSize`) and
fixes the switch to it; see [AppKit gotchas](../platform/appkit-gotchas.md#layout).

### Switch rows

Every on/off setting in the window is an `NSSwitch` (TASK-328, at the
user's request: General and Quick Detour used checkboxes until Nov 14
2026).[^task-328] A switch has no title, so each one has a label beside it.
Since TASK-338 every switch in the window is a form row's: the 13 pt name
at the group's text edge, the mini switch (36 × 16, as System Settings')
on the group's right edge, centred on the name's first line. Before, there
were four forms: Profiles' right-aligned 124 pt label column, a label then
a regular switch 8 pt after it (General, Quick Detour, Extensions' Enabled
and Allow in Private: `SettingsSwitchRow.make`), and a small switch then its
12 pt name in a bordered box (Profiles' filter lists and extension switches,
an extension's permissions: `SettingsGroupBoxView.switchRow`); TASK-328
measured the first two to match exactly (a 56 × 26 switch, its frame 6 pt
after the label's, one centre line). Only the sidebar's page settings
popover keeps a label then a switch. A click on a label does nothing, on
every pane: the labels are plain text fields (making them toggle the switch
was the alternative).
The five converted switches keep the identifiers the checkboxes had
(`peekEnabled`, `automationEnabled`, `automationAllowPrivate`,
`quickDetourHotKeyEnabled`, `quickDetourOptionCommandClick`).

**Accessibility (TASK-336).** Each switch and its label are one element:
`SettingsSwitchRow.name(_:by:)` gives the switch the label's text as its
accessibility label and takes the label out of the Accessibility tree, so
VoiceOver reads "<label>, switch, on" once. Every form row goes through it
(TASK-338; before, the three forms of the time did), and so does the
sidebar's page settings popover (`makeSwitchRow`).[^task-336] Before, a TASK-328 row was a static
text followed by a switch of the same name (read twice), and the Profiles
and Extensions switches had no name at all (read as "switch"). A text
field's Accessibility element is its cell, so the label is hidden on the
cell: on the field alone the text stayed in the tree (seen in the running
app and in a unit probe; see [AppKit gotchas](../platform/appkit-gotchas.md#accessibility)).
The label is not the switch's title UI element: that would keep the label
in the tree as text of its own, read before the switch, and an ignored
label could not serve as one. Measured with an Accessibility client over
every pane (`docs/harness/task336/axsettings.swift`), before and after:
General's 3 and Quick Detour's 2 duplicates gone, Profiles' 8 and an
extension's 23 unnamed switches named, the popover's 3 duplicates gone,
every `AXIdentifier` unchanged. Not changed, because they are not switches:
labels beside a pop-up or grid already named the same (Links' "Open other
links in", Quick Detour's idle pop-up, Spaces' Emoji and Color) and unnamed
pop-ups and fields beside a grid label (Profiles, Spaces); the Shortcuts
pane's recorders are named "<command> shortcut" inside a row titled by the
command.

| Pane | Content height (examples measured 2026-10-24) | Opened by |
|---|---|---|
| General | about 394 with automation off, 428 on in a test run (its four copy buttons), fixed (TASK-328 switch rows, 2026-11-14; the window's height less the 88 pt title bar and toolbar) | Detour > Settings… (Cmd+,), which opens whatever pane was last shown |
| Spaces | 400 minimum; 628 with 19 spaces | the sidebar's add-space and edit-space actions (`showSpacesPane(selectSpaceID:)`), the Spaces menu's Manage Spaces… (`openSpacesSettings`) |
| Links | 400 minimum (no routes); 743 with 5 routes (measured before the Quick Detour section came and went); capped (1242 on a 1410 pt screen) with 12 routes, then the route list scrolls (177 pt of list at 400, 129 pt at a 352 pt cap, 2026-10-27) | toolbar; Open Links Settings… in the blocked space-deletion alert (`showLinksPane(highlightingSpaceID:)`) |
| Quick Detour | 457, fixed (TASK-338's grouped form with the Debug build's warning line and the Learn more link, 2026-11-14; 317 with TASK-328's rows) | toolbar only |
| Profiles | 630 (Private) / 709 (a normal profile) to 1218 (custom UA, warning, 15 extensions); 1047 for Private with 14 extensions (2026-10-27) | toolbar only |
| Extensions | 400 (none, or one small extension) to 1092 (22 permissions, 4 hosts, 6 optional) | Extensions > Manage Extensions…, the settings popover (`showExtensionsPane()`) |
| Shortcuts | 400 minimum; every row (about 1,800 pt) is its natural height, so it opens at the screen's cap | toolbar only |
| Content Blocking | 554, fixed (TASK-338's grouped form: four list rows, the footnote, the buttons, Tracking Parameters (named Copied Links until 2026-11-15), 2026-11-14; 379 with the table and TASK-337's section) | toolbar only |

TASK-189 part 1 moved every pane into the container and rebuilt General,
Content Blocking and Spaces on the metrics; part 2 rebuilt Profiles (titled
sections) and Extensions (one column in the pane's scroll view).

### Learn more links

Settings links each feature that has a guide page on the website to it
(TASK-292.11).[^task-292-11] The pages are `GuidePage` in
[HelpMenu.swift](../../Detour/App/HelpMenu.swift): its raw value is the
site's slug, and its URL is `HelpLinks.detourHelp.url` (the Help menu's
guide index, https://detourbrowser.com/features/) plus `<slug>/`, so the
Help menu and Settings share one definition. Only pages that exist are
listed (all 11 answered 200 on Nov 14 2026).

The link is `SettingsGuideLink`, a borderless `NSButton` in `linkColor`
with a pointing-hand cursor, accessibility role link, label "Learn more
about <page>" and identifier `learnMore.<slug>`. Its action calls
`SettingsGuideLink.open`, which is `AppDelegate.openHelpPage`: the page
opens as the Help menu's do, in a new selected tab of the frontmost normal
browser window (which comes forward over Settings), or a new window. Not a
`.link` attribute in a text field, which would open through NSWorkspace in
the default browser. Tests replace `open` to record the URL. A borderless
button draws its title 2 pt further in than a label draws its text, so its
`alignmentRectInsets` take 2 pt off each side and its text lines up with
the text above it. Its vertical hugging is required: with the default, a
list pane held taller than its content (Links at its 400 pt minimum) gave
the spare height to the link button instead of the list, and in dark mode
the captures showed the top link centred in a 70 pt gap
(`testSpareHeightNeverStretchesALink`).

Where the links are:

| Where | Page | Placement |
|---|---|---|
| Spaces, Links, Quick Detour, Profiles, Search, Extensions, Content Blocking | spaces, link-routes, quick-detour, profiles, site-search, web-extensions, content-blocker | `guidePage` on the pane: the container puts "Learn more about <page>" (12 pt) 4 pt under the description, or 20 pt below the toolbar in a pane without one (Quick Detour, Extensions); the body starts 12 pt below it, and `naturalContentHeight` counts it |
| General › Peek | peek | under the Peek help text |
| Links › Default | quarantine | under the caption, which is where the pane explains Quarantine |
| Profiles › Tabs, Content Blocking, Extensions | tab-archiving, content-blocker, web-extensions | "Learn more" beside the section title (`ProfileSettingsSection.guidePage`); Tab Archiving covers sleeping too, so Private keeps it |
| Profiles › the Private profile's note | private-browsing | under "This profile is used for Private Windows." |

Not linked, because no Settings belong to them: command-palette,
favorites, pinned-tabs, split-tabs, recent-tabs, history, dev-mode (its
switch is in the sidebar's settings popover) and privacy (a setup guide
across several panes). Copy URL has no guide page.

## General

A grouped form since TASK-338. **Default Browser**: the row "Default web
browser" with the app that opens web links now (asked with
`https://example.com`: "Detour", or the other app's name) and "Set as
Default Browser", turned off while it is Detour, which calls
`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and
`https`. **Peek** (TASK-307): the switch "Open links from pinned tabs and
favorites in a Peek" (`PeekSettings`, app-wide, on by default) with the help
"Off, links to other sites from pinned tabs and favorites open in new tabs.
Shift-click still opens a Peek." and the Peek guide
([Peek](../tabs/peek.md#when-a-link-opens-in-a-peek)).
**Automation** (TASK-228): the switches "Let AI agents and scripts control
Detour (MCP)" and "Allow agents to use Private windows", each with its help,
the row "Disconnected agents [Allow Again]" while any are blocked, the
endpoint's status as the group's footnote, and the copy buttons under the
group (shown while it listens; Copy Token and Reset Token… in a test run
only); **Allowed Clients**: a row per client (its name, when it was allowed
and last used, Revoke), or "None yet", shown wherever clients are approved
one by one; see [automation endpoint](./automation-endpoint.md). Both
sections carry `AutomationWindows.automationSettingsIdentifier`, so the
endpoint's input tools refuse every view in them (TASK-228.7). The Private
switch is not disabled while automation is off: it is a saved choice of its
own, read at every check.

## Spaces

A list of the non-incognito spaces with name, emoji, colour and profile.
The selected space's settings are one form group in the detail column
(TASK-338): Name (the field), Emoji (the curated grid and All Emoji…),
Profile and Color (the curated colours), each control on the group's right
edge; the emoji and colour grids take their row's name and the names leave
the Accessibility tree, so each is read once (before, "Emoji" and "Color"
were read as a label and again as the grid).
Edits go through `TabStore.updateSpace(id:name:emoji:colorHex:profileID:)`;
rows can be dragged to reorder (`TabStore.moveSpace(from:to:)`).

- Changing a space's **profile** asks first ("Changing the profile will change
  which cookies and login sessions this space uses") and restores the popup
  on Cancel.
- Add creates a space named "Space" on the first non-incognito profile.
- In a row, the space name gives way first and truncates; the profile name
  keeps its width up to 40% of the row and then truncates too, so both stay
  readable (the other way round, a long profile name squeezed the space name
  to nothing). The Profile pop-up is capped at 260 and truncates its title.
- The list scrolls to the selected space when the pane opens on it.
- Delete is disabled while only one space remains.

## Links

The link routes and the Default: "Routes" (a section header on the rows'
text edge) with New Route beside it, one list drawn as a form group of
three-line rows (URL, From app, Open in), then the Default as a form
section (TASK-338): the row "Open other links in [pop-up]" with its warning
line, tinted when the blocked space deletion points to it
(`SettingsFormRow.isHighlighted`), and the caption with the Quarantine
guide as the group's footnote. Not a master list with a detail column: every route
is edited in place, as in Arc's sheet. Since TASK-211 the list fills the
pane's height between "Routes" and the Default, and its rows scroll inside
it (a `SettingsColumnScrollView`, so a list scrolled to its end stays at its
end); the Default and its caption stay at the bottom of the pane, 20 pt above
the window's edge, at every height.[^task-211] The list asks for the height
of all its rows at priority 250 (below the window's stay-put priority, so it
never resizes the window but does count in the natural height) and keeps at
least the empty list's 56 pt at priority 490. The Default and caption fit
the 400 pt minimum with room for about one and a half routes, so the
minimum was not raised. A highlighted route (the blocked-deletion alert) is
scrolled into view inside the list; a highlighted Default is always in view.

Until TASK-211 the list was as tall as its rows (its scroll view handed the
wheel to the pane's) and the pane scrolled as a whole, with the Quick Detour
section below the caption; that section is now the
[Quick Detour pane](#quick-detour). The behaviour, the validation (in
`LinkRouteStore`) and the choices made are on
[link routing](./link-routing.md#the-links-pane).

## Quick Detour

The controls for [Quick Detour](./quick-detour.md), moved out of the Links
pane by TASK-211 (user decision 2026-10-26: Links keeps the routes and the
Default only). The toolbar item sits after Links, labelled
`QuickDetour.displayName` with the SF Symbol `macwindow.on.rectangle` (a
window over another: the launcher opens over the app in front). No master
list, so it scrolls as one body, like General; no description (the
toolbar names it). Since TASK-338 a [grouped form](#the-grouped-form-task-338)
of two sections, below its Learn more link (TASK-292.11):

- **Opening**: "Open Quick Detour from any app [switch]" with what the
  launcher does; "Shortcut [⌥⌘N]" (the `ShortcutRecorderView`, named
  "Quick Detour shortcut") with the help saying it is also File > New Quick
  Detour Window, also when the switch above is off, and the row's warning
  line when the shortcut is refused or not registered (a Debug build says
  it does not register without `DETOUR_GLOBAL_HOTKEY=1`) (TASK-193.2; see
  [the Settings control](./quick-detour.md#the-settings-control)); "Open
  links and sidebar tabs in Quick Detour with ⌥⌘-click [switch]" and its
  help; and a footnote pointing links from other apps to a route's Open in
  or the Default "on the Links pane".
- **Closing**: the idle auto-close pop-up ("Close Quick Detour windows not
  used for [Never, 1 hour, 6 hours, 12 hours, 1 day]", 6 hours by default)
  and its help (TASK-193.5; see
  [the Settings section](./quick-detour.md#the-settings-section)).

The hotkey's help was one paragraph under the warning; in the form its
first sentence (the launcher) is the switch's help and its second (the
menu item) the Shortcut row's. The section titles are new. (Both
PROVISIONAL, chosen by Claude while the user was away; the alternative is
one untitled group.)[^task-338]

Until TASK-328 the hotkey was one sentence, "[✓] Open Quick Detour from
any app with [⌥⌘N]". With a switch, which follows its label, the sentence
would have run on into two controls ("… with [⌥⌘N] [switch]"), so the
switch row ends at "any app" and the recorder has a labelled row under it.
The recorder stays usable with the switch off: it is also File > New Quick
Detour Window's shortcut, which the help text says. (PROVISIONAL, chosen
by Claude while the user was away; the alternative is the one-line
sentence with the switch at its end.)[^task-328]

The pane retries a refused shortcut when it appears
(`QuickDetourHotKey.retryIfFailed`) and ends a recording when it disappears.

## Profiles

A list of the profiles plus the built-in Private profile, and the selected
profile's settings as a grouped form in the detail column (TASK-338): a
section per `ProfileSettingsSection`, titled as below, with "Learn more"
as the header's accessory where the section has a guide. Each control writes a property and
calls `TabStore.shared.updateProfile(profile)`. In the list a long profile
name truncates with an ellipsis and gives way before "N Spaces".

| Section | Rows | Shown |
|---|---|---|
| (no title) | Name (a 260 pt field on the right); "This profile is used for Private Windows." and the Private Browsing guide as the group's footnote | the note only for Private; the name is not editable there |
| Search | Search engine (Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi); Search suggestions | always. Suggestions gate the network row of the [suggestion pipeline](./suggestion-pipeline.md) |
| Tabs | Archive tabs after; Sleep tabs after; Per-tab isolation (each tab its own non-persistent data store) with the warning that sleeping tabs lose session data under isolation as its warning line | archive hidden for Private; the warning when isolation is on and tabs sleep |
| Content Blocking | Block content (the master switch); a row per filter list | always; the list rows are turned off (name dimmed) while blocking is off, each toggle calls `reapplyRuleLists()` |
| Extensions | a row per installed extension (`setRows` as they come and go) | when any extension is installed, Private included |
| User Agent | Identify as (Detour, Safari, Custom) with a preview of the resulting user agent as its help (selectable); Custom string (a 260 pt field on the right) | the string only for Custom |
| External Apps | Saved permissions: the count and Clear (`.value(count, button:)`) | hidden for Private (it never remembers one). See [external apps](./external-apps.md) |

Why this grouping: the untitled first section holds the name, which
identifies the profile as an account name heads a System Settings pane (a
"Profile" title would repeat the pane); per-tab isolation sits with the
tab lifecycle rows because its warning is about sleeping tabs, and the
warning sits right under it; each other section is one thing a person looks
for by name. Row labels do not repeat their section's title ("Block content",
"Identify as", "Saved permissions").

`ProfileSettingsLayout` is the pure rule: which rows a `ProfileSettingsState`
(Private, isolation, sleeping, custom user agent, any extension installed)
shows and which sections have a visible row. The view controller keeps each
row's form row and each section by these enum values and sets their
`isHidden` from the rule (on selection, on the switches and pop-ups that
change visibility, and on extension changes), which also reports the height
change; the form's stacks leave no gap for a hidden row or section. The
isolation warning and the user-agent preview have no rows of their own:
they drive the isolation row's warning line and Identify as's help. Until
TASK-338 the rule also gave the space above each row for the label-column
grids (`spacing(above:)`, gone with them).

A profile cannot be deleted while a space uses it ("Remove or reassign those
spaces first"), the Private profile cannot be deleted, and the last profile
cannot be deleted. What deleting does to the profile's data is on
[profile data removal](../architecture/profile-data-removal.md).

The per-profile extension switch shows the profile's own saved choice. While
the extension is turned off globally the row is turned off (switch disabled,
name dimmed, "Turned off for all profiles in Extensions settings." as its
help), rather than hidden: it tells the user what turning the extension back
on will restore. For the Private profile it is the same opt-in as "Allow in
Private" on the Extensions pane; see
[private profile extensions](../extensions/private-profile-extensions.md).

## Search

The site searches, one app-wide list (TASK-287): Name, Keyword and Address
columns in one list drawn as a form group under the "Site Search" header
(TASK-338), with a +, −, pencil bar; add and edit in an
`NSAlert` sheet holding `SiteSearchForm`, whose Save is off while the store
would refuse the entry. Details on [site search](./site-search.md).

## Shortcuts

Every menu command with its shortcut (TASK-327): a description, a search
field and Restore Defaults on one line, then one list drawn as a form
group that fills the pane (a column pane, 400 pt minimum; the list scrolls on its own) with
the menus as floating group rows and a row per command (title, a note when
it is set elsewhere, the shortcut recorder, a reset button once it differs
from the built-in one), then a warning line under the list for a refused
shortcut. The list stays a table inside the group rather than a form's rows
(TASK-338, PROVISIONAL, chosen by Claude while the user was away): about a
hundred commands under floating menu headers, filtered as the search field is
typed in, are a list to scan and search, and a hundred form rows would be as
many views laid out at once; the alternative is a form section per menu. No
Learn more link: the website's shortcuts page (Help >
Keyboard Shortcuts, `HelpLinks.keyboardShortcuts`, not a `GuidePage`) does
not cover customizing them yet. What it lists, what it refuses and how the shortcuts apply
are on [keyboard shortcuts](./keyboard-shortcuts.md).

## Extensions

A list of installed extensions and a detail view for the selected one:
version, a "Settings…" button when the extension declares an options page,
Enabled, **Turn On in All Profiles** with a line saying which profiles have
it on (TASK-312: an install is on only in its own profile and a new profile
starts with none; the button is off when every normal profile has it on, and
never touches Private), "Allow in Private", API permissions and site-access
decisions with their own switches, the install source with "Check for
Updates" / "Reload" / "Install Now" and the banner for permissions an update
added, and Uninstall. "Add Extension…" offers loading an unpacked extension
or opening the Chrome Web Store; an unpacked load is turned on in the
profile of the browser window behind Settings, and both alerts name it
([extensions on per profile](../decisions/extensions-on-per-profile.md)). The list's rows are 28 pt. The detail
column is a grouped form (TASK-338) in a column scroll view of its own
(TASK-211; before, in the pane's scroll view, so scrolling it moved the list
too), as tall as its content:

- a top group, as System Settings' Wi-Fi pane opens: a header row
  (`SettingsFormRow(content:)`: the icon, the 13 pt bold name, the version
  and the description, "Settings…" on the right edge level with the icon,
  added after the text so VoiceOver reads the name first; the icon, here and
  in the list's rows, is decorative and out of the Accessibility tree, on the
  view and its cell, since the name follows it: it was read as an unnamed
  image), the source row
  ("Loaded unpacked" or "Installed from…", the folder or the last check as a
  one-line detail, Reload or Check for Updates) and the staged update's row
  with Install Now;
- the permissions an update added, as a row of their own group ("Version X
  needs new permissions", the permissions as its help, Accept and Enable,
  and a warning line "Turned off until you accept them."; before, an orange
  banner);
- Enabled; "Profiles" (which profiles have it on, as help, and Turn On in
  All Profiles); Allow in Private (its note as help);
- Permissions, Optional Permissions, Requested Sites and Site Access, each
  a section of named switch rows (the switches' identifiers keep
  `id\tkey\ttype`), or the footnote "No special permissions requested."

**Uninstall Extension** is not in the column: it sits
under it, 20 pt below the column's scroll view and level with the bottom of
the list, so it stays in view however far the details scroll (user request
during TASK-211; Spaces and Profiles have no comparable action at the end of
their details, since deleting goes through the list's − button, which is
always in view). The layout choices above (the header row, the pending
group, the sections' titles, the new wording) are PROVISIONAL, chosen by
Claude while the user was away.[^task-338] The behaviour behind those controls is
covered by [extension manager](../extensions/extension-manager.md),
[permissions](../extensions/permissions.md) and
[updates](../extensions/updates.md).

The detail view is **rebuilt** on every `extensionsDidChangeNotification`,
which an update itself posts. State that must survive a rebuild therefore
lives on the view controller, not in the views: the selection is tracked by
extension id (an update or reload replaces the extension and appends the
replacement, so an index would jump to another extension), and so are the
result of the last update check and the set of checks still running.

## Content Blocking

A [grouped form](#the-grouped-form-task-338) since TASK-338. **Filter
Lists**: one row per list, its status on the right ("Active" in green, "Not
loaded", "Updating…": `filterListStatus`) and under its name the rules in
the list, the rules compiled and the last fetch ("74,713 rules, 74,713
active, updated 12 sec. ago", "Never updated": `filterListDetail`); a
footnote with the total of active rules and what is being fetched
(`totalsText`); "Clear Cache & Redownload" and "Update All Now" under the
group. Until then the lists were a five-column table sized to its rows
(name, In List, Active, Status, Last Updated), with the total and the
buttons under it; the rows keep all five, in words. (PROVISIONAL, chosen by
Claude while the user was away; the alternative is the table inside the
group as a custom row.) The rows refresh on `.contentBlockerStatusDidChange`
and `.contentBlockerRulesDidChange`. Which lists are *enabled* is a
per-profile setting on the Profiles pane, not here.

Under the buttons, a "Tracking Parameters" section (TASK-337; named
"Copied Links" until 2026-11-15, renamed by the user since its help also
covers quarantine pages) holds the one
app-wide switch of the pane: "Remove tracking parameters with the AdGuard
URL Tracking filter" (`trackingParameterListEnabled`, a form row since
TASK-338, on by default), help saying Copy URL, Copy Link, Share… and
Quarantine leave out common tracking parameters, that the list adds the
ones particular sites use, and that it blocks nothing, and a status line
(`trackingParameterListStatus`: "2,665 rules, updated 3 hr. ago", "Not
downloaded yet", or "Off: not downloaded or used", from
`trackingListStatus`, a detail line of its row). It is a section of its
own rather than a fifth list, since the lists are what blocks content. The switch calls
`ContentBlockerManager.setTrackingParameterListEnabled`; what off does is on
[Copy URL](./copy-url.md#the-downloaded-filter-task-329). The buttons carry
identifiers (`contentBlockerUpdateAll`, `contentBlockerClearCache`) for
Accessibility-driven checks.[^task-337]

# Gotchas

- **A required equality to the body's bottom caps the window.** If a body's
  content is pinned to the bottom with `==` and nothing in it can stretch,
  the scroll area gets a maximum height, and AppKit snaps the window to it the
  moment the pane is swapped in, with no animation (Content Blocking did this
  when shrinking onto it). Pin with `<=` plus a low-priority `==`
  (`bottomHug`), or let something stretch (a list column).[^task-189]
  This is about a scrolling body, whose document is at least as tall as the
  visible area. A column scroll view's document has no such tie to the
  window, so a column's content pins its bottom with `==`.[^task-211]
- **The overlay scroller of a detail column draws over its right edge.**
  The column ends at the pane's 20 pt margin, so while it scrolls the
  overlay scroller sits over the column's last few points (a group's
  border); the old whole-body scroller sat in the window's margin. With
  "always show scroll bars" the clip view narrows instead and the wrapping
  labels re-measure.[^task-211]
- **Bounds and animation.** Setting `contentMaxSize` below the window's
  current height (or `contentMinSize` above it) resizes the window at once.
  `fitWindow` widens the bounds to cover the current height, animates, and sets
  the pane's bounds in the completion. A pane's own refit can land
  mid-animation (Profiles reports from `viewWillAppear`); it must start from
  the animation's target height, not the window's intermediate one, or the
  window stops at the 400 minimum.[^task-189]
- **A replaced animation still completes (TASK-340).** A refit mid-animation
  starts a new animation; the one it replaces still calls its completion,
  and when both head to the same height (a list pane opened on another row
  refits as its rows and labels settle, often to the height it is already
  going to) the completion matched on the fit and the height took it for the
  newer one's: it cleared the target while the window was mid-resize, the
  next refit read the intermediate height as one the user dragged to and
  kept it, and the window stopped short (671 pt of content on the
  pre-TASK-338 Profiles pane, whose normal profile needed about 709).
  Each fit now takes a generation number and only the newest fit's
  completion applies the bounds and clears the target. The animator is
  `SettingsWindowController.animateFrame`, replaced in
  `SettingsWindowFitTests` to end the animations in a chosen order (the race
  test failed before the fix: the target was gone). Checked at runtime:
  Profiles opened first on rows 1 and 2 ends at its natural 1008 pt.[^task-340]
- **Measure wrapped text with a wrap width.** `fittingSize` does not do the
  two-pass layout a wrapping `NSTextField` needs: a wrapping label without
  `preferredMaxLayoutWidth` measures as one line. A constant wrap width
  goes wrong when the column's width does (legacy scrollers), so bodies use
  `SettingsWrappingLabel`, which takes its own width at layout and refits
  the pane when it changes; only the pane description, outside the scroll
  view, keeps a constant.[^task-189]
- **Text that does not fit must truncate.** With the width locked, a label
  at compression 750 squeezes its neighbours instead of widening the window:
  a long extension name in Profiles took 5 pt from the "Search suggestions"
  label. Long names get `.byTruncatingTail` and low compression
  resistance.[^task-189]
- **`NSStackView.edgeInsets` on the cross axis are soft.** They act at hugging
  priority only; in a height-constrained column the bottom inset collapses
  silently while the top one survives. Use your own required constraints for
  insets that must hold, pin the content's bottom to the container, and give
  the content required vertical compression resistance.[^layout-notes]
- **`NSBox` does not grow to an Auto Layout content view's fitting height.**
  The pending-permissions banner (`TintedBannerView`) and the bordered
  groups (`SettingsGroupBoxView`) were custom views for that reason, until
  the grouped form replaced them (TASK-338).[^layout-notes]
- **Measure, do not eyeball.** Log `convert(bounds, to: nil)` gaps and search
  the log for "Unable to simultaneously satisfy".[^layout-notes] See
  [AppKit gotchas](../platform/appkit-gotchas.md).
- **Capturing the window**: `cacheDisplay` works in light mode; after forcing
  a dark appearance the window background rendered transparent in
  captures.[^layout-notes] The TASK-189 harness shoots the window with
  `screencapture -l <windowNumber>` from a watcher instead. See
  [in-process UI automation](../playbooks/in-process-ui-automation.md).
- **A list border set as a `CGColor` keeps its appearance.**
  `NSColor.separatorColor.cgColor` resolved once at creation stayed the light
  colour and vanished in dark mode (29,30,30 on 32,33,33); resolve it in
  `updateLayer` (`SettingsListContainerView`): 54,55,55 now.[^task-189]
- **Driving and measuring the window at runtime.** Posted
  `leftMouseDown/Dragged/Up` events at the window's bottom edge (y = 1)
  resize it as a person's drag does, and respect `contentMin/MaxSize`. An
  animated resize cannot be sampled from a main-thread timer;
  `CGWindowListCopyWindowInfo` on a background thread sees every
  frame.[^survey-harness]
- **Scroll-wheel events for a harness: leave out the gesture phases.** A
  `CGEvent` scroll with `.began`/`.changed`/`.ended` phases, turned into an
  `NSEvent` and handed to the hit view's `scrollWheel(with:)`, left a column
  whose content fits overscrolled by 400 pt (the rubber band never sprang
  back); a phase-less event (a mouse wheel's) scrolls and clamps as a person's
  would.[^task211-harness]
- **A shell-launched instance never becomes the key app**, so anything that
  depends on `NSApp.keyWindow` cannot be driven that way.[^layout-notes]
- **`TabStore.updateProfile` always posts `UserAgentDidChange`.** Every
  profile edit, whatever the field, saves the profile row and posts that
  notification with the profile's id; each `BrowserTab` observes it. The
  content-blocker toggles additionally call `reapplyRuleLists()`, which
  reaches only the selected tab's panes (see
  [content blocking](./content-blocking.md)).

# Tests

`SettingsPaneHeightTests` covers the height rule (cap, minimum, short
screens, refit); `SettingsPaneColumnsTests` the two pane forms with a fake
list pane and the real panes (the list and the detail column filling the
body below the description at every height from the 200 pt floor to 900,
each scrolling without moving the other, the detail document as tall as its
content, the natural height from the detail content or the rows and never
from the window, a scrolling body still one scroll view, which panes take
which form, the toolbar order with Quick Detour after Links, the Quick
Detour pane's natural height, Links fitting the 400 pt minimum, and the end
anchoring of `SettingsColumnScrollView`); `LinkRouteEditorTests` the Links pane's rules (target
menus, drag destination, warnings, drafts); `ProfileSettingsLayoutTests` the Profiles sections and which
rows show for a normal and the Private profile;
`SettingsGuideLinkTests` the Learn more links (`GuidePage` URLs under the
Help menu's guide index, which links each pane has, a click handing its URL
to the opener, the link under the description or in its place, and the
natural height counting it); `SettingsSwitchRowTests` the switch rows (no
pane has a checkbox, the five converted settings are switches named by
their labels, General's each 8 pt after its label and centred on it and
Quick Detour's on the form's right edge, the labels plain text, the
Shortcut row right under the hotkey switch's, the Peek and ⌥⌘-click
switches showing and writing their settings; since TASK-336 every switch in
every pane and in the page popover named by the label beside it, and the
Accessibility tree, walked as a client gets it, holding each switch and not
its label); `SettingsFormTests` the grouped form (every control on one
right edge and every name on one left edge at 443 and 700 pt, long names
and help wrapping before the control with no overlap, controls on the
name's first line, row, section and form heights, hidden rows and sections
taking no room, the first measurement equal to the laid-out height for the
form and the two pilot panes, each control named by its row and read once,
the warning line, header accessories, turned-off rows, 44 pt button rows,
the Increase Contrast border) and the Content Blocking rows, buttons and
texts; `SettingsPanesFormTests` General (its controls on the form's edges,
the Automation sections' identifier, hidden button rows), Spaces' detail
form and its grids named once, Links' Default section, the lists drawn as
groups with their titles on the text edge, and that no pane draws a
material of its own (Reduce Transparency has nothing to change);
`SettingsProfilesExtensionsFormTests` the Profiles and Extensions details
(controls on the right edge, names on the left, Profiles normal and
Private, rows and sections hidden per `ProfileSettingsState`, filter lists
off while blocking is off, extension rows turned off and rebuilt, the
pending permissions, identifiers, Learn more pages and switch names, the
first measurement equal to the laid-out height, `setRows` and
`SettingsFormRow(content:)`). `SettingsCaptureHarnessTests` is a capture
harness, skipped unless `TEST_RUNNER_SETTINGS_CAPTURE_DIR` names a folder:
it draws every pane in light and dark with Increase Contrast forced through
`SettingsGroupStyle.increaseContrastOverride`. The
panes have no other UI tests; their layout is
checked at runtime with the TASK-189 survey harness (every pane and state,
light and dark, frames measured; pane switches, drags, the cap and a real
second screen; uninstalling the only extension through the pane; a run with
`-AppleShowScrollBars Always`) and the TASK-211 harness (every list pane at
its minimum with 18 spaces, 15 profiles, 14 extensions and 12 routes:
scroll-wheel events over the details and over the list, frames and offsets
logged to show the other did not move, a list scrolled to its end kept there
when the window shrinks by 50 pt, Links' Default and caption unmoved by a
wheel over the routes or over them, a 520 pt screen capping the panes at
352, the Quick Detour pane; light and dark). Their behaviour is tested through the model code they call: `TabStoreTests` and the profile and space suites,
`ExternalAppPermissionTests`, `ContentBlockerWhitelistTests`,
`ExtensionOptionsPageEntryTests`, and the extension update and permission
suites.

# Related

- [Profiles and spaces](../architecture/profiles-and-spaces.md) - the model the Spaces and Profiles panes edit.
- [Content blocking](./content-blocking.md) - lists, toggles and the per-site switch.
- [External apps](./external-apps.md) - the saved permissions the Profiles pane can clear.
- [Extension manager](../extensions/extension-manager.md), [permissions](../extensions/permissions.md), [updates](../extensions/updates.md) - what the Extensions pane drives.
- [Popup and options UI](../extensions/popup-and-options-ui.md) - the "Settings…" button and the sidebar's settings popover.
- [App shell](../architecture/app-shell.md) - the menu items that open the window.
- [Keyboard shortcuts](./keyboard-shortcuts.md) - the Shortcuts pane's behaviour.
- [AppKit gotchas](../platform/appkit-gotchas.md) - the stack-view and layout traps in general form.

[^layout-notes]: Settings pane layout lessons
[^task-292-11]: TASK-292.11
[^task-189]: TASK-189
[^task-211]: TASK-211
[^task-328]: TASK-328
[^task-336]: TASK-336
[^task-337]: TASK-337
[^task-338]: TASK-338
[^task-340]: TASK-340
[^task211-harness]: TASK-211 harness
[^survey-harness]: TASK-189 survey harness
