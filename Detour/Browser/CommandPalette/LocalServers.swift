import Foundation

// Local servers in the command palette (TASK-411): the HTTP servers the
// user's own processes are running on this Mac, each labelled with the
// directory it was started from. `LocalServerScanner` reads them; these are
// the pure rules for which ones count, how they are named and which typed
// text they answer, kept apart so they can be tested without a socket.

/// A listening TCP socket of one of the user's processes, as the scan reads it.
nonisolated struct LocalListener: Hashable, Sendable {
    var pid: Int32
    var port: Int
    /// The address it is bound to, as `inet_ntop` prints it (`0.0.0.0`,
    /// `127.0.0.1`, `::`, `::1`, or a LAN address).
    var address: String
    /// The process's executable, empty when it could not be read.
    var executablePath: String
    /// The process's working directory, empty when it could not be read.
    var directory: String
}

/// A local server the palette offers: a project's listener that answered HTTP.
nonisolated struct LocalServer: Hashable, Sendable {
    var port: Int
    /// It completed a TLS handshake (a self-signed certificate is fine).
    var isHTTPS: Bool
    /// The executable's file name (`node`, `ruby`, `python3.12`).
    var processName: String
    /// The working directory of the process serving it.
    var directory: String
    /// `127.0.0.1` reaches it: it listens on an IPv4 loopback or any address,
    /// not on `::1` alone.
    var listensOnIPv4: Bool

    /// Its root, on `host` (`localhost` unless the typed text named `127.0.0.1`).
    func url(host: String = "localhost") -> String {
        "\(isHTTPS ? "https" : "http")://\(host):\(port)/"
    }
}

/// Which local servers the typed text offers, and how.
nonisolated struct LocalServerMatch: Equatable, Sendable {
    /// The matching servers, best first.
    var servers: [LocalServer]
    /// The host the text is completing (`localhost` or `127.0.0.1`): the best
    /// server can then be the top hit, completing the field to `host:port`.
    /// Nil for a bare port, `0.0.0.0` or a folder name: those rows go after
    /// the verbatim row, so Return still does what the text alone does.
    var completingHost: String?

    static let none = LocalServerMatch(servers: [], completingHost: nil)
}

