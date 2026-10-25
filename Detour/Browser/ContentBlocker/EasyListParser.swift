import Foundation

class EasyListParser {

    /// The version of the rule JSON this parser emits for a given list text.
    /// A list WebKit's store holds from another version is recompiled from its
    /// cached text at launch (`ContentBlockerManager.shouldReuseCompiledList`),
    /// so bump this whenever the output changes.
    ///
    /// 2 (TASK-199): the output is ordered by `Section`; `$generichide` and
    /// `$elemhide` exceptions are page-wide and come before the block rules;
    /// `$document` adds a page-wide allowlist; `$important` block rules come
    /// last; `$badfilter` rules and the rules they name are left out.
    static let rulesFormatVersion = 2

    struct ParseResult {
        let rules: [[String: Any]]
        let skippedCount: Int
    }

    /// Where a rule goes in the output, in this order.
    ///
    /// WebKit's `ignore-previous-rules` undoes **every** earlier action of its
    /// rule list for a load its trigger matches (block, css-display-none,
    /// anything), and nothing after it. There is no "cosmetic only" exception,
    /// so the order of the list decides what an exception reaches:
    ///
    /// - Element hiding comes first. Generic hiding (no `if-domain`) is
    ///   followed by the `$generichide` exceptions, then domain-specific
    ///   hiding, then the `$elemhide` exceptions. A cosmetic exception is
    ///   page-wide (`url-filter` `.*` plus a page condition, so it covers
    ///   every load of the page: WebKit adds a list's element hiding from any
    ///   load it did not cancel, the page's subresources included), and it
    ///   undoes only the hiding before it.
    /// - The block rules follow, where no cosmetic exception reaches them.
    /// - Network exceptions come after all the block rules, so each undoes
    ///   every block rule it matches, wherever it stood in the file (Adblock
    ///   Plus semantics; before TASK-199 the file order was kept).
    /// - `$document` allowlists follow: a page-wide exception that undoes
    ///   everything before it for the page.
    /// - `$important` block rules are last, so no exception undoes them.
    ///
    /// The generic hiding rules stay ahead of the list's first exception, so
    /// WebKit still compiles them into its shared per-list style sheet.
    private enum Section: Int, CaseIterable {
        case genericHiding
        case genericHidingExceptions
        case specificHiding
        case elementHidingExceptions
        case blocking
        case exceptions
        case documentExceptions
        case importantBlocking
    }

    func parse(text: String) -> ParseResult {
        var sections = Array(repeating: [[String: Any]](), count: Section.allCases.count)
        var skipped = 0
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        // `$badfilter` disables the rule it repeats (without the option).
        let disabledRules = Set(lines.compactMap(badFilterTarget))

        for trimmed in lines {
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("!"),
                  !trimmed.hasPrefix("[") else { continue }

            if badFilterTarget(trimmed) != nil || disabledRules.contains(trimmed) {
                skipped += 1
                continue
            }

            let parsed = parseLine(trimmed)
            if parsed.isEmpty {
                skipped += 1
            } else {
                for (section, rule) in parsed {
                    sections[section.rawValue].append(rule)
                }
            }
        }

        return ParseResult(rules: sections.flatMap { $0 }, skippedCount: skipped)
    }

