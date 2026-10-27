import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "link-routing")

// Link Routes for typed URLs and links clicked in a page (TASK-191.4).
// The window's WebKit delegates and the command palette describe what
// happened; the pure `linkRoutingEligibility` / `typedURLIsRoutable` decide
// whether it is routed, `resolveLinkRoute` where, and `AppDelegate.openLink`
// (the pure `linkPlacement`) in which window — exactly as for a link from
// another app.

extension BrowserWindowController {

    /// How `navigationAction` reached `decidePolicyFor`, for the routing rule.
    static func linkRoutingEntry(for navigationAction: WKNavigationAction) -> InPageLinkEntry {
        .navigationAction(isLinkActivation: navigationAction.navigationType == .linkActivated,
                          targetsMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                          opensNewWindow: navigationAction.targetFrame == nil,
                          isRedirect: isRedirect(navigationAction))
    }

    /// The routing rule's view of a link to `url` leaving `webView`'s page.
    func inPageLinkRequest(for navigationAction: WKNavigationAction, to url: URL, in webView: WKWebView,
                           entry: InPageLinkEntry) -> InPageLinkRequest {
        InPageLinkRequest(entry: entry,
                                 modifiers: Self.linkClickModifiers(navigationAction.modifierFlags),
                                 isUserGesture: Self.isUserGesture(navigationAction),
                                 isInPeek: isPeekWebView(webView),
                                 pageURL: webView.url,
                                 targetURL: url,
                                 quickDetourClickEnabled: QuickDetourSettings.shared.isOptionCommandClickEnabled)
    }

    /// Opt-Cmd-click on a link (TASK-193.5): a new Quick Detour on the profile
    /// of the page that fired it (a Peek's and a favourite's tab are the
    /// window's space's), one main-queue turn later so the policy decision
    /// returns first. Its Open in names this window's space when it is the
    /// same profile's.
    func openQuickDetour(_ url: URL, firing webView: WKWebView) {
        guard let profile = tab(owning: webView)?.owningProfile ?? activeSpace?.profile else { return }
        let sourceSpace = activeSpace
        log.info("Opt-Cmd-click: Quick Detour")
        DispatchQueue.main.async {
            QuickDetourWindowController.open(profile: profile, sourceSpace: sourceSpace, url: url)
        }
    }

    /// Where a link leaving a page in this window is routed; nil when it is
    /// not routed, or its route keeps it here, so the caller carries on as
    /// before routes.
    func routedDecision(for request: InPageLinkRequest) -> LinkRouteDecision? {
        guard let spaceID = activeSpaceID else { return nil }
        let eligibility = linkRoutingEligibility(request)
        let decision = routedLinkDecision(eligibility) {
            resolveRoute(request.targetURL, from: .clicked(inSpace: spaceID, isPrivateWindow: isIncognito))
        }
        if let decision {
            log.info("Link routed (\(String(describing: eligibility), privacy: .public)): \(String(describing: decision), privacy: .public)")
        }
        return decision
    }

    /// Where a URL typed in this window's command palette is routed; nil when
    /// it stays here (`typedURLIsRoutable` has already said it may route).
    func routedTypedDecision(for url: URL) -> LinkRouteDecision? {
        guard let spaceID = activeSpaceID else { return nil }
        let decision = resolveRoute(url, from: .typed(fromSpace: spaceID, isPrivateWindow: isIncognito))
        guard decision != .stay else { return nil }
        log.info("Typed URL routed: \(String(describing: decision), privacy: .public)")
        return decision
    }

    private func resolveRoute(_ url: URL, from origin: LinkOrigin) -> LinkRouteDecision {
        resolveLinkRoute(url: url, origin: origin,
                         routes: store.linkRoutes.routes,
                         defaultTarget: store.linkRoutes.defaultTarget,
                         context: store.linkRouteContext)
    }

    /// Acts on `inPageLinkOutcome` for a link to `url` fired by `webView`:
    /// opens it where its route sends it, or in a Peek on `peekHost`. True when
    /// it did either, so the caller refuses the page's own navigation or window.
    func performInPageLinkOutcome(for url: URL, routed: LinkRouteDecision?, peekHost: BrowserTab?,
                                  firing webView: WKWebView) -> Bool {
        switch inPageLinkOutcome(routed: routed, anchorPeeks: peekHost != nil) {
        case .route(let decision):
            openRoutedLink(url, decision)
            return true
        case .peek:
            guard let peekHost else { return false }
            presentPeek(of: url, on: peekHost, firing: webView)
            return true
        case .asBefore:
            return false
        }
    }

    /// Opens a clicked link where its route sends it, one main-queue turn
    /// later, so the policy decision (or `createWebViewWith`) returns before
    /// windows switch spaces or come forward. The page's tab is left alone.
    func openRoutedLink(_ url: URL, _ decision: LinkRouteDecision) {
        DispatchQueue.main.async {
            (NSApp.delegate as? AppDelegate)?.openLink(url, routedTo: decision)
        }
    }

    /// A Peek's page, or anything while a Peek is presented (the overlay is
    /// modal, so a click can only be in the Peek).
    private func isPeekWebView(_ webView: WKWebView) -> Bool {
        if peekOverlayView != nil { return true }
        guard let tab = tab(owning: webView) else { return false }
        return store.tab(hostingPeek: tab) != nil
    }

    static func linkClickModifiers(_ flags: NSEvent.ModifierFlags) -> LinkClickModifiers {
        var modifiers: LinkClickModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    /// WebKit's user-gesture signal, `_isUserInitiated` (SPI, read by key
    /// behind a `responds(to:)` guard). Measured 2026-10-25: true for a real
    /// click and for a click handler's own script, false for a page's timer
    /// or load script (and for a client redirect); true as well for anything
    /// the app runs with `evaluateJavaScript`. Without the SPI every action
    /// counts as a gesture, so routing keeps working and the other exclusions
    /// still hold.
    static func isUserGesture(_ navigationAction: WKNavigationAction) -> Bool {
        let key = "_isUserInitiated"
        guard navigationAction.responds(to: NSSelectorFromString(key)) else { return true }
        return (navigationAction.value(forKey: key) as? Bool) ?? true
    }

    /// WebKit asks the policy again for a server redirect, with the link
    /// activation and user gesture of the click it interrupts; only
    /// `_isRedirect` (SPI) tells it apart. Without the SPI nothing counts as
    /// a redirect.
    private static func isRedirect(_ navigationAction: WKNavigationAction) -> Bool {
        let key = "_isRedirect"
        guard navigationAction.responds(to: NSSelectorFromString(key)) else { return false }
        return (navigationAction.value(forKey: key) as? Bool) ?? false
    }
}
