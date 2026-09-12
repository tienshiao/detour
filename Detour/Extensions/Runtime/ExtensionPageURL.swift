import Foundation

/// The scheme WebKit serves extension pages from. WebKit gives every loaded
/// `WKWebExtensionContext` a *fresh* `webkit-extension://<UUID>/` base URL — the
/// host is not the extension's id and is not stable across loads — so an
/// extension page's origin identifies one **context**, not one extension. When a
/// context is unloaded and reloaded mid-session, every page still open on the old
/// origin is orphaned: its native `chrome.*` bindings died with the old context
/// and the polyfill bridge no longer recognises the origin.
enum ExtensionPageURL {
    static let scheme = "webkit-extension"
}

/// Whether `url` is an extension page served from `host`, i.e. the host of some
/// context's `baseURL`.
///
/// The host comparison is case-insensitive: WebKit's base URL host is a
/// lowercase UUID, but a URL that has been round-tripped through persistence or
/// written by a page's own link can carry any case, and an origin check that
/// misses would leave a page behind on a dead origin.
func isExtensionPage(_ url: URL, ofOriginHost host: String) -> Bool {
    guard !host.isEmpty,
          url.scheme?.caseInsensitiveCompare(ExtensionPageURL.scheme) == .orderedSame,
          let urlHost = url.host, !urlHost.isEmpty
    else { return false }
    return urlHost.caseInsensitiveCompare(host) == .orderedSame
}

/// Rewrites an extension page URL from one context base URL onto another, keeping
/// the path, query and fragment so the user lands back on the page they were on.
///
/// Returns nil — leave the URL alone — unless the URL's scheme and host both
/// match `oldBase`'s: an ordinary web page, or another extension's page, has
/// nothing to do with this context's reload.
///
/// Path, query and fragment are carried over in their already-encoded form so a
/// percent-escape in the original cannot be decoded here and re-encoded
/// differently (an extension page's query often carries a URL of its own).
func rewriteExtensionPageURL(_ url: URL, from oldBase: URL, to newBase: URL) -> URL? {
    guard let oldHost = oldBase.host, isExtensionPage(url, ofOriginHost: oldHost),
          var components = URLComponents(url: newBase, resolvingAgainstBaseURL: false),
          let source = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }

    // A host-only URL ("webkit-extension://<uuid>") has an empty path, which
    // URLComponents rejects alongside a host.
    components.percentEncodedPath = source.percentEncodedPath.isEmpty ? "/" : source.percentEncodedPath
    components.percentEncodedQuery = source.percentEncodedQuery
    components.percentEncodedFragment = source.percentEncodedFragment
    return components.url
}
