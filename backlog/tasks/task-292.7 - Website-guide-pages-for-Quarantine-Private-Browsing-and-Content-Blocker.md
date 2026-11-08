---
id: TASK-292.7
title: 'Website: guide pages for Quarantine, Private Browsing and Content Blocker'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T09:10:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 348000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The privacy pages, written to the pilot template (TASK-292). Quarantine and Private Browsing are separate pages (user, Nov 7 2026). Quarantine is pitched to privacy-conscious users as a way to triage incoming links (from mail, chat, unknown senders) without leaking data: none of your cookies, no history, tracking parameters stripped. Its page explains how that differs from a private window, and Private Browsing links across to it. Quarantine is not an Arc feature, so its page has no Arc box. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Quarantine and Private Browsing are separate pages that each say when to use which and link to each other
- [x] #2 The Quarantine page leads with link triage and states exactly what is and is not shared with your profiles, checked against the code and the running app
- [x] #3 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [x] #4 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #5 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [x] #6 Pages are in the sitemap and linked from the home page entry for the feature
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 (agent, website worktree branch task-292.7, commit b351d21, not pushed): pages /features/quarantine/, /features/private-browsing/, /features/content-blocker/ (no media yet; captures listed for the lead), home grid entries 06/08/22 link to them (CSS at the end of styles.css), Arc hub Quarantine item links to its page. Private Browsing has an Arc box from Arc's 'Open Incognito Window' article (Wayback capture 20250515005439: Cmd+Shift+N, File > New Incognito Window, no history/cookies/site data saved); Quarantine and Content Blocker have none.

Runtime check (v0.4.0 tag, Debug build in the scratchpad app worktree, temporary harness Detour/App/DocsHarness.swift + one-line AppDelegate hook, not committed; DETOUR_DATA_DIR DetourDocs2927 and DetourDocs2927b): File menu New Private Window Shift-Cmd-N, Open Quick Detour in Space Cmd-O; Dock menu New Window / New Private Window. Private window: title 'Private Browsing', dark appearance, space '🔒 Private' on profile 'Private', non-persistent store; validated by its controller: Pin/Unpin Tab, Next/Previous Space, the space list, Manage Spaces…, Show/Clear Archived Tabs disabled. A cookie set in one Private window's store was still there in a second Private window opened after closing the first (same store object): Private windows share cookies until quit (page says so). Settings > Links: Default 'Open other links in' and a route's 'Open in' offer Most Recent Space, Private Window, Quick Detour, Quarantine (with its tooltip); URL condition Domain is/Contains/Is equal to/Any URL; From app. Resolver with a Domain is example.org -> Quarantine route: external -> quarantine, typed -> stay, clicked in normal -> quarantine, clicked in Private -> stay; Default = Quarantine: external -> quarantine, clicked/typed -> stay. A link from 'Mail' (openExternalURLs) with utm_source, utm_medium, gclid, id=7 opened a quarantine window on the Private profile with its own non-persistent store (neither the Private nor the profile store), loaded https://example.com/?id=7 (tracking parameters stripped: the home grid text is correct), no cookies, Safari's UA (10_15_7, no Detour token); badge menu 'Cookies and site data of its own, gone when it closes' / 'Not in history; extensions allowed in Private run' / 'Opened from example.com'; bar button 'Open in 🏠 Home ⌘O'; File menu item retitled 'Open in 🏠 Home'. A cookie and localStorage set in the quarantine did not reach the Home tab Open in created (only the profile's own cookie), window closed. history.db afterwards: only the Open in visit; the quarantine's example.org and the Private window's example.net were absent. Settings > Profiles: Content Blocking 'Block content' + EasyList (ads), EasyPrivacy (trackers), Cookie notices, Malicious URLs, all on for Default and Private; Private shows 'This profile is used for Private Windows.' and no Archive tabs/External Apps rows. Settings > Content Blocking: columns Filter List/In List/Active/Status/Last Updated, Update All Now, Clear Cache & Redownload, '24 hours' caption. Site Settings popover (address bar sliders button, a11y 'Site Settings') on www.theguardian.com: '30 resources blocked on this page'; turning off 'Block content on this site' whitelisted the host, reloaded, 0 blocked, 'No resources blocked yet'.
Code only (not run): quarantine downloads question, Cmd-click/popups sharing the store, fingerprinting SPI, Open in losing form text and back list, Cmd-W closing the quarantine window, Allow in Private (no extension installed in the isolated profile), Private download cancel prompt, Private per-site settings dropped with the last Private window, palette scope in Private windows.

Browser check: Chrome at 1462 px (pages, home grid underline, Arc box) and 390 px iframes of the three pages, home and /arc/: scrollWidth 386 everywhere; related cards render; all three in dist/sitemap.xml.
Cleanup: removed both NSWindow Frame / NSSplitView keys and the com.detourbrowser.mac.DetourDocs2927(b) defaults suites, and ~/Library/Application Support/DetourDocs2927(b). Left for the lead (outside the allowed deletions): WebKit stores ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore/752d233c-948d-5bb5-81a4-55b3c0b87081 (14 MB) and 80bcf68f-fcf5-5f8c-89c1-4c83f22f46aa (536 KB), created by the two runs; empty prefs plists may linger until cfprefsd flushes.

Follow-up (coordinator, Nov 8): website commit 6c7a23c rewords the home grid's Private Browsing line ('A throwaway Space with no history and nothing written to disk. Logins and cookies are cleared when you quit Detour.') and the page's opening (drops the 'someone else's account' example; says nothing is written to disk). The page already said Private cookies last until quit (runtime-confirmed here too) and contrasts Quarantine's per-window store; Quarantine's wipe on close is code-only (QuarantineSession deinit), its separate store was confirmed at runtime. The pages don't use the File menu's 'Pin/Unpin Tab' title.

Nov 8 2026: merged into the website (6d89c71), reviewed with the TASK-292.5 batch (a0a35d5: Private downloads do reach disk, Private site settings last until the last Private and Quarantine window closes, Quarantine fingerprinting protections apply where the Mac's WebKit offers them, target=_blank links share the Quarantine window's store), pushed with the user's approval and live: /features/quarantine/, /features/private-browsing/, /features/content-blocker/ answer 200, in the sitemap, linked from the home grid; the Arc hub links Quarantine. Open: criterion 5 waits for the captures (Quarantine loop, Private window still, Content Blocker popover still), to be made in one capture session per docs/feature-pages.md. The Private Browsing page describes v0.4.0's Private data lifetime; TASK-298 (fixed on main) changes it at the next release.

Nov 8 2026, user: the Content Blocker page's level is right (no promises about YouTube or specific ad types). The two WebKit data stores the agent's runs left in ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore (752d233c…, 80bcf68f…, created 00:23/00:26 during its runs) were deleted with the user's OK.
<!-- SECTION:NOTES:END -->
