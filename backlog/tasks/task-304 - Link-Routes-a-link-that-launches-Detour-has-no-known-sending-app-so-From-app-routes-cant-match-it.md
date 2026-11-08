---
id: TASK-304
title: >-
  Link Routes: a link that launches Detour has no known sending app, so From app
  routes can't match it
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T09:35:00Z'
updated_date: '2026-11-08T21:04:00Z'
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
- [x] #2 When the sending app can be known at launch, a From app route matches the link that launched Detour, as it does for links while Detour runs
- [x] #3 LinkSender/route resolver tests cover the launch case, both with a known sender and the fail-closed fallback; checked at runtime with /verify by launching Detour from a link in another app
- [x] #4 When it can't, Detour fails closed (user, Nov 8 2026, narrowed the same day): the link that launched Detour with no known sender opens in Quarantine where a From app route to Quarantine could have matched it (reached in route order, URL condition holds)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike: own GURL handler in applicationWillFinishLaunching, log the launch event's attributes for cold launches (bare CLI via NSWorkspace with DETOUR_DATA_DIR in the environment, the same tool as a LaunchServices-launched .app, open -n --env -a) and for a running copy with its own bundle ID. Record raw results.
2. Implement: AppDelegate.handleGetURLEvent (installed in applicationWillFinishLaunching) reads sender + URLs from the event; events before applicationDidFinishLaunching are queued and opened at its end as launch links; application(_:open:) stays for Open Documents.
3. Pure code: LaunchLinkTracker + linkURLs(in:) (LinkSender.swift), resolveExternalLinkRoute + linkRoutesSendToQuarantine (resolver): unknown sender at launch + any Quarantine route -> Quarantine; otherwise the routes as before.
4. Tests: resolver (known sender at launch, unknown with/without a Quarantine route, running unchanged), tracker, URL parsing, ExternalLinkRoutingTests through openExternalURLs and handleGetURLEvent.
5. Runtime check with the CLI senders and seeded routes; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision on the fallback: fail closed. When the launch link's sender can't be known, open it in Quarantine if any Quarantine route is configured.

