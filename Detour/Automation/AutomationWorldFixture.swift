import Foundation

/// A demo world for the endpoint's `seed_world` (TASK-228.3): a JSON file a
/// capture script hands to an empty test run. The format is documented in
/// `wiki/features/automation-endpoint.md` ("Seeding a world"); an example is
/// `docs/capture/demo-world.json`.
///
/// Reading is pure: the whole file is checked and turned into a plan before
/// anything in the store changes, so a malformed fixture changes nothing.
/// Every error names where in the file it is (`spaces[1].pinned[2].url`).
/// Titles and icons come from the file, so nothing has to load first: pinned
/// entries and favourites arrive dormant and tabs asleep, as an Arc import's
/// do (the plan is carried out by `TabStore.applyArcImport`).
struct AutomationWorldFixture {

    /// What is wrong with a fixture, and where.
    struct Problem: Error, Equatable, CustomStringConvertible {
        var path: String
        var message: String
        var description: String { path.isEmpty ? message : "\(path): \(message)" }
    }

    /// Everything `seed_world` does, worked out from the file.
    struct Plan {
        /// Profiles, spaces, folders, pinned entries, favourites and tabs.
        var world = ArcImportPlan()
        /// The first fixture profile is the existing default one, renamed:
        /// a profile with spaces is never deleted, and a new one would leave
        /// the default behind.
        var defaultProfileName: String
        /// Space id → the tab its window selects on entry.
        var selectedTabs: [UUID: UUID] = [:]
        /// Space id → its visits.
        var history: [(spaceID: UUID, visits: [HistoryDatabase.ImportedVisit])] = []
        var routes: [LinkRoute] = []
        var activeSpaceID: UUID
        /// For the result: how many of each.
        var counts: [String: Int] = [:]
    }

    static let currentVersion = 1
    /// Deeper than any sidebar a capture needs; keeps a runaway file bounded.
    static let maximumFolderDepth = 16

    /// Reads `data` as a fixture for a store whose default profile is
    /// `defaultProfileID`. Visit times are `now` minus each visit's age.
    static func plan(from data: Data, defaultProfileID: UUID, now: Date = Date(),
                     makeID: @escaping () -> UUID = UUID.init) throws(Problem) -> Plan {
        let root: JSONValue
        do {
            root = try JSONValue.parse(data)
        } catch {
            throw Problem(path: "", message: "Not JSON: \(error)")
        }
        var reader = Reader(defaultProfileID: defaultProfileID, now: now, makeID: makeID)
        return try reader.read(root)
    }

    // MARK: - Reading

    private struct Reader {
        let defaultProfileID: UUID
        let now: Date
        let makeID: () -> UUID

        var profileIDs: [String: UUID] = [:]
        var spaceIDs: [String: UUID] = [:]
        var plan: Plan!
        /// Next sort order per (space, parent folder) level.
        var orders: [String: Int] = [:]

        init(defaultProfileID: UUID, now: Date, makeID: @escaping () -> UUID) {
            self.defaultProfileID = defaultProfileID
            self.now = now
            self.makeID = makeID
        }

