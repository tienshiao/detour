---
type: Concept
title: "javascript: URLs from extensions"
description: Why windows.create, tabs.create and tabs.update refuse a javascript URL before anything opens or loads, where the check sits, and what the shipped WebKit did without it.
tags: [extensions, tabs, windows, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (isJavaScriptURL, javaScriptURLRefusal)
  - id: tab-conformance
    resource: ../../Detour/Extensions/Runtime/WKExtensionTabConformance.swift
    title: WKExtensionTabConformance.swift (BrowserTab.loadURL)
  - id: task-225
    resource: backlog:TASK-225
    title: windows.create opens a window for a javascript URL
  - id: windows-create-tests
    resource: ../../DetourTests/ExtensionWindowsCreatePrivateTests.swift
    title: ExtensionWindowsCreatePrivateTests
  - id: webkit-windows-api
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIWindowsCocoa.mm
    title: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
---
`windows.create` (the URL alone or among others), `tabs.create` and
`tabs.update` refuse a `javascript:` URL before anything opens or loads
(`ExtensionManager.isJavaScriptURL`, checked in `openNewWindowUsing`,
`openNewTabUsing` and `BrowserTab.loadURL`), with "Cannot load a javascript:
URL; use chrome.scripting.executeScript instead", as Chrome's MV3 refuses
them. The scheme is compared case-insensitively: Foundation's `URL` keeps a
scheme's case, so `JavaScript:` parses with the scheme "JavaScript".

# What the shipped WebKit does

The WebKit shipped with macOS 26.7 (build 25G229, Darwin 25.6) passes
all three through to Detour, although WebKit's `main` refuses the URL in
`windows.create` itself:[^webkit-windows-api] `windows.create` opened a
window, `tabs.create` a tab, and `tabs.update` loaded the URL into the tab,
which ran the script in its page, so an extension could script a page through
`tabs.update` instead of `scripting`.[^task-225]

# The message

WebKit prefixes the
message with "Invalid call to <api>()." and capitalises its first letter,
which is why it does not start with the scheme.

# Tests

`ExtensionWindowsCreatePrivateTests` — a `javascript:` URL refused by
`windows.create`, `tabs.create` and `tabs.update` (the page left alone) in
every form, in one test to keep the suite's retained profiles down.

# Related

- [Opening tabs and windows](./opening-tabs-and-windows.md) — the other rules `windows.create` and `tabs.create` apply.
- [Tab and window bridge](./tab-and-window-bridge.md) — `BrowserTab`'s `WKWebExtensionTab` conformance, where `tabs.update` lands.

[^task-225]: windows.create opens a window for a javascript URL
[^webkit-windows-api]: WebKit WebExtensionContextAPIWindowsCocoa.mm (windowsCreate, read 2026-10-27)
