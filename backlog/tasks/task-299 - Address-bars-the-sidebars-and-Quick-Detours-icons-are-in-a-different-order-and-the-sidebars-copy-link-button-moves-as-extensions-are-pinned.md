---
id: TASK-299
title: >-
  Address bars: the sidebar's and Quick Detour's icons are in a different order,
  and the sidebar's copy-link button moves as extensions are pinned
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T08:40:00Z'
updated_date: '2026-11-08T21:26:00Z'
labels:
  - ui
  - quick-detour
dependencies: []
priority: low
ordinal: 360000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The two address bars order their trailing icons differently (left to right, Nov 8 2026, main == v0.4.0):
- Sidebar faux address bar (Detour/Browser/Sidebar/FauxAddressBar.swift): host → copy link ("link", tooltip "Copy URL", shown only on hover) → pinned extensions → Site Settings ("slider.horizontal.3"). The copy button is pinned to the extension stack's leading edge, so its position changes as extensions are pinned or unpinned.
- Quick Detour title bar (Detour/Browser/QuickDetour/QuickDetourTitleBar.swift): profile pill → host → pinned extensions → Site Settings → copy link ("Copy Link") at the capsule's trailing edge.
The user finds the mismatch bothersome and recalls Arc keeping copy closer to the URL so it doesn't move around with extensions. (Arc's help center: pinned extensions show in Arc's URL bar when you hover the sidebar, and Site Controls sits to the right of the URL bar; it doesn't say where copy sits.)

Options for the agreed order, for example: copy and Site Settings at fixed spots with extensions growing away from them; or the sidebar adopting Quick Detour's order (copy at the trailing edge, fixed); or copy right after the host in both with extensions after Site Settings. The tooltip wording should match too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The order is agreed with the user before implementation
- [x] #2 Both bars show the same icons in the same order, with the same tooltips and accessibility labels
- [x] #3 The copy-link and Site Settings buttons stay in the same place when extensions are pinned or unpinned
- [x] #4 Checked at runtime with /verify with zero, one and several pinned extensions, in the sidebar and in Quick Detour
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. QuickDetourTitleBar: reorder the trailing constraints to host … [extensions] [copy] [Site Settings]: settings at the capsule's trailing edge, copy before it, the extension stack's trailing edge on copy's leading edge.
2. FauxAddressBar: same order; settings at the trailing edge, copy fixed before it, the extension stack trailing on copy (no constraint swapping as extensions come and go); the label's hover trailing edge is the stack's leading edge (or copy's when there are none).
3. Same tooltip and accessibility label in both: 'Copy Link' and 'Site Settings'; the sidebar's extension buttons get the extension's display name as tooltip, as Quick Detour's do.
4. Sidebar copy stays hover-only (all three kinds of trailing icon reveal together on hover, as today); its slot is fixed, so nothing moves when it appears or when extensions are pinned.
5. Layout test for both bars: copy and settings frames do not change between zero, one and three pinned extensions; order left to right is extensions, copy, settings.
6. Runtime check with 0, 1 and several pinned extensions in the sidebar and in Quick Detour.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: order in both bars is host … [extensions] [copy link] [Site Settings]. Copy and Site Settings sit together at the trailing edge, so the right side is identical regardless of pinned extensions (and across profiles); extensions grow leftward from copy.

Implemented (Nov 8 2026, @claude):
- QuickDetourTitleBar: Site Settings at the capsule's trailing edge, Copy Link before it, the extension stack's trailing edge on Copy's leading edge.
- FauxAddressBar: same order. Copy is pinned to Site Settings (no more swapping between 'copy to stack' and 'copy to settings' constraints); the stack ends on Copy. On hover the label ends before the leftmost icon (the stack, or Copy when nothing is pinned).
- Wording: 'Copy Link' (tooltip and accessibility label) in both bars, as Quick Detour already had; the sidebar's said 'Copy URL' with no tooltip. 'Site Settings' tooltip added to the sidebar's button. The sidebar's extension buttons now carry the extension's display name as tooltip and accessibility label, as Quick Detour's do (both bars set the accessibility label now). The label strings live once, on FauxAddressBar (copyLinkLabel / siteSettingsLabel), and the Quick Detour bar uses them. The Edit menu's 'Copy URL' (Shift-Cmd-C) and the tab menus' 'Copy URL' are menu commands and were left as they are.
- Decision: the sidebar's copy stays hover-only, as all of the sidebar bar's trailing icons are (extensions and Site Settings too); they appear together on hover, and Copy's slot is fixed beside Site Settings, so its appearing moves nothing and pinning moves neither Copy nor Site Settings. Only the host label's truncation point changes on hover, as before.
- Tests: new AddressBarIconOrderTests (5): in each bar Copy and Site Settings frames are identical with 0, 1, 3 and 0 pinned extensions, the left-to-right order is extensions, Copy, Site Settings, and both bars label Copy and Site Settings the same. Run with QuickDetourTitleBarTests (9), QuickDetourWindowTests (15), QuickDetourExtensionTests (18): 47 tests, 0 failures.
- Runtime (/verify, DETOUR_DATA_DIR=DetourB8-299-1, temporary DEBUG harness, three seeded copies of TestExtensions/hello-world): pinned 0, 1, 3, then 0 again at runtime through ExtensionManager.toggleExtensionPinned, with the sidebar bar hovered and a Quick Detour open on example.com. Sidebar bar (200 pt): Copy x=158, Site Settings x=177 in every state; extensions at 134 / 86,110,134. Quick Detour bar: Copy x=647, Site Settings x=673 in every state; extensions at 621 / 569,595,621; Open in unchanged. Tooltips 'Copy Link', 'Site Settings', 'Hello World 1..3'. Layer captures of both bars in each state confirmed the order visually. Not checked: a Private window's sidebar bar or a second profile (the code path is the same view). Defaults keys and the data dir removed; the run's WebKit store directories under ~/Library/WebKit/com.detourbrowser.mac/ were left in place.

Nov 8 2026 (lead review): /code-review medium found Copy's 6 pt padded hit area overlapping the neighbouring extension button and Site Settings (2 pt gaps), so clicks on their edges copied the link. FauxAddressBar now resolves the trailing button exactly first, then with 4 pt padding, then Copy's 6 pt (trailingHit(at:)). Built and AddressBarIconOrderTests/HelpMenuTests/QuickDetourDockMenuTests pass (47); the edge click itself was not exercised at runtime.

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).

Nov 8 2026: the user ran the post-release check list on the released 0.4.1 (signed build) and reported no problems. Check: edge clicks between extension icons, Copy Link and Site Settings in both address bars.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Both address bars now order their trailing icons host … [pinned extensions] [Copy Link] [Site Settings] (user decision), with Copy and Site Settings fixed together at the trailing edge so nothing moves as extensions are pinned, and with the same tooltips and accessibility labels ('Copy Link', 'Site Settings', each extension's name). The sidebar's icons stay hover-only and appear together. Layout tests (AddressBarIconOrderTests) and a runtime check with 0, 1 and 3 pinned extensions in the sidebar and in Quick Detour.
<!-- SECTION:FINAL_SUMMARY:END -->
