---
id: TASK-416
title: 'Printing: print the current page (File > Print…, Cmd+P, and window.print())'
status: To Do
assignee: []
created_date: '2026-11-20T05:52:00Z'
labels:
  - printing
  - feature
  - menus
dependencies: []
priority: medium
ordinal: 497000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Detour has no printing at all today: there is no Print item in the File menu, Cmd+P does nothing, and a page that calls `window.print()` (receipts, boarding passes, tickets, "printable version" buttons) gets no response, so users have to open the page in another browser to print or save it as a PDF. WKWebView only prints when the app drives it, so this has to be built. Things that are easy to get wrong in this app: a tab can be shown in a window that does not own its web view (another window shows a snapshot), a split shows two panes and only the focused pane is `selectedTabID`, internal detour:// pages and PDFs viewed in a tab are web views too, and Private windows must not leave anything behind. The `printing`/`printerProvider` extension APIs are out of scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 File menu has Print… (Cmd+P) that opens the standard macOS print panel for the selected tab, and the panel offers Save as PDF; the shortcut appears in the customizable shortcuts list in Settings
- [ ] #2 The printout is the whole page content (all pages, not only the visible viewport), with the page title and URL available for the header and footer
- [ ] #3 In a split, Print prints the focused pane only
- [ ] #4 Print works in a window that shows the tab as a snapshot (does not own its web view), or the item is disabled there; it never prints a blank page or the snapshot image
- [ ] #5 A page calling window.print() opens the print panel for that tab, as a sheet on the window showing it; a call from a background tab, an unselected tab or an iframe is handled deliberately (decision recorded in the task), and repeated calls cannot stack panels or loop
- [ ] #6 Print is disabled when there is nothing to print (no tab selected, a tab that has not loaded, the new-tab state)
- [ ] #7 A PDF opened in a tab and a detour:// internal page (History) print correctly
- [ ] #8 Printing from a Private window works and writes nothing to history or the session database
- [ ] #9 Rules with logic (which tab or pane is printed, enable/disable state, window.print() handling) have tests; the print panel and output are checked at runtime with /verify
<!-- AC:END -->
