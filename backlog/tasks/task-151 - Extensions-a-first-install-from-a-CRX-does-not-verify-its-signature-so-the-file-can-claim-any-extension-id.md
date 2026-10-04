---
id: TASK-151
title: >-
  Extensions: a first install from a CRX does not verify its signature, so the
  file can claim any extension id
status: Done
assignee: []
created_date: '2026-10-04 04:31'
updated_date: '2026-10-04 08:46'
labels:
  - bug
  - extensions
  - security
dependencies: []
priority: high
ordinal: 174000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 during TASK-132.4 (the Web Store install of the Claude extension) and confirmed by reading the code.

BrowserWindowController+Navigation intercepts ANY navigation response whose MIME type is application/x-chrome-extension or whose URL ends in .crx (isCRXResponse, no host check), downloads it, and finishCRXInstall calls CRXUnpacker.unpack(data:) and then ExtensionManager.install(from:publicKey:options:) with the public key read from the CRX header. CRX3Verifier.verify is called only from ExtensionUpdater (updates); the install path never checks that the archive is signed by the key it declares, nor that the declared key is the one the id is derived from.

Consequences to confirm and close:
- A CRX from any website can carry the public key of another extension in its header and so be installed under that extension's id. Native messaging hosts authorise by id (allowed_origins: chrome-extension://<id>/), so such an extension would be trusted by, for example, 1Password's or Claude Code's native host.
- If an extension with that id is already installed, install(from:) goes over the old copy and keeps its per-profile enablement, saved permission decisions and storage — the real extension could be replaced by the crafted one.
- The only barrier is the install prompt, which shows the name and permissions from the unverified manifest and does not show where the file came from, the id, or that it would replace an installed extension.
- A manifest 'key' field is also an id source (keyed manifest => unpacked install); check how a CRX whose manifest key disagrees with its header key is treated.

Related: TASK-139 (a crafted CRX header can crash the app at install). The update path already has the right check: the candidate must pass CRX3 signature verification and its signing key must derive the installed id.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A CRX is installed only if it passes CRX3 signature verification and the verified key is the one its id is derived from; a manifest key that disagrees with the verified key is refused or ignored by a stated rule
- [x] #2 A CRX with a header key that did not sign it, a tampered archive, an unsigned or CRX2 file, and a truncated header are each refused before any prompt, with an error that says why — tests cover each
- [x] #3 A CRX whose id matches an installed extension is refused, or installed only through the update rules (same verified key, newer version, added-permissions policy), and never silently replaces it — tests cover the attempt
- [x] #4 The install prompt says where the file came from (Chrome Web Store or the host) and, for a non-store CRX, makes that clear
- [x] #5 A genuine Web Store CRX (1Password, Claude) still installs — verified with a real store download
- [x] #6 docs/extensions.md states the install-time verification
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. CRXInstallGate.admit(crxData:installed:) — a pure gate the install path runs before anything is unpacked or shown: CRX3Verifier.verify, id from the verified key, refuse an installed id, unpack, refuse a manifest key that is not the verified key.
2. Tests first for each refusal and for admission (CRXInstallGateTests, built with CRX3TestBuilder).
3. finishCRXInstall uses the gate, installs under the verified key, re-checks the id after the modal prompt, and shows where the file came from (CRXInstallGate.originDescription, from the final URL of the fetch).
4. Real store CRXs through the gate (gated test).
5. docs/extensions.md, wiki installer page and the CRX decision page.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Rules chosen (AC #1, #3):
- Manifest key: REFUSED when present and not equal to the verified signing key (an undecodable key counts as a mismatch). Chrome's unpacker instead overwrites the manifest key with the CRX key; refusing was chosen so that no later reader of manifest.key can be led to another id. The Web Store does not accept a manifest with a key, and both real store files below pass. The update path is unchanged: it ignores the manifest key (the id there is pinned to the installed one by the verified key).
- Installed id: REFUSED, whatever the candidate's version ('…is already installed… use Settings > Extensions > Check for Updates; to reinstall it, remove it first'). Not routed through applyUpdate: that would add an update prompt to this path; the updater already covers newer versions. A non-store CRX without update_url can therefore only be replaced by remove + install.
- Origin (AC #4): the prompt's first line is 'From the Chrome Web Store.' only when the final URL of the fetch is on a store host (ExtensionSource.webStoreHosts), else 'From <host>, not from the Chrome Web Store.' The same final URL now feeds ExtensionSource.classifyCRX (before: the navigation response's URL, before the fetch's own redirects). Not checked: the store's own publisher proof, which Chrome requires for store installs — 'from the store' means the host, not the signature.
- The unzip now happens only after verification and the installed-id check.

Tests: CRXInstallGateTests 21 (20 run + 1 gated), CRX3VerifierTests 15, ExtensionIDDerivationTests 14 — all pass. New code, so 'failing before' is by construction: the gate did not exist and finishCRXInstall installed under CRXUnpacker's declared key.
AC #5: downloaded the current store CRXs (clients2.google.com update2 URL, 2026-10-04) and ran them through the gate with TEST_RUNNER_DETOUR_REAL_CRX_FILES: 1Password 8.12.38.34 (18,749,599 bytes) admitted as aeblfdkhhhdcdjpifhhbdiojplfjncoa; Claude 1.0.98 (6,918,124 bytes) admitted as fcoeoabgfenejglbffodgkkbkcdhcgfn.
NOT verified yet: the install through the UI (prompt text, refusal alert, a real store install end to end).

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
Through BrowserWindowController.handleCRXDownload, alerts read and answered in-process:
- a tampered copy of the Claude CRX: 'Extension Not Installed — The file's signature could not be verified, so it was not installed (a CRX3 signature does not verify). From a file on this Mac (tampered.crx), not from the Chrome Web Store.' No install prompt.
- the genuine file from disk: prompt 'Install "Claude"?' starting 'From a file on this Mac (genuine.crx), not from the Chrome Web Store.', then the permissions; cancelled, nothing installed.
- the real store URL (clients2.google.com update2): prompt starting 'From the Chrome Web Store.'; Install -> 'Extension Installed'; extension row fcoeoabgfenejglbffodgkkbkcdhcgfn 1.0.98 source webStore (AC #5 through the UI path, Claude only; 1Password passed the gate in the gated test).
- the same file again: 'Extension Not Installed — "Claude" (version 1.0.98) is already installed, and an install never replaces an installed extension…'
Not done: clicking 'Add to Chrome' on the store page itself, and a look at the alerts on screen.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A downloaded CRX must pass CRXInstallGate before anything is unpacked or shown: CRX3 signatures verify, the id is derived from the verified key, an id that is already installed is refused (updates go through the updater), and a manifest key that is not the signing key is refused. The prompt names where the file came from by the final URL of the fetch. Tests cover each refusal; the real 1Password and Claude store files pass the gate; in the launched app a tampered file was refused, the store download installed Claude through the prompt, and a second install of the same id was refused. Not checked: the store's own publisher proof ('from the store' means the host), and the alerts on screen.
<!-- SECTION:FINAL_SUMMARY:END -->