nonisolated enum LocalServerRules {

    /// The dynamic (ephemeral) ports. Apps and tools that pick a free port at
    /// random land here (Claude Code's IDE bridge, editor language servers);
    /// development servers use fixed, lower ports.
    static let dynamicPorts = 49152...65535

    /// Whether a listener may be a project's development server, worth
    /// probing and offering. Measured against what was listening on the
    /// user's Mac (2026-11-18): two `node` servers started from project
    /// folders and a tool in `~/Projects` stayed; macOS services, Discord,
    /// Stream Deck and editor helpers (started from `/`), Docker's port
    /// forwards and Tailscale (installed apps) and Claude Code's bridges
    /// (dynamic ports) went.
    ///
    /// "Installed app" means the executable lives under `/Applications`,
    /// `~/Applications` or `/System`, not merely inside some `.app`: Homebrew's
    /// and the system's `python3` run from a `Python.app` in their framework,
    /// and `python3 -m http.server` must still count.
    static func isProjectServer(_ listener: LocalListener, home: String = NSHomeDirectory()) -> Bool {
        guard !listener.directory.isEmpty, listener.directory != "/" else { return false }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let appFolders = ["/Applications/", "/System/", home + "/Applications/"]
        // Xcode's toolchain is a developer's, though it lives in an app:
        // with Xcode selected, `/usr/bin/python3` runs from
        // `/Applications/Xcode.app/Contents/Developer/.../Python.app`.
        let isDeveloperTool = listener.executablePath.contains(".app/Contents/Developer/")
        guard isDeveloperTool || !appFolders.contains(where: listener.executablePath.hasPrefix) else { return false }
        guard !dynamicPorts.contains(listener.port) else { return false }
        return reachableAddress(forBound: listener.address) != nil
    }

    /// The loopback address that reaches a socket bound to `address`, or nil
    /// when localhost cannot reach it (bound to a LAN address only).
    static func reachableAddress(forBound address: String) -> String? {
        switch address {
        case "0.0.0.0", "::ffff:0.0.0.0": return "127.0.0.1"
        case "::", "::1": return "::1"
        default:
            if address.hasPrefix("127.") || address.hasPrefix("::ffff:127.") { return "127.0.0.1" }
            return nil
        }
    }

    /// One candidate per port: the listener the probe connects to, and
    /// whether `127.0.0.1` reaches the port. A port has several listeners
    /// when it is bound on IPv4 and IPv6, or shared by forked workers; the
    /// lowest pid (the parent) is the one named, so the label does not change
    /// from one scan to the next.
    struct Candidate: Hashable, Sendable {
        var listener: LocalListener
        /// The address the probe connects to.
        var probeAddress: String
        var listensOnIPv4: Bool
    }

    static func candidates(from listeners: [LocalListener]) -> [Candidate] {
        let byPort = Dictionary(grouping: listeners.filter { isProjectServer($0) }, by: \.port)
        return byPort.keys.sorted().compactMap { port in
            let group = byPort[port] ?? []
            guard let named = group.min(by: { ($0.pid, $0.address) < ($1.pid, $1.address) }) else { return nil }
            let addresses = Set(group.compactMap { reachableAddress(forBound: $0.address) })
            let ipv4 = addresses.contains("127.0.0.1")
            return Candidate(listener: named, probeAddress: ipv4 ? "127.0.0.1" : "::1", listensOnIPv4: ipv4)
        }
    }

    // MARK: - Names

    /// `directory` with the home folder written `~`.
    static func abbreviated(_ directory: String, home: String) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return directory }
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    /// The folder each server's rows show, by port: the last component of its
    /// directory, or as many trailing components as it takes to tell it
    /// apart from the other servers' (`website`, `client/website`). A server
    /// started from the home folder is `~`; one with no directory is named by
    /// its process.
    static func folderLabels(for servers: [LocalServer], home: String) -> [Int: String] {
        // A scan has one server per port; keep the first should two share one.
        let components: [Int: [String]] = Dictionary(servers.map { server in
            let path = abbreviated(server.directory, home: home)
            return (server.port, path.split(separator: "/").map(String.init))
        }, uniquingKeysWith: { first, _ in first })
        var labels: [Int: String] = [:]
        for server in servers {
            let mine = components[server.port] ?? []
            guard !mine.isEmpty else {
                labels[server.port] = server.processName
                continue
            }
            // Servers in other directories whose label could collide; two
            // servers in one directory share a label, which is right.
            let others = servers
                .filter { $0.port != server.port && $0.directory != server.directory }
                .compactMap { components[$0.port] }
            var count = 1
            while count < mine.count,
                  others.contains(where: { $0.suffix(count) == mine.suffix(count) }) {
                count += 1
            }
            labels[server.port] = mine.suffix(count).joined(separator: "/")
        }
        return labels
    }

    // MARK: - URLs

    /// The port of `url` when its host is this Mac (`localhost`, an IPv4
    /// loopback, `[::1]`, `0.0.0.0`), with the scheme's default when it names
    /// none; nil for any other URL. A local server's rows are matched to the
    /// server by this port.
    static func loopbackPort(ofURL url: String) -> Int? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        let isLoopback = host == "localhost" || host == "::1" || host == "0.0.0.0" || isIPv4Loopback(host)
        guard isLoopback else { return nil }
        return components.port ?? (scheme == "https" ? 443 : 80)
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
                && (Int(part) ?? 256) <= 255
        }
    }

    // MARK: - Matching typed text

    /// The hosts typed text can complete to a server on, and how much of
    /// each must be typed first (`loc`, `127.`), so `l` alone does not list
    /// every server.
    private static let completingHosts: [(host: String, minimum: Int)] = [("localhost", 3), ("127.0.0.1", 4)]
    /// `0.0.0.0` lists the servers but never completes to itself: it is a
    /// bind address, not one to browse to, so its rows open `localhost`.
    private static let listingHosts: [(host: String, minimum: Int)] = [("0.0.0.0", 4)]
    /// A folder name needs this many letters before it matches.
    static let minimumFolderQuery = 2

    /// The servers `query` (the trimmed field text) offers.
    ///
    /// - A prefix of `localhost:` or `127.0.0.1:` and then of a port: the
    ///   servers whose port it prefixes, completing (`localhost:51` →
    ///   `localhost:5173`); `127.0.0.1` only reaches servers on IPv4.
    /// - A prefix of `0.0.0.0:` and a port, or digits alone (`51`): the
    ///   servers whose port it prefixes, listed, not completing.
    /// - Otherwise, two or more letters that start the server's folder name
    ///   or one of its words (`web` for `website`, `site` for `my-site`): listed.
    ///
    /// Servers come lowest port first, except that a port typed in full
    /// comes before the longer ports it prefixes.
    static func match(_ query: String, servers: [LocalServer], home: String = NSHomeDirectory()) -> LocalServerMatch {
        let q = query.lowercased()
        guard !q.isEmpty, !servers.isEmpty, !q.contains(where: \.isWhitespace) else { return .none }

        func byPort(_ portPrefix: Substring, ipv4Only: Bool) -> [LocalServer] {
            guard portPrefix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return [] }
            return servers
                .filter { (!ipv4Only || $0.listensOnIPv4) && String($0.port).hasPrefix(portPrefix) }
                .sorted { a, b in
                    let aExact = String(a.port) == portPrefix, bExact = String(b.port) == portPrefix
                    return aExact != bExact ? aExact : a.port < b.port
                }
        }

        for (host, minimum) in completingHosts + listingHosts {
            let full = host + ":"
            let completes = completingHosts.contains { $0.host == host }
            // Only `127.0.0.1` itself needs IPv4: `0.0.0.0` rows open `localhost`.
            let ipv4Only = host == "127.0.0.1"
            if q.count >= minimum, full.hasPrefix(q) {
                let found = byPort("", ipv4Only: ipv4Only)
                return found.isEmpty ? .none : LocalServerMatch(servers: found, completingHost: completes ? host : nil)
            }
            if q.hasPrefix(full) {
                let found = byPort(q.dropFirst(full.count), ipv4Only: ipv4Only)
                return found.isEmpty ? .none : LocalServerMatch(servers: found, completingHost: completes ? host : nil)
            }
        }

        if q.count <= 5, q.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return LocalServerMatch(servers: byPort(Substring(q), ipv4Only: false), completingHost: nil)
        }

        guard q.count >= minimumFolderQuery else { return .none }
        let found = servers.filter { server in
            let folder = abbreviated(server.directory, home: home).split(separator: "/").last.map(String.init)
                ?? server.processName
            let name = folder.lowercased()
            if name.hasPrefix(q) { return true }
            return name.split(whereSeparator: { "-_. ".contains($0) }).contains { $0.hasPrefix(q) }
        }.sorted { $0.port < $1.port }
        return LocalServerMatch(servers: found, completingHost: nil)
    }
}
