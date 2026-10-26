---
id: TASK-193.1
title: 'Quick Detour: the window, its single tab and the palette that opens it'
status: To Do
assignee: []
created_date: '2026-10-24 10:10'
updated_date: '2026-10-26 02:14'
labels:
  - window
  - feature
dependencies: []
parent_task_id: TASK-193
priority: medium
ordinal: 225000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First part of TASK-193. A new window type: one web view, minimal title-bar chrome (traffic lights, profile pill, host in the centre, extension and copy-link buttons, Open in <Space> on the right; reference docs/little-window/arc-little-arc.png), no sidebar. Opened in-app first (a menu item, File > New Quick Window, Opt-Cmd-N while Detour is active) showing the command palette; Return opens the URL or search in the window; Escape on an empty palette closes it. Clicking the host reopens the palette in place.

Model: the window's tab is a BrowserTab in no space list (like a Peek), built with the window's profile's configuration; several quick windows may be open. Decide and record: where its visits are recorded (history is keyed by spaceID; options: a per-profile hidden space id, the profile's first space, or no history), whether open quick windows are restored at launch, whether Private is allowed, and how extensions see the tab (tabs API: windowId/type). Find bar, zoom, back/forward keys work as in a normal window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A quick window opens from the menu and Opt-Cmd-N in-app, showing the palette; Return loads the page in its single web view; closing it tears the tab down cleanly
- [ ] #2 The chrome matches the reference layout (profile pill, host, copy link, extension button, Open in placeholder), light and dark
- [ ] #3 History, session restore, Private and the extension tabs API behaviour are decided, implemented and recorded
- [ ] #4 Checked at runtime; tab-model rules covered by tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-25):
1. History: visits are recorded under the window's profile with no space, labelled Quick Detour on the History page; searchable like any visit; no space's history is touched.
2. Session restore: open Quick Detour windows are not restored at launch; on quit they go to the archive (with the archiving of TASK-193.5), so they can be recovered from there.
3. Private: allowed, chosen in the profile pill (TASK-193.4); a Private Quick Detour has its own throwaway data store and records no history. Quarantine (TASK-194) relies on this.
4. Extensions: visible; the tabs API reports the page as a tab in a window of type 'popup'; content scripts and the extension button work (1Password fills logins there).
<!-- SECTION:NOTES:END -->
