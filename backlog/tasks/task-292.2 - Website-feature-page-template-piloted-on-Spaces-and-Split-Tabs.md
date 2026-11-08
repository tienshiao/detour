---
id: TASK-292.2
title: 'Website: feature page template, piloted on Spaces and Split Tabs'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T07:33:00Z'
labels:
  - website
dependencies:
  - TASK-292.1
references:
  - docs/task-110/README.md
parent_task_id: TASK-292
priority: medium
ordinal: 343000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The template every feature page uses gets settled on two real pages before the rest are written. Rules from planning (see TASK-292): the H1 is the feature name with a one-line plain outcome; search phrasing lives in the title tag, meta description, slug, lede and FAQ headings; the order is H1 + lede, media, what it does and why, how to use it (numbered steps, shortcuts, related settings), Coming from Arc (only where Arc had the feature in comparable form), FAQ (3-6 real questions), related features, download. BreadcrumbList structured data on subpages; no HowTo markup (Google dropped those rich results).

Spaces is a headline feature with an Arc counterpart; Split Tabs exercises a still image instead of a loop. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Spaces and Split Tabs pages are live at /features/spaces/ and /features/split-tabs/
- [x] #2 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [x] #3 Steps, menu paths and shortcuts on each page were checked against the current release build
- [x] #4 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [x] #5 The home page Spaces and Split Tabs sections link to their pages
- [ ] #6 Pages have BreadcrumbList structured data that validates in the Rich Results Test
- [x] #7 The template is documented in the website repo (sections, title and H1 rules, when to include Coming from Arc) so later page tasks follow it
- [x] #8 Checked in a browser at desktop and phone widths
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Content collection src/content/features/<id>.md (frontmatter: name, lede, title, description, accent, label, media, shareImage, arc, faq, related; body: What it does, How to use it) rendered by src/pages/features/[id].astro in a fixed order; BreadcrumbList JSON-LD (Detour > feature; Features level waits for the index, TASK-292.9); related cards only for pages that exist; Arc hub link only once /arc/ exists.
2. Facts: two read-only agents pulled the user-facing behavior of Spaces and Split Tabs from the code at v0.4.0 (identical to main for Detour/); Arc facts only where several sources agree (no Arc shortcuts: sources conflict).
3. Pages written for Spaces and Split Tabs, reusing the TASK-110 captures (spaces loop, split still, Spaces settings crop).
4. Runtime check: temporary harness in a throwaway v0.4.0 worktree (isolated DETOUR_DATA_DIR) dumping the main menu and the sidebar/split/space-button menus and driving the sidebar +, Settings + and Split with Next Tab.
5. Template documented in the website repo (docs/feature-pages.md); browser check at desktop and 390 px; review; commit; push (deploys) with the user's go-ahead; Rich Results Test on the live URLs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 7 2026: pages /features/spaces/ and /features/split-tabs/ built (not yet committed in the website repo). Arc facts used: Split View holds up to four tabs, side by side or stacked (TechCrunch, How-To Geek, Arc help center); Spaces have icons along the bottom of the sidebar, two-finger swipe, a Profile each. Arc's exact shortcuts left out (third-party sources disagree; resources.arc.net returns 403 to fetches).

Runtime check (v0.4.0 tag, Debug build in a throwaway worktree, harness copy in the session scratchpad, DETOUR_DATA_DIR DetourDocs292/292b, cleaned up afterwards including the four window/split-view defaults keys): File menu Close Tab ⌘W, Pin/Unpin Tab ⌘D, New Window ⌘N, New Private Window ⇧⌘N; Spaces menu Next Space ⌥⌘→, Previous Space ⌥⌘←, the space list, Manage Spaces…; Navigate Previous/Next Tab ⌥⌘↑/↓. Tab row menu: Copy Link/URL, Share…, Duplicate, Move to › spaces (current checked), Pin Tab, Archive Tab, Archive Tabs Below, Split with Next Tab (only when the next tab is free); choosing it made a split. Split row menu: Copy URL, Separate Tabs, Close Both Splits. Empty area: Edit Space…, Delete Space, New Folder. Space buttons: emoji, tooltip = name, menu Edit Space…/Delete Space. Sidebar + (tooltip Add Space) opens Settings on the Spaces pane without creating a space; Settings + creates "⭐️ Space" #007AFF on the default profile. Fixed from the check: key glyph order (⌥⌘ not ⌘⌥), "File › Pin/Unpin Tab".
Not run at runtime (code-verified by the agents only): Option-click and the link menu item, drag-to-split drops and drop bands, divider limits and memory, swipe paging, delete/undo flows, profile change sheet.

Browser check: both pages at 1462 px wide (Chrome) and in 390 px frames: no horizontal scroll (only the clipped decorative arrow extends), key glyphs in the system font, Arc box, FAQ and related cards render; the home Spaces and Split Tabs sections link to the pages.
Found while researching (not changed, for the user): Settings › Spaces "−" deletes a space with tabs and no confirmation, while sidebar Delete Space refuses a non-empty space.

Review (/code-review medium --fix, 7 findings): fixed the inline-Markdown helper (protocol-relative hrefs, formatting inside hrefs and code spans), the Spaces description length, link underline scope; skipped hrefs with parentheses and accent validation. Website commit 9a32167 local, not pushed: pushing deploys through Cloudflare. Criteria 1 (live) and 6 (Rich Results Test on the live URLs) wait for the push.
<!-- SECTION:NOTES:END -->
