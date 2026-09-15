import Foundation

/// Reads typed command-palette / address text as either a URL to open directly
/// or a search phrase (TASK-83).
///
/// Pure so the rule is unit-testable (`AddressInputClassifierTests`) and shared
/// by everything that has to agree on it: submitting the input and the palette's
/// "Go to" vs "Search" row label.
enum AddressInputClassifier {

    /// The URL `input` denotes, or nil when it should be searched for.
    ///
    /// - Explicit `http://` / `https://` input is taken as written.
    /// - Otherwise the host (everything before the first `/`, `?` or `#`, minus
    ///   any `user@`) decides: `localhost`, an IP literal, a dotted name, or any
    ///   non-numeric name carrying a valid explicit port is a URL. A dotless word
    ///   with no port (`swift`), a number with a colon (`10:30`), a colon not
    ///   followed by a port (`note:todo`) and anything containing whitespace
    ///   are searches.
    /// - Scheme: `https://` for a dotted name without a port (or with `:443`);
    ///   `http://` for localhost, IP literals and every other explicit port —
    ///   local and dev servers rarely serve TLS.
    static func directURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }

        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: text)
        }

        let authorityEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        var authority = text[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        guard let (host, port) = splitHostPort(authority),
              let kind = hostKind(host, hasPort: port != nil) else { return nil }

        let secure = port.map { $0 == 443 } ?? (kind == .domain)
        return URL(string: (secure ? "https://" : "http://") + text)
    }

    private enum HostKind {
        /// A dotted name such as `example.com`.
        case domain
        /// `localhost`, an IP literal, or a dotless name with an explicit port.
        case local
    }

    /// Splits `host[:port]` / `[ipv6][:port]`. Nil when the part after the
    /// colon is not a port in 1...65535, or an unbracketed host has more than
    /// one colon.
    private static func splitHostPort(_ authority: Substring) -> (host: Substring, port: Int?)? {
        let host: Substring
        let portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[...close]
            let rest = authority[authority.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":") else { return nil }
            portText = rest.isEmpty ? nil : rest.dropFirst()
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            portText = parts.count == 2 ? parts[1] : nil
        }
        guard let portText else { return (host, nil) }
        guard (1...5).contains(portText.count), portText.allSatisfy(\.isASCIIDigit),
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func hostKind(_ host: Substring, hasPort: Bool) -> HostKind? {
        guard !host.isEmpty else { return nil }
        let lowered = host.lowercased()
        if lowered.hasPrefix("[") {
            let inner = lowered.dropFirst().dropLast()
            let isIPv6 = inner.contains(":") && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
            return isIPv6 ? .local : nil
        }
        if lowered == "localhost" || lowered.hasSuffix(".localhost") || isIPv4Literal(lowered) {
            return .local
        }
        if lowered.contains(".") { return .domain }
        // An all-digit label with a "port" is a time or ratio (`10:30`, `16:9`),
        // not a host.
        return hasPort && !lowered.allSatisfy(\.isASCIIDigit) ? .local : nil
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            (1...3).contains(octet.count) && octet.allSatisfy(\.isASCIIDigit) && Int(octet)! <= 255
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
