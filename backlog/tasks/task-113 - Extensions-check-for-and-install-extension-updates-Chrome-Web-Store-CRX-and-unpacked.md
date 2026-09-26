---
id: TASK-113
title: >-
  Extensions: check for and install extension updates (Chrome Web Store CRX and
  unpacked)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-23 09:02'
updated_date: '2026-09-26 02:51'
labels:
  - extensions
  - enhancement
dependencies: []
priority: medium
ordinal: 113000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Extensions never update: once installed, a Chrome Web Store extension stays on that version forever, and an unpacked one never picks up edits to its source folder. Install paths today: Web Store installs arrive by intercepting the .crx download (BrowserWindowController+Navigation.swift handleCRXDownload -> CRXUnpacker -> ExtensionManager.install(from:publicKey:)); unpacked ones via Develop > Load Unpacked Extension. ExtensionInstaller copies the files into <data dir>/Extensions/<id> and the extension table stores only id/name/version/manifestJSON/basePath/isEnabled/installedAt — no source (store vs unpacked), no original folder, no update URL, no last-check time.

The replace-in-place half already exists: install(from:) on an existing id unloads the old context in every profile, keeps saved permission decisions (TASK-63), owes runtime.onInstalled reason 'update' (TASK-29) and rehomes open extension pages to the new origin. What is missing is knowing where to look for a newer version and doing it.

Chrome's model for reference: the manifest's update_url (Web Store manifests carry https://clients2.google.com/service/update2/crx) is polled with the update2 protocol (response=updatecheck, x=id%3D<id>%26v%3D<version>%26uc) roughly every few hours and on startup; a newer version's CRX is downloaded, its CRX3 signature/public key must derive the same extension id, and it is installed in place. If an update adds permissions that would show a new warning, Chrome disables the extension until the user approves. Extensions can also call runtime.requestUpdateCheck and listen to runtime.onUpdateAvailable (deferring the reload until the worker is idle).

Open decisions: how often to check (and only while the app is running?); whether updates install silently or show a notice/badge; how to handle an update that adds permissions or host permissions; whether unpacked extensions record their source folder and offer 'Reload' (Chrome's developer-mode behaviour) rather than auto-updating.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each installed extension records its source (Web Store / other CRX / unpacked) and, for CRX installs, the update URL (manifest update_url or the Web Store default); existing installs are migrated sensibly
- [ ] #2 A background check (at launch and on an interval) plus a manual 'Check for Updates' in Extension settings query the update URL and install a newer version in place through the existing install(from:) replace path
- [ ] #3 A downloaded update is rejected unless its CRX signature/public key derives the same extension id and its version is higher than the installed one
- [ ] #4 An update that adds permissions or host permissions does not silently gain them: the chosen policy (e.g. disable until approved, as Chrome does) is implemented and tested with positive and negative cases
- [ ] #5 Updating keeps per-profile enablement, Private-window opt-in, saved permission decisions and open extension pages, and fires runtime.onInstalled with reason 'update' and previousVersion
- [ ] #6 Unpacked extensions can be reloaded from their original folder (Develop menu / Extension settings)
- [ ] #7 runtime.requestUpdateCheck and runtime.onUpdateAvailable behave per Chrome (or are explicitly out of scope with a follow-up); API Explorer extension and tests updated for any API added
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions: check on launch (30 s in, if the last check is older than the interval) and every 5 h while running (Chrome's cadence), plus 'Check for Updates' in Settings; updates install silently in place; an update that adds permissions or host permissions (beyond what old patterns already cover; warning-free permissions ignored) installs DISABLED with a pending-approval record — Settings shows the new permissions with an Accept button and flipping Enabled prompts the same way; unpacked extensions record their source folder and get 'Reload' (Settings + Develop menu) instead of auto-update; runtime.requestUpdateCheck does a real, throttled check; runtime.onUpdateAvailable is defined but never fires (deferred apply is a follow-up).
1. Core: ExtensionVersion; ExtensionSource + classifyCRX; ExtensionManifest.updateURL; extension row columns source/updateURL/sourcePath/pendingPermissionApprovalJSON + migration v17; ExtensionInstaller.Options; CRX3Verifier (RSA PKCS#1 v1.5 + ECDSA P-256 over the CRX3 SignedData preamble, SPKI→PKCS#1); ExtensionUpdatePolicy; UpdateManifest (update2 request/response); ExtensionUpdater (single-flight, throttle, schedule, appState last-check); ExtensionManager.applyUpdate / reloadUnpacked / approvePendingPermissions.
2. Integration: source recorded at the install sites; Settings pane (source line, Check for Updates, Reload, pending-permissions banner + Accept, Enabled gate); Develop menu Reload items; Extensions menu 'Check for Extension Updates'; polyfill runtime.requestUpdateCheck + onUpdateAvailable; API Explorer; docs.
3. Tests: version, update2 parsing, policy, CRX3 verification (in-test signed CRX builder), updater end-to-end with a fake fetcher, migration, polyfill.
<!-- SECTION:PLAN:END -->
