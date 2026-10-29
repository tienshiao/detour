---
type: Platform Quirk
title: Unresponsive web process
description: What WebKit does and does not do when a page's web process stops reading its messages — reload and stop are queued behind the hang, one "unresponsive" report arrives after three seconds, the "responsive" report is unreliable — and the rule by which Detour replaces the process for a load or a Stop it never answers.
tags: [webkit, hang, navigation, loading]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-29T04:30:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-176
    resource: backlog:TASK-176
    title: Reload on a tab whose web process is unresponsive does nothing; terminate the process and reload
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
  - id: spike
    resource: ../../docs/harness/task176-unresponsive-web-process-spike.swift
    title: Standalone WKWebView spike (blocked page, reload, kill)
  - id: rule
    resource: ../../Detour/Browser/UnresponsiveLoadRecovery.swift
    title: UnresponsiveLoadRecovery.swift
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (issue, applyLoadRecovery, terminateUnresponsiveProcess)
  - id: tests
    resource: ../../DetourTests/UnresponsiveLoadRecoveryTests.swift
    title: UnresponsiveLoadRecoveryTests.swift
  - id: runtime
    resource: ../../docs/task-175/runtime-check-reload.log
    title: Runtime check of Reload on a blocked page through the window
  - id: aux-proxy
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/AuxiliaryProcessProxy.cpp
    title: WebKit AuxiliaryProcessProxy.cpp (startResponsivenessTimer)
  - id: page-proxy
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp
    title: WebKit WebPageProxy.cpp (the responsiveness timer is stopped when the view is hidden)
  - id: task-227
    resource: backlog:TASK-227
    title: YouTube tabs come back from a relaunch titled with their URL
---

`WKWebView.reload()`, `load(_:)` and `stopLoading()` only queue a message to
the page's web process. When that process's main thread is blocked — a
script that never yields, or a synchronous call that never returns
([abandoned GPU process](./abandoned-gpu-process.md)) — nothing a client
does through the public API reaches the page, and WebKit does not recover
by itself.

# Behavior

Measured with [the spike](../../docs/harness/task176-unresponsive-web-process-spike.swift)
on macOS 26.7 (WebKit 21624.5), with the web view in a window and in none;
both gave the same results.[^spike]

| Step | What the client sees |
|---|---|
| `reload()` on a blocked page | `isLoading` becomes true at once and `estimatedProgress` 0.1 at once. Neither says the load started. No `didStartProvisionalNavigation` |
| 3.00 s later | `_webViewWebProcessDidBecomeUnresponsive:` (`WKNavigationDelegatePrivate`); `_webProcessIsResponsive` reads false |
| After that | Nothing. `isLoading` stays true for as long as the process is blocked |
| `stopLoading()` | Queued behind the hang as well. `isLoading` stays true |
| `_killWebContentProcessAndResetState` | Calls `webViewWebContentProcessDidTerminate` **before it returns**. Inside that callback `isLoading` is still true and `url` still set; once the call returns `isLoading` is false, `url` is nil and the process identifier 0 |
| `reload()` after the kill | Launches a new process and loads the page (the back/forward list survives the reset); finished 80 ms later in the spike |

