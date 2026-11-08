---
id: TASK-301
title: 'Content blocker: add your own filter lists and rules'
status: To Do
assignee: []
created_date: '2026-11-08T08:41:00Z'
labels:
  - content-blocker
dependencies: []
references:
  - TASK-292.7
priority: low
ordinal: 362000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The built-in content blocker offers four fixed lists per profile (EasyList, EasyPrivacy, cookie notices, malicious URLs; Settings › Profiles "Block content" rows, Settings › Content Blocking "Update All Now") and a per-site switch in the Site Settings popover. There's no way to subscribe to another list (regional EasyList variants, uBlock filters, annoyance lists) or to add a rule of your own (hide an element, block a host). People who used uBlock Origin in Arc or Chrome expect it, and Manifest V3 limits those extensions. Found while writing the Content Blocker guide page (TASK-292.7), which currently says "Not yet".

Context: lists are compiled by EasyListParser into WebKit content rule lists (ContentBlocker/), which skip some advanced rule types; WebKit caps rules per list. Scope (custom list URLs, hand-written rules, element picker, per-profile or app-wide) is for the user to set.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Scope agreed with the user: custom list subscriptions by URL, hand-written rules, or both; per profile or app-wide
- [ ] #2 A custom list is fetched, compiled and applied like the built-in ones, updates with Update All Now, and reports rules it had to skip
- [ ] #3 Invalid or oversized lists fail with a clear message and don't break the other lists
- [ ] #4 Tests cover parsing/compiling custom input and the failure cases
- [ ] #5 The website's Content Blocker page is updated
<!-- AC:END -->
