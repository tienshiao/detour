---
id: TASK-84
title: >-
  Navigation: confirm before opening an external application URL (zoommtg:,
  mailto:, etc.) with an 'Always allow' option
status: Done
assignee: []
created_date: '2026-09-15 18:41'
updated_date: '2026-09-15 19:04'
labels:
  - navigation
  - security
dependencies: []
priority: medium
ordinal: 84000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Any non-http(s) navigation (zoommtg:, slack:, mailto:, itms-apps:, …) is handed straight to NSWorkspace.shared.open in BrowserWindowController+Navigation.swift (~line 94-99, the 'Open non-HTTP(S) URLs externally' branch) with no prompt, so any page can launch a local application without the user's consent. Show a confirmation sheet on the tab's window naming the page's origin and the target application (NSWorkspace.urlForApplication(toOpen:)), e.g. 'Open “zoom.us.app”?' with Open / Cancel and a checkbox 'Always allow <origin> to open links of this type in <app>' (Chrome's model: remembered per requesting origin + scheme). Persist decisions (per profile; not written from the Private profile) and provide a way to clear them in Settings. If no application handles the scheme, don't prompt — show an error/toast instead. Decide the behaviour for navigations without a user gesture (e.g. a page redirecting to zoommtg: on load, which Zoom's join page does) — they should still prompt, never auto-open unless allowed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Opening an external-scheme URL from a page shows a confirmation sheet naming the requesting origin and the handling application; Cancel opens nothing
- [x] #2 Checking 'Always allow' and choosing Open remembers the decision for that origin + scheme; later requests from that origin open without a prompt
- [x] #3 Remembered decisions persist across relaunch, are scoped per profile, are never persisted from the Private profile, and can be cleared in Settings
- [x] #4 A scheme with no registered handler does not prompt and surfaces a clear failure instead of silently doing nothing
- [x] #5 Tests cover the decision store (allow, lookup, per-origin/per-scheme isolation, private profile not persisted) and the policy that decides whether to prompt
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Findings: external-scheme navigations arrive in decidePolicyFor (main-frame, linkActivated for clicks, .other for script/redirect); window.open to a custom scheme would come via createWebViewWith and is out of the prompt path today (currently opens a blank tab) — left as is.
1. Persistence: Database migration v14 creates table externalAppPermission(profileID TEXT NOT NULL REFERENCES profile ON DELETE CASCADE, origin TEXT NOT NULL, scheme TEXT NOT NULL, UNIQUE(profileID, origin, scheme)); record type ExternalAppPermissionRecord; AppDatabase save/load/deleteAll(profileID:) methods; deleteProfileRows deletes the rows explicitly like the whitelist.
2. ExternalAppPermissionStore (Detour/Browser/ExternalApps/): in-memory [profileID: Set<Key(origin, scheme)>] loaded from the DB; isAllowed(origin:scheme:profileID:), allow(origin:scheme:profile:) (lowercases; incognito profile: never written to the DB, kept in memory for the session only), count(for:), clearAll(for:). Injectable AppDatabase for tests; .shared singleton.
3. Pure policy ExternalAppLaunchPolicy.decide(inputs) -> .open | .prompt(canRemember:) | .reportNoHandler | .ignore:
   - no handling app -> .reportNoHandler if the firing tab is hosted in this window, else .ignore
   - remembered allow for (origin, scheme, profile) -> .open
   - firing tab not hosted in this window (background tab, other window) -> .ignore (no surprise sheets, no background launches)
   - a sheet already attached to the window -> .ignore (throttles pages that loop location='app:')
   - else .prompt(canRemember: origin is a real tuple origin (non-empty host) && !profile.isIncognito)
   Applies with or without a user gesture — never auto-open unless remembered. Origin key = scheme://host[:port] of navigationAction.sourceFrame.securityOrigin (read defensively; nil source -> no remember).
4. BrowserWindowController+Navigation: replace the NSWorkspace.open branch with a call to handleExternalAppNavigation(url, action, webView) that resolves the handler via NSWorkspace.urlForApplication(toOpen:), evaluates the policy, and: .open -> NSWorkspace.open; .reportNoHandler -> toast 'No application can open “scheme:” links'; .prompt -> NSAlert sheet 'Open “AppName”?' / informative '<origin> wants to open this application.', buttons Open/Cancel, suppression checkbox 'Always allow <host> to open links of this type in AppName' (hidden when !canRemember); Open + checked -> store.allow. Hosted = selected tab, a pane of its split, or the selected tab's peek.
5. Settings > Profiles: new grid row 'External apps' with a label ('N sites allowed' / 'None') and a 'Clear' button (disabled when none), hidden for the Private profile.
6. Tests: ExternalAppPermissionStoreTests (allow + lookup, per-origin and per-scheme isolation, per-profile isolation, persistence across a reload from the same in-memory DB queue, incognito not written to DB, clearAll, profile delete removes rows) and ExternalAppLaunchPolicyTests (each branch and precedence).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: ExternalAppPermissionRecord + migration v14 (externalAppPermission, cascade + explicit delete in deleteProfileRows); ExternalAppPermissionStore (Browser/ExternalApps); pure ExternalAppLaunchPolicy.decide/origin; BrowserWindowController+ExternalApps.swift presents the NSAlert sheet (app icon/name via NSWorkspace, suppression checkbox = Always allow) synchronously inside the policy decision so looping requests hit attachedSheet and are dropped; missing handler -> toast. sourceFrame read via KVC (nil for app-initiated loads). Settings > Profiles: 'External apps' row with saved-permission count + Clear, hidden for Private. Private profile: checkbox not offered and the store never writes Private decisions. Tests: ExternalAppPermissionStoreTests, ExternalAppLaunchPolicyTests, AppDatabaseTests per-profile table list.

Code review fixes: missing-handler toast only for main-frame/new-window requests (hidden iframe app probes stay silent; subframes with a handler still prompt); ExternalAppPermissionStore.didChangeNotification refreshes the Settings count while open; numeric host:port fix belongs to TASK-83.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
External-scheme navigations now go through ExternalAppLaunchPolicy: a sheet naming the origin and handling app (Open/Cancel + Always allow), remembered per profile by origin+scheme in the new externalAppPermission table (v14, removed with the profile, never written for Private), auto-open for remembered origins, background/looping requests dropped, toast when no app handles the scheme, and a Settings > Profiles 'External apps' row with Clear. Verified by ExternalAppPermissionStoreTests, ExternalAppLaunchPolicyTests and AppDatabaseTests; the sheet and Settings row were not exercised in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