SPIKE (Nov 8 2026, agent-links; macOS 26.7 build 25G229, the only macOS available here). Temporary DEBUG patch: a kInternetEventClass/kAEGetURL handler installed with NSAppleEventManager.setEventHandler in applicationWillFinishLaunching, logging every event's attributes to a file; senders: (a) a bare swiftc CLI calling NSWorkspace.open([url], withApplicationAt: <worktree Debug Detour.app>, configuration: createsNewApplicationInstance = true, environment = [DETOUR_DATA_DIR: fresh name]); (a') the same binary inside an LSUIElement .app (bundle ID com.detourbrowser.verify.sender304) started through LaunchServices (open -n); (b) open -n --env DETOUR_DATA_DIR=... -a <Debug app> URL (-n added on purpose: without it LaunchServices can hand the URL to the user's running production Detour, same bundle ID); running case: a copy of the Debug app with its own bundle ID (com.detourbrowser.verify.debugcopy304, ad-hoc signed, get-task-allow only), launched with launch-detour.sh, then the .app sender, the bare CLI and open -a <copy> URL. Each log's first line confirmed the data dir (DetourB8-304-c1/c2/c3/r).

Raw results (pid = Detour's):
- c1 cold, bare CLI (pid 60799, no bundle ID): willFinishLaunching: currentAppleEvent nil. Then, BEFORE applicationDidFinishLaunching (+0.085 s), our handler got class 'GURL' id 'GURL', keySenderPIDAttr type 'magn' = 60799 (the CLI, path .../tools/sender304, NSRunningApplication bundle nil), keyAddressAttr type 'psn ' 8 bytes 01000000 7fed0000 (low word = the PID), keyOriginalAddressAttr the same 'psn ', keyEventSourceAttr 'shor' 3 (kAELocalProcess), keySenderAuditTokenAttr 'tokn' pid 60799, direct object 'TEXT' https://c1.test/a; currentAppleEvent === the handler's event. Resolved sender: none. didFinishLaunching userInfo NSApplicationLaunchIsDefaultLaunchKey = 0.
- c2 cold, the .app sender via LaunchServices (pid 60922, com.detourbrowser.verify.sender304), two URLs in one NSWorkspace.open: first URL before didFinishLaunching (+0.070 s), keySenderPIDAttr 'magn' 60922 -> bundle ID com.detourbrowser.verify.sender304 (KNOWN), address/original address 'psn ' with the same PID, esrc 3, audit token 60922. The second URL came as its own GURL event 0.11 s AFTER didFinishLaunching, same sender PID and bundle ID.
- c3 cold, open -n --env ... -a (pid 60975 = /usr/bin/open): before didFinishLaunching; keySenderPIDAttr 'magn' 60975, but the process had already exited (proc_pidpath failed, NSRunningApplication nil) -> no sender.
- r running copy: launch-detour.sh exec: didFinishLaunching's current event is 'aevt'/'oapp' (sender = Detour itself, esrc 1), NSApplicationLaunchIsDefaultLaunchKey = 1, no GURL. Then: .app sender -> GURL with spid 'magn' = 61034, com.detourbrowser.verify.sender304 (known); bare CLI -> spid its PID, no bundle ID; open -a <copy> URL -> spid /usr/bin/open, no bundle ID. Same attributes as before TASK-304 (wiki table).
- So: with Detour's own Get URL handler the launch URL's event is handled in place, before applicationDidFinishLaunching, and carries the opener's PID exactly like a link while running. The old 'no current event' at launch came from AppKit's own handler, which queues the launch URLs and calls application(_:open:) after didFinishLaunching outside any event. Nothing named LaunchServices (launchservicesd) or Detour as the sender of a GURL.
- Not tested: links clicked in Mail, Messages, Notes or Slack (the user's production Detour is the default browser and cannot be changed during the batch, so their links cannot reach a Debug build), and macOS 15.4 (only the current macOS is installed). Whether those apps open links from the app process itself (known sender) or from a helper/XPC process inside their bundle (NSRunningApplication nil -> unknown -> the fail-closed path) is therefore unverified.

Implementation (agent-links):
- AppDelegate.applicationWillFinishLaunching installs handleGetURLEvent(_:withReplyEvent:) for kInternetEventClass/kAEGetURL. It reads the sender (linkSenderPID + linkSenderBundleID, at arrival: the opener may exit) and the URLs (linkURLs(in:): a string or a list). Events handled before applicationDidFinishLaunching are queued and opened at the very end of that method (session and routes loaded) as launch links. application(_:open:) is kept: with a Get URL handler installed AppKit only calls it for Open Documents (file URLs, which openExternalURLs ignores, unchanged: opening an .html file in Detour does nothing today, before and after this task).
- LaunchLinkTracker (LinkSender.swift, pure): launch links = events while launching, plus events from one of those events' sender PIDs up to 10 s after launch finished (the next URLs of the same open arrive as their own events right after launch: 0.11 s in the spike). Everything else is a link while running.
- resolveExternalLinkRoute (LinkRouteResolver.swift, pure): launchedDetour && sourceApp == nil && web URL && linkRoutesSendToQuarantine(routes) -> .quarantine; otherwise resolveLinkRoute(.external(sourceApp:)) exactly as before. A known sender at launch therefore matches its From app route.
- Decision I made (rule file: conservative when undecided): 'any route sends links to Quarantine' is taken literally: any route with a condition whose target is Quarantine, app or URL route, and the fallback wins over URL routes listed before it. A narrower variant (only From app Quarantine routes whose URL condition matches, in route order) would quarantine less; not taken without the user. It is a one-function change (linkRoutesSendToQuarantine and the first line of resolveExternalLinkRoute).
- Not taken: mapping a helper process to its enclosing .app bundle (proc_pidpath) to name senders NSRunningApplication does not know. Could reduce how often the fail-closed path triggers if Mail/Messages/etc. open links from helpers; unverified, so left as an idea.
- Observation, unchanged behaviour (pre-existing, TASK-191.2 'kept exactly'): the Most Recent Space path puts a link in the KEY window's space, which can be a Private window (runtime check v4: after a link was routed to a Private window, an unmatched link from another app opened as a tab in that Private window). Not touched here.

Tests: LinkPlacementTests 24 (+4: Get URL URLs, LaunchLinkTracker x3), LinkRouteResolverTests 50 (+5), ExternalLinkRoutingTests 23 (+3, including handleGetURLEvent with a list event): 97/0 in the run with the change.

Runtime check (harness = temporary file logging, not committed; scratch agent-links/Spike304-final.swift + task304-with-verify.patch; screen lock held; launches only with DETOUR_DATA_DIR: launch-detour.sh, NSWorkspace with environment DETOUR_DATA_DIR, open -n --env; each log's first line confirmed the data dir):
- v1 cold launch from the LaunchServices-launched sender app (com.detourbrowser.verify.sender304), route 'From app sender304 -> Private Window': handler before didFinishLaunching, sender known, decision privateWindow, a new Private window with https://v1.test/known-sender.
- v2 cold launch from the bare CLI (no bundle ID), route 'From app com.apple.mail -> Quarantine': sender nil, launchedDetour true, decision quarantine; a quarantine window with the URL, no tab in a space.
- v3 cold launch from the bare CLI, route 'From app com.apple.mail -> Private Window' (no Quarantine route): decision mostRecentSpace; the URL opened as a tab in the restored window (Detour active, that window key at the flush; no second window).
- v4 running (renamed copy, routes sender304 -> Private Window, Mail -> Quarantine): app sender -> privateWindow (unchanged); bare CLI -> mostRecentSpace, launchedDetour false: not failed closed while running.
- Cleaned: defaults keys NSWindow Frame/NSSplitView for DetourB8-304-c1/c2/c3/v1/v2/v3, suites com.detourbrowser.mac.DetourB8-304-*, com.detourbrowser.verify.debugcopy304 (+ .DetourB8-304-r/.DetourB8-304-v4), App Support/DetourB8-304-*, the copy's Caches/HTTPStorages/WebKit folders; lsregister -u for the copy and the sender app. WebKit stores of com.detourbrowser.mac created by these runs (UUID-named, under ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore) were left.
- Not checked: links from Mail, Messages, Notes, Slack (production Detour is the default browser; the Debug build cannot receive their links during the batch), macOS 15.4 (not installed), Finder/Dock drops of .webloc (Finder hands a .webloc's URL to the default browser).

Final test run on the committed tree (harness removed): LinkPlacementTests 24, LinkRouteResolverTests 50, ExternalLinkRoutingTests 23, LinkRouteStoreTests 42, LinkRouteEditorTests 17: 156 tests, 0 failures.
AC #1 left unchecked: the spike ran on the current macOS (26.7) with simulated senders only; Mail/Messages/Notes/Slack and macOS 15.4 need the user (production Detour is the default browser, and 15.4 is not installed). AC #4's runtime part was done by launching Detour from another (test) app, not from those apps.

Website: updated Link Routes and Quarantine (a From app route also applies to the link that starts Detour; with no known sending app and any route to Quarantine, that link opens in Quarantine) on website branch next-release (86f8ad3), held for the release

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).

Nov 8 2026, user narrowed the fail-closed rule ('if the trigger can be determined to be falsy we do not need to fail closed'): a launch link with no known sender goes to Quarantine only where a From app route to Quarantine is reached (in route order) whose URL condition holds. A route whose URL condition fails, one behind a matching route, and a URL-only route to Quarantine resolve as usual. Supersedes the 'any Quarantine route' rule and linkRoutesSendToQuarantine above (removed); the resolver core takes senderMightMatchQuarantine. Tests: LinkRouteResolverTests (fail-closed and new skip test), ExternalLinkRoutingTests (launch test now adds a Mail→Quarantine route; new test: URL-only Quarantine route that does not match → the Default), 117 tests in the link-routing suites, 0 failures. /code-review medium --fix: 6 findings (doc comment, wiki tests summary, log placement, duplicated decision call, this note), all fixed. Runtime: not run; a pure resolver change whose launch path the wiring tests drive in the test host, and an unknown-sender launch cannot reach a Debug build while the production Detour is the default browser.

Nov 8 2026, user's production build with the TASK-304 code (macOS 26.7), unified log 'External link from': 13:03:34 a link from Mimestream while running -> 'External link from com.mimestream.Mimestream: quarantine'; 13:03:54 Detour quit, a Mimestream link launched it (pid 38893) -> 'External link from com.mimestream.Mimestream (launched Detour): quarantine'. The sender is known at launch in the signed build, so the user's From app route matched the launch link (before TASK-304 it was 'no known sender'). No lines from Mail, Messages, Notes or Slack in the last 3 h. Still open for #1: other apps, macOS 15.4.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Detour now handles Get URL Apple Events itself (handler installed in applicationWillFinishLaunching). The spike showed the event that launches Detour then arrives before applicationDidFinishLaunching with the opener's PID, exactly like a link while running, so a From app route matches the link that launched Detour (the old 'no sender' came from AppKit queueing launch URLs). Launch links are queued and opened once the session is restored. When the launch link's sender can't be named (a tool, an exited opener, a helper NSRunningApplication doesn't know), it fails closed: any route to Quarantine sends it to Quarantine (user decision; taken literally). Links while running are unchanged. Pure pieces: LaunchLinkTracker, linkURLs(in:), resolveExternalLinkRoute; tests 156/0 across the five Link Routes suites. Runtime: cold launches from a LaunchServices test app (known sender -> its route) and a bare tool (unknown -> Quarantine, or the Default with no Quarantine route), and a running copy (unchanged). Open: AC #1 for real apps (Mail, Messages, Notes, Slack) and macOS 15.4, which need the user's machine setup.

Narrowed Nov 8 2026 (user): the launch fail-closed applies only where a From app route to Quarantine could have matched (reached in route order, URL condition holds), not 'any route to Quarantine'; a579af9.
<!-- SECTION:FINAL_SUMMARY:END -->
