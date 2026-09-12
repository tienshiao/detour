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

/// Whether `url` is served from the extension scheme at all, whichever context's
/// origin it names.
func isExtensionPageURL(_ url: URL?) -> Bool {
    guard let url, let host = url.host, !host.isEmpty else { return false }
    return url.scheme?.caseInsensitiveCompare(ExtensionPageURL.scheme) == .orderedSame
}

/// The base URL of the context origin `host` names (`webkit-extension://<host>/`),
/// e.g. to rewrite pages persisted on an origin that no longer exists.
func extensionOriginBaseURL(host: String) -> URL? {
    guard !host.isEmpty else { return nil }
    return URL(string: "\(ExtensionPageURL.scheme)://\(host)/")
}

// MARK: - Persisted extension pages (TASK-24)

/// What a persisted URL is, as far as restoring it goes.
///
/// A stored extension page URL names the origin of the context that served it
/// *in the launch that saved it*; WebKit mints a new one for every context load,
/// so the URL on its own is dead after a relaunch. The durable identity is the
/// extension id saved alongside it (the URL still carries the page's path, query
/// and fragment), and restore rewrites the page onto that extension's current
/// context once it is loaded.
enum PersistedExtensionPage: Equatable {
    /// An ordinary URL (or none): restore it as it always was.
    case notExtensionPage
    /// An extension page of an extension installed and enabled in the profile.
    /// `originHost` is the dead origin the page was saved on, lowercased — the
    /// key its pages are later rewritten from.
    case restorable(extensionID: String, originHost: String)
    /// An extension page of an extension that is installed but not enabled in
    /// the profile (globally off, or off for this profile). Nothing can show it
    /// now, but a later enable can: bookmark-like tiles (pinned entries,
    /// favourites) and closed-tab records keep it, while open tabs on it are
    /// dropped — what a mid-session disable does.
    case disabled(extensionID: String, originHost: String)
    /// An extension page that can never load again: its extension is not
    /// installed, or the row predates the saved id. Dropped at restore rather
    /// than restored as a blank tab.
    case unavailable
}

/// Classifies a persisted `url` and its saved `extensionID` against the installed
/// extensions (`AppDatabase.installedExtensionIDs`) and those enabled in the
/// profile it is restored into (`AppDatabase.enabledExtensionIDs`, the rule
/// `ExtensionManager` loads contexts by).
func classifyPersistedExtensionPage(
    url: URL?, extensionID: String?,
    installedExtensionIDs: Set<String>, enabledExtensionIDs: Set<String>
) -> PersistedExtensionPage {
    guard let url, isExtensionPageURL(url), let host = url.host else { return .notExtensionPage }
    guard let extensionID, !extensionID.isEmpty, installedExtensionIDs.contains(extensionID) else {
        return .unavailable
    }
    return enabledExtensionIDs.contains(extensionID)
        ? .restorable(extensionID: extensionID, originHost: host.lowercased())
        : .disabled(extensionID: extensionID, originHost: host.lowercased())
}

extension PersistedExtensionPage {
    /// The extension and dead origin of an installed extension's page — the
    /// pending origin to register when the page (or its tile) is kept.
    var pendingOrigin: (extensionID: String, originHost: String)? {
        switch self {
        case .restorable(let id, let host), .disabled(let id, let host): return (id, host)
        case .notExtensionPage, .unavailable: return nil
        }
    }
}
