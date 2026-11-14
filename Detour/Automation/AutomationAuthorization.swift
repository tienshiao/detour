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
///
/// Which tokens count depends on how the endpoint was turned on
/// (TASK-228.5): a test run takes its one shared token (`mcp-token`); the
/// user's setting takes only the tokens of clients the user approved, and
/// the shared token is never accepted there. With the user's setting, the
/// one route that needs no token is `POST /mcp/authorize`, where a client
/// asks for one (Detour shows the user its Allow / Deny prompt); it is
/// reached only after the Host and Origin checks.
nonisolated enum AutomationAuthorization {

    enum Decision: Equatable, Sendable {
        /// The test run's shared token.
        case allowed
        /// An approved client's token (the user's setting).
        case allowedClient(AutomationClientIdentity)
        /// `/mcp/authorize` with the user's setting: a client asks for a
        /// token. The route checks the method and the body itself.
        case authorizationRequest
        /// The request is refused with this status and plain-text reason.
        case refused(status: Int, reason: String)
    }

    /// What a request's bearer token is checked against.
    enum Credentials: Sendable {
        /// A test run: the one shared token.
        case shared(token: String)
        /// The user's setting: the approved clients' tokens.
        case perClient(AutomationClientStore)
    }

    /// Where a client asks for a token of its own (the user's setting only).
    static let authorizePath = "/mcp/authorize"

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    static func decide(headers: [String: String], token: String, port: UInt16) -> Decision {
        decide(path: "/mcp", headers: headers, credentials: .shared(token: token), port: port)
    }

    static func decide(path: String, headers: [String: String], credentials: Credentials, port: UInt16) -> Decision {
        guard let host = headers["host"], isLoopbackHost(host, port: port) else {
            return .refused(status: 403, reason: "Host must be 127.0.0.1:\(port)")
        }
        if let origin = headers["origin"], !isLoopbackOrigin(origin) {
            return .refused(status: 403, reason: "Requests from web pages are not accepted")
        }
        let presented = headers["authorization"].flatMap(bearerToken)
        switch credentials {
        case .shared(let token):
            guard let presented, constantTimeEqual(presented, token) else {
                return .refused(status: 401, reason: "Missing or wrong bearer token")
            }
            return .allowed
        case .perClient(let store):
            // Exactly this path: any other spelling needs a token like the rest.
            if path == authorizePath { return .authorizationRequest }
            guard let presented, let client = store.client(presenting: presented) else {
                return .refused(status: 401, reason: "Missing, wrong or revoked bearer token")
            }
            return .allowedClient(AutomationClientIdentity(id: client.clientID, name: client.displayName))
        }
    }

    /// Why an authorize request is refused on its head alone, before its
    /// body is read: it must be a POST of JSON with a Content-Length of at
    /// most `AutomationApprovalRequest.maximumBodySize` (no chunked body).
    static func authorizationHeadRefusal(_ head: AutomationHTTP.Request) -> (status: Int, reason: String)? {
        guard head.method == "POST" else { return (405, "Use POST to ask for a token") }
        guard head.header("content-type")?.lowercased().contains("application/json") == true else {
            return (415, "Content-Type must be application/json")
        }
        guard head.header("transfer-encoding") == nil, let lengthValue = head.header("content-length"),
              let length = Int(lengthValue), length >= 0 else {
            return (411, "An authorize request needs a Content-Length")
        }
        guard length <= AutomationApprovalRequest.maximumBodySize else {
            return (413, "An authorize request is at most \(AutomationApprovalRequest.maximumBodySize) bytes")
        }
        return nil
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
