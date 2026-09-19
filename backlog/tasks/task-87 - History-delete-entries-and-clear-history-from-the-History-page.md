---
id: TASK-87
title: 'History: delete entries and clear history from the History page'
status: To Do
assignee: []
created_date: '2026-09-19 16:51'
labels: []
dependencies:
  - TASK-86
references:
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/TabStore.swift
priority: medium
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-86. The History page is read-only; users need to remove entries. HistoryDatabase has no delete API today - only expireOldVisits (90-day expiry at launch).

Deletion is scoped like the view: it removes the PROFILE's visits (historyVisit rows whose spaceID belongs to a space using the tab's profile), never another profile's.

Things to get right:
- historyURL is one global row per URL shared by all profiles. After deleting visits, recompute visitCount / lastVisitTime from the remaining visits, and delete the historyURL row only when no visit in any profile remains. See how expireOldVisits prunes orphans and keep the behaviour consistent.
- historySearch is an FTS5 table synchronized with historyURL; verify row deletes propagate (GRDB synchronize triggers) so deleted URLs stop appearing in search and in command-palette suggestions / bestURLCompletion.
- TabStore keeps an in-memory history dedup cache keyed "url|spaceID" (near recordHistoryVisit); invalidate affected keys so a revisit right after deletion is recorded.
- The delete bridge messages inherit TASK-86's restrictions (main frame of the internal page only); destructive calls must not be reachable from web content or extensions.
- Decide here whether deleting a space should also delete its visits (deleteSpace currently leaves them to age out, invisible to every profile). Recommended: delete them at space deletion.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A single entry can be deleted from the page (button/context menu and Delete key on selection); it disappears without a full reload
- [ ] #2 Multiple selected entries can be deleted at once
- [ ] #3 A Clear History action offers time ranges (last hour, today, all time) and asks for confirmation before deleting
- [ ] #4 Deletion only removes visits belonging to the tab's profile; another profile's visits to the same URL survive, with its visitCount/lastVisitTime recomputed (test)
- [ ] #5 A historyURL row is removed only when no visits remain in any profile, and then no longer appears in FTS search, command-palette suggestions, or URL completion (test)
- [ ] #6 Revisiting a URL immediately after deleting it records a new visit (dedup cache invalidated) (test)
- [ ] #7 Delete bridge messages are rejected from anything but the internal page's main frame (negative tests)
- [ ] #8 Deleting a space removes that space's visits (or the task records the decision not to)
- [ ] #9 Unit tests cover the new HistoryDatabase delete APIs including aggregate recomputation and orphan pruning
<!-- AC:END -->
