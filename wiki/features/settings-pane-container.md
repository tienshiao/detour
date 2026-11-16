---
type: Component
title: Settings pane container
description: "SettingsPaneViewController, the base of every Settings pane: the description and Learn more header, the two body forms (one scrolling body, or since TASK-211 a list and detail column fixed to the pane that scroll on their own), how the natural height is measured and changes reported, SettingsMetrics, the wrapping label and the list group."
resource: ../../Detour/Browser/Settings/SettingsPaneViewController.swift
tags: [settings, appkit, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: container
    resource: ../../Detour/Browser/Settings/SettingsPaneViewController.swift
    title: SettingsPaneViewController.swift (pane container, list group, wrapping label)
  - id: metrics
    resource: ../../Detour/Browser/Settings/SettingsMetrics.swift
    title: SettingsMetrics.swift
  - id: columns-tests
    resource: ../../DetourTests/SettingsPaneColumnsTests.swift
    title: SettingsPaneColumnsTests.swift
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents (and the Quick Detour pane)"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
---

# Role

`SettingsPaneViewController` is the base of every pane of the
[Settings window](./settings.md). It lays out the pane's header and body,
measures the pane's natural height for the
[height rule](./settings-window-height.md), and passes height changes to
the window controller. TASK-189 part 1 moved every pane into it; part 2
rebuilt Profiles and Extensions on it.[^task-189]

# How it works

## Header

A fixed **description** sits at the top (`paneDescription`, wrapped at
`740 - 2 * 20`), with the pane's Learn more link (`guidePage`) 4 pt under
it. Extensions and Quick Detour have no description, so their link sits
20 pt below the toolbar (see
[Settings Learn more links](./settings-learn-more-links.md)); General has
neither and starts its body 20 pt below the toolbar.

## The two body forms

Below the header the pane's **body** (`makeBody()`) takes one of two forms,
chosen by `scrollsBodyAsWhole`:[^task-211]

- **One scrolling body** (the default: General, Quick Detour, Content
  Blocking). The body is the document of an `NSScrollView` (flipped clip
  view) that fills the rest of the pane, inset by 20 on the sides and
  bottom. The document is pinned to the clip view's width, and is at least
  as tall as the visible area (a `>=` plus a priority-49 `==`).
  `scrollView` is that scroll view. A form body pins its content's bottom
  with `<=` plus `bottomHug`; see
  [the trap](./settings-window-height.md#applying-a-fit).
- **Fixed columns** (`scrollsBodyAsWhole == false`: Spaces, Links,
  Profiles, Search, Shortcuts, Extensions). The body is pinned to the
  pane's edges, 12 below the description (or its link) and 20 from the
  sides and bottom; `scrollView` is nil. The master list (its group, table
  and +/- bar) fills the body's height, and so does the detail column,
  which is a `makeColumnScrollView(document:estimatedWidth:)`: a
  `SettingsColumnScrollView` (flipped clip view, autohiding scroller) whose
  document is pinned to its top and width and is as tall as its content (a
  pane pins its content's bottom to the document with `==`; a priority-1
  zero height defines an empty column). Each scrolls only its own
  contents, so scrolling the details never moves the list, and the other
  way round.
  - When the details show another item than before (tracked by id:
    `shownSpaceID`, `shownProfileID`, `shownExtensionID`, so a click, an
    add, a delete, an uninstall or `showSpacesPane(selectSpaceID:)` all
    count) the pane calls `scrollColumnsToTop()`, so they start at the top;
    a rebuild for the same item (an extension's switch toggled, an update)
    keeps the offset.
  - Links has no detail column: its route list is the scrolling column, and
    the Default with its caption are fixed below it (see
    [Settings panes](./settings-panes.md#links)). Search and Shortcuts are
    one list that fills the body.

Before TASK-211 every pane scrolled as one body, so scrolling a long detail
column moved the list with it.[^task-211]

## SettingsColumnScrollView

The scroll view of every master list and detail column. In `tile()`, a
column scrolled to its end (and long enough to scroll) is put back at its
end after the clip view is resized, so dragging the window shorter or a
refit never slides the last rows out of view; anywhere else the offset is
kept, and content that fits stays at its top. The sidebar's `SpacePageView`
does the same in its `layout()` (TASK-192).

Its overlay scroller draws over the column's right edge: the column ends at
the pane's 20 pt margin, so while it scrolls the scroller sits over the
column's last few points (a group's edge); the old whole-body scroller sat
in the window's margin. With "always show scroll bars" the clip view
narrows instead and the wrapping labels re-measure.[^task-211]

## Natural height and changes

- `naturalContentHeight` = margin + description (+ 4 + link) + 12 + the
  body's height + margin. The body's height is its `fittingSize` at its
  width (the clip view's in a scrolling body, narrower with legacy
  scrollers). In a column pane each visible column scroll view is held,
  for the measurement, at the full `fittingSize` of its document (measured
  at its clip view's width, its `estimatedWidth` before the first layout),
  so the body's fitting height counts the whole column plus anything above
  or below it (Extensions' Uninstall button). The stretch constraints are
  switched off while measuring, so the window's current height never feeds
  back into it.
- `idealBodyHeight(fittingHeight:)` lets a list pane ask for the height
  that shows every row (rows + the 29 pt button bar).
- A pane calls `contentHeightDidChange()` when rows appear or disappear or
  a list's length changes (Spaces add/delete, Profiles selection and the
  rows it hides, Extensions rebuilds and selection, Content Blocking's
  rows); form rows call it themselves when their help or warning changes
  (see [Settings grouped form](./settings-grouped-form.md)). Calls in one
  run-loop turn are coalesced and the window controller refits if the pane
  is the shown one. Spaces' height does not depend on its selection, so it
  does not report it.
- `paneDidFit()` runs after each fit (Spaces scrolls its selection into
  view there).

## SettingsListContainerView

Holds a list (Spaces', Profiles' and Extensions' master lists, Search's
site searches, Links' routes, the Shortcuts list) and draws it as a
grouped form's group in `updateLayer`, so it follows the appearance: the
12 pt rounded fill, its rows clipped to the shape, a 1 pt separator border
under Increase Contrast (`SettingsGroupStyle`). A list's title is a 13 pt
semibold header on the rows' text edge (`settingsSectionTitle`).[^task-338]
Until TASK-338 it was `SettingsBorderedView`, a 4 pt rounded 1 pt
separator-coloured border shared with `SettingsGroupBoxView`, the bordered
box of switch rows that grew with its rows where an `NSBox` does
not;[^task-189] the form's groups replaced both and `SettingsBorderedView`
was folded into this class.

## SettingsWrappingLabel

The wrapping label of every body (help text, descriptions, an extension's
name): its wrap width (`preferredMaxLayoutWidth`) is its own width, taken
in `setFrameSize`, and when that changes it re-measures and calls the
enclosing pane's `contentHeightDidChange()` (found through the responder
chain). Its `estimatedWidth` (the column's width with overlay scrollers)
is used until the first layout, so the first `fittingSize` measurement is
already right in the usual case. Its owner gives it a definite width (both
edges pinned or a width constraint). The wrap width used to be a constant,
the column's width, which with "always show scroll bars" (a clip view
17 pt narrower) cut the last line.[^task-189]

# SettingsMetrics

| Metric | Value |
|---|---|
| Window width | 740 |
| Pane margins, section gap, list to detail column | 20 |
| Description to body | 12 |
| Between rows | 10 |
| Control to its help text | 4 |
| Label to control | 8 |
| Text field width, cap on a detail pop-up | 260 |
| Master list | 220 wide, 28 pt rows, 24 pt +/- buttons, a 29 pt bar |
| Detail column | the rest: 740 − 2 × 20 − 220 − 20 = 460 |
| List pane minimum height | 400 |
| Design maximum content height | 720 (TASK-347) |
| Screen margin for the cap, smallest cap | 80, 200 |

The detail column starts level with the top of the list. The grouped
form's own metrics (`SettingsMetrics.form…`) are on
[Settings grouped form](./settings-grouped-form.md#metrics). Until TASK-338
a right-aligned 124 pt label column (Profiles, Spaces), 8 pt from a section
title to its first row and bordered groups with 10 / 8 pt insets set the
details; those metrics were removed with them.

# Tests

`SettingsPaneColumnsTests` covers the two forms with a fake list pane and
the real panes: the list and the detail column filling the body below the
description at every height from the 200 pt floor to 900, each scrolling
without moving the other, the detail document as tall as its content, the
natural height from the detail content or the rows and never from the
window, a scrolling body still one scroll view, which panes take which
form, the toolbar order (TASK-347's), the Quick Detour pane's natural
height, Links fitting the 400 pt minimum, and the end anchoring of
`SettingsColumnScrollView`.[^columns-tests]

# Related

- [Settings window](./settings.md) - the window and the pane list.
- [Settings window height](./settings-window-height.md) - what the natural height feeds.
- [Settings grouped form](./settings-grouped-form.md) - what the bodies are built from.
- [Settings layout traps and runtime checks](./settings-layout-traps.md) - why the wrap width and insets are done this way.

[^task-189]: TASK-189
[^task-211]: TASK-211
[^task-338]: TASK-338
[^columns-tests]: SettingsPaneColumnsTests.swift
