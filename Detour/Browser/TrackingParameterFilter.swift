import Foundation

/// The `$removeparam` rules of a downloaded tracking-parameter filter list
/// (AdGuard's URL Tracking filter, TASK-329), parsed into a rule set that
/// answers, for one page address, which of its query parameters to remove and
/// which the list's `@@` exceptions keep.
///
/// The address is matched as a page (a `document` request): its own host is
/// both the URL the pattern is matched against and the domain `domain=` is
/// checked against, as AdGuard and uBlock Origin do for a top-level document.
///
/// Supported rule forms:
/// - a URL pattern in Adblock syntax: `||host` (the host or any subdomain),
///   `|` anchors, `^` separators, `*`, plain substrings, and a wildcard top
///   level domain `||amazon.*/…` (see `isPublicSuffixLike`);
/// - `domain=a.example|~b.a.example|amazon.*`;
/// - `$removeparam=name` (compared exactly, raw or percent-decoded),
///   `$removeparam` (every parameter), `$removeparam=~name` (every parameter
///   but `name`);
/// - `@@` exceptions of each of those: `@@…$removeparam=name` keeps `name`
///   (compared without case), `@@…$removeparam` keeps every parameter.
///
/// Skipped and counted (`Counts`): regex values (`$removeparam=/…/`) and regex
/// patterns; rules for other request types (`xhr`, `image`, …) or third-party
/// requests, which a page address never is; block rules with an option the
/// parser does not know (`$app`, `$match-case`, …); lines that are no
/// `$removeparam` rule. An exception is never dropped for an option it does
/// not know: it is kept without it (`Counts.widenedExceptions`), so the list
/// errs on the side of keeping a parameter. A widened exception, or one for
/// every site, cancels only the list's own rules; an exception as written for
/// some sites also keeps the built-in names (`Verdict.protects`). `$important`
/// is accepted and ignored: an exception still wins (the list has none).
///
/// Pure and immutable: parsed off the main thread, matched on a menu click.
nonisolated struct TrackingParameterFilter: Sendable {

    struct Counts: Sendable, Equatable {
        /// Rules used, exceptions included.
        var supported = 0
        /// Of `supported`, the `@@` exceptions.
        var exceptions = 0
        /// Of `exceptions`, those kept broader than written: a regex exception
        /// (it keeps every parameter of its URLs) or one with an option the
        /// parser does not know (ignored).
        var widenedExceptions = 0
        /// Regex `$removeparam=/…/` values and `/…/` patterns, skipped.
        var regex = 0
        /// Rules limited to request types a page is not (`xhr`, `image`,
        /// `~document`, third-party), skipped.
        var notForPages = 0
        /// Block rules with an option the parser does not know, or that would
        /// remove every parameter of every address, skipped.
        var unsupported = 0
        /// Lines that are no `$removeparam` rule (element hiding, other
        /// options), skipped. Comments and the header are not counted.
        var other = 0

        var skipped: Int { regex + notForPages + unsupported + other }
    }

    let counts: Counts

    /// Whether the list gave any rule: a download that parsed into none (an
    /// error page, an empty file) does not replace the rules in use.
    var isEmpty: Bool { counts.supported == 0 }

    /// What the rules say about one address's parameters.
    struct Verdict: Sendable {
        fileprivate var names: Set<String> = []
        fileprivate var removesAll = false
        fileprivate var keepsOnly: [String] = []
        /// Exceptions as written, for this site: they keep a parameter from
        /// the built-in names too. Lower-cased.
        fileprivate var protectedNames: Set<String> = []
        fileprivate var protectsAll = false
        /// Exceptions kept broader than written, or for every site: they keep
        /// a parameter from the list's own rules only. Lower-cased.
        fileprivate var listOnlyProtectedNames: Set<String> = []
        fileprivate var listOnlyProtectsAll = false

        /// Whether an exception for this site keeps the parameter (`rawName`
        /// as written in the query, `name` percent-decoded), whatever else
        /// would remove it, the built-in names included.
        func protects(rawName: String, name: String) -> Bool {
            protectsAll || protectedNames.contains(rawName.lowercased()) || protectedNames.contains(name.lowercased())
        }

        /// Whether one of the list's rules removes the parameter and no
        /// exception keeps it from them. A named rule needs a `name=` pair
        /// (`hasValue`), as AdGuard's `^name=[^&#]*$` does: a bare `?name`
        /// is kept.
        func removes(rawName: String, name: String, hasValue: Bool = true) -> Bool {
            guard !protects(rawName: rawName, name: name), !listOnlyProtectsAll,
                  !listOnlyProtectedNames.contains(rawName.lowercased()),
                  !listOnlyProtectedNames.contains(name.lowercased()) else { return false }
            return (hasValue && (names.contains(rawName) || names.contains(name))) || removesAll
                || keepsOnly.contains { $0 != rawName && $0 != name }
        }
    }

    // MARK: - Rules

    fileprivate enum Action: Sendable {
        case name(String)
        case all
        case allBut(String)
    }

    fileprivate struct Rule: Sendable {
        let action: Action
        let pattern: URLPattern?
        let domains: DomainCondition?
        /// An exception that keeps its parameters from the built-in names
        /// too: one taken as written (not widened) and limited to some
        /// addresses (a pattern or an included domain). Other exceptions only
        /// cancel the list's own rules, so the built-in names stay the floor.
        var overridesBuiltInNames = false

        func applies(to address: Address) -> Bool {
            (domains?.matches(host: address.host) ?? true) && (pattern?.matches(address) ?? true)
        }
    }

    /// Block rules with no pattern and no domain: they apply everywhere.
    private let globalNames: Set<String>
    /// Block rules whose pattern names a whole host (`||host^`, `||host/…`),
    /// by that host: only an address on it or a subdomain can match.
    private let rulesByHost: [String: [Rule]]
    /// Every other block rule.
    private let otherRules: [Rule]
    private let exceptionRules: [Rule]

    // MARK: - Matching

    /// The rules' verdict on `url`'s parameters; nil when it is not an http(s)
    /// address.
    func verdict(for url: URL) -> Verdict? {
        guard let address = Address(url) else { return nil }
        var verdict = Verdict()
        verdict.names = globalNames
        func add(_ rule: Rule) {
            switch rule.action {
            case .name(let name): verdict.names.insert(name)
            case .all: verdict.removesAll = true
            case .allBut(let name): verdict.keepsOnly.append(name)
            }
        }
        for suffix in address.hostSuffixes {
            for rule in rulesByHost[suffix] ?? [] where rule.applies(to: address) { add(rule) }
        }
        for rule in otherRules where rule.applies(to: address) { add(rule) }
        for rule in exceptionRules where rule.applies(to: address) {
            switch (rule.action, rule.overridesBuiltInNames) {
            case (.name(let name), true): verdict.protectedNames.insert(name.lowercased())
            case (.name(let name), false): verdict.listOnlyProtectedNames.insert(name.lowercased())
            case (.all, true), (.allBut, true): verdict.protectsAll = true
            case (.all, false), (.allBut, false): verdict.listOnlyProtectsAll = true
            }
        }
        return verdict
    }

    // MARK: - Parsing

    init(text: String) {
        var counts = Counts()
        var globalNames: Set<String> = []
        var rulesByHost: [String: [Rule]] = [:]
        var otherRules: [Rule] = []
        var exceptionRules: [Rule] = []

        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
            switch Self.parse(line) {
            case .skipped(let reason):
                switch reason {
                case .regex: counts.regex += 1
                case .notForPages: counts.notForPages += 1
                case .unsupported: counts.unsupported += 1
                case .other: counts.other += 1
                }
            case .exception(let rule, let widened):
                counts.supported += 1
                counts.exceptions += 1
                if widened { counts.widenedExceptions += 1 }
                exceptionRules.append(rule)
            case .block(let rule, let hostKey):
                counts.supported += 1
                if case .name(let name) = rule.action, rule.pattern == nil, rule.domains == nil {
                    globalNames.insert(name)
                } else if let hostKey {
                    rulesByHost[hostKey, default: []].append(rule)
                } else {
                    otherRules.append(rule)
                }
            }
        }
        self.counts = counts
        self.globalNames = globalNames
        self.rulesByHost = rulesByHost
        self.otherRules = otherRules
        self.exceptionRules = exceptionRules
    }

    private enum SkipReason { case regex, notForPages, unsupported, other }

    private enum Parsed {
        case block(Rule, hostKey: String?)
        case exception(Rule, widened: Bool)
        case skipped(SkipReason)
    }

    /// Request types a rule can be limited to. A page is `document`.
    private static let requestTypes: Set<String> = [
        "document", "doc", "subdocument", "frame", "script", "image", "stylesheet", "css", "xhr",
        "xmlhttprequest", "font", "media", "object", "other", "ping", "websocket", "webrtc", "popup",
    ]

    private static func parse(_ line: String) -> Parsed {
        let isException = line.hasPrefix("@@")
        let body = isException ? String(line.dropFirst(2)) : line
        guard let (patternText, options) = splitOptions(body) else { return .skipped(.other) }

        var removeparam: String?? = nil
        var domains: DomainCondition?
        var positiveTypes: Set<String> = []
        var excludesDocument = false
        var thirdPartyOnly = false
        var unknownOption = false
        for option in options {
            let (rawName, value) = option.firstIndex(of: "=").map {
                (String(option[..<$0]), String(option[option.index(after: $0)...]))
            } ?? (option, nil)
            let negated = rawName.hasPrefix("~")
            let name = negated ? String(rawName.dropFirst()) : rawName
            switch name {
            case "removeparam" where !negated:
                removeparam = .some(value)
            case "domain" where !negated:
                guard let value, let condition = DomainCondition(value) else {
                    unknownOption = true
                    continue
                }
                domains = condition
            case _ where requestTypes.contains(name) && value == nil:
                let isDocument = name == "document" || name == "doc"
                if negated { excludesDocument = excludesDocument || isDocument } else { positiveTypes.insert(name) }
            case "3p", "third-party":
                if !negated { thirdPartyOnly = true }
            case "1p", "first-party":
                if negated { thirdPartyOnly = true }
            case "important":
                break
            default:
                unknownOption = true
            }
        }
        guard case .some(let rawValue) = removeparam else { return .skipped(.other) }

        let notForPages = excludesDocument || thirdPartyOnly
            || (!positiveTypes.isEmpty && !positiveTypes.contains("document") && !positiveTypes.contains("doc"))
        if notForPages { return .skipped(.notForPages) }

        var widened = unknownOption
        let action: Action
        let value = rawValue.map { $0.replacingOccurrences(of: "\\,", with: ",") } ?? ""
        if value.isEmpty {
            action = .all
        } else if value.hasPrefix("/") || value.hasPrefix("~/") {
            // A regex exception still keeps its URLs' parameters, all of
            // them, rather than letting a plain rule remove what it protects.
            guard isException else { return .skipped(.regex) }
            action = .all
            widened = true
        } else if value.hasPrefix("~") {
            action = .allBut(String(value.dropFirst()))
            if isException { widened = true }
        } else {
            action = .name(value)
        }

        let trimmedPattern = patternText.trimmingCharacters(in: .whitespaces)
        let pattern: URLPattern?
        if trimmedPattern.isEmpty || trimmedPattern == "*" {
            pattern = nil
        } else if trimmedPattern.count > 2, trimmedPattern.hasPrefix("/"), trimmedPattern.hasSuffix("/") {
            return .skipped(.regex)
        } else {
            pattern = URLPattern(trimmedPattern)
        }
        var rule = Rule(action: action, pattern: pattern, domains: domains)

        if isException {
            // An exception for every address would switch the list off.
            if pattern == nil && (domains?.include.isEmpty ?? true), case .all = action { return .skipped(.unsupported) }
            rule.overridesBuiltInNames = !widened && (pattern != nil || !(domains?.include.isEmpty ?? true))
            return .exception(rule, widened: widened)
        }
        if unknownOption { return .skipped(.unsupported) }
        // A rule removing every parameter, or all but one, on every address.
        if pattern == nil && (domains?.include.isEmpty ?? true) {
            if case .name = action {} else { return .skipped(.unsupported) }
        }
        return .block(rule, hostKey: pattern?.hostKey)
    }

    /// The pattern and the options of `body`: the options start at the first
    /// `$` whose tail has a `removeparam` option, so a `$` inside a pattern or
    /// inside a regex value does not end the pattern early. Options are split
    /// on commas not escaped with a backslash.
    private static func splitOptions(_ body: String) -> (String, [String])? {
        var searchStart = body.startIndex
        while let dollar = body[searchStart...].firstIndex(of: "$") {
            let tail = body[body.index(after: dollar)...]
            var options: [String] = []
            var current = ""
            var previous: Character?
            for character in tail {
                if character == ",", previous != "\\" {
                    options.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
                previous = character
            }
            options.append(current)
            if options.contains(where: { $0 == "removeparam" || $0.hasPrefix("removeparam=") }) {
                return (String(body[..<dollar]), options)
            }
            searchStart = body.index(after: dollar)
        }
        return nil
    }
}

