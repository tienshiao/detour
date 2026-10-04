import Foundation

/// A `declarativeNetRequest` **session** rule whose action is `modifyHeaders`
/// with `requestHeaders`, as Detour keeps it to apply to requests the
/// extension's own contexts make (TASK-132.4).
///
/// Why Detour keeps any: WebKit owns `chrome.declarativeNetRequest`, but
/// (measured on macOS 26.7, `ExtensionDeclarativeNetRequestTests`)
///  - it refuses a `modifyHeaders` rule naming a header outside its own fixed
///    list (`anthropic-client-platform` → "The header … is not recognized"), and
///  - a rule it does accept is applied to requests from the extension's pages
///    but not to `fetch` from its service worker.
/// So the polyfill (`ExtensionAPIPolyfill.declarativeNetRequestJS`) hands these
/// rules to Detour as well, and its `fetch` / `XMLHttpRequest` wrappers ask
/// which header changes apply to each request.
///
/// Everything here is pure: parsing what the extension passed, matching a
/// request, and combining the changes of every matching rule.
struct ExtensionHeaderRule {

    enum Operation: String {
        case set, append, remove
    }

    /// One entry of a rule's `action.requestHeaders`.
    struct HeaderChange: Equatable {
        let header: String
        let operation: Operation
        /// Present for `set` and `append`, absent for `remove`.
        let value: String?

        /// The shape the polyfill's wrappers apply.
        var payload: [String: Any] {
            var payload: [String: Any] = ["header": header, "operation": operation.rawValue]
            if let value { payload["value"] = value }
            return payload
        }
    }

    /// Why a rule was not kept.
    enum ParseError: Error, Equatable {
        /// Not `modifyHeaders` with `requestHeaders`: nothing for Detour to do.
        case notAHeaderRule
        /// Malformed, whoever applies it.
        case invalid(String)
        /// Well-formed, but it asks for something Detour's own matching does
        /// not implement. Applying it anyway could put a header on a request
        /// the extension meant to leave alone, so it is not applied at all.
        case unsupported(String)

        var reason: String {
            switch self {
            case .notAHeaderRule: return "not a modifyHeaders rule with requestHeaders"
            case .invalid(let reason), .unsupported(let reason): return reason
            }
        }
    }

    /// The part of a rule's `condition` Detour matches on.
    struct Condition {
        /// Compiled from `urlFilter` or `regexFilter`; nil matches every URL.
        let urlPattern: NSRegularExpression?
        let requestMethods: Set<String>?
        let excludedRequestMethods: Set<String>
        let requestDomains: [String]?
        let excludedRequestDomains: [String]
        /// Whether the rule's resource types cover a script-made request
        /// (`xmlhttprequest`, the only kind a `fetch`/XHR wrapper ever sees).
        let coversScriptRequests: Bool

        func matches(url: URL, method: String) -> Bool {
            guard coversScriptRequests else { return false }
            let method = method.lowercased()
            if let requestMethods, !requestMethods.contains(method) { return false }
            if excludedRequestMethods.contains(method) { return false }

            let host = (url.host ?? "").lowercased()
            if let requestDomains, !requestDomains.contains(where: { Self.host(host, isWithin: $0) }) { return false }
            if excludedRequestDomains.contains(where: { Self.host(host, isWithin: $0) }) { return false }

            if let urlPattern {
                let text = ExtensionHeaderRule.matchableString(for: url)
                let range = NSRange(text.startIndex..., in: text)
                if urlPattern.firstMatch(in: text, range: range) == nil { return false }
            }
            return true
        }

        /// `domain` itself or one of its subdomains, as Chrome matches
        /// `requestDomains`.
        static func host(_ host: String, isWithin domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }
    }

    let id: Int
    let priority: Int
    let changes: [HeaderChange]
    let condition: Condition
    /// The rule exactly as the extension passed it: what `getSessionRules`
    /// answers for a rule only Detour holds.
    let original: [String: Any]
    /// False when WebKit refused the rule and Detour is its only keeper.
    let acceptedByWebKit: Bool

