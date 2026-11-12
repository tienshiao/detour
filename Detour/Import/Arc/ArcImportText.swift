import Foundation

/// The words the Arc import window shows (TASK-293.3), kept pure so the
/// counts and the plural rules are unit-tested apart from the view code.
nonisolated enum ArcImportText {
    static let windowTitle = "Import from Arc"

    /// What never comes across, shown before the import (AC: told, not
    /// silently dropped). Arc encrypts logins and cookies with a Keychain key,
    /// and WebKit has no way to load cookies in bulk.
    static let notImported = """
        Not imported: logins and cookies (you sign in to your sites again), saved passwords, \
        extensions, Easels, Notes, Boosts and Little Arc windows.
        """

    /// Shown for an export file: the shared-lead rule is a guess.
    static let exportGuess = """
        An export file doesn’t say which links are favorites. Links that open the Favorites \
        list of two or more spaces become favorites; the rest of each list, and pinned tabs \
        outside folders, come in as that space’s Today tabs.
        """

    static let historyNote = "History covers the last 90 days, as much as Detour keeps."

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// "3 pinned · 1 folder · 7 Today tabs", or "Empty".
    static func spaceDetail(_ space: ArcSpace) -> String {
        let pinned = space.pinned.flatMap(\.allTabs).count
        let folders = space.pinned.reduce(0) { $0 + folderCount($1) }
        let today = space.unpinned.flatMap(\.allTabs).count
        var parts: [String] = []
        if pinned > 0 { parts.append("\(pinned) pinned") }
        if folders > 0 { parts.append(count(folders, "folder")) }
        if today > 0 { parts.append(count(today, "Today tab")) }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private static func folderCount(_ node: ArcSidebarNode) -> Int {
        guard case .folder(let folder) = node else { return 0 }
        return 1 + folder.children.reduce(0) { $0 + folderCount($1) }
    }

    /// "2 favorites · history", or "No favorites".
    static func profileDetail(_ profile: ArcProfile) -> String {
        var parts: [String] = []
        if !profile.favorites.isEmpty { parts.append(count(profile.favorites.count, "favorite")) }
        if profile.historyFile != nil { parts.append("history") }
        return parts.isEmpty ? "Nothing but its spaces" : parts.joined(separator: " · ")
    }

    /// "2 links only Arc can open and 1 Easel are left out.", or nil.
    static func skippedNote(_ skipped: [ArcSkippedItem]) -> String? {
        guard !skipped.isEmpty else { return nil }
        var unusable = 0
        var kinds: [String: Int] = [:]
        for item in skipped {
            switch item.reason {
            case .unusableURL: unusable += 1
            case .unsupportedKind(let kind): kinds[kindName(kind), default: 0] += 1
            }
        }
        var parts: [String] = []
        if unusable > 0 { parts.append(count(unusable, "link") + " only Arc can open") }
        for kind in kinds.keys.sorted() {
            parts.append(count(kinds[kind]!, kind))
        }
        let list = parts.count <= 2
            ? parts.joined(separator: " and ")
            : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "\(list) \(skipped.count == 1 ? "is" : "are") left out."
    }

    /// Arc's item kind as a person would say it.
    static func kindName(_ kind: String) -> String {
        switch kind {
        case "easel": "Easel"
        case "arcDocument": "Note"
        default: "\(kind) item"
        }
    }

    /// What an applied plan added, one line per kind, for the result view.
    static func summary(of plan: ArcImportPlan) -> [String] {
        var lines: [String] = []
        if !plan.profiles.isEmpty {
            lines.append(count(plan.profiles.count, "new profile") + ": "
                         + plan.profiles.map(\.name).joined(separator: ", "))
        }
        if !plan.spaces.isEmpty {
            lines.append(count(plan.spaces.count, "new space") + ": "
                         + plan.spaces.map { "\($0.emoji) \($0.name)" }.joined(separator: ", "))
        }
        if !plan.reusedSpaceIDs.isEmpty {
            lines.append("Added to " + count(plan.reusedSpaceIDs.count, "existing space"))
        }
        if !plan.pinnedEntries.isEmpty || !plan.folders.isEmpty {
            var line = count(plan.pinnedEntries.count, "pinned tab")
            if !plan.folders.isEmpty { line += " in " + count(plan.folders.count, "new folder") }
            lines.append(line)
        }
        if !plan.favorites.isEmpty { lines.append(count(plan.favorites.count, "favorite")) }
        if !plan.tabs.isEmpty { lines.append(count(plan.tabs.count, "Today tab") + ", asleep until you open them") }
        if plan.alreadyPresent > 0 {
            lines.append(count(plan.alreadyPresent, "tab or favorite", "tabs and favorites")
                         + " Detour already had " + (plan.alreadyPresent == 1 ? "was" : "were") + " left as they are")
        }
        if lines.isEmpty { lines.append("Nothing new: Detour already has everything you chose.") }
        return lines
    }

    /// One line per history import: "Default history: 4312 visits added", "Home history wasn’t
    /// imported: …". `names` maps Arc profiles to the names shown.
    static func historyLines(_ results: [TabStore.ArcHistoryImportResult],
                             names: [ArcProfile.ID: String]) -> [String] {
        results.map { result in
            let name = names[result.arcProfile] ?? "History"
            if let added = result.added {
                return "\(name) history: " + count(added, "visit") + " added"
            }
            return "\(name) history wasn’t imported: \(result.failure ?? "unknown error")"
        }
    }

    /// For Arc profiles whose history had no space to go to.
    static func historyWithoutSpaceLine(_ ids: [ArcProfile.ID], names: [ArcProfile.ID: String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let list = ids.map { names[$0] ?? "?" }.joined(separator: ", ")
        return "History of \(list) wasn’t imported: no space of \(ids.count == 1 ? "that profile" : "those profiles") came over."
    }
}