// MARK: - Address

/// A page address as the rules see it: the lower-cased URL string and the
/// range of its host.
nonisolated private struct Address {
    let bytes: [UInt8]
    let hostRange: Range<Int>
    let host: String

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var bytes = Array(url.absoluteString.lowercased().utf8)
        guard let schemeEnd = bytes.firstRange(of: Array("://".utf8)) else { return nil }
        var start = schemeEnd.upperBound
        var end = start
        while end < bytes.count, ![UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#")].contains(bytes[end]) {
            end += 1
        }
        if let at = bytes[start..<end].lastIndex(of: UInt8(ascii: "@")) { start = at + 1 }
        var hostEnd = start
        while hostEnd < end, bytes[hostEnd] != UInt8(ascii: ":") { hostEnd += 1 }
        // A fully qualified host's trailing dot is not part of the name, and
        // is dropped from the bytes too, so `||host^` still meets a separator.
        var nameEnd = hostEnd
        if nameEnd > start, bytes[nameEnd - 1] == UInt8(ascii: ".") {
            nameEnd -= 1
            bytes.remove(at: nameEnd)
        }
        guard nameEnd > start else { return nil }
        self.bytes = bytes
        hostRange = start..<nameEnd
        host = String(decoding: bytes[start..<nameEnd], as: UTF8.self)
    }

    /// The host and each of its parent domains (`a.b.example`, `b.example`,
    /// `example`).
    var hostSuffixes: [String] {
        var suffixes = [host]
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty { suffixes.append(String(rest)) }
        }
        return suffixes
    }
}