    /// The resource type of every request the polyfill's wrappers intercept.
    static let scriptRequestResourceType = "xmlhttprequest"

    /// `condition` keys Detour's matching implements. A rule using any other
    /// (`initiatorDomains`, `tabIds`, `domainType`, …) is `.unsupported`.
    static let supportedConditionKeys: Set<String> = [
        "urlFilter", "regexFilter", "isUrlFilterCaseSensitive",
        "resourceTypes", "excludedResourceTypes",
        "requestMethods", "excludedRequestMethods",
        "requestDomains", "excludedRequestDomains",
    ]

    /// The URL text a filter is matched against: absolute, without the
    /// fragment (a fragment is never sent).
    static func matchableString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    // MARK: - Parsing

    /// Whether `rule` is the kind Detour keeps: `modifyHeaders` with a
    /// `requestHeaders` list.
    static func isHeaderRule(_ rule: [String: Any]) -> Bool {
        guard let action = rule["action"] as? [String: Any],
              action["type"] as? String == "modifyHeaders" else { return false }
        return action["requestHeaders"] is [Any]
    }

    static func parse(_ rule: [String: Any], acceptedByWebKit: Bool) -> Result<ExtensionHeaderRule, ParseError> {
        guard isHeaderRule(rule), let action = rule["action"] as? [String: Any] else {
            return .failure(.notAHeaderRule)
        }
        guard let id = integer(rule["id"]), id >= 1 else {
            return .failure(.invalid("`id` must be an integer of 1 or more"))
        }
        let priority: Int
        if let raw = rule["priority"] {
            guard let value = integer(raw), value >= 1 else {
                return .failure(.invalid("`priority` must be an integer of 1 or more"))
            }
            priority = value
        } else {
            priority = 1
        }

        // A response header can only be changed by the network stack. WebKit
        // does that for a rule it accepted; a rule only Detour holds would
        // silently lose them, so it is refused instead.
        if action["responseHeaders"] != nil, !acceptedByWebKit {
            return .failure(.unsupported("`responseHeaders` cannot be applied by Detour"))
        }

        guard let entries = action["requestHeaders"] as? [[String: Any]], !entries.isEmpty,
              entries.count == (action["requestHeaders"] as? [Any])?.count else {
            return .failure(.invalid("`requestHeaders` must be a non-empty array of objects"))
        }
        var changes: [HeaderChange] = []
        for entry in entries {
            guard let header = entry["header"] as? String, isHeaderName(header) else {
                return .failure(.invalid("a `requestHeaders` entry has no valid `header` name"))
            }
            guard let operation = (entry["operation"] as? String).flatMap(Operation.init(rawValue:)) else {
                return .failure(.invalid("the `operation` for `\(header)` must be set, append or remove"))
            }
            let value = entry["value"] as? String
            switch operation {
            case .remove:
                guard entry["value"] == nil else {
                    return .failure(.invalid("`\(header)` is removed, so it must not have a `value`"))
                }
            case .set, .append:
                guard let value, isHeaderValue(value) else {
                    return .failure(.invalid("`\(header)` needs a string `value` without line breaks"))
                }
            }
            changes.append(HeaderChange(header: header, operation: operation, value: value))
        }

        guard let rawCondition = rule["condition"] as? [String: Any] else {
            return .failure(.invalid("`condition` must be an object"))
        }
        switch parseCondition(rawCondition) {
        case .failure(let error):
            return .failure(error)
        case .success(let condition):
            return .success(ExtensionHeaderRule(id: id, priority: priority, changes: changes,
                                                condition: condition, original: rule,
                                                acceptedByWebKit: acceptedByWebKit))
        }
    }

