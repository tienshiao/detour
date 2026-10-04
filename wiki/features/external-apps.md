---
type: Feature
title: External application links
description: "What happens when a page navigates to a non-web scheme such as zoommtg: or mailto: - the confirmation sheet, the pure launch policy, and the per-profile 'Always allow' store keyed by origin and scheme."
tags: [navigation, security, external-apps, profiles, permissions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
sources:
  - id: policy
    resource: ../../Detour/Browser/ExternalApps/ExternalAppLaunchPolicy.swift
    title: ExternalAppLaunchPolicy.swift
  - id: store
    resource: ../../Detour/Browser/ExternalApps/ExternalAppPermissionStore.swift
    title: ExternalAppPermissionStore.swift
  - id: window-extension
    resource: ../../Detour/Browser/Window/BrowserWindowController+ExternalApps.swift
    title: BrowserWindowController+ExternalApps.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: task-84
    resource: backlog:TASK-84
    title: Confirm before opening an external application URL, with an "Always allow" option
  - id: tests
    resource: ../../DetourTests/ExternalAppPermissionTests.swift
    title: ExternalAppPermissionTests.swift (ExternalAppPermissionStoreTests, ExternalAppLaunchPolicyTests)
  - id: delegate-spike
    resource: "Agent session notes, 2026-09-15: standalone WKWebView delegate spike (not in the repository)"
    title: WKWebView delegate order spike
---

# What it does

A navigation to a scheme Detour does not load itself (`zoommtg:`, `slack:`,
`mailto:`, `itms-apps:` …) belongs to another application. Detour asks first:
a sheet on the tab's window names the requesting origin and the application
that would open, with Open, Cancel and a checkbox "Always allow *site* to open
links of this type in *App*". A remembered decision opens the application
without asking. Before TASK-84 every such URL went straight to
`NSWorkspace.shared.open`, so any page could launch a local application.

# How it works

## Where it is caught

`BrowserWindowController.decidePolicy` treats a navigation as external when
its scheme is none of `http`, `https`, `about`, `blob`, `webkit-extension` or
`browser-error`. The check runs **after** the internal-scheme guard, the
Cmd/Shift/Option-click branches and the error-page re-attempt, and before the
download check. It calls `handleExternalAppNavigation(to:action:in:)` and
returns `.cancel`.

## The policy

`ExternalAppLaunchPolicy.decide(...)` is pure. In order:

| Condition | Decision |
|---|---|
| no application handles the URL, request is on screen and targets the main frame or a new window | `.reportNoHandler` - toast "No application can open “scheme:” links" |
| no application handles it, otherwise | `.ignore` |
| origin + scheme was allowed in this profile, and there is an origin | `.open` |
| the firing web view is not on screen in this window | `.ignore` |
| the window already has a sheet | `.ignore` |
| otherwise | `.prompt(canRemember:)`, with `canRemember = origin != nil && !isPrivateProfile` |

Inputs are gathered in `BrowserWindowController+ExternalApps.swift`:

- **Handler**: `NSWorkspace.shared.urlForApplication(toOpen:)`.
- **Profile**: the navigating tab's `owningProfile`, falling back to the
  active space's. A missing profile counts as private.
- **On screen** means the selected tab, a pane of its split, or the selected
  tab's Peek. A background tab never raises a sheet and never launches
  anything unless the origin was already allowed.
- **Origin**: `ExternalAppLaunchPolicy.origin(protocol:host:port:)` gives
  `scheme://host[:port]`, lowercased; port 0 (the scheme's default, as
  `WKSecurityOrigin` reports it) is omitted. An opaque or hostless origin
  (`about:blank`, `data:`, `file:`) yields nil: it is prompted every time and
  can never be remembered.

**User gesture plays no part.** A page that redirects to `zoommtg:` on load
(Zoom's join page does) is prompted exactly like a click, and nothing opens
unasked unless the origin was allowed before.

## The store

`ExternalAppPermissionStore` keeps `[profileID: Set<(origin, scheme)>]` in
memory, loaded from the `externalAppPermission` table at init, both parts
lowercased. This is Chrome's model: remembered per requesting origin and
scheme, per profile.

- `allow(...)` writes to the database unless the profile is the Private one.
  A Private decision would live in memory for the session only, but the
  checkbox is not offered there in the first place.
- Rows reference `profile` with `ON DELETE CASCADE`, so they go with the
  profile.
- Settings > Profiles shows an "External apps" row with the saved count and a
  Clear button (`clearAll(for:)`), hidden for the Private profile. The store
  posts `didChangeNotification` so an open pane refreshes its count.

# Edge cases

- **Looping pages.** The sheet is begun *synchronously inside the policy
  decision*. A page running `location = "app:…"` in a loop therefore finds
  `window.attachedSheet` set on its next attempt and is dropped, instead of
  queueing a prompt per attempt.
- **Hidden-iframe probes.** A subframe navigating to a scheme nothing handles
  (a probe for an app the user does not have, or a `data:` iframe) is dropped
  silently rather than toasting on page load. A subframe request *with* a
  handler still prompts.
- **`sourceFrame` is read through KVC.** `WKNavigationAction.sourceFrame` is
  imported as non-optional but is nil for navigations the app itself started
  (`load(_:)`); reading nil through the typed accessor is undefined behaviour.
- **`window.open("app:…")` is outside this path.** Script `window.open` calls
  only `createWebViewWith`, never `decidePolicyFor`[^delegate-spike], so it
  does not reach the prompt. TASK-84 left that case as it was.
- **Unclaimed tabs.** The check lives in the window's navigation delegate
  only. A tab's own delegate (a web view no window has claimed) hands nothing
  to an application.
- A custom-scheme *link* does reach `decidePolicyFor`, with the main frame as
  its target.[^delegate-spike]

# Tests

`ExternalAppPermissionTests.swift` holds two suites:

- `ExternalAppPermissionStoreTests` - allow and lookup; isolation per origin,
  scheme and profile; persistence across a reload; a Private decision is
  session-only and never written; `clearAll` touches one profile.
- `ExternalAppLaunchPolicyTests` - every branch and its precedence, plus the
  origin key.

The sheet and the Settings row were not exercised in the running app when the
feature landed.[^task-84]

# Related

- [WKWebView delegate order](../platform/wkwebview-delegate-order.md) - which delegate call a `_blank` link, `window.open` and a custom-scheme link produce.
- [Downloads](./downloads.md) - the next branch of the same policy function.
- [Settings](./settings.md) - the "External apps" row in the Profiles pane.
- [Incognito](../architecture/incognito.md) - why Private decisions are not persisted.
- [Session database](../architecture/session-database.md) - the `externalAppPermission` table.
- [Peek](../tabs/peek.md) - a Peek's web view counts as on screen for the prompt.

[^task-84]: Confirm before opening an external application URL, with an "Always allow" option
[^delegate-spike]: WKWebView delegate order spike
