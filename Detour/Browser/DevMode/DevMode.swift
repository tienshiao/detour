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
    guard var host = url?.authorityHost?.lowercased() else { return "" }
    // Show a fully-qualified `localhost.` as the host the rule matched.
    if host.count > 1, host.hasSuffix(".") { host.removeLast() }
    return url?.nonDefaultPort.map { "\(host):\($0)" } ?? host
}

/// What a sidebar row draws for dev mode.
enum DevModeRowMarking: Equatable {
    case none
    /// A single tab: the hazard border around the row and `hostLabel` under the title.
    case tab(hostLabel: String)
    /// A split row: the hazard border around each local pane's half, no host line.
    case split(left: Bool, right: Bool)
}

/// What a sidebar row or favourite tile shows for its `DevModeRowMarking`
/// (TASK-197).
struct DevModeRowDisplay: Equatable {
    /// The host line under the title; nil hides it.
    var hostLabel: String?
    /// The hazard border around the whole row (a single tab or a tile), or
    /// around a split row's left half.
    var showsMainBorder: Bool
    /// The hazard border around a split row's right half.
    var showsRightBorder: Bool

    static let hidden = DevModeRowDisplay(hostLabel: nil, showsMainBorder: false, showsRightBorder: false)
}

extension DevModeRowMarking {
    /// Like Arc, only the selected row is bordered; an unselected dev-mode tab
    /// keeps its host line, and an unselected split row (no host line) shows
    /// nothing. The host line never depends on selection, so it doesn't move
    /// when the selection does. `isSelected` is the window's own selection:
    /// a split row is selected when it holds the selected tab, whichever pane
    /// is focused, and a dormant pinned row never is.
    func display(isSelected: Bool) -> DevModeRowDisplay {
        switch self {
        case .none:
            return .hidden
        case .tab(let hostLabel):
            return DevModeRowDisplay(hostLabel: hostLabel, showsMainBorder: isSelected, showsRightBorder: false)
        case .split(let left, let right):
            return DevModeRowDisplay(hostLabel: nil, showsMainBorder: isSelected && left,
                                     showsRightBorder: isSelected && right)
        }
    }
}

/// The site a dev-mode override is stored under (TASK-186.5): the host plus
/// a non-default port, the same string as `devModeHostLabel(for:)`, so two
/// local apps on different ports are separate sites. Nil for a URL that is
/// not `http`/`https` or has no host: such a page is never in dev mode.
func devModeSiteKey(for url: URL?) -> String? {
    guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    let key = devModeHostLabel(for: url)
    return key.isEmpty ? nil : key
}

enum DevMode {
    /// The rule: the site's stored override (TASK-186.5), else the
    /// local-development default (`isLocalDevelopmentURL`).
    static func isActive(url: URL?, override: Bool?) -> Bool {
        override ?? isLocalDevelopmentURL(url)
    }

    /// Whether a page at `url` is in dev mode in `profileID`. Every caller
    /// decides through here. With no profile there is no override to read.
    static func isActive(for url: URL?, profileID: UUID?, store: SiteSettingsStore = .shared) -> Bool {
        isActive(url: url, override: override(for: url, profileID: profileID, store: store))
    }

    /// The site's stored `devMode` value, matched exactly by site key.
    static func override(for url: URL?, profileID: UUID?, store: SiteSettingsStore = .shared) -> Bool? {
        guard let profileID, let key = devModeSiteKey(for: url) else { return nil }
        return store.override(.devMode, forSite: key, profileID: profileID)
    }

    /// A tab follows its current URL; a sleeping tab keeps its stored one.
    static func isActive(for tab: BrowserTab, store: SiteSettingsStore = .shared) -> Bool {
        isActive(for: tab.url, profileID: tab.owningProfile?.id, store: store)
    }

    /// The popover's switch: stores `isOn` for `url`'s site, or removes the
    /// site's row when `isOn` is what the URL rule gives anyway, so no
    /// redundant override is kept and the site follows the rule again. The
    /// rule depends only on the host, so it is the same for every page of
    /// one site key.
    static func setEnabled(_ isOn: Bool, for url: URL?, profileID: UUID, store: SiteSettingsStore = .shared) {
        guard let key = devModeSiteKey(for: url) else { return }
        if isOn == isLocalDevelopmentURL(url) {
            store.clear(.devMode, sites: [key], profileID: profileID)
        } else {
            store.set(.devMode, site: key, to: isOn, profileID: profileID)
        }
    }

    static func rowMarking(for url: URL?, profileID: UUID?, store: SiteSettingsStore = .shared) -> DevModeRowMarking {
        isActive(for: url, profileID: profileID, store: store) ? .tab(hostLabel: devModeHostLabel(for: url)) : .none
    }

    static func splitRowMarking(left: URL?, right: URL?, profileID: UUID?,
                                store: SiteSettingsStore = .shared) -> DevModeRowMarking {
        let left = isActive(for: left, profileID: profileID, store: store)
        let right = isActive(for: right, profileID: profileID, store: store)
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
