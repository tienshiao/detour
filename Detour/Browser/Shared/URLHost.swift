import Foundation

// URL hosts as they are written in a URL (TASK-198).
//
// Foundation's `URL.host` strips the brackets from an IPv6 literal:
// `http://[::1]:3000/` has host `::1`. Interpolated back into a URL string it
// gives `http://::1/…`, which `URL(string:)` rejects — the force unwrap of the
// optimistic favicon URL crashed Detour on every IPv6 page. `URLComponents.host`
// and `WKSecurityOrigin.host` keep the brackets (`[::1]`), so a host read one
// way never equals a host read the other. Rebuild URLs with `URLComponents`;
// compare hosts through `authorityHost`.

extension URL {
    /// `host` as it appears in the URL's authority: an IPv6 literal keeps its
    /// brackets (`[::1]`), as `WKSecurityOrigin.host` and `URLComponents.host`
    /// report it. Any other host is `host` unchanged (punycode for an IDN, like
    /// the URL strings WebKit and history store). Nil when `host` is nil or empty.
    var authorityHost: String? {
        guard let host, !host.isEmpty else { return nil }
        // Only an IPv6 literal has a colon in its host; a port is not part of `host`.
        return host.contains(":") ? "[\(host)]" : host
    }

    /// `port` unless it is the scheme's default (80 for http, 443 for https),
    /// which WebKit leaves out of the URLs it reports: `http://localhost:80/`
    /// and `http://localhost/` are the same origin. Nil when there is no port.
    var nonDefaultPort: Int? {
        guard let port else { return nil }
        let defaultPort: Int? = switch scheme?.lowercased() {
        case "http", "ws": 80
        case "https", "wss": 443
        default: nil
        }
        return port == defaultPort ? nil : port
    }
}

/// The `/favicon.ico` a page's origin would serve: the page URL's scheme,
/// host and port with the path replaced and the query, fragment and
/// credentials dropped. The port is kept — a favicon belongs to the origin,
/// and the server on `localhost:3000` is not the one on `localhost:80`. Nil
/// when the URL has no scheme or no host (`about:blank`, `file:`, `data:`).
func faviconFallbackURL(for pageURL: URL) -> URL? {
    guard pageURL.scheme != nil, pageURL.authorityHost != nil,
          var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
    // Copied from the page's own components, so the host stays exactly as the
    // page URL encodes it (brackets, an IPv6 zone's `%25`, punycode).
    components.user = nil
    components.password = nil
    components.percentEncodedPath = "/favicon.ico"
    components.percentEncodedQuery = nil
    components.percentEncodedFragment = nil
    return components.url
}

/// What `BrowserTab` compares to decide a navigation reached another site's
/// favicon: the lowercased `authorityHost` plus the port when it is not the
/// scheme's default — the same origin `faviconFallbackURL` fetches from, so
/// moving from one local dev server to another on the same host fetches the
/// new server's icon. Nil when the URL has no host.
func faviconSiteKey(for url: URL?) -> String? {
    guard let url, let host = url.authorityHost?.lowercased() else { return nil }
    return url.nonDefaultPort.map { "\(host):\($0)" } ?? host
}

/// Whether `originHost`, a `WKSecurityOrigin.host` (an IPv6 literal in
/// brackets), names the host of `url`, without case.
func securityOriginHost(_ originHost: String, isHostOf url: URL) -> Bool {
    url.authorityHost?.caseInsensitiveCompare(originHost) == .orderedSame
}
