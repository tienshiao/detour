import Foundation
import WebKit

/// The web views Detour itself creates or presents for extension content —
/// tabs, the action popup, offscreen documents (TASK-66).
///
/// It exists to tell an ordinary extension page apart from the extension's real
/// background context. `WKWebExtensionContext` exposes no background web view
/// (only `webViewConfiguration`, `isLoaded` and `loadBackgroundContent`), so the
/// discriminator has to be the inverse one: WebKit's background page runs in the
/// one web view a context has that Detour never creates and never presents.
/// Absence from this registry is therefore what identifies it, and presence
/// means "this is a page Detour is showing the user" however that page is
/// navigated — including a tab or popup navigated to the background document's
/// own path, which is exactly the hole a path-only check leaves open
/// (`ExtensionPolyfillHandler.senderIsBackgroundContext`).
///
/// Membership is a weak set, so a registered view is forgotten when it is
/// released; identity is the object, never a URL. Main-thread only: every
/// registration site (tab creation, popup presentation, offscreen load) and the
/// only reader (the polyfill message handler) already runs there.
enum ExtensionPageHostRegistry {
    private static let hosted = NSHashTable<WKWebView>.weakObjects()

    /// Record `webView` as one Detour hosts. Idempotent; safe to call on every
    /// assignment of a tab's web view.
    static func register(_ webView: WKWebView) {
        hosted.add(webView)
    }

    /// Whether Detour created or presented `webView`. False for a web view the
    /// host never touched — in an extension context, that is WebKit's own
    /// background page.
    static func isDetourHosted(_ webView: WKWebView) -> Bool {
        hosted.contains(webView)
    }
}