    private static func parseCondition(_ raw: [String: Any]) -> Result<Condition, ParseError> {
        if let unknown = raw.keys.sorted().first(where: { !supportedConditionKeys.contains($0) }) {
            return .failure(.unsupported("the condition key `\(unknown)` is not matched by Detour"))
        }

        var caseSensitive = false
        if let rawFlag = raw["isUrlFilterCaseSensitive"] {
            guard let flag = rawFlag as? Bool else {
                return .failure(.invalid("`isUrlFilterCaseSensitive` must be a boolean"))
            }
            caseSensitive = flag
        }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]

        var urlPattern: NSRegularExpression?
        switch (raw["urlFilter"], raw["regexFilter"]) {
        case (.some, .some):
            return .failure(.invalid("define only one of `urlFilter` and `regexFilter`"))
        case (.some(let rawFilter), nil):
            guard let filter = rawFilter as? String, !filter.isEmpty else {
                return .failure(.invalid("`urlFilter` must be a non-empty string"))
            }
            guard let compiled = try? NSRegularExpression(pattern: regexPattern(forURLFilter: filter),
                                                          options: options) else {
                return .failure(.invalid("`urlFilter` could not be compiled"))
            }
            urlPattern = compiled
        case (nil, .some(let rawFilter)):
            guard let filter = rawFilter as? String, !filter.isEmpty else {
                return .failure(.invalid("`regexFilter` must be a non-empty string"))
            }
            // Chrome's syntax is RE2; ICU takes everything RE2 does that an
            // extension is likely to write. A pattern it cannot compile is
            // not guessed at.
            guard let compiled = try? NSRegularExpression(pattern: filter, options: options) else {
                return .failure(.unsupported("`regexFilter` could not be compiled"))
            }
            urlPattern = compiled
        case (nil, nil):
            urlPattern = nil
        }

        func strings(_ key: String) -> Result<[String]?, ParseError> {
            guard let rawList = raw[key] else { return .success(nil) }
            guard let list = rawList as? [String], list.count == (rawList as? [Any])?.count else {
                return .failure(.invalid("`\(key)` must be an array of strings"))
            }
            return .success(list.map { $0.lowercased() })
        }
        var lists: [String: [String]] = [:]
        for key in ["resourceTypes", "excludedResourceTypes", "requestMethods", "excludedRequestMethods",
                    "requestDomains", "excludedRequestDomains"] {
            switch strings(key) {
            case .failure(let error): return .failure(error)
            case .success(let list): if let list { lists[key] = list }
            }
        }
        if lists["resourceTypes"] != nil, lists["excludedResourceTypes"] != nil {
            return .failure(.invalid("define only one of `resourceTypes` and `excludedResourceTypes`"))
        }
        if let included = lists["resourceTypes"], included.isEmpty {
            return .failure(.invalid("`resourceTypes` cannot be an empty array"))
        }
        if let included = lists["requestMethods"], included.isEmpty {
            return .failure(.invalid("`requestMethods` cannot be an empty array"))
        }
        if let included = lists["requestDomains"], included.isEmpty {
            return .failure(.invalid("`requestDomains` cannot be an empty array"))
        }

        // With neither list a rule covers everything but `main_frame`.
        let covers: Bool
        if let included = lists["resourceTypes"] {
            covers = included.contains(scriptRequestResourceType)
        } else {
            covers = !(lists["excludedResourceTypes"] ?? []).contains(scriptRequestResourceType)
        }