// MARK: - Domains

/// Whether the rest of a host after a wildcard entity (`amazon.` in
/// `amazon.*`) is a public suffix. Detour has no public suffix list, so this
/// is a bounded approximation: one label of letters (`com`, `de`, `xn--p1ai`),
/// or a common second-level label over a two-letter country code (`co.uk`,
/// `com.au`, `co.jp`). It accepts no host of its own (`amazon.evil.com`
/// is not `amazon.*`), at the cost of a rare real suffix it does not know.
nonisolated func isPublicSuffixLike(_ rest: Substring) -> Bool {
    let labels = rest.split(separator: ".", omittingEmptySubsequences: false)
    func isTopLevel(_ label: Substring) -> Bool {
        label.count >= 2 && (label.allSatisfy { $0.isASCII && $0.isLetter } || label.hasPrefix("xn--"))
    }
    switch labels.count {
    case 1:
        return isTopLevel(labels[0])
    case 2:
        let secondLevel: Set<Substring> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go", "gob",
                                           "nic", "ltd", "plc", "sch", "mil", "nom", "info", "biz", "gen", "web"]
        return secondLevel.contains(labels[0]) && labels[1].count == 2 && labels[1].allSatisfy { $0.isASCII && $0.isLetter }
    default:
        return false
    }
}

