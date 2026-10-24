import Foundation
import Darwin

// Dev mode (TASK-186): a tab whose page is a local development server gets an
// "under construction" sidebar row (and, later, an in-page dev toolbar).
//
// Pure so the rule is unit-testable (`DevModeTests`). It is deliberately
// separate from `AddressInputClassifier`, which decides how typed text becomes
// a URL; this decides what a URL a tab is already showing means.

/// Whether `url` is a local development URL: an `http`/`https` URL whose host
/// is `localhost`, a subdomain of `localhost`, an IPv4 loopback address
/// (127.0.0.0/8, in any form a browser's URL parser accepts), `[::1]`,
/// `0.0.0.0`, or a subdomain of the reserved `.test` TLD.
///
/// LAN addresses and `.local` names are not: they are as often a printer or
/// a NAS as a dev server (decision, TASK-186.1). Any site can be put in dev
/// mode by hand instead (TASK-186.5).
func isLocalDevelopmentURL(_ url: URL?) -> Bool {
    guard let url, let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          var host = url.host?.lowercased(), !host.isEmpty else { return false }
    // A fully-qualified `localhost.` is the same host.
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return false }

    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    // `.test` itself is a TLD, not a site.
    if host.hasSuffix(".test") { return true }
    // Foundation strips the brackets from an IPv6 host.
    if host.contains(":") { return isIPv6Loopback(host) }
    if let address = parseIPv4Address(host) {
        return address >> 24 == 127 || address == 0
    }
    return false
}

/// The host a dev-mode row shows under its title: `host:port` when the port is
/// not the scheme's default, else the host. IPv6 hosts are bracketed. Empty
/// when the URL has no host.
func devModeHostLabel(for url: URL?) -> String {
    guard let url, let rawHost = url.host, !rawHost.isEmpty else { return "" }
    var lowered = rawHost.lowercased()
    // Show a fully-qualified `localhost.` as the host the rule matched.
    if lowered.count > 1, lowered.hasSuffix(".") { lowered.removeLast() }
    let host = lowered.contains(":") ? "[\(lowered)]" : lowered
    guard let port = url.port else { return host }
    let defaultPort: Int? = switch url.scheme?.lowercased() {
    case "http": 80
    case "https": 443
    default: nil
    }
    return port == defaultPort ? host : "\(host):\(port)"
}

/// What a sidebar row draws for dev mode.
enum DevModeRowMarking: Equatable {
    case none
    /// A single tab: the hazard border around the row and `hostLabel` under the title.
    case tab(hostLabel: String)
    /// A split row: the hazard border around each local pane's half, no host line.
    case split(left: Bool, right: Bool)
}

enum DevMode {
    /// Whether a page at `url` is in dev mode. Every caller decides through
    /// here, so the per-site override (TASK-186.5) is added in one place:
    /// effective state = the site's override, else `isLocalDevelopmentURL`.
    static func isActive(for url: URL?) -> Bool {
        isLocalDevelopmentURL(url)
    }

    /// A tab follows its current URL; a sleeping tab keeps its stored one.
    static func isActive(for tab: BrowserTab) -> Bool {
        isActive(for: tab.url)
    }

    static func rowMarking(for url: URL?) -> DevModeRowMarking {
        isActive(for: url) ? .tab(hostLabel: devModeHostLabel(for: url)) : .none
    }

    static func splitRowMarking(left: URL?, right: URL?) -> DevModeRowMarking {
        let left = isActive(for: left), right = isActive(for: right)
        return left || right ? .split(left: left, right: right) : .none
    }
}

extension PinnedEntry {
    /// The URL dev mode reads: the live tab's page, else the pinned URL.
    var devModeURL: URL? { tab?.url ?? pinnedURL }
}

extension Favorite {
    /// The URL dev mode reads: the live tab's page, else the favourite's URL.
    var devModeURL: URL? { tab?.url ?? url }
}

/// `::1` in any spelling (`0:0:0:0:0:0:0:1`, `0000::0001`). The IPv4-mapped
/// `::ffff:127.0.0.1` does not count.
private func isIPv6Loopback(_ host: String) -> Bool {
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
    return withUnsafeBytes(of: &address) { bytes in
        bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}

/// The WHATWG URL Standard's IPv4 parser: one to four dot-separated parts,
/// each decimal, `0x` hex or leading-`0` octal, the last filling the remaining
/// bytes (`127.1` is 127.0.0.1, `2130706433` and `0x7f000001` are too). Nil
/// when `host` is not an IPv4 address.
private func parseIPv4Address(_ host: String) -> UInt32? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    var numbers: [UInt64] = []
    for part in parts {
        guard let number = parseIPv4Number(part) else { return nil }
        numbers.append(number)
    }
    guard numbers.dropLast().allSatisfy({ $0 <= 255 }),
          numbers.last! < (1 << (8 * UInt64(5 - numbers.count))) else { return nil }
    var address = numbers.last!
    for (index, number) in numbers.dropLast().enumerated() {
        address += number << (8 * UInt64(3 - index))
    }
    return UInt32(address)
}

private func parseIPv4Number(_ part: Substring) -> UInt64? {
    guard !part.isEmpty else { return nil }
    var digits = part
    var radix = 10
    if digits.count >= 2, digits.hasPrefix("0x") || digits.hasPrefix("0X") {
        digits = digits.dropFirst(2)
        radix = 16
    } else if digits.count >= 2, digits.hasPrefix("0") {
        digits = digits.dropFirst()
        radix = 8
    }
    // Leading zeros carry no value and the standard allows any number of
    // them, so drop them before the length bound. `0x` alone is zero too.
    let significant = digits.drop(while: { $0 == "0" })
    if significant.isEmpty { return 0 }
    // Bounded so a long digit string cannot overflow; anything this long is
    // past 32 bits whatever its radix.
    guard significant.count <= 12, significant.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return UInt64(significant, radix: radix)
}
