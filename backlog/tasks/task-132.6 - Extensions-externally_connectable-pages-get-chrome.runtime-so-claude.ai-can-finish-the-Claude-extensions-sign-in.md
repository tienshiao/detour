---
id: TASK-132.6
title: >-
  Extensions: externally_connectable pages get chrome.runtime, so claude.ai can
  finish the Claude extension's sign-in
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 138000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Sign-in opens https://claude.ai/oauth/authorize in a tab; claude.ai then calls chrome.runtime.sendMessage(<extension id>, {type: 'oauth_redirect', redirect_uri}) which the worker receives on runtime.onMessageExternal. WebKit installs only a `browser` global on web pages (WebExtensionControllerProxy::addBindingsToWebPageFrameIfNecessary), so chrome.runtime is undefined there and sign-in cannot finish. Provide chrome.runtime (sendMessage, connect) on pages matched by an enabled extension's externally_connectable.matches, backed by WebKit's web-page runtime. Contexts already use the Chrome id as uniqueIdentifier (Profile.swift).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 On a page matching externally_connectable, chrome.runtime.sendMessage(extensionId, msg) reaches runtime.onMessageExternal with the right sender origin and tab, and the reply comes back
- [ ] #2 A page that matches no enabled extension's externally_connectable gets no chrome.runtime from Detour
- [ ] #3 A message to an id that is not installed, or to an extension not enabled in that profile, fails the way Chrome's does (lastError / rejection), never delivered to another extension
- [ ] #4 The page's own window.chrome, if it defines one, is not clobbered
- [ ] #5 Signing in to the Claude extension completes in the app
- [ ] #6 Tests cover the positive and negative cases; API Explorer has an externally_connectable check
<!-- AC:END -->
