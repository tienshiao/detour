---
id: TASK-415
title: >-
  Website: capture session — retake the Settings stills, and record the
  Automation (MCP) loop
status: Done
assignee: []
created_date: '2026-11-20T02:57:00Z'
updated_date: '2026-11-20T07:58:00Z'
labels:
  - website
dependencies: []
priority: low
ordinal: 496000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-338 redesigned Settings (grouped rows, switches) and TASK-327 added a Shortcuts pane. link-routes.webp on the Link Routes guide shows the old window (no Shortcuts pane, old layout); check the other feature stills (profiles-*.webp, web-extensions.webp, privacy.webp, private-browsing.webp) for Settings content too. Retake with docs/capture/capture.py (takes the screen over while it runs; see wiki/playbooks/release-and-website.md, Website captures).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Every website still that shows Settings shows the 0.5.0 Settings window
- [x] #2 The retaken stills are deployed after the user's review
- [x] #3 The Automation guide (src/content/features/automation.md) gets a short loop: the connected-agent label naming Claude Code and the agent pointer clicking a tab and typing into a page (Debug build: the agent pointer and indicator overrides), added as the page's media after the user's review
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-19: the user asked to record the Automation page's video later, with this capture session, not on release night. The page shipped on website branch guides-0.5.0 without media (the schema allows it).

2026-11-19 capture run (Debug build of 472ee7bd; no app code changed since c9ec65cd, so the stills match 0.5.0). Stills showing Settings: link-routes, privacy, profiles-list, profiles-spaces (checked: web-extensions, private-browsing, content-blocker, dev-mode and history show no Settings window). Retaken with new capture.py shots (profiles-list, profiles-spaces, link-routes, privacy, automation; banking world variant; vdisplay size option; browser window looked up by kind). Automation loop: 1000x720 pt, Claude Code capsule, agent clicks the GitHub Docs row, its search, types 'pull request', back to GitHub; first and last frames match. Wikipedia search was rejected as the typing target: its live suggestions flashed Saddam Hussein, the Sandy Hook shooting and a convicted murderer between keystrokes. Candidates on website branch media-0.5.0 (e055300), built, NOT deployed, awaiting the user's review. Kit changes (docs/capture/capture.py, vdisplay.m, README.md) uncommitted in MyBrowser.

Also viewed tab-archiving and both arc-import stills: no Settings window. The home page uses profiles-list/-spaces at the same 448x230 size. Website checkout switched back to main after the branch commit.

2026-11-19: the user reviewed the branch on a local dev server and approved it. media-0.5.0 fast-forwarded into the website's main (e055300, pushed) and deployed (Worker version 6573df37). The six media files on detourbrowser.com match the build (sha256), and the live Automation and Privacy pages carry the new video and the 1258 pt still. Kit changes were committed earlier in c4ffea36.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Retook every website still that shows Settings (link-routes, privacy, profiles-list, profiles-spaces) in the 0.5.0 grouped-form Settings window. Recorded the Automation loop: Claude Code shown in the connected-agent label, and the agent pointer clicking a tab and typing into GitHub Docs. Added it as the Automation guide's media. capture.py gained Settings stills, a banking world variant, a --display size and a browser-window lookup by kind (c4ffea36). The user reviewed and approved the media, which is now on detourbrowser.com (website e055300). Not re-run after the window-id refactor: the older spaces, split and space-editor shots, whose website media were unchanged. The loop shows the real repo's commit list on GitHub.
<!-- SECTION:FINAL_SUMMARY:END -->
