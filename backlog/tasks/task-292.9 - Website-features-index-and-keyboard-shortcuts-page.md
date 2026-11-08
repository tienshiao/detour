---
id: TASK-292.9
title: 'Website: features index and keyboard shortcuts page'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T10:37:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 350000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Features without their own page (Find in Page, Dark Mode, Drag Handles, Web Inspector, Auto-Updates, Multi-Window, Downloads, Audio Controls, Session Restore, Hover Cards, Sidebar Auto-Hide, Liquid Glass) still need a home, and keyboard shortcuts are a page people search for and the Help menu opens. Shortcuts must come from the app (AppDelegate menus and key handlers), not memory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 /features/ lists every feature with a one-line description, linking to its page where one exists
- [x] #2 /shortcuts/ lists every keyboard shortcut grouped by menu, generated from or checked against the menus in the current release
- [x] #3 Both pages are in the sitemap and linked from the nav or footer
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inventory v0.4.0: main menu (AppDelegate.setupMainMenu + validateMenuItem retitles), key handlers (RecentTabSwitcher monitor, CommandPaletteView doCommandBy/handleEscape, FindBarView, ArchivePageView, History page JS, BrowserWindowController keyDown/closeCurrentTab for Peek, QuickDetourWindowController, TabCellView/FolderCellView rename), link-click modifiers (BrowserWindowController+Navigation), the Quick Detour system hotkey; feature facts for the no-page features from the v0.4.0 code.
2. /features/ (src/pages/features/index.astro): every feature in groups, guide-page entries take name + lede from the content collection (the build fails if a page is missing from the index), no-page entries written from the code; links to /arc/ and /shortcuts/; BreadcrumbList Detour › Features.
3. /shortcuts/ (src/pages/shortcuts.astro): one table per v0.4.0 menu in menu-bar order (Detour, File, Edit, View, Navigate, Spaces, Develop, Window; Extensions has none), then shortcuts outside the menus; BreadcrumbList Detour › Keyboard Shortcuts.
4. Feature-page breadcrumb gains Features (markup + BreadcrumbList); footer links Features and Keyboard Shortcuts; docs/feature-pages.md updated.
5. npm ci + build, check sitemap; browser check at desktop and 390 px; commit on task-292.9 (no push).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 (website branch task-292.9, commit 469ee69 in /Users/tma/Projects/browser/dw-292.9; not pushed, not merged, not deployed: pushing to the website main deploys, the user's call).

Pages: /features/ (src/pages/features/index.astro) and /shortcuts/ (src/pages/shortcuts.astro), exact URLs https://detourbrowser.com/features/ and /shortcuts/ for the TASK-292.10 Help menu. Each has its own title, meta description and BreadcrumbList (Detour › Features; Detour › Keyboard Shortcuts). Feature pages' breadcrumb now Detour › Features › name in markup and BreadcrumbList. Footer links Features, Keyboard Shortcuts, Switching from Arc on every page (nav left alone: its Features link still goes to the home page's section). docs/feature-pages.md: index/shortcuts section, new breadcrumb, checklist item. src/lib/inline.ts: [[⌘]]] now renders as one key (old regex rendered <kbd>⌘</kbd>]); built HTML of all existing pages diffed against a pre-change build: only the breadcrumb, BreadcrumbList and footer lines changed.

Features index: 7 groups, every home-grid item and headline feature, the 18 guide pages by id (name, lede, accent from frontmatter; the build throws if a guide page is not listed, tested by removing peek), the Arc hub, and no-page entries written from v0.4.0 code: Sleeping Tabs, Undo, Find in Page, Hover Cards, Multi-Window, Session Restore, Downloads, Audio Controls (speaker button + now-playing bar), Picture in Picture (automatic on tab switch, per-site switch in Site Settings), Liquid Glass (NSGlassEffectView on macOS 26, blur fallback on 15), Dark Mode (follows system; no in-app appearance setting in v0.4.0), Sidebar Auto-Hide, Drag Handles (38-pt strip over the page top + sidebar), Keyboard Shortcuts, Auto-Updates (Sparkle, Detour › Check for Updates…), Default Browser (Settings › General), Web Inspector. Conservative choices: names use the brief's (Liquid Glass, Dark Mode) rather than the home grid's 'Liquid Glass Native'/'Real Dark Mode'; the home grid was not changed; Session Restore says back/forward history only (the home grid's 'scroll position and form state' claim was not repeated: interactionState is restored but what WebKit keeps in it was not checked at runtime).

Shortcuts: from AppDelegate.setupMainMenu at v0.4.0 plus validateMenuItem retitles (Undo/Redo named, Pin Tab/Unpin Tab, Open in <Space> in Quick Detour windows), menu-bar order Detour, File, Edit, View, Navigate, Spaces, Develop, Window (Extensions has no keys; no Help menu in v0.4.0). Outside menus, each from its handler: Quick Detour system hotkey (QuickDetourHotKey, default ⌥⌘N), RecentTabSwitcher monitor, link-click modifiers (BrowserWindowController+Navigation; ⌥⌘-click setting QuickDetourSettings), Dev Mode ⌥-click capture, CommandPaletteView doCommandBy/handleEscape, FindBarView (Return, Escape key equivalent), Peek (keyDown/cancelOperation, closeCurrentTab), QuickDetourWindowController, ArchivePageView (search field + ArchiveTableView), History page JS onKeyDown, TabCellView/FolderCellView rename. Shown as written in code, not checked in the running app: menu item 'Find...' (three periods in code), Zoom In shown as ⌘+ (keyEquivalent '+'). Left out: items macOS adds to menus by itself (Enter Full Screen, Emoji & Symbols, etc.) since they could not be confirmed without launching the app.

Checks: npm ci + npm run build clean (22 pages), both URLs in dist/sitemap.xml. Chrome: both pages at desktop width (1462 px) and in 390 px frames (plus a feature page and /arc/): scrollWidth 390, no element past the edge; key glyphs, tables, link cards, footer links render. Not done: /code-review; runtime check of the menus in the app (code only, per the brief).

Awaiting the user's push of website branch task-292.9 (merge to main deploys). When TASK-292.10 adds the Help menu, /shortcuts/ needs a Help row if it has keys.
<!-- SECTION:NOTES:END -->
