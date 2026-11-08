---
id: TASK-312
title: >-
  Extensions: on only in the profile they were installed from; a new profile
  starts with none
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T22:20:00Z'
updated_date: '2026-11-08T22:52:00Z'
labels:
  - extensions
  - privacy
dependencies: []
priority: medium
ordinal: 374000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User decision, Nov 8 2026. Today a missing profileExtension row means ON in every normal profile (OFF only in Private, TASK-74), so a new profile starts with every installed extension on and an extension installed later is on in every normal profile. A Banking profile can't stay extension-free. Change, as Chrome does per profile: a new profile starts with no extensions on; a new install is on only in the profile it was installed from (Chrome Web Store tab: that tab's profile; the app's install command for a .crx/folder: the front window's profile; Settings › Extensions: the front window's profile, and Settings says which); Private unchanged (off unless Allow in Private); an update never changes where an extension is on. A migration writes today's implicit ON as explicit rows for every normal profile × installed extension, so existing setups don't change. A 'Turn On in All Profiles' action in Settings › Extensions covers users who want an extension everywhere (e.g. 1Password across four profiles). Follow-up text: privacy guide step 2 (TASK-292.13, website branch privacy-guide) and any page that says extensions are on in every profile.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A missing profileExtension row means off in every profile (Database.extensionEnabledByDefault), and a migration records ON rows for every existing normal profile × installed extension that had no row, so nothing changes for existing setups (migration test)
- [x] #2 A new profile starts with no extensions loaded or enabled
- [x] #3 Installing (Web Store tab, the install command, Settings) turns the extension on in exactly the profile it was installed from and loads it there only; reinstalling or updating an installed extension keeps its per-profile choices
- [x] #4 Settings › Extensions offers Turn On in All Profiles (normal profiles; not Private), and says which profile a Settings install went to
- [x] #5 Tests cover the default, the migration, each install path's target profile, updates keeping rows, Private unchanged; the change is checked at runtime with /verify
- [ ] #6 Wiki updated; the privacy guide (TASK-292.13 branch) and any website page that describes the old default are updated on a branch held for the release
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Database: extensionEnabledByDefault -> false for every profile; migration v24 writes ON rows for every normal profile x installed extension with no row (INSERT OR IGNORE, Private id spelled out).
2. ExtensionInstallTarget (pure): first normal candidate, else first normal profile in TabStore order; Private and deleted profiles never targets.
3. ExtensionManager.install(from:publicKey:options:turningOnIn:): writes the target's ON row after the extension row, before the async load; update/reload pass nil; staged update path untouched. setEnabled refactored to setEnabled(id:profileIDs:enabled:) + turnOnInAllProfiles(id:).
4. Callers: CRX (window tab / BrowserTab / Quick Detour) pass the source profile; AppDelegate + Settings use the frontmost normal browser window. Alerts name the profile.
5. Settings > Extensions: Turn On in All Profiles button + 'On in ...' summary line.
6. Tests: new ExtensionProfileScopeTests; update suites that relied on default-on (PrivateDefault, Database, EnabledState, NewProfileExtensionLoad, StartupEnabledReads, Updater, Rehost, RuntimeInstalledEvent, NativeMessagingEnforcement).
7. /verify in an isolated profile; wiki decision page + updates; backlog notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026 implementation (agent-312):
- Default: AppDatabase.extensionEnabledByDefault(inProfile:) returns false for every profile (the parameter is kept so every reader still asks one place).
- Migration v24 (data only): INSERT OR IGNORE an ON row for every profile x extension, profile id != Private (UPPER() compare, literal spelled out as in v10/v19). There is no 'deleted profile' flag in the schema: deleted profiles' rows are gone (cascade), so nothing to exclude. Globally disabled extensions get rows too (re-enabling restores them where they were).
- New profile: TabStore.addProfile writes no rows; ExtensionManager.profileWasAdded still runs loadExtensionsIntoProfile and loads nothing (kept: Private's allow rows outlive the profile object).
- Install: ExtensionManager.install(from:publicKey:options:turningOnIn:) - required parameter, so every caller decides. Writes the target's ON row after the installer's extension row (FK) and before the async load. Private target ignored. Reinstall keeps all rows and turns the target on. applyUpdate/reloadUnpacked pass nil; applyStagedUpdatesBeforeLoad calls the installer directly and writes no rows (now asserted in ExtensionUpdaterTests).
- Target rule: ExtensionInstallTarget.resolveProfile(candidates:normalProfiles:) = first candidate that is a normal profile still in TabStore, else the first normal profile in TabStore order.
  * CRX (Web Store) in a browser tab: the tab's space's profile (window falls back to its active space), captured when the response arrives and resolved again after the download (a profile deleted meanwhile is no target). BrowserTab's own delegate (unclaimed tab) and Quick Detour pass their profile.
  * Extensions > Install Extension... and Settings > Load Unpacked: browser windows front to back (NSApp.browserWindowControllersFrontToBack, so Settings is skipped), each window's active-space profile.
- DECISIONS (conservative, mine): (a) a Private window in front for the menu/Settings install is skipped in favour of the next normal window behind it, not jumped straight to the first profile - the window behind is closer to what the user was doing; only with no normal window is it the first normal profile. (b) A CRX from a Private tab / Private Quick Detour goes to the first normal profile (brief's rule). (c) No normal profile at all -> nil -> installed but on nowhere (cannot happen: the last normal profile cannot be deleted).
- Alerts: confirm alerts now say 'It will be turned on in the "X" profile.' (CRX and Settings; menu install: 'This extension will be installed and turned on in the "X" profile.'); the success alert (all three paths) says '"N" has been installed and turned on in the "X" profile. To use it in other profiles, choose Turn On in All Profiles in Settings › Extensions, or turn it on per profile in Settings › Profiles.' (ExtensionInstallTarget.installedMessage).
- Settings > Extensions: under Enabled, a 'Turn On in All Profiles' button (disabled when every normal profile has it on) and a line 'On in “Work”.' / 'On in all profiles.' / 'Off in every profile.' + ' Turn it on or off per profile in Settings › Profiles.' The button calls ExtensionManager.turnOnInAllProfiles(id:) = the Profiles pane switch's path (setEnabled refactored into setEnabled(id:profileIDs:enabled:)), never Private.
- Tests adjusted because they relied on missing row = on (fixtures now write the row an install leaves, or go through ExtensionManager.setEnabled(id:profileID:enabled:)): ExtensionPrivateDefaultTests, ExtensionDatabaseTests, ExtensionEnabledStateTests, NewProfileExtensionLoadTests (reshaped: a new profile starts with none; turning one on loads it), ExtensionStartupEnabledReadsTests, ExtensionUpdaterTests, ExtensionPageRehostTests, RuntimeInstalledEventTests, NativeMessagingEnforcementTests (install call sites), ExtensionPagePersistenceTests, ExtensionPageUndoTests, ExtensionPageFavoriteTests, MoveTabToSpaceTests. The first broad run crashed the test host 4 times in ExtensionPagePersistence/ExtensionPageUndo (array index out of range on empty restored lists); those indexings now go through testElement(_:_:) (XCTUnwrap) so they fail instead of crashing. New: ExtensionProfileScopeTests (13). Helpers: turnOnTestExtension, testElement in ExtensionTestSupport.
- Runtime check (isolated DetourB8-312-1, temporary DEBUG harness, not committed; copy in scratch agent-312): fresh profile -> no rows; Work space made the front window's -> target Work; install of TestExtensions/hello-world -> row Work only, loaded in Work only (Default, Private none); adding Banking -> no row, nothing loaded; Settings > Extensions showed 'On in “Work”.' with the button enabled; performClick on it -> rows ON in Default/Work/Banking, loaded in all three, Private none, button disabled, line 'On in all profiles.'; Banking turned off. Relaunch after deleting the ON rows and the v24 marker (a pre-312 DB with Banking explicitly off): v24 re-ran, Default and Work ON and loaded, Banking OFF kept, Private nothing. Not exercised at runtime: the NSOpenPanel / Web Store download UI paths and their alerts (the button click was performClick, not a HID click). Leftover WebKit dirs: ~/Library/WebKit/com.detourbrowser.mac/WebExtensions/{531FCF08-...,A9BA5C3A-...,FE51E257-...}/08C8A5C4-1024-45B2-B0C9-BEC6BE1FC9D0. Defaults keys and the app-support dir were deleted.
- WEBSITE FACTS (AC #6 website half, held for release; branch privacy-guide, TASK-292.13): (1) A new profile starts with no extensions. (2) An extension you install is on only in the profile you installed it from: from the Chrome Web Store, the profile of the tab you installed it in; from Extensions › Install Extension… or Settings › Extensions, the profile of the front browser window. It is never turned on in Private by an install; Private stays off until you turn on Allow in Private. (3) To use an extension in other profiles: Settings › Extensions › select it › Turn On in All Profiles (every profile except Private), or turn it on per profile in Settings › Profiles › Extensions. (4) Settings › Extensions shows where it is on ('On in “Work”.'). (5) Updates never change which profiles an extension is on in. (6) Existing setups are unchanged after updating Detour: extensions already installed stay on in every profile that existed. Any page that says installed extensions are on in every profile is now wrong.

Tests (final run, harness removed): 79 suites touching extension enablement, profiles and extension pages (the 10 changed/new + every suite that installs, seeds or loads an extension or creates profiles) = 1553 tests, 0 failures, 13 skipped (pre-existing gated legs), no host restarts. ExtensionProfileScopeTests 13/13. Website AC pending (held for release): facts above; the wiki half of AC #6 is done (new decision page wiki/decisions/extensions-on-per-profile.md + 8 pages updated, lint clean).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A missing profileExtension row now means off in every profile. Migration v24 wrote the old implicit ON as explicit rows for every existing normal profile x installed extension (existing rows and Private untouched), so existing setups are unchanged. A new profile starts with no extensions. ExtensionManager.install(from:publicKey:options:turningOnIn:) turns a new install on in exactly the profile it came from (ExtensionInstallTarget: the CRX's tab or Quick Detour profile; the frontmost normal browser window for Extensions > Install Extension... and Settings; never Private; else the first normal profile); updates, reloads and staged updates never touch rows; a reinstall keeps every row and turns on its target. The install alerts name the profile. Settings > Extensions gained Turn On in All Profiles (normal profiles only, through the per-profile enable path) and a line saying where the extension is on. Tests: new ExtensionProfileScopeTests; 13 suites adjusted for the new default; 79 suites / 1553 tests pass. Runtime: install landed in one profile only, a new profile loaded nothing, the button turned it on everywhere but Private, and v24 re-run on a pre-312-shaped DB restored the old state. Open: the website half of AC #6 (facts in the notes), the NSOpenPanel / Web Store UI install paths not driven at runtime.
<!-- SECTION:FINAL_SUMMARY:END -->