    private func parseLine(_ line: String) -> [(Section, [String: Any])] {
        // Extended CSS / snippet filters — not supported in Safari
        if line.contains("#?#") || line.contains("#@?#") ||
           line.contains("#$#") || line.contains("#@$#") {
            return []
        }

        // Element hiding rules: ##.class, ##[attr], domain##selector
        if let hashRange = line.range(of: "##") {
            guard let rule = parseElementHidingRule(line, separatorRange: hashRange) else { return [] }
            let isGeneric = (rule["trigger"] as? [String: Any])?["if-domain"] == nil
            return [(isGeneric ? .genericHiding : .specificHiding, rule)]
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
        let section: Section = optionTokens(in: line).contains("important") ? .importantBlocking : .blocking
        return parseBlockingRules(line).map { (section, $0) }
    }

    /// The rule a `$badfilter` line disables: the line without that option.
    /// Nil for any other line.
    private func badFilterTarget(_ line: String) -> String? {
        guard line.range(of: "badfilter", options: .caseInsensitive) != nil,
              let dollarIndex = findOptionSeparator(in: line) else { return nil }
        let options = line[line.index(after: dollarIndex)...].split(separator: ",", omittingEmptySubsequences: false)
        let kept = options.filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "badfilter" }
        guard kept.count < options.count else { return nil }
        let pattern = String(line[line.startIndex..<dollarIndex])
        return kept.isEmpty ? pattern : pattern + "$" + kept.joined(separator: ",")
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

    /// An `@@` rule. Its options decide what it may undo:
    ///
    /// - `$document`: the page is allowlisted. The plain exception (resource
    ///   type `document`, for the document load itself, also in a frame) plus
    ///   a page-wide exception at the end of the list.
    /// - `$generichide`, `$elemhide`: element hiding only, as page-wide
    ///   exceptions in the element-hiding section; they never reach a block
    ///   rule.
    /// - `$genericblock`, `$specifichide`: left out. WebKit cannot undo only
    ///   the generic block rules, or only the domain-specific hiding, without
    ///   also undoing what these must leave alone; skipping them over-blocks
    ///   or over-hides a little instead of unblocking the network. No list
    ///   Detour ships has one.
    /// - Only for load types the parser compiles no block rule for (`$popup`,
    ///   `$websocket`, `$webrtc`, `$ping`, `$csp`): left out. There is
    ///   nothing for it to undo, and since those options map to no WebKit
    ///   resource type the exception would otherwise undo every block rule
    ///   for its URLs (`@@||accounts.google.com^$popup` did, TASK-199).
    /// - Anything else is a network exception.
    private func parseExceptionRules(_ line: String) -> [(Section, [String: Any])] {
        let options = Set(optionTokens(in: line))
        if options.contains("document") {
            let pageWide = pageWideException(line).map { [(Section.documentExceptions, $0)] } ?? []
            return networkExceptionRules(line).map { (.exceptions, $0) } + pageWide
        }
        // `$elemhide` covers `$generichide`: checked first when a rule has both.
        if !options.isDisjoint(with: ["elemhide", "ehide"]) {
            return pageWideException(line).map { [(.elementHidingExceptions, $0)] } ?? []
        }
        if !options.isDisjoint(with: ["generichide", "ghide"]) {
            return pageWideException(line).map { [(.genericHidingExceptions, $0)] } ?? []
        }
        if !options.isDisjoint(with: ["genericblock", "specifichide", "shide"]) {
            return []
        }
        // An exception from a redirect or CSP rule: no such rule is compiled.
        if options.contains(where: Self.isRewritingOption) {
            return []
        }
        let types = options.filter { mapResourceType($0) != nil || Self.typesWithoutBlockRules.contains($0) }
        if !types.isEmpty && types.allSatisfy(Self.typesWithoutBlockRules.contains) {
            return []
        }
        return networkExceptionRules(line).map { (.exceptions, $0) }
    }

    /// Type options `parseBlockingRules` skips every rule for.
    private static let typesWithoutBlockRules: Set<String> = ["popup", "websocket", "webrtc", "ping", "csp"]

    /// Options that make a rule rewrite a load instead of blocking it;
    /// `parseBlockingRules` skips every rule with one.
    private static func isRewritingOption(_ option: String) -> Bool {
        option == "rewrite" || option == "redirect" ||
            option.hasPrefix("rewrite=") || option.hasPrefix("redirect=") || option.hasPrefix("csp=")
    }

    private func networkExceptionRules(_ line: String) -> [[String: Any]] {
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

    /// An exception for whole pages: `ignore-previous-rules` for every load
    /// (`url-filter` `.*`) of a page the rule names, which undoes, for those
    /// pages, every rule before it in the list. The pages are the rule's
    /// pattern applied to the page's URL (`if-top-url`), so a pattern that is
    /// not a plain domain (`://192.168.`, `://localhost:`,
    /// `||www.google.*/search?`) works as well; with no pattern they are the
    /// `domain=` option's domains (`if-domain`). A WebKit trigger takes one
    /// page condition, so a rule with both keeps the pattern. Nil when the
    /// rule names no page.
    private func pageWideException(_ line: String) -> [String: Any]? {
        let pattern = patternPart(of: line)
        var trigger: [String: Any] = ["url-filter": ".*"]
        if pattern.isEmpty || pattern == "*" {
            let (domainTrigger, _) = buildTrigger(from: line, urlFilter: ".*")
            guard let domains = domainTrigger["if-domain"] as? [String], !domains.isEmpty else { return nil }
            trigger["if-domain"] = domains
        } else {
            let pageFilters = convertPatternToRegexes(line)
            guard !pageFilters.isEmpty else { return nil }
            trigger["if-top-url"] = pageFilters
        }
        return [
            "trigger": trigger,
            "action": ["type": "ignore-previous-rules"]
        ]
    }

    /// The rule's options, trimmed and lower-cased; empty when it has none.
    private func optionTokens(in line: String) -> [String] {
        guard let dollarIndex = findOptionSeparator(in: line) else { return [] }
        return line[line.index(after: dollarIndex)...].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    /// The rule without its options.
    private func patternPart(of line: String) -> String {
        guard let dollarIndex = findOptionSeparator(in: line) else { return line }
        return String(line[line.startIndex..<dollarIndex])
    }

    // MARK: - Blocking Rules

    private func parseBlockingRules(_ line: String) -> [[String: Any]] {
        let urlFilters = convertPatternToRegexes(line)
        guard !urlFilters.isEmpty else { return [] }

        // Check options once (same for all expanded filters)
        if optionTokens(in: line).contains(where: { Self.typesWithoutBlockRules.contains($0) || Self.isRewritingOption($0) }) {
            return []
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
        "elemhide", "generichide", "genericblock", "specifichide", "ehide", "ghide", "shide", "badfilter",
        "websocket", "webrtc", "csp", "rewrite", "redirect",
    ]

    /// Returns one or more regex strings (multiple when disjunctions are expanded).
    private func convertPatternToRegexes(_ line: String) -> [String] {
        let pattern = patternPart(of: line)
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
            case "\\":
                result += "\\\\"
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
