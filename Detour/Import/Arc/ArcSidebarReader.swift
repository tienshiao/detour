import Foundation

/// Reads Arc's own files on this Mac into an `ArcImportSnapshot`.
///
/// Sources, checked against Arc 1.172.1 (build 90370); the format is described
/// in `wiki/features/arc-import.md`:
/// - `StorableSidebar.json` — spaces, their pinned and unpinned items, folders,
///   split views and each profile's favourites. Only `sidebar.containers` is
///   read: the `firebaseSyncState` and `sidebarSyncState` blocks beside it are
///   sync shadows that can be years out of date.
/// - `User Data/Local State` — the names of Arc's (Chromium) profiles.
/// - `User Data/<profile>/History` — located here, read by `ArcHistoryReader`.
///
/// Pure apart from reading the two files, and safe off the main thread.
nonisolated enum ArcSidebarReader {
    /// Arc's data folder for the current user.
    static var defaultDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc", directoryHint: .isDirectory)
    }

    /// The id of the space Arc creates for every new user. It has no title.
    static let builtInPersonalSpaceID = "thebrowser.company.defaultPersonalSpaceID"

    /// Item kinds that are part of Arc's onboarding, not the user's sidebar,
    /// and are dropped without being reported as skipped.
    static let ignoredKinds: Set<String> = ["welcomeToArc"]

    /// Deeper than any sidebar a person builds; guards against a cyclic or
    /// corrupt `childrenIds` chain.
    static let maximumDepth = 64

    static func read(dataDirectory: URL = defaultDataDirectory) throws(ArcImportError) -> ArcImportSnapshot {
        let sidebarFile = dataDirectory.appending(path: "StorableSidebar.json", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: sidebarFile.path) else {
            throw .arcNotFound
        }
        let sidebarData: Data
        do {
            sidebarData = try Data(contentsOf: sidebarFile)
        } catch {
            throw .unreadable(path: sidebarFile.path, reason: error.localizedDescription)
        }
        // Profile names are a nicety: without Local State the folder names stand in.
        let localState = try? Data(contentsOf: dataDirectory.appending(path: "User Data/Local State",
                                                                       directoryHint: .notDirectory))
        var snapshot = try parse(sidebarJSON: sidebarData, localStateJSON: localState,
                                 sidebarPath: sidebarFile.path)
        snapshot.source = .installation(dataDirectory)
        for index in snapshot.profiles.indices {
            let history = dataDirectory
                .appending(path: "User Data", directoryHint: .isDirectory)
                .appending(path: profileDirectoryName(snapshot.profiles[index].id), directoryHint: .isDirectory)
                .appending(path: "History", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: history.path) {
                snapshot.profiles[index].historyFile = history
            }
        }
        return snapshot
    }

    /// The folder under `User Data` that holds a profile's Chromium data.
    static func profileDirectoryName(_ id: ArcProfile.ID) -> String {
        switch id {
        case .default, .export: "Default"
        case .directory(let name): name
        }
    }

    // MARK: - Parsing

    /// Parses the sidebar file (and, optionally, Local State for profile
    /// names). The snapshot's source is a placeholder `installation` of the
    /// sidebar's folder; `read` fills in the real one and the history files.
    static func parse(sidebarJSON: Data, localStateJSON: Data?,
                      sidebarPath: String = "StorableSidebar.json") throws(ArcImportError) -> ArcImportSnapshot {
        func unrecognized(_ reason: String) -> ArcImportError {
            .unrecognizedFormat(path: sidebarPath, reason: reason)
        }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: sidebarJSON) as? [String: Any] else {
                throw unrecognized("the file is not a JSON object")
            }
            root = object
        } catch let error as ArcImportError {
            throw error
        } catch {
            throw unrecognized("the file is not valid JSON (\(error.localizedDescription))")
        }
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else {
            throw unrecognized("no sidebar.containers")
        }
        // containers[0] is `{global: {}}`; the one holding spaces is the sidebar.
        guard let container = containers.lazy.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["spaces"] != nil && $0["items"] != nil }) else {
            throw unrecognized("no sidebar container with spaces and items")
        }

        let items = Dictionary(orderedMap(container["items"]).compactMap { key, value -> (String, [String: Any])? in
            guard let key = key as? String, let item = value as? [String: Any] else { return nil }
            return (key, item)
        }, uniquingKeysWith: { first, _ in first })

        let profileNames = parseProfileNames(localStateJSON)
        var builder = TreeBuilder(items: items)

        // Favourites: topAppsContainerIDs pairs a profile with the container
        // whose children are that profile's favourites.
        var favoritesByProfile: [ArcProfile.ID: [ArcTab]] = [:]
        var profileOrder: [ArcProfile.ID] = []
        for (key, value) in orderedMap(container["topAppsContainerIDs"]) {
            guard let profile = parseProfile(key), let containerID = value as? String else { continue }
            if !profileOrder.contains(profile) { profileOrder.append(profile) }
            let nodes = builder.children(of: containerID, spaceTitle: nil)
            favoritesByProfile[profile, default: []].append(contentsOf: nodes.flatMap(\.allTabs))
        }

        var spaces: [ArcSpace] = []
        for (key, value) in orderedMap(container["spaces"]) {
            guard let spaceID = key as? String, let space = value as? [String: Any] else { continue }
            let profile = parseProfile(space["profile"]) ?? .default
            if !profileOrder.contains(profile) { profileOrder.append(profile) }
            let title = spaceTitle(space, id: spaceID)
            let containerIDs = spaceContainerIDs(space)
            let pinned = containerIDs.pinned.map { builder.children(of: $0, spaceTitle: title) } ?? []
            let unpinned = containerIDs.unpinned.map { builder.children(of: $0, spaceTitle: title) } ?? []
            let customInfo = space["customInfo"] as? [String: Any]
            spaces.append(ArcSpace(sourceKey: "space:\(spaceID)", title: title,
                                   emoji: spaceEmoji(customInfo), colorHex: spaceColorHex(customInfo),
                                   profileID: profile, pinned: pinned, unpinned: unpinned))
        }

        // Every profile Arc has, even one with no space or favourite: its
        // history is still worth importing.
        for directory in profileNames.keys where directory != "Default" {
            let id = ArcProfile.ID.directory(directory)
            if !profileOrder.contains(id) { profileOrder.append(id) }
        }
        if profileNames["Default"] != nil, !profileOrder.contains(.default) {
            profileOrder.append(.default)
        }
        let profiles = sortedProfiles(profileOrder).map { id in
            ArcProfile(id: id, name: profileName(id, names: profileNames),
                       favorites: favoritesByProfile[id] ?? [], historyFile: nil)
        }

        let directory = URL(filePath: sidebarPath).deletingLastPathComponent()
        return ArcImportSnapshot(source: .installation(directory), profiles: profiles,
                                 spaces: spaces, skipped: builder.skipped)
    }

    // MARK: - Items

    private struct TreeBuilder {
        let items: [String: [String: Any]]
        var skipped: [ArcSkippedItem] = []

        init(items: [String: [String: Any]]) {
            self.items = items
        }

        mutating func children(of containerID: String, spaceTitle: String?) -> [ArcSidebarNode] {
            var visited: Set<String> = [containerID]
            return children(of: containerID, spaceTitle: spaceTitle, depth: 0, visited: &visited)
        }

        private mutating func children(of parentID: String, spaceTitle: String?, depth: Int,
                                       visited: inout Set<String>) -> [ArcSidebarNode] {
            guard depth < ArcSidebarReader.maximumDepth,
                  let parent = items[parentID],
                  let childIDs = parent["childrenIds"] as? [Any] else { return [] }
            var nodes: [ArcSidebarNode] = []
            for case let childID as String in childIDs {
                guard visited.insert(childID).inserted, let child = items[childID] else { continue }
                if let node = node(childID, child, spaceTitle: spaceTitle, depth: depth, visited: &visited) {
                    nodes.append(node)
                }
            }
            return nodes
        }

        private mutating func node(_ id: String, _ item: [String: Any], spaceTitle: String?, depth: Int,
                                   visited: inout Set<String>) -> ArcSidebarNode? {
            let data = item["data"] as? [String: Any] ?? [:]
            let renamed = nonEmpty(item["title"] as? String)
            if let tabData = data["tab"] as? [String: Any] {
                return tab(id, tabData, renamed: renamed, spaceTitle: spaceTitle).map(ArcSidebarNode.tab)
            }
            if data["list"] != nil {
                let children = children(of: id, spaceTitle: spaceTitle, depth: depth + 1, visited: &visited)
                return .folder(ArcFolder(sourceKey: "item:\(id)", title: renamed ?? "Folder", children: children))
            }
            if let split = data["splitView"] {
                let tabs = children(of: id, spaceTitle: spaceTitle, depth: depth + 1, visited: &visited)
                    .flatMap(\.allTabs)
                switch tabs.count {
                case 0: return nil
                case 1: return .tab(tabs[0])
                default:
                    return .split(ArcSplit(sourceKey: "item:\(id)", tabs: tabs,
                                           leadingFraction: Self.leadingFraction(split, firstPane: tabs[0])))
                }
            }
            let kind = data.keys.sorted().first ?? "unknown"
            if !ArcSidebarReader.ignoredKinds.contains(kind) {
                skipped.append(ArcSkippedItem(reason: .unsupportedKind(kind), title: renamed,
                                              spaceTitle: spaceTitle))
            }
            return nil
        }

        /// `itemWidthFactors` is an ordered map of pane item id → width share.
        /// Arc stores only the panes whose width was set, so a missing entry
        /// for the first pane leaves the split at Detour's default.
        static func leadingFraction(_ split: Any, firstPane: ArcTab) -> Double? {
            guard let split = split as? [String: Any] else { return nil }
            let paneID = firstPane.sourceKey.replacingOccurrences(of: "item:", with: "")
            for (key, value) in ArcSidebarReader.orderedMap(split["itemWidthFactors"])
            where key as? String == paneID {
                guard let fraction = (value as? NSNumber)?.doubleValue, fraction > 0, fraction < 1 else { return nil }
                return fraction
            }
            return nil
        }

        private mutating func tab(_ id: String, _ data: [String: Any], renamed: String?,
                                  spaceTitle: String?) -> ArcTab? {
            let savedTitle = nonEmpty(data["savedTitle"] as? String)
            guard let urlString = data["savedURL"] as? String,
                  let url = URL(string: urlString),
                  ArcSidebarReader.isImportable(url) else {
                skipped.append(ArcSkippedItem(reason: .unusableURL, title: renamed ?? savedTitle,
                                              spaceTitle: spaceTitle))
                return nil
            }
            return ArcTab(sourceKey: "item:\(id)", url: url,
                          title: renamed ?? savedTitle ?? url.host() ?? url.absoluteString)
        }
    }

    /// Web pages only: Arc's own pages (`arc://`), Chromium's (`chrome://`) and
    /// extension pages (`chrome-extension://`) have no counterpart in Detour.
    static func isImportable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host()?.isEmpty == false
    }

    // MARK: - Spaces

    private static func spaceTitle(_ space: [String: Any], id: String) -> String {
        if let title = nonEmpty(space["title"] as? String) { return title }
        return id == builtInPersonalSpaceID ? "Personal" : "Untitled Space"
    }

    /// The pinned and unpinned container ids. `containerIDs` is
    /// `["unpinned", id, "pinned", id]`; `newContainerIDs` carries the same
    /// with tagged keys (`{"pinned": {}}`), read when the plain form is absent.
    private static func spaceContainerIDs(_ space: [String: Any]) -> (pinned: String?, unpinned: String?) {
        var pinned: String?
        var unpinned: String?
        for field in ["containerIDs", "newContainerIDs"] {
            for (key, value) in orderedMap(space[field]) {
                guard let id = value as? String else { continue }
                let tag = (key as? String) ?? (key as? [String: Any])?.keys.first
                switch tag {
                case "pinned": pinned = pinned ?? id
                case "unpinned": unpinned = unpinned ?? id
                default: break
                }
            }
            if pinned != nil || unpinned != nil { break }
        }
        return (pinned, unpinned)
    }

    /// The emoji Arc shows for a space, or nil for a symbol icon.
    static func spaceEmoji(_ customInfo: [String: Any]?) -> String? {
        guard let icon = customInfo?["iconType"] as? [String: Any] else { return nil }
        if let emoji = nonEmpty(icon["emoji_v2"] as? String) { return emoji }
        if let scalarValue = icon["emoji"] as? Int, let scalar = Unicode.Scalar(scalarValue) {
            return String(Character(scalar))
        }
        return nil
    }

    /// The space's colour as `RRGGBB`: the theme's shaded primary colour (what
    /// Arc tints the space's chrome with), else its mid tone.
    static func spaceColorHex(_ customInfo: [String: Any]?) -> String? {
        guard let theme = customInfo?["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any] else { return nil }
        for key in ["shaded", "midTone"] {
            guard let color = palette[key] as? [String: Any],
                  let red = number(color["red"]), let green = number(color["green"]),
                  let blue = number(color["blue"]) else { continue }
            func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
            return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
        }
        return nil
    }

    // MARK: - Profiles

    /// `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1", …}}}`.
    static func parseProfile(_ value: Any?) -> ArcProfile.ID? {
        guard let value = value as? [String: Any] else { return nil }
        if value["default"] != nil { return .default }
        if let custom = value["custom"] as? [String: Any],
           let payload = custom["_0"] as? [String: Any],
           let directory = nonEmpty(payload["directoryBasename"] as? String) {
            return directory == "Default" ? .default : .directory(directory)
        }
        return nil
    }

    /// Profile folder → display name, from Chromium's `profile.info_cache`.
    /// A profile still on Chromium's placeholder name ("Person 1") is left out,
    /// so `profileName` falls back to Arc's own wording.
    static func parseProfileNames(_ localStateJSON: Data?) -> [String: String] {
        guard let localStateJSON,
              let root = try? JSONSerialization.jsonObject(with: localStateJSON) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (directory, value) in cache {
            guard let info = value as? [String: Any] else { continue }
            let usesPlaceholder = (info["is_using_default_name"] as? Bool) ?? false
            names[directory] = usesPlaceholder ? "" : (nonEmpty(info["name"] as? String) ?? "")
        }
        return names
    }

    private static func profileName(_ id: ArcProfile.ID, names: [String: String]) -> String {
        let directory = profileDirectoryName(id)
        if let name = nonEmpty(names[directory]) { return name }
        return id == .default ? "Default" : directory
    }

    /// Default first, then Arc's profile folders in Finder order
    /// ("Profile 2" before "Profile 10").
    private static func sortedProfiles(_ ids: [ArcProfile.ID]) -> [ArcProfile.ID] {
        ids.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.default, _): return rhs != .default
            case (_, .default): return false
            default:
                return profileDirectoryName(lhs).localizedStandardCompare(profileDirectoryName(rhs))
                    == .orderedAscending
            }
        }
    }

    // MARK: - Helpers

    /// Swift encodes an ordered dictionary as `[key, value, key, value, …]`.
    static func orderedMap(_ value: Any?) -> [(key: Any, value: Any)] {
        guard let array = value as? [Any] else { return [] }
        return stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

nonisolated private func nonEmpty(_ string: String?) -> String? {
    guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
