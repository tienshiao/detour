---
id: TASK-266
title: >-
  Native messaging: a host manifest without allowed_origins admits every
  extension
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - native-messaging
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: medium
type: bug
ordinal: 313000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`NativeMessagingHost.connect()` (NativeMessagingHost.swift ~180-186) validates the origin only inside `if let allowedOrigins`, so a manifest that omits the key lets any extension with `nativeMessaging` start the host. Chrome treats a manifest without `allowed_origins` as invalid. The manifest's `type` is not checked to be `stdio`, and a relative `path` resolves against the app's working directory instead of being refused (Chrome on macOS requires an absolute path).

Host manifests live in user-writable directories (Detour's and Chrome's NativeMessagingHosts), so the check is the only thing tying a host to the extensions it was installed for.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A host manifest with no allowed_origins, or a non-array one, is refused and no process is spawned
- [ ] #2 A host manifest whose type is not stdio is refused
- [ ] #3 A host manifest whose path is not absolute is refused
- [ ] #4 The refusals reach the extension as Chrome's errors (one-shot rejection / port disconnect with lastError) and are logged
- [ ] #5 1Password's real host manifest still connects (checked in a signed build or recorded as owed)
- [ ] #6 Tests cover each refusal and the valid case
<!-- AC:END -->
