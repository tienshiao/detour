import Foundation

/// Converts Chrome extension match patterns to URL matching logic.
/// See: https://developer.chrome.com/docs/extensions/develop/concepts/match-patterns
struct ContentScriptMatcher {
    private let patterns: [MatchPattern]

    init(patterns: [String]) {
        self.patterns = patterns.compactMap { MatchPattern($0) }
    }

    func matches(_ url: URL) -> Bool {
        patterns.contains { $0.matches(url) }
    }

    /// Generates a JavaScript condition string that checks `location.href` against the patterns.
    func jsGuardCondition() -> String {
        if patterns.contains(where: { $0.isAllURLs }) {
            return "(location.protocol === 'http:' || location.protocol === 'https:')"
        }
        let checks = patterns.map { $0.jsCondition() }
        return "(" + checks.joined(separator: " || ") + ")"
    }
}

struct MatchPattern {
    let isAllURLs: Bool
    let scheme: String?  // "http", "https", "*"
    let host: String?    // e.g. "*.example.com", "*"
    let path: String?    // e.g. "/*", "/foo/*"

    init?(_ pattern: String) {
        if pattern == "<all_urls>" {
            isAllURLs = true
            scheme = nil
            host = nil
            path = nil
            return
        }

        // Pattern format: scheme://host/path
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let schemeStr = String(pattern[..<schemeEnd.lowerBound])
        let rest = String(pattern[schemeEnd.upperBound...])

        guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
        let hostStr = String(rest[..<slashIndex])
        let pathStr = String(rest[slashIndex...])

        isAllURLs = false
        scheme = schemeStr
        host = hostStr
        path = pathStr
    }

    func matches(_ url: URL) -> Bool {
        if isAllURLs {
            return url.scheme == "http" || url.scheme == "https"
        }

        // Check scheme
        if let scheme, scheme != "*" {
            guard url.scheme == scheme else { return false }
        } else {
            guard url.scheme == "http" || url.scheme == "https" else { return false }
        }

        // Check host
        if let host, host != "*" {
            guard let urlHost = url.host else { return false }
            if host.hasPrefix("*.") {
                let domain = String(host.dropFirst(2))
                guard urlHost == domain || urlHost.hasSuffix(".\(domain)") else { return false }
            } else {
                guard urlHost == host else { return false }
            }
        }

        // Check path
        if let path, path != "/*" {
            let urlPath = url.path.isEmpty ? "/" : url.path
            let regexPattern = "^" + path
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "*", with: ".*") + "$"
            guard urlPath.range(of: regexPattern, options: .regularExpression) != nil else { return false }
        }

        return true
    }

    func jsCondition() -> String {
        if isAllURLs {
            return "(location.protocol === 'http:' || location.protocol === 'https:')"
        }

        var conditions: [String] = []

        // Scheme check
        if let scheme, scheme != "*" {
            conditions.append("location.protocol === '\(scheme):'")
        } else {
            conditions.append("(location.protocol === 'http:' || location.protocol === 'https:')")
        }

        // Host check
        if let host, host != "*" {
            if host.hasPrefix("*.") {
                let domain = String(host.dropFirst(2))
                conditions.append("(location.hostname === '\(domain)' || location.hostname.endsWith('.\(domain)'))")
            } else {
                conditions.append("location.hostname === '\(host)'")
            }
        }

        // Path check
        if let path, path != "/*" {
            let regexStr = "^" + path
                .replacingOccurrences(of: ".", with: "\\\\.")
                .replacingOccurrences(of: "*", with: ".*") + "$"
            conditions.append("new RegExp('\(regexStr)').test(location.pathname)")
        }

        return "(" + conditions.joined(separator: " && ") + ")"
    }
}
