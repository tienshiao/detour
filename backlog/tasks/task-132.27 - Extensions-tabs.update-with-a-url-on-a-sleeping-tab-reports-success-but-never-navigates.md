---
id: TASK-132.27
title: >-
  Extensions: tabs.update with a url on a sleeping tab reports success but never
  navigates
status: To Do
assignee: []
created_date: '2026-11-07T23:55:00Z'
labels:
  - bug
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/WKExtensionTabConformance.swift
parent_task_id: TASK-132
priority: high
ordinal: 339000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-132.5 subagent (2026-11-07). BrowserTab.loadURL(_:for:completionHandler:) in Detour/Extensions/Runtime/WKExtensionTabConformance.swift calls webView?.load(...) and then completionHandler(nil). A sleeping tab has no web view, so the load is dropped and the extension is told it succeeded. The tab keeps its old page, and the next tabs.get still reports the old URL.

Why it matters: the Claude extension drives unselected agent tabs (TASK-132.3) and navigates them with tabs.update. A tab of its group that the sleep policy put to sleep (unselected long enough, or over the show budget) silently stops following the agent, which then acts on a page it did not ask for. reload() has the same shape (webView?.reload()).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 tabs.update({url}) on a sleeping tab navigates it to the URL (waking it or loading it on wake) and the reply and the next tabs.get report the new URL
- [ ] #2 tabs.reload on a sleeping tab either reloads it or fails with an error, never reports success with nothing done
- [ ] #3 Tests in a real extension context cover a sleeping and an awake tab, from the worker and from an extension page, promise and callback forms
<!-- AC:END -->
