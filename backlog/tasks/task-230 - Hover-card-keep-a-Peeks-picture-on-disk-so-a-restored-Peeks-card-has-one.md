---
id: TASK-230
title: 'Hover card: keep a Peek''s picture on disk, so a restored Peek''s card has one'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-29T07:20:00Z'
updated_date: '2026-10-29T07:33:00Z'
labels:
  - sidebar
  - peek
dependencies: []
references:
  - TASK-229
priority: low
ordinal: 266000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested Oct 29 2026. TASK-229 gave the Peek badge its own hover card, with the Peek's in-memory picture (its switcherPreview, taken when the host is left with the Peek up). Nothing was written to disk because TabStore.thumbnailKey(for:) is nil for a Peek (it is in no sidebar list), so after a relaunch a restored Peek's card is text only until the Peek has been shown and left again. The user wants the picture kept like a tab's (TabThumbnailCache, TASK-190).

Constraints: never wake, host or show a Peek or its host to take a picture (wiki/platform/gpu-iosurface-limit.md); nothing written for Private; a different Peek opened on the same host must never show the previous Peek's picture; files of closed Peeks are swept like other orphans.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A Peek's picture is written to the thumbnail cache from the same capture as its in-memory preview, under a key derived from its host row's key and the Peek's URL, and never for Private
- [x] #2 After a relaunch, hovering a restored Peek's badge shows its picture from disk; a Peek on a different URL than the one pictured shows none
- [x] #3 The sweep keeps the picture of every host's current Peek and removes the rest (closed Peeks, a Peek that navigated away)
- [x] #4 Covered by TabThumbnailTests and TabHoverCardTests, and checked at runtime across a relaunch
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Test first (TabThumbnailTests): TabStore.peekThumbnailKey(hostKey:peekURL:) is deterministic, differs from the host key, and differs per URL and per host; thumbnailKey(for: peek) = that key from the host row's key (normal, pinned, favourite) and the Peek's URL (its tab's, else host.peekURL), nil for Private and for a Peek with no host; liveThumbnailKeys includes each host's current Peek key; the old 'a Peek is not a row' assertion becomes 'a tab no row lists and no row hosts'.
2. Test first (TabHoverCardTests): a Peek's content carries that disk key (from the host's key and the Peek's URL) when it has no in-memory preview; none while the host is on screen; none for Private.
3. Implement: the key (SHA-256 of the host key and the URL, first 16 bytes), thumbnailKey(for:) via tab(hostingPeek:), liveThumbnailKeys, HoverCardContent.peekContent. The capture in captureSwitcherPreview already writes whatever thumbnailKey(for:) returns, and the controller already reads the disk for a content key with no preview.
4. Wiki (tab-hover-card thumbnails section), /code-review --fix, runtime check across a relaunch (harness phases 1 and 2), tests, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (Oct 29 2026):
- TabStore.peekThumbnailKey(hostKey:peekURL:): first 16 bytes of a SHA-256 of the host row's key and the URL; peekThumbnailKey(of:hostKey:) keys by host.peekURL, the URL the session saves for the Peek. thumbnailKey(for:) returns it for a Peek (via tab(hostingPeek:)), so captureSwitcherPreview's existing write covers Peeks with no change there; nil for Private. liveThumbnailKeys keeps each normal, pinned and favourite tab's current Peek (live, parked or restored); a closed or navigated Peek's key leaves the set and the next sweep removes the file. The URL in the key means a different Peek on the same host never shows the old picture, with no delete needed.
- HoverCardContent for a Peek carries that disk key (the controller's existing disk read does the rest); its text uses BrowserTab.peekPageURL (the Peek tab's URL, else peekURL).
- /code-review --fix: 7 found, 3 fixed by the review (two stale doc comments, the key steps in one helper, no Data copy of the hash), 2 fixed by me: (1) the key first used the Peek tab's url, which can differ from the saved peekURL (an error page keeps the failed URL), so a picture would be read and swept under another key after a relaunch; now keyed by peekURL; (2) from TASK-229: the card treated a Peek as on screen whenever its host was, so the unfocused pane of the selected split showed no picture for its (hidden) Peek; hoverCardIsOnScreen now answers for the presented Peek itself and the rule asks about the Peek tab. Skipped: the extra scans for a Peek's key (small). The two tests for these fixes were written with them, not run red first; each checks exactly the rule it replaces.
- Tests: TDD for the key, liveness and content (8 new failing first against a stub). 275 tests in the thumbnail, hover card, Peek, split and sidebar suites: 1 failure, TabHoverCardControllerTests.testDismissSuppressesUntilThePointerLeavesTheRow, a 2 s wait for a 0.45 s timer at load average ~21; passes 3/3 alone.
- Runtime (harness phases 1 and 2, screen locked): Peek files written under the derived keys before quitting, still live after the relaunch, and the restored normal and pinned Peeks' badge cards showed the picture from disk (light and dark). Not checked: pixels; the favourite's Peek after a relaunch (the harness favourited the tab after it was pictured, and the favourite came back dormant).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A Peek's picture is now kept on disk like a tab's, so a restored Peek's hover card shows it after a relaunch. It is written from the same capture as its in-memory preview, under a key derived from the host row's key and the URL the session saves for the Peek, so another Peek on the same host (or the same Peek after it navigated) never shows the old picture, and the sweep removes closed and navigated Peeks' files. Nothing is written for Private. Also fixed from review: a Peek card counts as on screen only while that Peek is presented, so the unfocused split pane's Peek card keeps its picture. Covered by TabThumbnailTests and TabHoverCardTests; checked at runtime across a relaunch (no pixels, the screen was locked).
<!-- SECTION:FINAL_SUMMARY:END -->