        return .success(Condition(
            urlPattern: urlPattern,
            requestMethods: lists["requestMethods"].map(Set.init),
            excludedRequestMethods: Set(lists["excludedRequestMethods"] ?? []),
            requestDomains: lists["requestDomains"],
            excludedRequestDomains: lists["excludedRequestDomains"] ?? [],
            coversScriptRequests: covers))
    }

    /// A JSON number that is a whole number, as a JS bridge delivers it
    /// (`NSNumber`, possibly a double). A boolean is not a number here.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    /// An HTTP field name: a non-empty token (RFC 9110 §5.6.2).
    static func isHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let other = Set("!#$%&'*+-.^_`|~".unicodeScalars)
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || other.contains($0))
        }
    }

    /// A field value that cannot smuggle a second header line.
    static func isHeaderValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }

    /// Chrome's `urlFilter` syntax as a regular expression: `*` is a
    /// wildcard, `^` a separator (anything but a letter, a digit or one of
    /// `_-.%`, or the end of the URL), a leading `|` / trailing `|` anchor the
    /// start / end, a leading `||` anchors at a domain boundary, and anything
    /// else is literal text matched anywhere in the URL.
    static func regexPattern(forURLFilter filter: String) -> String {
        var body = Substring(filter)
        var pattern = ""
        if body.hasPrefix("||") {
            pattern += "^[a-z][a-z0-9+.\\-]*://(?:[^/?#]*\\.)?"
            body = body.dropFirst(2)
        } else if body.hasPrefix("|") {
            pattern += "^"
            body = body.dropFirst()
        }
        var anchoredAtEnd = false
        if body.hasSuffix("|") {
            anchoredAtEnd = true
            body = body.dropLast()
        }
        for character in body {
            switch character {
            case "*": pattern += ".*"
            case "^": pattern += "(?:[^A-Za-z0-9_\\-.%]|$)"
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        if anchoredAtEnd { pattern += "$" }
        return pattern
    }
}

/// The header rules Detour holds for one extension in one profile, for as long
/// as its context stays loaded — session rules do not outlive the session, and
/// WebKit drops its own when a context unloads.
struct ExtensionHeaderRuleSet {

    /// Chrome's `MAX_NUMBER_OF_SESSION_RULES`.
    static let maximumRuleCount = 5000

    private(set) var rules: [Int: ExtensionHeaderRule] = [:]

    var isEmpty: Bool { rules.isEmpty }

    struct TooManyRules: Error {}

    /// What `update` would leave behind, without changing anything.
    func updated(removing ids: [Int], adding added: [ExtensionHeaderRule]) throws -> ExtensionHeaderRuleSet {
        var copy = self
        for id in ids { copy.rules[id] = nil }
        // A rule WebKit now holds under an id replaces what Detour held under
        // it, and the other way round: one id, one keeper.
        for rule in added { copy.rules[rule.id] = rule }
        guard copy.rules.count <= Self.maximumRuleCount else { throw TooManyRules() }
        return copy
    }

    /// The rules only Detour holds, as the extension passed them, by id —
    /// the ones WebKit's `getSessionRules` cannot report.
    func originalsKeptByDetourAlone(ruleIDs: Set<Int>? = nil) -> [[String: Any]] {
        rules.values
            .filter { !$0.acceptedByWebKit && (ruleIDs?.contains($0.id) ?? true) }
            .sorted { $0.id < $1.id }
            .map(\.original)
    }

    /// The header changes to make to one request, in the order to make them.
    ///
    /// Rules are taken by priority (highest first, then by id), and what a
    /// rule did to a header limits what a later one may do to it, as in
    /// Chrome: after a `remove` nothing; after a `set` or an `append` only
    /// another `append`.
    ///
    /// - Parameter includingAcceptedByWebKit: false for a request from a page,
    ///   where WebKit applies the rules it accepted itself; true for the
    ///   service worker, where it applies none.
    func changes(for url: URL, method: String, includingAcceptedByWebKit: Bool) -> [ExtensionHeaderRule.HeaderChange] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        let matching = rules.values
            .filter { (includingAcceptedByWebKit || !$0.acceptedByWebKit) && $0.condition.matches(url: url, method: method) }
            .sorted { ($0.priority, $1.id) > ($1.priority, $0.id) }

        var lastOperation: [String: ExtensionHeaderRule.Operation] = [:]
        var result: [ExtensionHeaderRule.HeaderChange] = []
        for rule in matching {
            for change in rule.changes {
                let name = change.header.lowercased()
                switch (lastOperation[name], change.operation) {
                case (nil, _):
                    lastOperation[name] = change.operation
                    result.append(change)
                case (.set?, .append), (.append?, .append):
                    result.append(change)
                default:
                    continue
                }
            }
        }
        return result
    }
}
