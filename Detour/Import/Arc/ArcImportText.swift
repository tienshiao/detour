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
        outside folders, come in as that space’s unpinned tabs.
        """

    static let historyNote = "History covers the last 90 days, as much as Detour keeps."

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// "3 pinned · 1 folder · 7 unpinned", or "Empty". Arc's help calls them
    /// Pinned and Unpinned Tabs; "Today" was early Arc and reviewers' word.
    static func spaceDetail(_ space: ArcSpace) -> String {
        let pinned = space.pinned.flatMap(\.allTabs).count
        let folders = space.pinned.reduce(0) { $0 + folderCount($1) }
        let today = space.unpinned.flatMap(\.allTabs).count
        var parts: [String] = []
        if pinned > 0 { parts.append("\(pinned.formatted()) pinned") }
        if folders > 0 { parts.append(count(folders, "folder")) }
        if today > 0 { parts.append("\(today.formatted()) unpinned") }
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

    /// "2 links aren’t web pages (like arc:// pages), so they’re
    /// left out. 1 Easel is left out.", or nil. The links get their own
    /// sentence that says why: they are Arc's own pages, extension pages or
    /// files, not something Detour fails to open.
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
        var sentences: [String] = []
        if unusable > 0 {
            sentences.append(unusable == 1
                ? "1 link isn’t a web page (like arc:// pages), so it’s left out."
                : "\(unusable.formatted()) links aren’t web pages (like arc:// pages), so they’re left out.")
        }
        if !kinds.isEmpty {
            let parts = kinds.keys.sorted().map { count(kinds[$0]!, $0) }
            let list = parts.count <= 2
                ? parts.joined(separator: " and ")
                : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            let total = kinds.values.reduce(0, +)
            sentences.append("\(list) \(total == 1 ? "is" : "are") left out.")
        }
        return sentences.joined(separator: " ")
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
        if !plan.tabs.isEmpty { lines.append(count(plan.tabs.count, "unpinned tab")) }
        if plan.alreadyPresent > 0 {
            lines.append(count(plan.alreadyPresent, "tab or favorite", "tabs and favorites")
                         + " Detour already had " + (plan.alreadyPresent == 1 ? "was" : "were") + " left as they are")
        }
        if lines.isEmpty { lines.append("Nothing new: Detour already has everything you chose.") }
        return lines
    }

    /// What an applied import added and left out, one line each, for the
    /// window's and the launch offer's result: the summary, a failed save,
    /// the skipped items and history with nowhere to go.
    static func resultLines(of plan: ArcImportPlan, saveFailure: String?, skipped: [ArcSkippedItem],
                            names: [ArcProfile.ID: String]) -> [String] {
        summary(of: plan) + resultNotes(of: plan, saveFailure: saveFailure, skipped: skipped, names: names)
    }

    /// The part of `resultLines` that is not what was added: a failed save,
    /// what was left out, history with nowhere to go. The launch offer shows
    /// these apart from the summary, in small print.
    static func resultNotes(of plan: ArcImportPlan, saveFailure: String?, skipped: [ArcSkippedItem],
                            names: [ArcProfile.ID: String]) -> [String] {
        var lines: [String] = []
        if let saveFailure {
            lines.append("Detour couldn’t save this yet (\(saveFailure)); it tries again with the next change.")
        }
        if let skipped = skippedNote(skipped) { lines.append(skipped) }
        if let missing = historyWithoutSpaceLine(plan.historyWithoutSpace, names: names) { lines.append(missing) }
        return lines
    }

    // MARK: - The launch offer (TASK-293.5)

    static let offerTitle = "Bring your Arc setup along"
    static let offerBody = "Detour found Arc on this Mac. Your spaces, pinned tabs and favorites can come with you."
    static let offerImportButton = "Import Everything"
    static let offerChooseButton = "Choose…"
    static let offerDeclineButton = "Not Now"
    static let offerDoneTitle = "Your Arc setup is in Detour"
    static let offerFailed = "Detour changed while this was open, so nothing was imported. Choose… to try again."

    /// The day Arc stops working (TASK-293), from its start in the user's
    /// time zone, so the line names the date until that date is here.
    static var arcShutdown: Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 12, day: 22))!
    }

    /// What stays behind, and while Arc still works, until when it does: one
    /// line each, so neither breaks mid-sentence.
    static func offerFinePrint(now: Date) -> String {
        let stays = "Logins, passwords and extensions stay in Arc."
        return now < arcShutdown ? stays + "\nArc stops working on December 22, 2026." : stays
    }

    /// "5 spaces · 48 pinned tabs · 12 favorites · 90 days of history".
    static func offerTotals(_ snapshot: ArcImportSnapshot) -> String {
        let pinned = snapshot.spaces.reduce(0) { $0 + $1.pinned.flatMap(\.allTabs).count }
        let favorites = snapshot.profiles.reduce(0) { $0 + $1.favorites.count }
        var parts: [String] = []
        if !snapshot.spaces.isEmpty { parts.append(count(snapshot.spaces.count, "space")) }
        if pinned > 0 { parts.append(count(pinned, "pinned tab")) }
        if favorites > 0 { parts.append(count(favorites, "favorite")) }
        if snapshot.profiles.contains(where: { $0.historyFile != nil }) { parts.append("90 days of history") }
        return parts.joined(separator: " · ")
    }

    /// A space's chip: its emoji, when Arc has one, and its title.
    static func offerChipTitle(_ space: ArcSpace) -> String {
        [space.emoji, space.title].compactMap { $0 }.joined(separator: " ")
    }

    /// The chip that stands for the spaces that did not fit.
    static func offerMoreChipTitle(_ hidden: Int) -> String { "+\(hidden.formatted()) more" }

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
