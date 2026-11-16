---
type: Feature
title: The Links pane
description: "The Settings Links pane that edits Link Routes (TASK-191.3): one three-line row per route (URL, From app, Open in) with a drag handle and a wrapping warning line, New Route, the Default with its caption; Any URL, an app with an empty pattern and Any App as the 'no condition' choices; drafts and refused edits kept on their rows while the store keeps the last valid route; broken routes; live updates; the blocked-deletion alert's highlighting; and the runtime checks."
tags: [links, settings, ui]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
sources:
  - id: pane
    resource: ../../Detour/Browser/Settings/LinksSettingsViewController.swift
    title: LinksSettingsViewController.swift (the Links pane)
  - id: editor
    resource: ../../Detour/Browser/Settings/LinkRouteEditor.swift
    title: LinkRouteEditor.swift (the pane's rules and rows)
  - id: validation
    resource: ../../Detour/Browser/LinkRouting/LinkRouteValidation.swift
    title: LinkRouteValidation.swift (linkRouteProblems)
  - id: editor-tests
    resource: ../../DetourTests/LinkRouteEditorTests.swift
    title: LinkRouteEditorTests.swift
  - id: task-191-3
    resource: backlog:TASK-191.3
    title: "TASK-191.3: Settings UI to add, edit, reorder and remove routes"
  - id: harness-3
    resource: ../../docs/harness/task191-3-harness.patch
    title: TASK-191.3 runtime harness
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: task-302
    resource: backlog:TASK-302
    title: "Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL"
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
---

TASK-191.3.[^task-191-3] Settings has its own **Links** pane (toolbar item
`arrow.triangle.branch`, after Spaces; user decision 2026-10-25: not a
section of the Spaces pane), after Arc's sheet in `docs/air-traffic-control/`.
Every route is edited in place; validity is the
[store's](./link-routing-store.md#validation), never the pane's. Part of
[Link Routes](./link-routing.md); the pane's layout within the Settings
window is on [Settings panes](./settings-panes.md#links).

# What it shows

| Part | What it shows |
|---|---|
| Description | What Link Routes do ("Link Routes open links in the space you choose: …"), that routes are tried from the top and the first match decides, and that rows drag. A "Learn more" link to the Link Routes guide page sits under it ([Learn more links](./settings-learn-more-links.md)). |
| Routes | A "Routes" header with **New Route** at the trailing edge, then a list drawn as a form group (TASK-338): one row per route, three lines (`URL [kind ▾] [pattern] ⊖`, `From app [app ▾]`, `↳ Open in [target ▾]`), a drag handle at the left, and, when the row has a problem, a fourth line: an orange triangle and the whole warning, wrapping, under Open in. No routes: one centred line in the box. |
| Default | A form section (TASK-338): the row "Open other links in [target ▾]" with its warning line, tinted when the blocked deletion points to it, and a caption as the group's footnote with the Quarantine guide: it applies to every link no route matches (from other apps, typed in a new tab, clicked to another site), and Most Recent Space opens a link from another app in the space in front and leaves a typed or clicked link where it is. |

The route list fills the pane's height and scrolls its own rows; the Default
and its caption stay at the bottom (TASK-211).[^task-211] The Quick Detour
section that followed the caption (TASK-193.2, TASK-193.5) is a pane of its
own since TASK-211; see [Settings panes](./settings-panes.md#quick-detour).

- **Match kind pop-up**: Domain is, Contains, Is equal to, then **Any URL**
  (`match == nil`). The pattern carries over when the kind changes; Any URL
  hides the field. Placeholders (`linkRoutePatternPlaceholder`):
  `example.com`, `text in the address`, `https://example.com/page`; with an
  app chosen they read "Any URL from this app, or a domain such as
  example.com" (… "or text in the address", … "or
  https://example.com/page"), since the empty field then means any URL
  (TASK-302).[^task-302]
- **From app pop-up**: **Any App** (no source condition), the regular apps
  running now (icon and name; Detour itself left out; rebuilt as the menu
  opens), the route's own app first when it is not running (name and icon
  from where it is installed, else the bundle ID), then **Choose…**: an
  `NSOpenPanel` sheet on `/Applications` for any `.app`, whose bundle ID is
  stored (an app without one beeps and changes nothing).
- **Target pop-up** (`linkRouteTargetMenu`): the normal spaces in order
  (emoji and name), Most Recent Space, Private Window, Quick Detour
  (TASK-193.5; links from other apps only, as the resolver rules)[^task-193-5]
  and Quarantine (TASK-194, with a tooltip saying what it is; the Default's
  caption says Quick Detour and Quarantine take links from other apps and a
  Quarantine route also the clicked links it matches, except in Private
  windows).[^task-194] A space that is not offered (deleted, or a Private
  window's) is listed first as "Space deleted" (or "Private space") with the
  warning image.
- Fixed widths (kind 120, the pop-ups 220) so the controls line up from row to
  row; a long name truncates.
- **Drag to reorder**: an NSTableView drag of the route's id
  (`com.detour.link-route`); `linkRouteMoveIndex` turns the drop row into the
  store index. Saved routes move among themselves only: a drop below the
  drafts is retargeted to the end of the saved routes, and a draft has no
  handle and does not drag.
- **⊖** removes at once, as in Arc (no confirmation).
- **Live**: the pane observes `LinkRouteStore.didChangeNotification` and
  `TabStoreObserver.tabStoreDidUpdateSpaces` (a space added, renamed,
  re-emojied, reordered or deleted elsewhere) and refreshes: rows whose order
  did not change are reconfigured in place, so a field being edited keeps its
  editor; otherwise the table reloads.
- **Warnings get their own line, and rows their own height.** A first
  version put the warning beside the target pop-up on one truncating line
  (the full text in a tooltip); "Enter a full address starting with
  https://. Not saved: links follow the saved route." was cut off. Now the
  warning is a line under Open in, from the controls' column to the row's
  edge (552 pt at the default width), wrapping, and the row grows by that
  line (`tableView(_:heightOfRow:)` = the measured base height plus
  `LinkRouteCellView.warningLineHeight`; 104 → 124 pt for one line).
  Chosen over keeping one line and shortening the messages (the "not saved"
  half is what tells the user links still follow the saved route) and over
  a fixed fourth line on every row (empty space on most). Heights are noted
  after every refresh without animation and re-measured when the table's
  width changes (legacy scroll bars). While typing, a warning that appears
  gets its line at once, but one that goes keeps its (empty) line until the
  field is committed, so the window does not resize with every keystroke.
  The Default's warning wraps under its pop-up the same way. Drag and the
  drop gap work with the variable heights (NSTableView handles them).
- **The list never takes focus** (`acceptsFirstResponder` false): its rows
  are not selectable, and with it in the key loop Tab out of a pattern field
  went to the table.
- **Edits are committed before anything else acts** (`commitPendingEdit`,
  from the code review): a click on New Route, a pop-up, ⊖ or a drop first
  ends the field editor, so a pattern typed without Return is saved (or kept
  on its draft) rather than lost to a reload.
- **Height**: a list pane (400 pt minimum). The list asks for the height of
  all its rows weakly, so it counts in the pane's natural height but in a
  shorter window gives way and its rows scroll; see
  [Settings panes](./settings-panes.md#links). Before TASK-211 the list box
  was the sum of its rows and the whole pane scrolled instead.

# The two "no condition" choices and incomplete routes

- **App-only routes: "Any URL" in the match kind pop-up, or an app with an
  empty pattern.** TASK-191.3 offered only Any URL and refused an empty
  pattern even with an app (an empty field reads as unfinished, and
  emptying it would widen a route). In practice a new route starts as
  "Domain is" with an empty field, so choosing an app (every link from Mail
  to Quarantine, say) left the row flagged until the user found Any URL
  (found at runtime for the Quarantine guide, TASK-302). The user decided on
  2026-11-08 that an app with an empty pattern is app-only, so the store
  saves it as soon as the app is chosen; the empty field's placeholder says
  "Any URL from this app, or …", and the row keeps "Domain is" with the empty
  field (it round-trips as stored: kind, `""`, app). Accepted: emptying the
  field of a route with both conditions widens it to every link from that
  app. A rejected alternative was a separate checkbox.[^task-302]
  Symmetrically, **Any App** is the From app pop-up's "no condition", so the
  From app line is always shown: the condition is discoverable without an
  "add condition" button, and rows differ in height only by a warning line.
  Rejected: a From app line shown only when set (needs a separate add/remove
  control).
- **Nothing incomplete is saved; drafts stay on their rows, marked.** New
  Route adds a draft (Domain is, empty, Most Recent Space) after the saved
  routes, with the cursor in its field and the warning "Enter a domain, such
  as example.com, or choose an app. Not saved yet." The store takes it the
  moment it is complete (on Return, Tab or a click elsewhere, or a pop-up
  change). An edit the store refuses on a saved route (an emptied pattern
  with no app, Any URL plus Any App) stays on the row with "… Not saved:
  links follow the saved route.", and the store keeps routing by the saved
  version until the row is valid again. Chosen over refusing the edit
  outright (reverting what the user typed). Drafts and refused edits live in
  `LinkRouteEditor` for the app's session; a refused edit goes when its
  route is removed anywhere. While typing, the warning follows the text
  (`problems(previewing:)`) without saving.

# Broken routes

Deletion is blocked while routes target a space
([space deletion](./link-routing-space-deletion.md)), so a broken route only
comes from a space removed some other way. Its row keeps its pattern and
app, shows "Space deleted" in the target pop-up and "Its space was deleted.
Choose where these links open."; it stays editable and removable (the store
lets an update that leaves the target alone through), and the resolver
skips it. A broken Default shows the same warning under its pop-up.

# Opened from the blocked-deletion alert

**Open Links Settings…** calls `showLinksPane(highlightingSpaceID:)`: the
rows whose target is that space, and the Default row if it targets it, are
tinted with the accent colour (0.14 alpha), and the first is scrolled into
view once the window has its height (`paneDidFit`). A row is tinted by its
**saved** route's target, which is what blocks the deletion: a row showing a
refused edit to another space is still tinted, and a draft never is. The
highlight clears when the pane is left.

# Runtime check

Harness `docs/harness/task191-3-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1913`, 2026-10-25, screen unlocked, light and
dark.[^harness-3] Seeded: a URL-only, an app-only (Mail), a URL-and-app
(Safari), a Private Window route, a broken route (its space never existed)
and a Default. Driven with posted clicks and keys (pop-ups through their real
menus), each step logging the store and the resolver's decision from the
live store: New Route put the cursor in a marked draft; typing a domain and
Return saved it, and the next decision for that host changed (Most Recent
Space, then Work after the target pop-up); a pattern edit applied to the next
link, and a link delivered through `openExternalURLs` opened in Work; an
invalid kind change was refused and marked while the saved route kept
routing; Finder as From app matched only links from Finder; ⊖ and the
Default pop-up applied at once; renaming a space elsewhere updated every
pop-up; Choose… showed the open panel on `/Applications`; the alert's Open
Links Settings… from the sidebar, the Spaces pane and an Undo Add Space each
opened the pane with the right rows (and the Default) tinted; the empty
state is one line in a 400 pt pane; 20 routes reached the screen cap (1242
on a 1410 pt screen) and the pane scrolled to the last (the pane-wide
scrolling of the time, before TASK-211).

**Reorder at runtime: a posted drag cannot be aimed.** Posted mouse-down and
drag events on a handle start a real drag session, but the session follows
the real pointer: in a first run it outlived the posted mouse-up, swallowed
the next posted click and then dropped wherever the pointer was (it did move
a route through `acceptDrop`, so the real path works), and later pop-ups no
longer opened. The reorder was checked through a stub `NSDraggingInfo`
handed to `validateDrop`/`acceptDrop`, and the unit tests cover the index
rule. **Not verified at runtime:** a person's drag with the gap animation,
choosing an app in the open panel (shown and cancelled only), and a real
link from Mail or Safari through a source-app route (TASK-191.2 covers the
sender: [links from other apps](./link-routing-external-links.md)).

Second pass the same evening, after the code review's fixes and the warning
moved to its own line (captures `task191-3/out/light2` and `dark2`): every
warning shown whole (the label measured against its row: fits in each
case, including a broken Default); a pattern typed into a draft without
Return was saved by the next New Route click, and one typed before an Open
in change was saved with that target; Tab out of a completed draft left one
row with the cursor still in its field; a saved route emptied and pointed at
another space (both refused) still blocked deleting its saved space, and
Open Links Settings… tinted that row.

# Tests

`LinkRouteEditorTests` (TASK-191.3): the target menu (Quarantine offered
since TASK-194, Quick Detour since TASK-193.5) and an unavailable space, the
drag destination, the warnings, drafts saved once complete, an app-only
draft, a refused edit kept on its row while the store keeps the saved route,
previews, a broken saved route repaired from the pop-up, removing, moving
saved routes with drafts last, rows following changes made elsewhere. The
validation itself is in `LinkRouteStoreTests`
([store](./link-routing-store.md#tests)).

# Related

- [Link Routes](./link-routing.md): the hub.
- [Settings panes](./settings-panes.md#links): the pane's place and layout in the Settings window.
- [Link Routes store](./link-routing-store.md): validation and the operations the pane calls.
- [Space deletion blocked by Link Routes](./link-routing-space-deletion.md): the alert that opens this pane.

[^task-191-3]: TASK-191.3: Settings UI to add, edit, reorder and remove routes
[^harness-3]: TASK-191.3 runtime harness
[^task-211]: Settings: keep a pane's list and details fixed; scroll only their contents
[^task-302]: Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL
[^task-193-5]: Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive
[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
