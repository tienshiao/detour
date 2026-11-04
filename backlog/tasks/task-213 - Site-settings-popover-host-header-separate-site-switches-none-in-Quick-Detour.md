---
id: TASK-213
title: >-
  Site settings popover: host header, separate site switches, none in Quick
  Detour
status: Done
assignee:
  - '@claude'
created_date: '2026-10-27 03:59'
updated_date: '2026-10-27 04:11'
labels:
  - window
  - feature
dependencies: []
priority: low
ordinal: 249000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback after TASK-210 (user, 2026-10-26). The site settings popover (SettingsPopoverViewController, shared by the main window's address bar and the Quick Detour bar since TASK-210) lists Picture in Picture and Dev Mode under the 'Content Blocking' heading, though they aren't content blocking. In a Quick Detour the two switches do nothing visible: it has no tab switching and no sidebar. Layout chosen by the user: the host becomes the popover's header; a divider; Content Blocking (heading, shield badge, blocked count, switch); a divider; Picture in Picture and Dev Mode as an untitled section; a divider; Extensions. The Quick Detour leaves out the PiP/Dev Mode section and its divider.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The popover's header is the page's host ('No site loaded' without one), above a divider and the Content Blocking section
- [x] #2 Picture in Picture and Dev Mode sit in their own section between dividers, not under the Content Blocking heading
- [x] #3 A Quick Detour's popover has no Picture in Picture or Dev Mode switch and no empty section; the main window's still has both
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. SettingsPopoverViewController: showsTabSwitches (default true); forPage(showsTabSwitches:) wires the PiP/dev handlers only when shown.
2. Layout: host header, divider, Content Blocking (title + shield, blocked count, switch row), [divider, PiP row, dev row], divider, Extensions. Switch rows are label+switch views chained top to bottom.
3. Quick Detour's makePageSettings passes false.
4. Tests: Quick Detour popover has the blocking switch and no PiP/dev switches; the default popover has all three. Runtime check of both popovers, light and dark.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
- SettingsPopoverViewController.showsTabSwitches (default true); forPage(showsTabSwitches:) leaves the PiP/dev handlers nil and skips their lookups when false. QuickDetourWindowController.makePageSettings passes false.
- loadView rewritten as a top-to-bottom chain (stack(_:gap:fullWidth:)) so the middle section and its divider can be left out; switch rows are label+switch views as tall as the switch; the host header is 14 pt semibold, middle truncation, secondary 'No site loaded' without a host. The blocking switch now has an accessibility label.
- No red step first: view layout (CLAUDE.md: TDD optional for UI); the two new tests assert which switches each builder makes.
- Code review (medium --fix): fixed a 2 pt squeeze of the PiP switch (label gap 8 -> 6, tail truncation), the stale makePageSettings doc, and lookups computed for switches never shown. Not fixed: the Content Blocking title isn't constrained against the shield (short fixed string); showsTabSwitches and the nil handlers are two expressions of one flag (correct as built by forPage).
- Harness: docs/harness/task213-harness.patch.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The site settings popover now has the page's host as its header, then Content Blocking, then picture in picture and dev mode in their own section between dividers, then Extensions. A Quick Detour's popover leaves out the PiP/dev section (it has no tab switching, sidebar rows or dev toolbar).

Tests: QuickDetourTitleBarTests 9 (2 new: the Quick Detour's popover has only the blocking switch and no PiP/dev handlers; the main window's builder keeps all three), DevModeSiteOverrideTests 15, QuickDetourExtensionTests 16, ContentBlockerWhitelistTests 22, SiteSettingsStoreTests 11: 73 passed.

Runtime (light and dark, twice: before and after the review fixes): a posted click on the Quick Detour bar opened a 280x234 popover with the host, two dividers and one switch; the main window's address-bar button opened a 280x315 popover with three dividers and the three switches; a long host truncated in the middle; 7 blocked resources showed on the shield badge and in the count line; no page showed 'No site loaded' with PiP/dev disabled. Every label, switch and divider logged with its frame, no overlaps or overflow; after the fix all switches align at x210.

Not verified: a person's own hand, Retina capture (1x display only), localized strings.
<!-- SECTION:FINAL_SUMMARY:END -->
