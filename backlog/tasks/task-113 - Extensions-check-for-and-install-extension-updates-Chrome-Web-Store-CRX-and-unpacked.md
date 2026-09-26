---
id: TASK-113
title: >-
  Extensions: check for and install extension updates (Chrome Web Store CRX and
  unpacked)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-23 09:02'
updated_date: '2026-09-26 04:03'
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
- [x] #1 Each installed extension records its source (Web Store / other CRX / unpacked) and, for CRX installs, the update URL (manifest update_url or the Web Store default); existing installs are migrated sensibly
- [x] #2 A background check (at launch and on an interval) plus a manual 'Check for Updates' in Extension settings query the update URL and install a newer version in place through the existing install(from:) replace path
- [x] #3 A downloaded update is rejected unless its CRX signature/public key derives the same extension id and its version is higher than the installed one
- [x] #4 An update that adds permissions or host permissions does not silently gain them: the chosen policy (e.g. disable until approved, as Chrome does) is implemented and tested with positive and negative cases
- [x] #5 Updating keeps per-profile enablement, Private-window opt-in, saved permission decisions and open extension pages, and fires runtime.onInstalled with reason 'update' and previousVersion
- [x] #6 Unpacked extensions can be reloaded from their original folder (Develop menu / Extension settings)
- [x] #7 runtime.requestUpdateCheck and runtime.onUpdateAvailable behave per Chrome (or are explicitly out of scope with a follow-up); API Explorer extension and tests updated for any API added
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Decisions: check on launch (30 s in, if the last check is older than the interval) and every 5 h while running (Chrome's cadence), plus 'Check for Updates' in Settings; updates install silently in place; an update that adds permissions or host permissions (beyond what old patterns already cover; warning-free permissions ignored) installs DISABLED with a pending-approval record — Settings shows the new permissions with an Accept button and flipping Enabled prompts the same way; unpacked extensions record their source folder and get 'Reload' (Settings + Develop menu) instead of auto-update; runtime.requestUpdateCheck does a real, throttled check; runtime.onUpdateAvailable is defined but never fires (deferred apply is a follow-up).
1. Core: ExtensionVersion; ExtensionSource + classifyCRX; ExtensionManifest.updateURL; extension row columns source/updateURL/sourcePath/pendingPermissionApprovalJSON + migration v17; ExtensionInstaller.Options; CRX3Verifier (RSA PKCS#1 v1.5 + ECDSA P-256 over the CRX3 SignedData preamble, SPKI→PKCS#1); ExtensionUpdatePolicy; UpdateManifest (update2 request/response); ExtensionUpdater (single-flight, throttle, schedule, appState last-check); ExtensionManager.applyUpdate / reloadUnpacked / approvePendingPermissions.
2. Integration: source recorded at the install sites; Settings pane (source line, Check for Updates, Reload, pending-permissions banner + Accept, Enabled gate); Develop menu Reload items; Extensions menu 'Check for Extension Updates'; polyfill runtime.requestUpdateCheck + onUpdateAvailable; API Explorer; docs.
3. Tests: version, update2 parsing, policy, CRX3 verification (in-test signed CRX builder), updater end-to-end with a fake fetcher, migration, polyfill.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Runtime verification Sep 25 2026 (isolated profile, harness): the real 1Password 8.12.37.1 store CRX (18 MB) passed CRX3Verifier (RSA) and derived the expected id; a live update2 check against clients2.google.com answered noupdate → Settings shows 'Installed from the Chrome Web Store · Last checked just now' + 'Up to date'; Extensions > Check for Extension Updates ran all three installs; Settings Reload of the unpacked API Explorer replaced it under the same id; editing a fixture's manifest to add history + a host pattern and reloading installed it disabled with the pending-permissions banner, Accept and Enable re-enabled it and loaded its context; chrome.runtime.requestUpdateCheck from an options page answered {status: no_update}. Code review (--fix medium) findings applied: varint length overflow in CRX3 header parsing (remote crash), frontmost-window resolution shared via NSApplication.frontmostBrowserWindowController, server-side updatecheck errors surface as failures, https-only update URLs on update too, store-host check on the domain boundary, deduplicated reload-availability rule. Migration decision: a manifest with a key reads as unpacked even with update_url (never auto-replace a developer's folder). Follow-up TASK-123 (deferred apply + onUpdateAvailable) was created — delete it if unwanted.

Banner layout reworked after the user's review of the capture (commit on task113): 14 pt insets, 13 pt semibold title with a matching warning symbol, 3 pt line spacing in the permission list, Accept and Enable on its own trailing row 12 pt below the list (stack distribution .fill so the text column spans the box), source path middle-truncated on one line with a tooltip, and the Reload/Update status drops the '— new permissions need your approval' suffix while the banner shows. Re-captured in the isolated profile.

Banner container: NSBox replaced by a layer-backed TintedBannerView that sizes from its content — NSBox's autoresizing content view never grew to the stack's fitting height, so the vertical insets collapsed. Re-captured: 14 pt top/bottom now hold. (A dark-appearance cacheDisplay capture comes out with a transparent window background, so dark mode was not visually assessed.)
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extensions now update. Each install records its source (webStore/crx/unpacked), update URL and, for unpacked loads, the source folder (migration v17 classifies existing installs; keyed manifests stay unpacked). ExtensionUpdater polls update2 at launch (if due) and every 5 h, plus Settings > Check for Updates, Extensions > Check for Extension Updates and chrome.runtime.requestUpdateCheck (throttled); a candidate is taken only when its CRX3 signatures verify (RSA/ECDSA, CRX3Verifier), the declared key derives the installed id, the version is newer and the announced SHA-256 matches, then ExtensionManager.applyUpdate replaces it in place through install(from:) keeping per-profile rows, saved permission decisions, open pages and the onInstalled 'update' ledger. An update or reload that adds permissions/host access installs disabled with a pending-approval record; Settings shows the delta with Accept and Enable (Enabled switch prompts too). Unpacked extensions get Reload in Settings and the Develop menu. runtime.onUpdateAvailable is defined but never fires (TASK-123). 60+ new tests incl. an in-test CRX3 builder; verified at runtime against the real 1Password store CRX.
<!-- SECTION:FINAL_SUMMARY:END -->