        mutating func read(_ root: JSONValue) throws(Problem) -> Plan {
            let top = try object(root, at: "", keys: ["version", "profiles", "spaces", "history", "link_routes",
                                                       "active_space"])
            let version = try int(top["version"], at: "version") ?? currentVersion
            guard version == currentVersion else {
                throw Problem(path: "version", message: "Only version \(currentVersion) is read, got \(version)")
            }

            // Profiles first: spaces name them.
            let profiles = try array(top["profiles"], at: "profiles", required: true)
            guard !profiles.isEmpty else { throw Problem(path: "profiles", message: "Needs at least one profile") }
            var favoriteLists: [(UUID, [JSONValue], String)] = []
            for (index, value) in profiles.enumerated() {
                let path = "profiles[\(index)]"
                let fields = try object(value, at: path, keys: ["name", "favorites"])
                let profileName = try name(fields["name"], at: "\(path).name")
                guard profileName.caseInsensitiveCompare("Private") != .orderedSame else {
                    throw Problem(path: "\(path).name", message: "\"Private\" is the built-in Private profile")
                }
                guard profileIDs[profileName.lowercased()] == nil else {
                    throw Problem(path: "\(path).name", message: "Another profile is called \(profileName)")
                }
                let id = index == 0 ? defaultProfileID : makeID()
                profileIDs[profileName.lowercased()] = id
                if index == 0 {
                    plan = Plan(defaultProfileName: profileName, activeSpaceID: UUID())
                } else {
                    plan.world.profiles.append(.init(id: id, name: profileName))
                }
                favoriteLists.append((id, try array(fields["favorites"], at: "\(path).favorites"), "\(path).favorites"))
            }
            for (profileID, favorites, path) in favoriteLists {
                for (index, value) in favorites.enumerated() {
                    let page = try page(value, at: "\(path)[\(index)]", extraKeys: [])
                    plan.world.favorites.append(.init(id: makeID(), profileID: profileID, url: page.url,
                                                      title: page.title, faviconURL: page.faviconURL))
                }
            }

            // Spaces: names first, so routes and history can name any of them.
            let spaces = try array(top["spaces"], at: "spaces", required: true)
            guard !spaces.isEmpty else { throw Problem(path: "spaces", message: "Needs at least one space") }
            var spaceFields: [(UUID, [String: JSONValue], String)] = []
            for (index, value) in spaces.enumerated() {
                let path = "spaces[\(index)]"
                let fields = try object(value, at: path, keys: ["name", "emoji", "color", "profile", "pinned", "tabs"])
                let spaceName = try name(fields["name"], at: "\(path).name")
                guard spaceIDs[spaceName.lowercased()] == nil else {
                    throw Problem(path: "\(path).name", message: "Another space is called \(spaceName)")
                }
                let emoji = try name(fields["emoji"], at: "\(path).emoji")
                let color = try color(fields["color"], at: "\(path).color")
                let profileName = try name(fields["profile"], at: "\(path).profile")
                guard let profileID = profileIDs[profileName.lowercased()] else {
                    throw Problem(path: "\(path).profile", message: "No profile is called \(profileName)")
                }
                let id = makeID()
                spaceIDs[spaceName.lowercased()] = id
                plan.world.spaces.append(.init(id: id, name: spaceName, emoji: emoji, colorHex: color, profileID: profileID))
                spaceFields.append((id, fields, path))
            }
            for (spaceID, fields, path) in spaceFields {
                for (index, value) in try array(fields["pinned"], at: "\(path).pinned").enumerated() {
                    try pinnedItem(value, at: "\(path).pinned[\(index)]", spaceID: spaceID, folderID: nil, depth: 0)
                }
                for (index, value) in try array(fields["tabs"], at: "\(path).tabs").enumerated() {
                    try tabItem(value, at: "\(path).tabs[\(index)]", spaceID: spaceID)
                }
            }

            for (index, value) in try array(top["history"], at: "history").enumerated() {
                try historyItem(value, at: "history[\(index)]")
            }
            for (index, value) in try array(top["link_routes"], at: "link_routes").enumerated() {
                try route(value, at: "link_routes[\(index)]")
            }

            if let active = top["active_space"] {
                let activeName = try name(active, at: "active_space")
                guard let id = spaceIDs[activeName.lowercased()] else {
                    throw Problem(path: "active_space", message: "No space is called \(activeName)")
                }
                plan.activeSpaceID = id
            } else {
                plan.activeSpaceID = plan.world.spaces[0].id
            }

            plan.counts = [
                "profiles": profiles.count,
                "spaces": plan.world.spaces.count,
                "folders": plan.world.folders.count,
                "pinned": plan.world.pinnedEntries.count,
                "favorites": plan.world.favorites.count,
                "tabs": plan.world.tabs.count,
                "history_visits": plan.history.reduce(0) { $0 + $1.visits.count },
                "link_routes": plan.routes.count,
            ]
            return plan
        }

        // MARK: Items

