# Investigations

* [Abandoned GPU process](abandoned-gpu-process.md) - A GPU process that WebKit "terminated" while its main thread was blocked stays alive, and every web process still connected to it freezes for good on its next synchronous call to it; how it was diagnosed in a running app and the reaper that kills such processes.
* [GPU process IOSurface limit](gpu-iosurface-limit.md) - After days of uptime WebKit's GPU process reaches the kernel's 16,384-IOSurface limit, WebGL and canvas die in every page and YouTube stops playing; how it was diagnosed, the show-budget sleep rule and the GPU process recycler that contain it.
* [Hidden web view load stalls](hidden-webview-load-stalls.md) - Why a tab opened in the background can sit part-loaded until it is shown — WebKit drops a hidden page's web process to background priority about a second after commit — and what Detour does about it.

# Platform quirks

* [AppKit gotchas](appkit-gotchas.md) - A collection of AppKit behaviours that cost debugging time in Detour — first responder and key-view loop, split and stack view layout, hit testing, table views under a drag session, popovers — each with where it bit and what to do instead.
* [Driving the Web Inspector](web-inspector-control.md) - How Detour opens, switches and closes the docked Web Inspector from the dev toolbar with no public API — the private _WKInspector calls and the frontend's own WI functions that work on macOS 26.7, what was rejected, the guards that hide a button when WebKit drops a call, and the inspector preferences WebKit writes to the app's shared defaults. *(draft)*
* [Media and picture-in-picture](media-and-pip.md) - WebKit media behaviour Detour has to accommodate — picture-in-picture needs the video's view on screen to start and to return, a standalone video URL ends its navigation with error 204, and audio and capture state gate sleeping and GPU process recycling.
* [Service worker unload rules](service-worker-unload-rules.md) - WebKit's rules for unloading an extension's background — the 30-second timer, the 2-minute inactive-ports rule and what counts as activity — plus the ways a worker dies without its page closing and the native ports WebKit drops without telling anyone.
* [Unresponsive web process](unresponsive-web-process.md) - What WebKit does and does not do when a page's web process stops reading its messages — reload and stop are queued behind the hang, one "unresponsive" report arrives after three seconds, the "responsive" report is unreliable — and the rule by which Detour replaces the process for a load or a Stop it never answers.
* [WebKit test host traps](webkit-test-host-traps.md) - WebKit and macOS behaviours that crash the DetourTests host, make it eat memory, or let a test run write into the installed app's data — and the guard the project has for each.
* [WKWebView delegate call order](wkwebview-delegate-order.md) - Which WKNavigationDelegate and WKUIDelegate methods WebKit calls, and in what order, for target=_blank links, window.open, custom-scheme links, failed and superseded loads, and custom-scheme internal pages — verified with a standalone spike.

# References

* [WebKit source lookup](webkit-source-lookup.md) - How to read the WebKit source that explains a behaviour seen in Detour — fetching files and older revisions from GitHub, which files answered which questions, and how far a source reading can be trusted.
