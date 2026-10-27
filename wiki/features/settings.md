---
type: Component
title: Settings window
description: "The Settings window and its seven panes (General, Spaces, Links, Quick Detour, Profiles, Extensions, Content Blocking): what each one edits, how changes reach TabStore, the shared metrics and pane container (one scrolling body, or since TASK-211 a list and detail column fixed to the pane and scrolling on their own), the height rule (natural height, capped to the screen, resizable in height only) and the layout traps met on the way."
resource: ../../Detour/Browser/Settings
tags: [settings, appkit, profiles, spaces, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T06:00:00Z }
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
    title: LinksSettingsViewController.swift (Air Traffic Control routes, TASK-191.3)
  - id: profiles
    resource: ../../Detour/Browser/Settings/ProfilesSettingsViewController.swift
    title: ProfilesSettingsViewController.swift
  - id: extensions
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift
  - id: content-blocker
    resource: ../../Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
    title: ContentBlockerSettingsViewController.swift
  - id: layout-notes
    resource: "Agent session notes, 2026-09-25 and 2026-09-26: Settings pane layout (not in the repository)"
    title: Settings pane layout lessons
---

# Role

`SettingsWindowController.shared` is one window with a preference-style
toolbar and seven panes. It holds no settings of its own: each pane reads and
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
- The seven view controllers (in toolbar order: General, Spaces, Links,
  Quick Detour, Profiles, Extensions, Content Blocking;
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
`740 - 2 * 20`); a pane without one (Extensions, Quick Detour) starts its
body 20 pt below the toolbar. Below it the pane's **body** (`makeBody()`)
takes one of two forms, chosen by `scrollsBodyAsWhole`:[^task-211]

- **One scrolling body** (the default: General, Quick Detour, Content
  Blocking). The body is the document of an `NSScrollView` (flipped clip
  view) that fills the rest of the pane, inset by 20 on the sides and
  bottom. The document is pinned to the clip view's width, and is at least
  as tall as the visible area (a `>=` plus a priority-49 `==`). `scrollView`
  is that scroll view.
- **Fixed columns** (`scrollsBodyAsWhole == false`: Spaces, Links,
  Profiles, Extensions). The body is pinned to the pane's edges, 12 below
  the description and 20 from the sides and bottom; `scrollView` is nil.
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
- `naturalContentHeight` = margin + description + 12 + the body's height +
  margin. The body's height is its `fittingSize` at its width (the clip
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
- `SettingsBorderedView` draws a 1 pt separator-coloured rounded border in
  `updateLayer`, so it follows the appearance. `SettingsListContainerView`
  (around a master list) and `SettingsGroupBoxView` are its subclasses.