Any exit of the web process — this kill, a crash, a `SIGKILL` from the
system or a test — ends in `WebPageProxy::resetStateAfterProcessExited`,
which calls `PageLoadState::reset`: `url` becomes nil **and `title` the empty
string**. An unclaimed tab's page stays like that until a window claims it.
`BrowserTab` keeps its own `url` and, since TASK-227, its title through
this; see [BrowserTab](../architecture/browser-tab.md#url-and-title-rules).
In the test host on macOS 26, `_killWebContentProcess` (without
`AndResetState`) left the process of a web view in no window running and
changed nothing; `TabTitleRetentionTests` sends `SIGKILL` to
`_webProcessIdentifier` instead.[^task-227]

Three more facts, from the incident behind TASK-175 and WebKit's
source:[^task-175]

- **The responsiveness timer only runs when the client asks for
  something.** A load request or an input event starts it. A blocked page
  nobody touches is never reported.
- **The "responsive" report is not evidence.** WebKit stops the timer when
  the view is hidden, because a hidden page may not answer a repaint
  request,[^page-proxy] and that sends
  `_webViewWebProcessDidBecomeResponsive:` with the process as blocked as
  before. Seen twice in the incident, each time at the exact moment the
  view's visibility changed.
- **A process that is still launching is not timed.** The check is
  deferred until the launch finishes,[^aux-proxy] so a slow launch is not
  reported; a slow *first load* after it can be.

# Why it matters here

Before TASK-176 a blocked page left the user with a stale frame, then a
white pane and a Stop button that did nothing; the only way out was closing
the tab or quitting.[^task-176] Reload is what people try first, and it was
exactly the thing that could not work.

The machine this was found on runs at a load average of 40 to 60, where a
healthy process can miss a three-second deadline. WebKit's own three-second
verdicts on its GPU process misfired five times in a day there. A rule that
replaced a process on the report alone would make slow loads slower.

# Workaround

`UnresponsiveLoadRecovery` is a pure reducer; `BrowserTab` feeds it and
carries out its one effect that matters, "terminate the process, then issue
this load".[^task-176]

| Event | Source |
|---|---|
| `requested(.reload)` / `requested(.url)` | `BrowserTab.reload()` and `load(_:)`, just before the web view is asked |
| `answered` | `didStartProvisionalNavigation` from either navigation delegate; a main-frame navigation policy request (`decidePolicyFor`), which a blocked process cannot send; and `isLoading` turning false (finished, failed, stopped) |
| `stopped` | `BrowserTab.stopLoading()`, which the sidebar's Stop calls, when the web view is loading |
| `becameUnresponsive`, `becameResponsive` | the two private delegate callbacks, implemented by the window and by the tab for an unclaimed web view |
| `waitingOnUser` | the window is about to show a script dialog (`alert`, `confirm`, `prompt`) for the tab |
| `patienceElapsed` | `BrowserTab.unresponsiveLoadPatience` (5 s) after a wait was started |
| `reset` | the process died by itself, or the web view was released |

The process is replaced in two cases:

1. A load or a Stop has not been answered `patience` after WebKit reported
   the process unresponsive: about 8 s after the click.
2. A load is requested while the process is already reported unresponsive:
   at once.

What is issued in the new process is the load that was asked for. After an
unanswered Stop it is a reload of the page the tab was on: the user wanted
out of a load that could not be stopped, and the alternative is a web view
that stays "loading" behind a Stop button that does nothing, which is where
the incident ended up.[^task-176]

The process is left alone when it answers (a Stop on a healthy page ends
the load and nothing more happens), and when nobody asked anything of it: a
page busy with its own script is not Detour's to kill.

Rules that follow from the behaviour above:

- A "responsive" report is ignored while a request is unanswered. A
  process that really recovered answers the request, and that clears it.
- A repeated unresponsive report does not start the patience over; WebKit
  sends one after each false "responsive".
- A process already reported unresponsive gets no second report, so a Stop
  that arrives then starts the wait itself.
- **A script dialog is not a hang.** While `alert()` is up the page's
  process answers nothing, for as long as the user takes. The window tells
  the tab (`scriptDialogDidBegin` / `scriptDialogDidEnd`): reports that
  arrive meanwhile are dropped and a wait in flight is cancelled. The
  request itself stays owed and is answered once the dialog is gone. The
  count is kept per web process, not per tab: a window a page opened
  shares its opener's process, and a dialog in one blocks both.
- **The policy request is what answers a load that starts nothing.** A
  jump within the document, a link handed to another app and a download
  begin no provisional load, and when an earlier load is still in flight
  `isLoading` does not turn false either. Without the policy request such
  a request stayed "unanswered", and the next time the page was merely
  busy for eight seconds it was replayed in a new process.
- A request is only tracked while something can answer it: not without a
  web view, not when the web view did not start loading (a reload with
  nothing to reload), and a Stop only while the web view is loading.
  Otherwise it would sit there until some unrelated busy spell.
- The load issued in the new process is not tracked as a request. One
  termination per request; a page that blocks again on every load cannot
  loop.
- The tab issues the load **after** the kill returns, and
  `isTerminatingUnresponsiveProcess` is true only during the kill. The
  window's `webViewWebContentProcessDidTerminate` runs inside it and must
  neither reload nor count a crash (`noteProcessTermination`). The kill
  also turns `isLoading` false, which would end the tab's
  `navigationPending`; for a URL load it is restored, so a redirect on the
  way does not become the retry target.
- The tab does **not** implement `webViewWebContentProcessDidTerminate`
  for an unclaimed web view. Implementing it switches off WebKit's own
  reload-when-next-visible for a crashed background page; `isLoading`
  turning false already clears the rule's state.
- An unresponsive report also triggers the abandoned-GPU-process sweep,
  which can unfreeze the page without replacing anything.

# Checked in the running app

A Debug build with [the harness](../../docs/harness/task175-176-harness.patch):
a selected tab whose page blocks its main thread two seconds after each
load, then `reloadPage` (the action of the Reload button and
Cmd+R).[^runtime]

| Time | Event |
|---|---|
| 17:20:31.492 | `WebPageProxy::reload:`; the sidebar button turns to Stop |
| 17:20:34.494 | `WebProcessProxy::didBecomeUnresponsive:` |
| 17:20:39.742 | `Terminating an unresponsive web process to start the load it never read`; WebKit logs `processDidTerminate … reason=RequestedByClient` |
| 17:20:39.744 | `WebPageProxy::reload:` again, issued by the tab |
| 17:20:39.8 | the page is loaded in a new web process, once; the pane stayed in the window |

Stop and the script dialog were not driven in the running app; they are
covered by the tests below.

# Tests

- `UnresponsiveLoadRecoveryRuleTests`: each case of the rule, including the
  false "responsive" report, a stale patience wait, the three Stop cases
  and the script dialog.
- `UnresponsiveLoadRecoveryTests`: a real web process whose page spins its
  main thread; `reload()` ends with the page loaded once more in a
  different process, and so does `reload()` followed by `stopLoading()`;
  stopping a load on a healthy page, a reload while a script dialog is up,
  and a busy spell after a jump within the page each keep the process. The
  waits for a first page load are 60 s: in a full run the suites before
  this one leave about fifty web processes still launching, and ten
  seconds ran out on a busy machine. The fixture blocks
  the page from a timer
  (`setTimeout(() => { while (…) {} }, 0)`) so the `evaluateJavaScript`
  call that installs it returns first.[^tests]

# Open questions

- Nothing tells the user that a page has stopped responding when they have
  not asked for a load (TASK-177).
- `goBack()`, `goForward()` and loads issued by web content are not
  tracked; only `reload()`, `load(_:)` and Stop are. An extension's
  `tabs.reload` and `tabs.update` call the web view directly
  (`WKExtensionTabConformance`) and are not tracked either.
- A script paused in the Web Inspector blocks the process like a dialog
  does, and nothing tells the tab. Reload during a pause is expected to
  replace the process after the patience; not tried.
- Dialogs other than the three script dialogs (a `beforeunload`
  confirmation, a file chooser) were not checked for whether they hold the
  web process's main thread.
- Peek reloads call the Peek web view directly and are not tracked.
- The patience of 5 s is a judgement, not a measurement.

# Related

- [Abandoned GPU process](./abandoned-gpu-process.md) — the hang that led here, and its in-place cure.
- [BrowserTab](../architecture/browser-tab.md) — where the events are raised.
- [Error pages](../features/error-pages.md) — the crash-reload cap this must not trip.
- [WKWebView delegate order](./wkwebview-delegate-order.md) — the same spike technique for other callbacks.
- [Hidden web view load stalls](./hidden-webview-load-stalls.md) — a load that is slow, not blocked.

[^task-176]: Reload on a tab whose web process is unresponsive does nothing; terminate the process and reload
[^task-175]: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
[^spike]: Standalone WKWebView spike (blocked page, reload, kill)
[^tests]: UnresponsiveLoadRecoveryTests.swift
[^aux-proxy]: WebKit AuxiliaryProcessProxy.cpp (startResponsivenessTimer)
[^page-proxy]: WebKit WebPageProxy.cpp (the responsiveness timer is stopped when the view is hidden)
[^runtime]: Runtime check of Reload on a blocked page through the window
[^task-227]: YouTube tabs come back from a relaunch titled with their URL
