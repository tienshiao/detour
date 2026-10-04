---
id: TASK-151
title: >-
  Extensions: a first install from a CRX does not verify its signature, so the
  file can claim any extension id
status: To Do
assignee: []
created_date: '2026-10-04 04:31'
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
- [ ] #1 A CRX is installed only if it passes CRX3 signature verification and the verified key is the one its id is derived from; a manifest key that disagrees with the verified key is refused or ignored by a stated rule
- [ ] #2 A CRX with a header key that did not sign it, a tampered archive, an unsigned or CRX2 file, and a truncated header are each refused before any prompt, with an error that says why — tests cover each
- [ ] #3 A CRX whose id matches an installed extension is refused, or installed only through the update rules (same verified key, newer version, added-permissions policy), and never silently replaces it — tests cover the attempt
- [ ] #4 The install prompt says where the file came from (Chrome Web Store or the host) and, for a non-store CRX, makes that clear
- [ ] #5 A genuine Web Store CRX (1Password, Claude) still installs — verified with a real store download
- [ ] #6 docs/extensions.md states the install-time verification
<!-- AC:END -->
