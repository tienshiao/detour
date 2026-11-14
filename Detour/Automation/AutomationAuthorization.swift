import Foundation

/// Who may talk to the automation endpoint (TASK-228.1, AC #14). Pure: the
/// endpoint asks it about every request before reading the body.
///
/// Listening on loopback alone is not enough. Any local process can reach a
/// loopback port, and so can a web page: a page cannot read the response
/// across origins, but a POST still arrives, and DNS rebinding (a hostile
/// name that resolves to 127.0.0.1) lets it read too. So, in this order:
/// 1. `Host` must name the loopback address on our port. A rebound name
///    arrives with the hostile host name and stops here.
/// 2. `Origin`, when present, must be a loopback origin. Browsers send it on
///    every cross-origin POST; MCP clients outside a browser send none.
/// 3. `Authorization: Bearer <token>` must carry the endpoint's token. That
///    stops local programs that cannot read the user's files (sandboxed apps,
///    other accounts). Malware running as the user can read the token file
///    and is out of scope: it could drive the browser in other ways anyway.
///
/// A refused token gets a bare 401 with `WWW-Authenticate: Bearer` and no
/// OAuth `resource_metadata`, so a client that only does OAuth fails at once
/// instead of starting a discovery flow Detour does not offer.
nonisolated enum AutomationAuthorization {

    enum Decision: Equatable, Sendable {
        case allowed
        /// The request is refused with this status and plain-text reason.
        case refused(status: Int, reason: String)
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    static func decide(headers: [String: String], token: String, port: UInt16) -> Decision {
        guard let host = headers["host"], isLoopbackHost(host, port: port) else {
            return .refused(status: 403, reason: "Host must be 127.0.0.1:\(port)")
        }
        if let origin = headers["origin"], !isLoopbackOrigin(origin) {
            return .refused(status: 403, reason: "Requests from web pages are not accepted")
        }
        guard let authorization = headers["authorization"],
              let presented = bearerToken(authorization),
              constantTimeEqual(presented, token) else {
            return .refused(status: 401, reason: "Missing or wrong bearer token")
        }
        return .allowed
    }

    /// `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>`. The port is
    /// required: HTTP clients always send it for a non-default port.
    static func isLoopbackHost(_ host: String, port: UInt16) -> Bool {
        let lowered = host.lowercased()
        guard let colon = lowered.lastIndex(of: ":"), lowered[colon...] == ":\(port)" else { return false }
        return loopbackHosts.contains(String(lowered[..<colon]))
    }

    /// An `http://` origin on a loopback host (any port). An opaque origin
    /// (`null`, from a sandboxed iframe or a `file:` page) is refused.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// The token of a `Bearer <token>` header value (scheme case-insensitive).
    static func bearerToken(_ value: String) -> String? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Compares without returning early at the first differing byte, so the
    /// time taken says nothing about how much of a guess was right.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0 && a.count == b.count
    }

    /// The 401 a refused token gets (see the type's comment).
    static let unauthorizedHeaders: [(String, String)] = [("WWW-Authenticate", "Bearer realm=\"Detour\"")]
}
