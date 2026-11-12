import Foundation

/// Reads the Markdown file Arc's Settings › Advanced › Export Data writes
/// (`Arc Data Export.md`) into an `ArcImportSnapshot`.
///
/// What Arc 1.172.1 writes (checked against two real exports; the wiki page
/// `features/arc-import.md` has the details):
///
///     # <space title>
///
///     ## Favorites
///     - <url>
///
///     ## <folder title>
///     - <url>
///
///     ### <folder inside it>
///     - <url>
///
/// Only URLs: no titles, profiles, split views or ids. The "Favorites" list
/// is the profile's favourites, then the space's top-level pinned tabs, then
/// its Today tabs (a split view's panes flattened among them), with nothing
/// marking either boundary, so top-level pinned tabs come over as Today tabs.
/// The rule for telling them apart (user, Nov 12 2026): a link run that opens
/// the Favorites list of two or more spaces is the favourites; the rest of
/// each list is that space's Today tabs. With one space nothing is a
/// favourite. The window says this is a guess for any snapshot whose
/// `source` is `.exportFile`.
///
/// The parser is lenient beyond what Arc was seen to write: a bullet that is
/// not a link opens a folder for the bullets indented below it, and
/// `[title](url)` and `<url>` links are read as well as bare URLs.
nonisolated enum ArcExportReader {
    static let favoritesHeading = "favorites"

    static func read(file: URL) throws(ArcImportError) -> ArcImportSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .unreadable(path: file.path, reason: error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw .unrecognizedFormat(path: file.path, reason: "the file is not UTF-8 text")
        }
        var snapshot = try parse(text, path: file.path)
        snapshot.source = .exportFile(file)
        return snapshot
    }

    /// The export's single stand-in profile.
    static let exportProfileName = "Arc"

    static func parse(_ text: String, path: String = "Arc Data Export.md") throws(ArcImportError) -> ArcImportSnapshot {
        let parsed = parseSpaces(text)
        guard !parsed.isEmpty else {
            throw .unrecognizedFormat(path: path, reason: "no “# Space” headings")
        }
        var skipped: [ArcSkippedItem] = []
        let favoriteLists = parsed.map(\.favorites)
        let favoriteCounts = favoriteLists.indices.map { sharedLeadLength(at: $0, in: favoriteLists) }

        var favorites: [ArcTab] = []
        var favoriteURLs: Set<String> = []
        var spaces: [ArcSpace] = []
        var spaceKeys = KeyMaker()
        for (index, space) in parsed.enumerated() {
            let spaceKey = spaceKeys.key("export:space:\(space.title)")
            var tabKeys = KeyMaker()
            for link in space.favorites.prefix(favoriteCounts[index]) where !favoriteURLs.contains(link.url) {
                favoriteURLs.insert(link.url)
                guard let tab = tab(link, key: "export:favorite:\(link.url)", skipped: &skipped,
                                    spaceTitle: space.title) else { continue }
                favorites.append(tab)
            }
            let unpinned = space.favorites.dropFirst(favoriteCounts[index]).compactMap { link -> ArcSidebarNode? in
                tab(link, key: tabKeys.key("\(spaceKey)/today/\(link.url)"), skipped: &skipped,
                    spaceTitle: space.title).map(ArcSidebarNode.tab)
            }
            let pinned = nodes(space.folders, path: "\(spaceKey)/pinned", keys: &tabKeys,
                               skipped: &skipped, spaceTitle: space.title)
            spaces.append(ArcSpace(sourceKey: spaceKey, title: space.title, emoji: nil, colorHex: nil,
                                   profileID: .export, pinned: pinned, unpinned: unpinned))
        }
        let profile = ArcProfile(id: .export, name: exportProfileName, favorites: favorites, historyFile: nil)
        return ArcImportSnapshot(source: .exportFile(URL(filePath: path)), profiles: [profile],
                                 spaces: spaces, skipped: skipped)
    }

    /// How many links opening `lists[index]` also open, in the same order,
    /// the Favorites list of at least one other space.
    static func sharedLeadLength(at index: Int, in lists: [[Link]]) -> Int {
        lists.indices.filter { $0 != index }.map { other in
            zip(lists[index], lists[other]).prefix { $0.url == $1.url }.count
        }.max() ?? 0
    }

    // MARK: - Markdown structure

    nonisolated struct Link: Equatable {
        var url: String
        var title: String?
    }

    /// A folder (a `##` heading other than Favorites, or a non-link bullet)
    /// and what it holds, in file order.
    nonisolated final class Folder {
        let title: String
        var entries: [Entry] = []
        init(title: String) { self.title = title }
    }

    nonisolated enum Entry {
        case link(Link)
        case folder(Folder)
    }

    nonisolated struct ParsedSpace {
        var title: String
        var favorites: [Link] = []
        var folders: [Entry] = []
    }

    static func parseSpaces(_ text: String) -> [ParsedSpace] {
        var spaces: [ParsedSpace] = []
        // The open headings below the space: (level, folder), outermost first.
        var headingStack: [(level: Int, folder: Folder)] = []
        var inFavorites = false
        // Arc writes one Favorites list, first; a later top-level heading of
        // the same name is a pinned folder the user called "Favorites".
        var sawFavorites = false
        // The open non-link bullets: (indent, folder), outermost first.
        var bulletStack: [(indent: Int, folder: Folder)] = []

        func append(_ entry: Entry, indent: Int) {
            guard !spaces.isEmpty else { return }
            while let last = bulletStack.last, last.indent >= indent { bulletStack.removeLast() }
            if let parent = bulletStack.last?.folder {
                parent.entries.append(entry)
            } else if let heading = headingStack.last?.folder {
                heading.entries.append(entry)
            } else if inFavorites, case .link(let link) = entry {
                spaces[spaces.count - 1].favorites.append(link)
            } else {
                // A link before any section, or a folder bullet in Favorites.
                spaces[spaces.count - 1].folders.append(entry)
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let found = heading(trimmed) {
                let (level, title) = found
                bulletStack.removeAll()
                if level == 1 {
                    spaces.append(ParsedSpace(title: title.isEmpty ? "Untitled Space" : title))
                    headingStack.removeAll()
                    inFavorites = false
                    sawFavorites = false
                    continue
                }
                guard !spaces.isEmpty else { continue }
                while let last = headingStack.last, last.level >= level { headingStack.removeLast() }
                if headingStack.isEmpty, !sawFavorites, title.lowercased() == favoritesHeading {
                    inFavorites = true
                    sawFavorites = true
                    continue
                }
                inFavorites = false
                let folder = Folder(title: title.isEmpty ? "Folder" : title)
                if let parent = headingStack.last?.folder {
                    parent.entries.append(.folder(folder))
                } else {
                    spaces[spaces.count - 1].folders.append(.folder(folder))
                }
                headingStack.append((level, folder))
                continue
            }
            guard let found = bullet(line) else { continue }
            let (indent, content) = found
            if let link = link(content) {
                append(.link(link), indent: indent)
            } else {
                let folder = Folder(title: content)
                append(.folder(folder), indent: indent)
                bulletStack.append((indent, folder))
            }
        }
        return spaces
    }

    /// `## Title` → (2, "Title").
    static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `  - text` → (2, "text"), for `-`, `*` and `+` bullets.
    static func bullet(_ line: String) -> (Int, String)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " else { return nil }
        let content = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return content.isEmpty ? nil : (indent, content)
    }

    /// A bare URL, `<url>`, or `[title](url)`; nil for plain text.
    static func link(_ content: String) -> Link? {
        if content.hasPrefix("["), let close = content.range(of: "]("), content.hasSuffix(")") {
            let title = String(content[content.index(after: content.startIndex)..<close.lowerBound])
            let url = String(content[close.upperBound..<content.index(before: content.endIndex)])
            return looksLikeURL(url) ? Link(url: url, title: title.isEmpty ? nil : title) : nil
        }
        if content.hasPrefix("<"), content.hasSuffix(">") {
            let url = String(content.dropFirst().dropLast())
            return looksLikeURL(url) ? Link(url: url, title: nil) : nil
        }
        return looksLikeURL(content) ? Link(url: content, title: nil) : nil
    }

    /// Schemes without `//` that Arc can have in a sidebar (bookmarklets,
    /// blank and mail tabs): read as links so they are reported as skipped
    /// rather than opening an empty folder.
    static let opaqueSchemes: Set<String> = ["javascript", "about", "mailto", "data", "blob", "tel"]

    private static func looksLikeURL(_ text: String) -> Bool {
        guard !text.contains(" "), let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
            return false
        }
        return text[colon...].hasPrefix("://")
            || (opaqueSchemes.contains(scheme.lowercased()) && text.index(after: colon) < text.endIndex)
    }

    // MARK: - Snapshot nodes

    private static func nodes(_ entries: [Entry], path: String, keys: inout KeyMaker,
                              skipped: inout [ArcSkippedItem], spaceTitle: String) -> [ArcSidebarNode] {
        entries.compactMap { entry -> ArcSidebarNode? in
            switch entry {
            case .link(let link):
                return tab(link, key: keys.key("\(path)/\(link.url)"), skipped: &skipped,
                           spaceTitle: spaceTitle).map(ArcSidebarNode.tab)
            case .folder(let folder):
                let folderPath = keys.key("\(path)/\(folder.title)")
                return .folder(ArcFolder(sourceKey: folderPath, title: folder.title,
                                         children: nodes(folder.entries, path: folderPath, keys: &keys,
                                                         skipped: &skipped, spaceTitle: spaceTitle)))
            }
        }
    }

    private static func tab(_ link: Link, key: String, skipped: inout [ArcSkippedItem],
                            spaceTitle: String) -> ArcTab? {
        guard let url = URL(string: link.url), ArcSidebarReader.isImportable(url) else {
            skipped.append(ArcSkippedItem(reason: .unusableURL, title: link.title ?? link.url,
                                          spaceTitle: spaceTitle))
            return nil
        }
        return ArcTab(sourceKey: key, url: url, title: link.title ?? url.host() ?? link.url)
    }

    /// Source keys from content: the same link twice in one folder gets
    /// `#2`, `#3`, … so each occurrence keeps its own key across exports.
    nonisolated struct KeyMaker {
        private var seen: [String: Int] = [:]

        mutating func key(_ base: String) -> String {
            let count = seen[base, default: 0] + 1
            seen[base] = count
            return count == 1 ? base : "\(base)#\(count)"
        }
    }
}
