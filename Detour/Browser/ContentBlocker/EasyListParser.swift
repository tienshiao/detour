import Foundation

class EasyListParser {

    struct ParseResult {
        let rules: [[String: Any]]
        let skippedCount: Int
    }

    func parse(text: String) -> ParseResult {
        var rules: [[String: Any]] = []
        var skipped = 0
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("!"),
                  !trimmed.hasPrefix("[") else { continue }

            let parsed = parseLine(trimmed)
            if parsed.isEmpty {
                skipped += 1
            } else {
                rules.append(contentsOf: parsed)
            }
        }

        return ParseResult(rules: rules, skippedCount: skipped)
    }

    private func parseLine(_ line: String) -> [[String: Any]] {
        // Extended CSS / snippet filters — not supported in Safari
        if line.contains("#?#") || line.contains("#@?#") ||
           line.contains("#$#") || line.contains("#@$#") {
            return []
        }

        // Element hiding rules: ##.class, ##[attr], domain##selector
        if let hashRange = line.range(of: "##") {
            if let rule = parseElementHidingRule(line, separatorRange: hashRange) {
                return [rule]
            }
            return []
        }

        // Element hiding exception: domain#@#selector
        if line.contains("#@#") {
            return []
        }

        // Exception rules: @@||domain
        if line.hasPrefix("@@") {
            return parseExceptionRules(String(line.dropFirst(2)))
        }

        // URL blocking rules
        return parseBlockingRules(line)
    }

    // MARK: - Element Hiding

    private func parseElementHidingRule(_ line: String, separatorRange: Range<String.Index>) -> [String: Any]? {
        let domainPart = String(line[line.startIndex..<separatorRange.lowerBound])
        let selector = String(line[separatorRange.upperBound...])
        guard !selector.isEmpty else { return nil }

        var trigger: [String: Any] = ["url-filter": ".*"]

        if !domainPart.isEmpty {
            let domains = domainPart.split(separator: ",").map(String.init)
            var ifDomains: [String] = []
            var unlessDomains: [String] = []
            for domain in domains {
                if domain.hasPrefix("~") {
                    guard let d = sanitizeDomain(String(domain.dropFirst())), !d.isEmpty else { continue }
                    unlessDomains.append("*\(d)")
                } else {
                    guard let d = sanitizeDomain(domain), !d.isEmpty else { continue }
                    ifDomains.append("*\(d)")
                }
            }
            if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
            if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
        }

        return [
            "trigger": trigger,
            "action": ["type": "css-display-none", "selector": selector]
        ]
    }

    // MARK: - Exception Rules

    private func parseExceptionRules(_ line: String) -> [[String: Any]] {
        let urlFilters = convertPatternToRegexes(line)
        guard !urlFilters.isEmpty else { return [] }
        return urlFilters.map { urlFilter in
            let (trigger, _) = buildTrigger(from: line, urlFilter: urlFilter)
            return [
                "trigger": trigger,
                "action": ["type": "ignore-previous-rules"]
            ]
        }
    }

    // MARK: - Blocking Rules

    private func parseBlockingRules(_ line: String) -> [[String: Any]] {
        let urlFilters = convertPatternToRegexes(line)
        guard !urlFilters.isEmpty else { return [] }

        // Check options once (same for all expanded filters)
        let (_, options) = buildTrigger(from: line, urlFilter: urlFilters[0])
        for opt in options {
            let lower = opt.lowercased().trimmingCharacters(in: .whitespaces)
            if lower == "popup" || lower == "websocket" || lower == "webrtc" ||
               lower == "csp" || lower == "rewrite" || lower == "redirect" ||
               lower == "ping" ||
               lower.hasPrefix("redirect=") || lower.hasPrefix("csp=") {
                return []
            }
        }

        return urlFilters.map { urlFilter in
            let (trigger, _) = buildTrigger(from: line, urlFilter: urlFilter)
            return [
                "trigger": trigger,
                "action": ["type": "block"]
            ]
        }
    }

    // MARK: - Pattern Conversion

    private func buildTrigger(from line: String, urlFilter: String) -> ([String: Any], [String]) {
        var trigger: [String: Any] = ["url-filter": urlFilter]
        var options: [String] = []

        // Extract options after $
        let patternLine: String
        if let dollarIndex = findOptionSeparator(in: line) {
            patternLine = String(line[line.startIndex..<dollarIndex])
            let optionString = String(line[line.index(after: dollarIndex)...])
            options = optionString.split(separator: ",").map(String.init)
        } else {
            patternLine = line
        }

        // Process domain options
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var resourceTypes: [String] = []
        var excludeResourceTypes: [String] = []
        var thirdParty: Bool?

        for option in options {
            let opt = option.trimmingCharacters(in: .whitespaces)
            let lower = opt.lowercased()

            if lower.hasPrefix("domain=") {
                let domainList = String(opt.dropFirst("domain=".count))
                for domain in domainList.split(separator: "|").map(String.init) {
                    if domain.hasPrefix("~") {
                        guard let d = sanitizeDomain(String(domain.dropFirst())), !d.isEmpty else { continue }
                        unlessDomains.append("*\(d)")
                    } else {
                        guard let d = sanitizeDomain(domain), !d.isEmpty else { continue }
                        ifDomains.append("*\(d)")
                    }
                }
            } else if lower == "third-party" {
                thirdParty = true
            } else if lower == "~third-party" {
                thirdParty = false
            } else if let resourceType = mapResourceType(lower) {
                if lower.hasPrefix("~") {
                    excludeResourceTypes.append(resourceType)
                } else {
                    resourceTypes.append(resourceType)
                }
            }
        }

        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
        if !resourceTypes.isEmpty { trigger["resource-type"] = resourceTypes }
        if !excludeResourceTypes.isEmpty && resourceTypes.isEmpty {
            // Compute allowed types as all minus excluded
            let allTypes = ["document", "image", "style-sheet", "script", "font",
                           "raw", "svg-document", "media", "popup"]
            let filtered = allTypes.filter { !excludeResourceTypes.contains($0) }
            if !filtered.isEmpty { trigger["resource-type"] = filtered }
        }
        if let tp = thirdParty {
            trigger["load-type"] = tp ? ["third-party"] : ["first-party"]
        }

        // Case sensitivity
        if patternLine.hasPrefix("||") || patternLine.contains("*") {
            trigger["url-filter-is-case-sensitive"] = false
        }

        return (trigger, options)
    }

    private func findOptionSeparator(in line: String) -> String.Index? {
        // Find $ that separates pattern from ABP options
        for i in line.indices {
            guard line[i] == "$" else { continue }
            let remaining = String(line[line.index(after: i)...])
            if remaining.isEmpty { return i }
            let tokens = remaining.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            if tokens.allSatisfy({ isKnownOption($0) }) {
                return i
            }
        }
        return nil
    }

    private func isKnownOption(_ token: String) -> Bool {
        let t = token.hasPrefix("~") ? String(token.dropFirst()) : token
        if t.contains("=") { return true }
        return Self.knownOptions.contains(t)
    }

    private static let knownOptions: Set<String> = [
        "third-party", "script", "image", "stylesheet", "font", "media",
        "xmlhttprequest", "subdocument", "object", "object-subrequest", "other",
        "document", "popup", "ping", "all", "important", "match-case",
        "elemhide", "generichide", "genericblock", "badfilter",
        "websocket", "webrtc", "csp", "rewrite", "redirect",
    ]

    /// Returns one or more regex strings (multiple when disjunctions are expanded).
    private func convertPatternToRegexes(_ line: String) -> [String] {
        // Strip options for pattern extraction
        let pattern: String
        if let dollarIndex = findOptionSeparator(in: line) {
            pattern = String(line[line.startIndex..<dollarIndex])
        } else {
            pattern = line
        }

        guard !pattern.isEmpty else { return [] }

        // Handle /regex/ literals — raw regex between delimiters
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            let inner = String(pattern.dropFirst().dropLast())
            if inner.contains("\\") || inner.contains("(") || inner.contains("{") ||
               inner.contains("[") || inner.hasPrefix("^") || inner.hasSuffix("$") {
                let converted = convertRegexLiteral(inner)
                return converted.filter { isValidRegex($0) && $0.count < 500 }
            }
        }

        var regex = pattern

        // Handle ||domain^ (domain anchor)
        if regex.hasPrefix("||") {
            regex = String(regex.dropFirst(2))
            regex = "^[^:]+:(//)?([^/]+\\.)?" + escapeForRegex(regex)
        } else if regex.hasPrefix("|") {
            regex = "^" + escapeForRegex(String(regex.dropFirst()))
        } else {
            regex = escapeForRegex(regex)
        }

        // Handle trailing |
        if regex.hasSuffix("\\|") {
            regex = String(regex.dropLast(2)) + "$"
        }

        // Verify regex validity — reject patterns WebKit would reject
        guard regex.count < 500 else { return [] }
        guard isValidRegex(regex) else { return [] }

        return [regex]
    }

    /// Converts an ABP regex literal to one or more WebKit-compatible regexes.
    private func convertRegexLiteral(_ inner: String) -> [String] {
        var regex = inner
        // \/ is used in ABP to escape the / delimiter — not needed for WebKit
        regex = regex.replacingOccurrences(of: "\\/", with: "/")
        // Expand shorthand character classes WebKit doesn't support in all contexts
        regex = regex.replacingOccurrences(of: "\\w", with: "[a-zA-Z0-9_]")
        regex = regex.replacingOccurrences(of: "\\d", with: "[0-9]")
        // Expand {n}, {n,m}, {n,} quantifiers into repeated atoms (WebKit doesn't support them)
        regex = expandQuantifiers(regex)

        // Expand disjunctions — WebKit doesn't support (a|b|c)
        if let expanded = expandDisjunctions(regex) {
            return expanded
        }

        return [regex]
    }

    /// Expands `{n}`, `{n,m}`, `{n,}` quantifiers by repeating the preceding atom.
    /// E.g. `[a-z]{2,4}` → `[a-z][a-z][a-z]?[a-z]?`, `x{3}` → `xxx`, `x{2,}` → `xx+`
    private func expandQuantifiers(_ regex: String) -> String {
        // Match: (atom){n}, (atom){n,m}, (atom){n,}
        // atom can be: [charset], (group), \escape, or single char
        let pattern = #"(\[[^\]]*\]|\([^)]*\)|\\.|[^\\{(\[])\{(\d+)(?:,(\d*))?\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return regex }

        var result = regex
        // Process from end to start so indices stay valid
        let matches = re.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let atomRange = Range(match.range(at: 1), in: result),
                  let minRange = Range(match.range(at: 2), in: result),
                  let minVal = Int(result[minRange]) else { continue }

            let atom = String(result[atomRange])
            let hasComma = match.range(at: 3).location != NSNotFound
            let maxRange = hasComma ? Range(match.range(at: 3), in: result) : nil
            let maxStr = maxRange.map { String(result[$0]) } ?? ""

            var replacement: String
            let cap = 20 // limit expansion to avoid regex explosion

            if !hasComma {
                // {n} — exactly n repetitions
                let n = min(minVal, cap)
                replacement = String(repeating: atom, count: n)
            } else if maxStr.isEmpty {
                // {n,} — n or more
                let n = min(minVal, cap)
                replacement = String(repeating: atom, count: max(n, 1)) + (n == 0 ? "*" : "+")
                if n > 1 {
                    replacement = String(repeating: atom, count: n - 1) + atom + "+"
                }
            } else if let maxVal = Int(maxStr) {
                // {n,m} — between n and m
                let n = min(minVal, cap)
                let m = min(maxVal, cap)
                let required = String(repeating: atom, count: n)
                let optional = String(repeating: atom + "?", count: max(m - n, 0))
                replacement = required + optional
            } else {
                continue
            }

            result.replaceSubrange(fullRange, with: replacement)

            // Bail if the expansion is getting too long
            if result.count > 1000 { return result }
        }

        return result
    }

    /// If the regex contains a `(alt1|alt2|...)` group, expands into one regex per alternative.
    /// Returns nil if no disjunction is found.
    private func expandDisjunctions(_ regex: String) -> [String]? {
        // Find the first top-level disjunction group (not nested)
        guard let openParen = regex.firstIndex(of: "(") else { return nil }
        // Walk forward to find matching close paren and check for |
        var depth = 0
        var closeParen: String.Index?
        var hasPipe = false
        for i in regex.indices[openParen...] {
            if regex[i] == "(" { depth += 1 }
            else if regex[i] == ")" {
                depth -= 1
                if depth == 0 { closeParen = i; break }
            }
            else if regex[i] == "|" && depth == 1 { hasPipe = true }
        }

        guard hasPipe, let close = closeParen else { return nil }

        let prefix = String(regex[regex.startIndex..<openParen])
        let groupContent = String(regex[regex.index(after: openParen)..<close])
        let suffix = String(regex[regex.index(after: close)...])
        let alternatives = groupContent.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

        // Cap expansion to avoid rule explosion
        guard alternatives.count <= 50 else { return nil }

        return alternatives.map { prefix + $0 + suffix }
    }

    private func isValidRegex(_ pattern: String) -> Bool {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return true
        } catch {
            return false
        }
    }

    /// Converts domains to lower-case ASCII, encoding non-ASCII via punycode.
    private func sanitizeDomain(_ domain: String) -> String? {
        let d = domain.lowercased()
        guard !d.isEmpty else { return nil }
        if d.allSatisfy({ $0.isASCII }) { return d }
        // Convert non-ASCII domain to punycode via URL host resolution
        var components = URLComponents()
        components.host = d
        if let ascii = components.percentEncodedHost, ascii.allSatisfy({ $0.isASCII }) {
            return ascii
        }
        return nil
    }

    private func escapeForRegex(_ pattern: String) -> String {
        var result = ""
        for char in pattern {
            switch char {
            case "*":
                result += ".*"
            case "^":
                result += "[^a-zA-Z0-9_.%-]"
            case ".":
                result += "\\."
            case "+":
                result += "\\+"
            case "?":
                result += "\\?"
            case "$":
                result += "\\$"
            case "{", "}", "(", ")", "[", "]":
                result += "\\\(char)"
            case "|":
                result += "\\|"
            default:
                result += String(char)
            }
        }
        return result
    }

    private func mapResourceType(_ option: String) -> String? {
        let opt = option.hasPrefix("~") ? String(option.dropFirst()) : option
        switch opt {
        case "script": return "script"
        case "image": return "image"
        case "stylesheet": return "style-sheet"
        case "font": return "font"
        case "media": return "media"
        case "xmlhttprequest": return "raw"
        case "subdocument": return "document"
        case "object", "object-subrequest": return "media"
        case "other": return "raw"
        case "document": return "document"
        default: return nil
        }
    }
}
