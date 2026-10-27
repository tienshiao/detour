---
id: TASK-216
title: >-
  Privacy: check whether normal profiles' user agent reveals the exact macOS
  version
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - privacy
  - question
dependencies: []
priority: low
ordinal: 252000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-194: quarantine windows send Safari's standard user agent, but normal profiles appear to send one that includes the exact macOS version, which makes Detour easier to fingerprint than Safari. Confirm what each profile kind sends (navigator.userAgent and the request header), compare with Safari on the same Mac, and decide whether normal profiles should send the standard Safari user agent too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The user agent each profile kind sends is recorded, with Safari's for comparison
- [ ] #2 The decision is recorded; if changed, a test covers the user agent a normal profile's web view gets
<!-- AC:END -->