        /// A page, a folder or a split among a space's pinned items.
        mutating func pinnedItem(_ value: JSONValue, at path: String, spaceID: UUID, folderID: UUID?,
                                 depth: Int) throws(Problem) {
            let fields = try object(value, at: path, keys: nil)
            if fields["folder"] != nil {
                let folder = try object(value, at: path, keys: ["folder", "collapsed", "items"])
                guard depth < maximumFolderDepth else {
                    throw Problem(path: path, message: "Folders nest at most \(maximumFolderDepth) deep")
                }
                let id = makeID()
                plan.world.folders.append(.init(id: id, spaceID: spaceID, name: try name(folder["folder"], at: "\(path).folder"),
                                                parentID: folderID, sortOrder: takeOrder(spaceID, folderID),
                                                isCollapsed: try bool(folder["collapsed"], at: "\(path).collapsed") ?? false))
                for (index, child) in try array(folder["items"], at: "\(path).items").enumerated() {
                    try pinnedItem(child, at: "\(path).items[\(index)]", spaceID: spaceID, folderID: id, depth: depth + 1)
                }
            } else if fields["split"] != nil {
                let (pages, fraction) = try split(value, at: path)
                let group = makeID()
                for page in pages {
                    plan.world.pinnedEntries.append(.init(id: makeID(), spaceID: spaceID, url: page.url, title: page.title,
                                                          folderID: folderID, sortOrder: takeOrder(spaceID, folderID),
                                                          splitGroupID: group, splitFraction: fraction,
                                                          faviconURL: page.faviconURL))
                }
            } else {
                let page = try page(value, at: path, extraKeys: [])
                plan.world.pinnedEntries.append(.init(id: makeID(), spaceID: spaceID, url: page.url, title: page.title,
                                                      folderID: folderID, sortOrder: takeOrder(spaceID, folderID),
                                                      faviconURL: page.faviconURL))
            }
        }

        /// A page or a split among a space's normal tabs; `selected` on one
        /// picks the tab the window shows.
        mutating func tabItem(_ value: JSONValue, at path: String, spaceID: UUID) throws(Problem) {
            let fields = try object(value, at: path, keys: nil)
            var added: [(UUID, Bool)] = []
            if fields["split"] != nil {
                let (pages, fraction) = try split(value, at: path)
                let group = makeID()
                for page in pages {
                    let id = makeID()
                    plan.world.tabs.append(.init(id: id, spaceID: spaceID, url: page.url, title: page.title,
                                                 splitGroupID: group, splitFraction: fraction,
                                                 faviconURL: page.faviconURL))
                    added.append((id, page.selected))
                }
            } else {
                let page = try page(value, at: path, extraKeys: ["selected"])
                let id = makeID()
                plan.world.tabs.append(.init(id: id, spaceID: spaceID, url: page.url, title: page.title,
                                             faviconURL: page.faviconURL))
                added.append((id, page.selected))
            }
            for (id, selected) in added where selected {
                guard plan.selectedTabs[spaceID] == nil else {
                    throw Problem(path: path, message: "Another tab of the space is already selected")
                }
                plan.selectedTabs[spaceID] = id
            }
        }

        mutating func historyItem(_ value: JSONValue, at path: String) throws(Problem) {
            let fields = try object(value, at: path, keys: ["url", "title", "space", "ago", "typed"])
            let url = try webURL(fields["url"], at: "\(path).url", required: true)!
            let title = try string(fields["title"], at: "\(path).title")
            let spaceName = try name(fields["space"], at: "\(path).space")
            guard let spaceID = spaceIDs[spaceName.lowercased()] else {
                throw Problem(path: "\(path).space", message: "No space is called \(spaceName)")
            }
            let typed = try bool(fields["typed"], at: "\(path).typed") ?? false
            let ages = try array(fields["ago"], at: "\(path).ago", required: true)
            guard !ages.isEmpty else { throw Problem(path: "\(path).ago", message: "Needs at least one visit") }
            var visits: [HistoryDatabase.ImportedVisit] = []
            for (index, age) in ages.enumerated() {
                let seconds = try Self.age(age, at: "\(path).ago[\(index)]")
                guard seconds < HistoryDatabase.visitRetention else {
                    throw Problem(path: "\(path).ago[\(index)]",
                                  message: "Older than history keeps visits (\(Int(HistoryDatabase.visitRetention / 86400)) days)")
                }
                visits.append(.init(url: url.absoluteString, title: title,
                                    visitTime: now.timeIntervalSince1970 - seconds, isTyped: typed))
            }
            if let index = plan.history.firstIndex(where: { $0.spaceID == spaceID }) {
                plan.history[index].visits += visits
            } else {
                plan.history.append((spaceID, visits))
            }
        }

