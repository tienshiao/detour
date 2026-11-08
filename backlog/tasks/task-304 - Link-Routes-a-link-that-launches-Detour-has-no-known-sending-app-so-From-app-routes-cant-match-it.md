---
id: TASK-304
title: >-
  Link Routes: a link that launches Detour has no known sending app, so From app
  routes can't match it
status: To Do
assignee: []
created_date: '2026-11-08T09:35:00Z'
updated_date: '2026-11-08T09:37:00Z'
labels:
  - link-routes
dependencies: []
priority: medium
type: bug
ordinal: 365000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Routes can match the app a link came from (TASK-191.2). AppDelegate.application(_:open:) reads the sender from the Get URL Apple Event being handled (NSAppleEventManager.currentAppleEvent → keySenderPIDAttr → bundle ID; LinkSender.swift). Observed when that was built (macOS 26, Oct 25 2026): the URL that cold-launches Detour arrives with no current event, so it has no sender, and a "From app" route (say, links from Mail go to Quarantine) is skipped for exactly the link that started Detour — it goes to the Default instead. Confirmed by reading while writing the Link Routes page (TASK-292.8, Nov 8 2026). For a route to Quarantine this is a privacy hole: the first link after launch lands in a normal Space with the user's cookies.

Likely possible, needs a spike first: register Detour's own handler for kInternetEventClass/kAEGetURL in applicationWillFinishLaunching (NSAppleEventManager.setEventHandler, as Chrome and Firefox do) and read keySenderPIDAttr from the event it receives, including the launch URL; check whether that event still names the opening app at launch (it may name LaunchServices instead). Fallbacks to evaluate if it doesn't: the app that was frontmost when Detour was launched (NSWorkspace notifications), or holding the first URL until the sender is known.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A spike on macOS 15.4 and the current macOS records what the launch URL's event carries (sender PID, address) with a custom Get URL handler, for links from Mail, Messages, Notes and Slack while Detour is not running
- [ ] #2 When the sending app can be known at launch, a From app route matches the link that launched Detour, as it does for links while Detour runs
- [ ] #3 When it can't, Detour fails closed (user, Nov 8 2026): if any route sends links to Quarantine, the link that launched Detour with no known sender opens in Quarantine
- [ ] #4 LinkSender/route resolver tests cover the launch case, both with a known sender and the fail-closed fallback; checked at runtime with /verify by launching Detour from a link in another app
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision on the fallback: fail closed. When the launch link's sender can't be known, open it in Quarantine if any Quarantine route is configured.
<!-- SECTION:NOTES:END -->