/// A `domain=` option: the page's host must be one of `include` (when any)
/// and none of `exclude`, each matching the domain itself or a subdomain.
nonisolated private struct DomainCondition: Sendable {
    struct Domain: Sendable {
        /// Lower-cased, without the `.*` of a wildcard entity.
        let name: String
        /// `amazon.*`: `name` followed by any public suffix.
        let isEntity: Bool

        func matches(host: String) -> Bool {
            guard isEntity else { return host == name || host.hasSuffix("." + name) }
            let prefix = name + "."
            var start = host.startIndex
            while true {
                let candidate = host[start...]
                if candidate.hasPrefix(prefix), isPublicSuffixLike(candidate.dropFirst(prefix.count)) { return true }
                guard let dot = candidate.firstIndex(of: ".") else { return false }
                start = host.index(after: dot)
            }
        }
    }

    let include: [Domain]
    let exclude: [Domain]

    /// Nil for a value this does not read (a regex domain, a wildcard other
    /// than a trailing `.*`).
    init?(_ value: String) {
        var include: [Domain] = []
        var exclude: [Domain] = []
        for item in value.lowercased().split(separator: "|") {
            let negated = item.hasPrefix("~")
            var name = negated ? item.dropFirst() : item
            var isEntity = false
            if name.hasSuffix(".*") {
                name = name.dropLast(2)
                isEntity = true
            }
            guard !name.isEmpty, !name.contains("*"), !name.contains("/") else { return nil }
            let domain = Domain(name: String(name), isEntity: isEntity)
            if negated { exclude.append(domain) } else { include.append(domain) }
        }
        guard !include.isEmpty || !exclude.isEmpty else { return nil }
        self.include = include
        self.exclude = exclude
    }

    func matches(host: String) -> Bool {
        (include.isEmpty || include.contains { $0.matches(host: host) }) && !exclude.contains { $0.matches(host: host) }
    }
}

// MARK: - URL patterns