        mutating func route(_ value: JSONValue, at path: String) throws(Problem) {
            let fields = try object(value, at: path, keys: ["match", "pattern", "source_app", "target"])
            var match: LinkRouteMatch?
            if let kindValue = fields["match"] {
                let kind: LinkRouteMatchKind
                switch try string(kindValue, at: "\(path).match") {
                case "is_equal_to": kind = .isEqualTo
                case "contains": kind = .contains
                case "domain_is": kind = .domainIs
                case let other:
                    throw Problem(path: "\(path).match",
                                  message: "match is is_equal_to, contains or domain_is, got \(other ?? "null")")
                }
                match = LinkRouteMatch(kind: kind, pattern: try string(fields["pattern"], at: "\(path).pattern") ?? "")
            } else if fields["pattern"] != nil {
                throw Problem(path: "\(path).pattern", message: "pattern needs match")
            }
            let sourceApp = try string(fields["source_app"], at: "\(path).source_app")
            let targetName = try name(fields["target"], at: "\(path).target")
            let target: LinkRouteTarget
            switch targetName {
            case "most_recent_space": target = .mostRecentSpace
            case "private_window": target = .privateWindow
            case "quarantine": target = .quarantine
            case "quick_detour": target = .quickDetour
            default:
                guard targetName.hasPrefix("space:") else {
                    throw Problem(path: "\(path).target", message: "target is space:<name>, most_recent_space, "
                                  + "private_window, quarantine or quick_detour, got \(targetName)")
                }
                let spaceName = String(targetName.dropFirst("space:".count))
                guard let id = spaceIDs[spaceName.lowercased()] else {
                    throw Problem(path: "\(path).target", message: "No space is called \(spaceName)")
                }
                target = .space(id)
            }
            let route = LinkRoute(id: makeID(), match: match, sourceApp: sourceApp, target: target,
                                  sortOrder: plan.routes.count)
            let context = LinkRouteContext(spaceIDs: Set(spaceIDs.values), privateSpaceIDs: [])
            if let problem = linkRouteProblems(route, context: context).first {
                throw Problem(path: path, message: "The route cannot be saved: \(problem)")
            }
            plan.routes.append(route)
        }

        // MARK: Parts

        struct Page {
            var url: URL
            var title: String
            var faviconURL: URL?
            var selected: Bool
        }

        func page(_ value: JSONValue, at path: String, extraKeys: Set<String>) throws(Problem) -> Page {
            let fields = try object(value, at: path, keys: Set(["url", "title", "favicon_url"]).union(extraKeys))
            let url = try webURL(fields["url"], at: "\(path).url", required: true)!
            let title = try string(fields["title"], at: "\(path).title")?.trimmingCharacters(in: .whitespaces)
            return Page(url: url, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? url.absoluteString,
                        faviconURL: try webURL(fields["favicon_url"], at: "\(path).favicon_url", required: false),
                        selected: try bool(fields["selected"], at: "\(path).selected") ?? false)
        }

        /// `{"split": [page, page], "fraction": 0.5}`: two panes, the first
        /// on the left taking `fraction` of the width.
        func split(_ value: JSONValue, at path: String) throws(Problem) -> ([Page], Double?) {
            let fields = try object(value, at: path, keys: ["split", "fraction"])
            let panes = try array(fields["split"], at: "\(path).split", required: true)
            guard panes.count == 2 else {
                throw Problem(path: "\(path).split", message: "A split has exactly two pages, got \(panes.count)")
            }
            var pages: [Page] = []
            for (index, pane) in panes.enumerated() {
                pages.append(try page(pane, at: "\(path).split[\(index)]", extraKeys: ["selected"]))
            }
            var fraction: Double?
            if let given = fields["fraction"] {
                guard let number = given.doubleValue, number > 0.1, number < 0.9 else {
                    throw Problem(path: "\(path).fraction", message: "fraction is a number between 0.1 and 0.9")
                }
                fraction = number
            }
            return (pages, fraction)
        }