- `SettingsGroupBoxView` is a bordered group of rows (Profiles' filter lists
  and extension switches, an extension's permissions): a vertical stack inset
  10 / 8 by required constraints, every row pinned to the group's width. Its
  height is its rows' height plus the insets, so it grows and shrinks with
  them, which an `NSBox` does not; a long name in a row truncates instead of
  widening it.[^task-189]
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
| Section title to its first row | 8 |
| Between rows | 10 |
| Control to its help text | 4 |
| Label to control | 8 |
| Label column (right-aligned) | 124 |
| Text field width, cap on a detail pop-up | 260 |
| Master list | 220 wide, 28 pt rows, 24 pt +/- buttons |
| Bordered group | insets 10 (sides) and 8 (top, bottom), 6 between rows (4 in a permission list) |
| List pane minimum height | 400 |
| Screen margin for the cap | 80 |

The detail column starts level with the top of the list. Grid labels sit on
their control's first baseline (`rowAlignment = .firstBaseline`); a row
whose control has no text (the colour well, a switch) is centred instead. A
section title is 12 pt semibold, like System Settings' group headers.

| Pane | Content height (examples measured 2026-10-24) | Opened by |
|---|---|---|
| General | 90, fixed | Detour > Settings… (Cmd+,), which opens whatever pane was last shown |
| Spaces | 400 minimum; 628 with 19 spaces | the sidebar's add-space and edit-space actions (`showSpacesPane(selectSpaceID:)`), the Spaces menu's Manage Spaces… (`openSpacesSettings`) |
| Links | 400 minimum (no routes); 743 with 5 routes (measured before the Quick Detour section came and went); capped (1242 on a 1410 pt screen) with 12 routes, then the route list scrolls (177 pt of list at 400, 129 pt at a 352 pt cap, 2026-10-27) | toolbar; Open Links Settings… in the blocked space-deletion alert (`showLinksPane(highlightingSpaceID:)`) |
| Quick Detour | 248, fixed (with the Debug build's warning line, 2026-10-27) | toolbar only |
| Profiles | 630 (Private) / 709 (a normal profile) to 1218 (custom UA, warning, 15 extensions); 1047 for Private with 14 extensions (2026-10-27) | toolbar only |
| Extensions | 400 (none, or one small extension) to 1092 (22 permissions, 4 hosts, 6 optional) | Extensions > Manage Extensions…, the settings popover (`showExtensionsPane()`) |
| Content Blocking | 243, fixed | toolbar only |

TASK-189 part 1 moved every pane into the container and rebuilt General,
Content Blocking and Spaces on the metrics; part 2 rebuilt Profiles (titled
sections) and Extensions (one column in the pane's scroll view).

## General

One control: "Set as Default Browser". It calls
`NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and
`https`, and reports the current state by asking which application would open
`https://example.com`.

## Spaces

A list of the non-incognito spaces with name, emoji, colour and profile.
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

Air Traffic Control's routes and Default: "Routes" with New Route beside
it, one bordered list of three-line rows (URL, From app, Open in), then the
Default and its caption. Not a master list with a detail column: every route
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
list, so it scrolls as one body, like General; no description and no
section title (the toolbar names it). Top to bottom:

- "[✓] Open Quick Detour from any app with" and the shortcut recorder
  (`ShortcutRecorderView`), a warning line when the shortcut is refused or
  not registered (a Debug build says it does not register without
  `DETOUR_GLOBAL_HOTKEY=1`), and help text (TASK-193.2; see
  [the Settings control](./quick-detour.md#the-settings-control)).
- "Open links and sidebar tabs in Quick Detour with ⌥⌘-click" and its help,
  the idle auto-close pop-up ("Close Quick Detour windows not used for
  [Never, 1 hour, 6 hours, 12 hours, 1 day]", 6 hours by default) and its
  help, and a caption pointing links from other apps to a route's Open in
  or the Default "on the Links pane" (TASK-193.5; see
  [the Settings section](./quick-detour.md#the-settings-section)).

The pane retries a refused shortcut when it appears
(`QuickDetourHotKey.retryIfFailed`) and ends a recording when it disappears.

## Profiles

A list of the profiles plus the built-in Private profile, and the selected
profile's settings in titled sections. Each control writes a property and
calls `TabStore.shared.updateProfile(profile)`. In the list a long profile
name truncates with an ellipsis and gives way before "N Spaces".

| Section | Rows | Shown |
|---|---|---|
| (no title) | Name; "This profile is used for Private Windows." | the note only for Private; the name is not editable there |
| Search | Search engine (Google, DuckDuckGo, Bing, Yahoo, Ecosia, Kagi); Search suggestions | always. Suggestions gate the network row of the [suggestion pipeline](./suggestion-pipeline.md) |
| Tabs | Archive tabs after; Sleep tabs after; Per-tab isolation (each tab its own non-persistent data store); the warning that sleeping tabs lose session data under isolation | archive hidden for Private; the warning when isolation is on and tabs sleep |
| Content Blocking | Block content (the master switch); the four filter lists in a bordered group | always; the lists are disabled while blocking is off, each toggle calls `reapplyRuleLists()` |
| Extensions | one switch per installed extension, in a bordered group | when any extension is installed, Private included |
| User Agent | Identify as (Detour, Safari, Custom); Custom string; a preview of the resulting user agent | the string only for Custom |
| External Apps | Saved permissions: the count and Clear | hidden for Private (it never remembers one). See [external apps](./external-apps.md) |

Why this grouping: the untitled first section holds the name, which
identifies the profile as an account name heads a System Settings pane (a
"Profile" title would repeat the pane); per-tab isolation sits with the
tab lifecycle rows because its warning is about sleeping tabs, and the
warning sits right under it; each other section is one thing a person looks
for by name. Row labels do not repeat their section's title ("Block content",
"Identify as", "Saved permissions").

`ProfileSettingsLayout` is the pure rule: which rows a `ProfileSettingsState`
(Private, isolation, sleeping, custom user agent, any extension installed)
shows, which sections have a visible row, and the space above each row (0
for a section's first visible row, 4 for help text, 10 otherwise). The view
controller keeps each row's `NSGridRow` and each section's view by these
enum values and applies the rule in `applyRowLayout()` (called on selection,
on the switches and pop-ups that change visibility, and on extension
changes), which also reports the height change. Each section is its own
grid with `rowSpacing = 0`; the spacing is each row's `topPadding`, so a
hidden row leaves no gap and help text sits 4 pt below its control. Help
text, the groups and the custom string field take the whole control column
(the section's width less the 132 pt label column).

A profile cannot be deleted while a space uses it ("Remove or reassign those
spaces first"), the Private profile cannot be deleted, and the last profile
cannot be deleted. What deleting does to the profile's data is on
[profile data removal](../architecture/profile-data-removal.md).

The per-profile extension switch shows the profile's own saved choice. While
the extension is turned off globally the switch is disabled and the name
dimmed, rather than hidden: it tells the user what turning the extension back
on will restore. For the Private profile it is the same opt-in as "Allow in
Private" on the Extensions pane; see
[private profile extensions](../extensions/private-profile-extensions.md).

## Extensions

A list of installed extensions and a detail view for the selected one:
version, a "Settings…" button when the extension declares an options page,
Enabled and "Allow in Private" switches, API permissions and site-access
decisions with their own switches, the install source with "Check for
Updates" / "Reload" / "Install Now" and the banner for permissions an update
added, and Uninstall. "Add Extension…" offers loading an unpacked extension
or opening the Chrome Web Store. The list's rows are 28 pt. The detail
column is one vertical stack in a column scroll view of its own (TASK-211;
before, in the pane's scroll view, so scrolling it moved the list too), as
tall as its content: the header (icon; the name, wrapping to two lines and then
truncated; the version; "Settings…" at the trailing edge), the description,
the source and update rows, the pending-permissions banner (it makes the
column taller and squeezes nothing), Enabled, Allow in Private and its note,
"Permissions". **Uninstall Extension** is not in the column: it sits
under it, 20 pt below the column's scroll view and level with the bottom of
the list, so it stays in view however far the details scroll (user request
during TASK-211; Spaces and Profiles have no comparable action at the end of
their details, since deleting goes through the list's − button, which is
always in view). The permissions are a bordered group as
tall as its rows (one permission: 32 pt), or one line of text when the
extension asks for none; there is no inner scroll view any more (it had a
96 pt floor and put a one-line list in a 287 pt box). The behaviour behind those controls is
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

A table of the four filter lists (name, parsed rules, compiled rules, status,
last fetch), a total of active rules, "Update All Now" and "Clear Cache &
Redownload". The table is sized to its header and rows (`updateTableHeight`),
so there are no empty striped rows under the four lists and the pane is
exactly as tall as its content; the alternative, letting the table fill a
fixed pane, left 28 pt of empty stripes. It refreshes on `.contentBlockerStatusDidChange` and
`.contentBlockerRulesDidChange`. Which lists are *enabled* is a per-profile
setting on the Profiles pane, not here.

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
  The pending-permissions banner uses a custom view (`TintedBannerView`) and
  the bordered groups `SettingsGroupBoxView` for that reason.[^layout-notes]
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
menus, drag destination, warnings, drafts); `ProfileSettingsLayoutTests` the Profiles sections, which
rows show for a normal and the Private profile, and the row spacing. The panes have no dedicated UI tests; their layout is
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
- [AppKit gotchas](../platform/appkit-gotchas.md) - the stack-view and layout traps in general form.

[^layout-notes]: Settings pane layout lessons
[^task-189]: TASK-189
[^task-211]: TASK-211
[^task211-harness]: TASK-211 harness
[^survey-harness]: TASK-189 survey harness