/// An Adblock URL pattern, matched against the whole lower-cased address.
nonisolated private struct URLPattern: Sendable {
    enum Anchor: Sendable { case none, start, host }
    enum Token: Sendable, Equatable {
        case literal([UInt8])
        /// `*`: any run of characters.
        case wildcard
        /// `^`: one character that is not a letter, digit or `_-.%`, or the
        /// end of the address.
        case separator
        /// The `*` of a wildcard top level domain (`||amazon.*`): the rest of
        /// the host, when it is a public suffix (`isPublicSuffixLike`).
        case publicSuffix
    }

    let anchor: Anchor
    let tokens: [Token]
    let anchoredEnd: Bool
    /// For `||host^`, `||host/…`, `||host:…` and `||host?…`: the host. An
    /// address can match only when its host is this one or a subdomain.
    let hostKey: String?

    init(_ text: String) {
        var text = Substring(text.lowercased())
        var anchor = Anchor.none
        if text.hasPrefix("||") {
            anchor = .host
            text = text.dropFirst(2)
        } else if text.hasPrefix("|") {
            anchor = .start
            text = text.dropFirst()
        }
        var anchoredEnd = false
        if text.hasSuffix("|") {
            anchoredEnd = true
            text = text.dropLast()
        }

        var hostKey: String?
        var tokens: [Token] = []
        var rest = text
        if anchor == .host {
            let isHostCharacter: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.*".contains($0)) }
            let hostPart = rest.prefix(while: isHostCharacter)
            let after = rest.dropFirst(hostPart.count).first
            // `.*` ending the host (`||amazon.*^`, `||audible.*/series/`,
            // `||metro.*`) is a wildcard top level domain; one followed by
            // more of the address (`||amazon.*&linkCode=`) is a plain `*`.
            let endsHost = after.map { "^/:?".contains($0) } ?? true
            if hostPart.hasSuffix(".*"), hostPart.dropLast(2).firstIndex(of: "*") == nil, hostPart.count > 2, endsHost {
                tokens.append(.literal(Array(hostPart.dropLast().utf8)))
                tokens.append(.publicSuffix)
                rest = rest.dropFirst(hostPart.count)
            } else if !hostPart.contains("*"), !hostPart.hasPrefix("."), !hostPart.hasSuffix("."), !hostPart.isEmpty,
                      let after, "^/:?".contains(after) {
                hostKey = String(hostPart)
            }
        }
        var literal: [UInt8] = []
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)) }
            literal = []
        }
        for byte in rest.utf8 {
            switch byte {
            case UInt8(ascii: "*"):
                flush()
                if tokens.last != .wildcard { tokens.append(.wildcard) }
            case UInt8(ascii: "^"):
                flush()
                tokens.append(.separator)
            default:
                literal.append(byte)
            }
        }
        flush()
        self.anchor = anchor
        self.tokens = tokens
        self.anchoredEnd = anchoredEnd
        self.hostKey = hostKey
    }

    func matches(_ address: Address) -> Bool {
        let bytes = address.bytes
        switch anchor {
        case .start:
            return match(0, at: 0, in: address)
        case .host:
            if match(0, at: address.hostRange.lowerBound, in: address) { return true }
            for i in address.hostRange where bytes[i] == UInt8(ascii: ".") {
                if match(0, at: i + 1, in: address) { return true }
            }
            return false
        case .none:
            for start in 0...bytes.count where match(0, at: start, in: address) { return true }
            return false
        }
    }

    private func match(_ index: Int, at position: Int, in address: Address) -> Bool {
        let bytes = address.bytes
        guard index < tokens.count else { return !anchoredEnd || position == bytes.count }
        switch tokens[index] {
        case .literal(let literal):
            guard position + literal.count <= bytes.count,
                  bytes[position..<(position + literal.count)].elementsEqual(literal) else { return false }
            return match(index + 1, at: position + literal.count, in: address)
        case .separator:
            if position == bytes.count { return match(index + 1, at: position, in: address) }
            guard Self.isSeparator(bytes[position]) else { return false }
            return match(index + 1, at: position + 1, in: address)
        case .wildcard:
            if index == tokens.count - 1 && !anchoredEnd { return true }
            for next in position...bytes.count where match(index + 1, at: next, in: address) { return true }
            return false
        case .publicSuffix:
            let host = address.hostRange
            guard host.contains(position) else { return false }
            let rest = String(decoding: bytes[position..<host.upperBound], as: UTF8.self)
            guard isPublicSuffixLike(Substring(rest)) else { return false }
            return match(index + 1, at: host.upperBound, in: address)
        }
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "%"):
            return false
        default:
            return true
        }
    }
}