        mutating func takeOrder(_ spaceID: UUID, _ folderID: UUID?) -> Int {
            let key = "\(spaceID.uuidString)/\(folderID?.uuidString ?? "-")"
            let order = orders[key, default: 0]
            orders[key] = order + 1
            return order
        }

        // MARK: Values

        /// An object, with only `keys` allowed (nil: any), so a misspelt
        /// field fails instead of being ignored.
        func object(_ value: JSONValue?, at path: String, keys: Set<String>?) throws(Problem) -> [String: JSONValue] {
            guard let fields = value?.objectValue else {
                throw Problem(path: path, message: "Expected an object")
            }
            if let keys, let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
                throw Problem(path: path.isEmpty ? unknown : "\(path).\(unknown)",
                              message: "Unknown field (allowed: \(keys.sorted().joined(separator: ", ")))")
            }
            return fields
        }

        func array(_ value: JSONValue?, at path: String, required: Bool = false) throws(Problem) -> [JSONValue] {
            guard let value, value != .null else {
                if required { throw Problem(path: path, message: "Missing") }
                return []
            }
            guard let values = value.arrayValue else { throw Problem(path: path, message: "Expected an array") }
            return values
        }

        func string(_ value: JSONValue?, at path: String) throws(Problem) -> String? {
            guard let value, value != .null else { return nil }
            guard let string = value.stringValue else { throw Problem(path: path, message: "Expected a string") }
            return string
        }

        /// A required, non-blank string.
        func name(_ value: JSONValue?, at path: String) throws(Problem) -> String {
            guard let string = try string(value, at: path)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else {
                throw Problem(path: path, message: "Missing or blank")
            }
            return string
        }

        func int(_ value: JSONValue?, at path: String) throws(Problem) -> Int? {
            guard let value, value != .null else { return nil }
            guard let number = value.intValue else { throw Problem(path: path, message: "Expected an integer") }
            return number
        }

        func bool(_ value: JSONValue?, at path: String) throws(Problem) -> Bool? {
            guard let value, value != .null else { return nil }
            guard let flag = value.boolValue else { throw Problem(path: path, message: "Expected true or false") }
            return flag
        }

        /// Six hex digits, with or without a leading #, stored upper-case.
        func color(_ value: JSONValue?, at path: String) throws(Problem) -> String {
            var hex = try name(value, at: path)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
                throw Problem(path: path, message: "A colour is six hex digits such as FF7600")
            }
            return hex.uppercased()
        }

        /// An http(s) URL with a host.
        func webURL(_ value: JSONValue?, at path: String, required: Bool) throws(Problem) -> URL? {
            guard let text = try string(value, at: path) else {
                if required { throw Problem(path: path, message: "Missing") }
                return nil
            }
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host() != nil else {
                throw Problem(path: path, message: "Expected an http or https URL, got \(text)")
            }
            return url
        }

        /// How long ago a visit was: seconds, or a string such as "90s",
        /// "15m", "2h", "3d", "1w".
        static func age(_ value: JSONValue, at path: String) throws(Problem) -> TimeInterval {
            if let seconds = value.doubleValue {
                guard seconds >= 0, seconds.isFinite else { throw Problem(path: path, message: "An age is 0 or more") }
                return seconds
            }
            let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 7 * 86400]
            guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), let unit = text.last,
                  let scale = units[unit], let amount = Double(text.dropLast()), amount >= 0, amount.isFinite else {
                throw Problem(path: path, message: "An age is seconds or a string such as 90s, 15m, 2h, 3d, 1w")
            }
            return amount * scale
        }
    }
}
