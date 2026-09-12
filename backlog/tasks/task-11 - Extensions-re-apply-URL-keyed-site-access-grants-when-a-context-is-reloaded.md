---
id: TASK-11
title: 'Extensions: re-apply URL-keyed site-access grants when a context is (re)loaded'
status: To Do
assignee: []
created_date: '2026-09-12 02:48'
labels:
  - extensions
  - permissions
dependencies: []
priority: medium
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Profile.loadExtensionContext restores saved decisions for the extension's requested API permissions, its requested match patterns, and the <all_urls> key, but grants recorded by the permission prompt for specific URLs (site access granted while browsing) are never re-applied to a new context. Until 2026-09-11 a context was only created at launch, so the gap surfaced as re-prompts after relaunch. Profile.recoverFromBackgroundLoadFailure (TASK-2) now unloads and reloads a context mid-session, so a user can be re-prompted for a site they granted minutes earlier, or lose access silently. Decide how prompt-time URL grants and denials map onto WKWebExtensionContext permission statuses (setPermissionStatus(_:for: URL) exists alongside the match-pattern form) and apply them in the restore loop; store them in a form that survives the base URL changing on every context.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a context reload (recovery path or disable/enable), a site the user previously granted access to is accessible without a new prompt, and a site the user denied stays denied
- [ ] #2 The permission DB records URL-keyed decisions distinctly from API permissions and match patterns, with a migration if the table shape changes
- [ ] #3 ExtensionPermissionTests cover restore of URL grants and denials (positive and negative) and the interaction with match-pattern and <all_urls> grants
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2 (skipped there as a permission-model change).
<!-- SECTION:NOTES:END -->
