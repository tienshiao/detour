---
id: TASK-11
title: 'Extensions: re-apply URL-keyed site-access grants when a context is (re)loaded'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 02:48'
updated_date: '2026-09-12 08:33'
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
- [x] #1 After a context reload (recovery path or disable/enable), a site the user previously granted access to is accessible without a new prompt, and a site the user denied stays denied
- [x] #2 The permission DB records URL-keyed decisions distinctly from API permissions and match patterns, with a migration if the table shape changes
- [x] #3 ExtensionPermissionTests cover restore of URL grants and denials (positive and negative) and the interaction with match-pattern and <all_urls> grants
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionPermissionType gains .url = 2; the site-access prompt (promptForPermissionToAccess urls:) records with recordType .url and key = url.absoluteString instead of .matchPattern.
2. AppDatabase.loadPermissions(extensionID:) is the single read; Array<ExtensionPermissionRecord>.statusByKey(type:) partitions per type (loadPermissionsByKey removed: a .url key can equal a .matchPattern key). No migration: legacy prompt rows stored as match patterns stay inert (a *-free key is indistinguishable from a wildcard-free manifest host permission), costing at most one re-prompt.
3. Profile.loadExtensionContext applies every .url row via context.setPermissionStatus(.grantedExplicitly | .deniedExplicitly, for: URL), gated on the URL matching one of wkExt.requestedPermissionMatchPatterns ∪ optionalPermissionMatchPatterns so stale grants for origins a newer manifest dropped are skipped.
4. ExtensionsSettingsViewController: permissionToggled handles .url; a Site access group lists .url rows so a prompt decision can be reversed.
5. Tests: ExtensionPermissionTests (URL rows distinct; statusByKey never merges types); ExtensionPermissionRestoreTests with a real Profile + temp extension (granted/denied restore, survives unload+reload, denial beats <all_urls>, denied pattern beats a URL grant inside it, grant outside requested patterns skipped, optional host pattern honoured, legacy rows inert).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Found by the 2026-09-11 code review of TASK-2 (skipped there as a permission-model change).

Implemented: ExtensionPermissionType.url; the URL site-access prompt records .url rows; AppDatabase.loadPermissions(extensionID:type:) and migration v8 reclassifying legacy *-free scheme:// match-pattern rows to .url; Profile.loadExtensionContext applies .url rows via setPermissionStatus(_:for: URL); settings toggle handles .url. Observed WebKit behaviour (recorded in ExtensionPermissionRestoreTests): a URL grant is widened to an origin pattern *://*.host/* (scheme and subdomains), a per-URL denial beats a granted <all_urls>, and a denied pattern beats a URL grant inside it (status deniedExplicitly). 84 tests green across six suites; app builds.

Code review (medium) findings and decisions: migration v8 removed (its heuristic would also flip wildcard-free manifest host permissions and widen them; legacy rows stay inert, one re-prompt at most); loadPermissionsByKey replaced by a single fetch partitioned per type via statusByKey(type:) so same-string URL and pattern keys never shadow each other and the launch path reads once; the URL restore is gated on the manifest's requested/optional host patterns so stale grants for origins a newer manifest dropped are not re-applied; Settings gains a Site access group listing .url rows so a prompt decision can be reversed. Not addressed here (pre-existing, separate row kind): optional API permissions and an <all_urls> denial are not restored on reload because the loop is gated on wkExt.requestedPermissions.

Follow-up commit after the TASK-3 review: Settings listed .url rows the restore would skip; the askable check moved to WebExtension.canAskForAccess(to:) and Settings now hides stale rows.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Site-access decisions for specific URLs are now recorded as ExtensionPermissionType.url rows and re-applied on every context load via WKWebExtensionContext.setPermissionStatus(_:for: URL), which WebKit converts to an origin match pattern (observed: *://*.host/*), so they survive the base-URL change on reload (recovery path, disable/enable, relaunch). The restore reads the table once and partitions by type; URL rows are applied only when the URL matches a requested or optional host pattern of the current manifest. Settings lists site-access decisions so they can be reversed. Verified with ExtensionPermissionRestoreTests (8) and ExtensionPermissionTests (19), plus the polyfill wiring/integration and DB suites: 85 tests green; app builds. Review-driven decisions: no migration of legacy rows (heuristic unsafe), statusByKey to avoid cross-type key shadowing, manifest gate to avoid stale grants. Not in scope: optional API permissions and an <all_urls> denial are still not restored on reload (restore loops are gated on requestedPermissions).
<!-- SECTION:FINAL_SUMMARY:END -->
