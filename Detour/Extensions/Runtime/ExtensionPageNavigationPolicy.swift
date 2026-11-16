import Foundation
import WebKit

/// Decides whether a main-frame navigation to a page of the extension a tab's
/// web view serves may proceed. Pure, so both navigation delegates
/// (`BrowserWindowController` for a claimed web view, `BrowserTab` for one no
/// window has claimed) share one tested rule, as `InternalPageNavigationPolicy`
/// does for `detour://` pages (TASK-382).
///
/// A web view built from an extension context's configuration
/// (`BrowserTab.servedExtensionOriginHost`) can show every page of that
/// extension in its main frame, web-accessible or not: WebKit's scheme handler
/// serves a main-frame load whenever the configuration is the extension's own
/// (TASK-352). WebKit also keeps the main frame on the extension: it ignores a
/// main-frame navigation off it, after the delegate allowed it
/// (`isUnsupportedWebExtensionNavigation` in `NavigationState.mm`), so no web
/// page is ever such a tab's main frame. Web content can still live in its
/// subframes, which the extension's page may embed, and a subframe can send the
/// top frame anywhere, without a user gesture. Measured: a loopback frame's
/// `top.location = <extension>/other.html` loaded that non-web-accessible page
/// into the tab, running with the extension's privileges.
///
/// So the requesting frame decides. A navigation action names it
/// (`sourceFrame`); an app-initiated load reports the main frame and the
/// document it holds, or no frame at all.
enum ExtensionPageNavigationPolicy {
    /// The frame that asked for a navigation.
    struct Requester: Equatable {
        var isMainFrame: Bool
        /// The frame's security origin, as `WKSecurityOrigin` reports it: an
        /// empty protocol for the initial `about:blank` document (and an opaque
        /// origin).
        var originProtocol: String
        var originHost: String
    }

    /// - Parameters:
    ///   - targetsMainFrame: `navigationAction.targetFrame?.isMainFrame == true`.
    ///     A subframe load is the scheme handler's business (it serves a
    ///     subframe only web-accessible pages, or pages for a frame of the
    ///     extension's own), and a new window gets no extension configuration
    ///     (`createWebViewWith`).
    ///   - servedOriginHost: the tab's `servedExtensionOriginHost`. Nil, or
    ///     another extension's page: WebKit refuses the load itself, and the
    ///     error page names it (TASK-372).
    ///   - requester: `requester(of:)`; nil when the action names no frame,
    ///     which only an app-initiated load does.
    static func allows(_ url: URL?, targetsMainFrame: Bool, servedOriginHost: String?,
                       requester: Requester?) -> Bool {
        guard targetsMainFrame, let url, let served = servedOriginHost,
              isExtensionPage(url, ofOriginHost: served) else { return true }
        guard let requester else { return true }
        // The extension's own page, in any frame of the tab: its links, its
        // scripts, Back from it, and an app load (`tabs.update`, Reload) while
        // it is on screen.
        if requester.originProtocol.caseInsensitiveCompare(ExtensionPageURL.scheme) == .orderedSame,
           requester.originHost.caseInsensitiveCompare(served) == .orderedSame {
            return true
        }
        // Detour's own documents in the main frame: the initial `about:blank`
        // of the web view `wake` or `addExtensionTab` builds and loads, and the
        // error page a Reload leaves from. No page script chose those loads.
        // A main frame holding anything else would be a web page, which
        // WebKit's gate keeps out today; it gets no pass should that change.
        guard requester.isMainFrame else { return false }
        return requester.originProtocol.isEmpty
            || requester.originProtocol.caseInsensitiveCompare(ErrorPage.scheme) == .orderedSame
    }

    /// The frame `action` names as asking for it (`requestingFrame`).
    static func requester(of action: WKNavigationAction) -> Requester? {
        guard let frame = action.requestingFrame else { return nil }
        let origin = frame.securityOrigin
        return Requester(isMainFrame: frame.isMainFrame, originProtocol: origin.protocol, originHost: origin.host)
    }
}

extension WKNavigationAction {
    /// `sourceFrame`, read through KVC because it is imported as non-optional
    /// yet is nil for a navigation the app itself started (`load(_:)`), and a
    /// nil read through the typed accessor is undefined behaviour.
    var requestingFrame: WKFrameInfo? {
        value(forKey: "sourceFrame") as? WKFrameInfo
    }
}
