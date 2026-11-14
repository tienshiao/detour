---
id: TASK-228.3
title: >-
  Automation: capture tooling on the MCP endpoint, so a release's website media
  is one script instead of a harness rebuild
status: To Do
assignee: []
created_date: '2026-11-14T01:49:00Z'
labels:
  - tooling
  - automation
  - website
dependencies:
  - TASK-228.1
references:
  - TASK-228.1
  - docs/task-110/README.md
  - TASK-293.6
  - TASK-110
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 395000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14. Website captures (loops and stills for detourbrowser.com) use the kit in docs/task-110. Its DemoStage harness is pasted into a throwaway worktree, wired into AppDelegate with a patch that has to be adapted to each release, and rebuilt. It is then driven through a command file it polls. Every capture session re-does that work and adds harness commands for new UI: for TASK-293.6 that meant the space editor (TASK-289) and the Arc import offer (TASK-293.5). The endpoint from TASK-228.1 already drives input, menus and appearance, and its client CLI can script a sequence. What capturing still needs is staging: a demo world, exact window placement, and specific UI on demand.

Stays outside Detour: the 2x virtual display (vdisplay.m), screencapture for video and for stills with the native window shadow (an in-app snapshot has no shadow), the wallpaper swap, and encode.sh. The capture scripts themselves live with the kit or the website, not in the app.

Same gate as TASK-228.1: these tools exist only in the isolated DETOUR_DATA_DIR test-run mode, and the UI-on-demand tools are Debug-only like 228.1's Debug overrides.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A client can seed a demo world from a fixture file (profiles, spaces with name/emoji/colour/profile, pinned tabs and nested folders, splits, favorites, normal tabs, history visits, link routes) into an empty isolated data directory, and the result matches the fixture after a relaunch
- [ ] #2 A client can set a window's size and position in points, move it to a given display (including a virtual display), and read back its on-screen frame and CGWindowID for screencapture
- [ ] #3 A client can type text into the focused field at a given per-character pace, so recorded typing reads naturally
- [ ] #4 Debug builds can open specific UI on demand for staging: the space editor with a draft (name, colour, emoji, profile), the Arc import offer and window fed from a fixture Arc folder (never the real one), and a given Settings pane and row
- [ ] #5 A fixture-driven capture script for the next release's media replaces DemoStage in docs/task-110 (README updated, the harness and AppDelegate hook patch retired), demonstrated by re-taking at least one existing loop and one still with no app patching
- [ ] #6 Tests cover the seeding (round trip through a relaunch, a malformed fixture refused with a clear error, refusal outside the isolated test-run mode) and the window placement tool's errors (unknown window or display)
<!-- AC:END -->
