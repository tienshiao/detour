import Foundation

/// The site searches (TASK-287), kept in the session database's `siteSearch`
/// table and cached here. App-wide, not per profile. Loaded once at creation;
/// every change writes through and posts `didChangeNotification`, so an open
/// palette and the Settings pane read the current list.
final class SiteSearchStore {
    /// Posted (object: the store) after any change to the list.
    static let didChangeNotification = Notification.Name("SiteSearchStoreDidChange")

    static let shared = SiteSearchStore(database: .shared)

    private let database: AppDatabase

    /// The entries in the order Settings lists them.
    private(set) var entries: [SiteSearch] = []

    /// The hosts (`displayHost` form) of every entry the user removed
    /// (TASK-288): discovery never adds one of these sites again.
    private(set) var removedHosts: Set<String> = []

    init(database: AppDatabase) {
        self.database = database
        entries = database.loadSiteSearches().compactMap(Self.entry(from:))
        removedHosts = Set(database.loadSiteSearchRemovedHosts())
    }

    /// Whether discovery may add a site search for `host` (`displayHost`
    /// form): no entry has that host, and the user never removed one that did.
    func mayDiscover(host: String) -> Bool {
        let host = host.lowercased()
        return !host.isEmpty && !removedHosts.contains(host) && !entries.contains { $0.displayHost == host }
    }

    /// Appends a site search found on its own site (TASK-288), marked
    /// discovered and without a keyword. Nil, and nothing changes, when the
    /// site is listed already, was removed, or the entry has a problem.
    @discardableResult
    func addDiscovered(_ found: SiteSearch) -> SiteSearch? {
        var entry = found.normalized
        entry.keyword = ""
        entry.isDiscovered = true
        guard let host = entry.displayHost, mayDiscover(host: host) else { return nil }
        return add(entry)
    }

    /// The entry whose keyword is exactly `text` (ignoring case), or nil.
    func entry(forKeyword text: String) -> SiteSearch? {
        entries.first { $0.matches(keyword: text) }
    }

    func entry(withID id: UUID) -> SiteSearch? {
        entries.first { $0.id == id }
    }

    /// What keeps `entry` from being saved (`siteSearchProblems` against the
    /// other entries); empty when it can be.
    func problems(for entry: SiteSearch) -> [SiteSearchProblem] {
        siteSearchProblems(entry, among: entries)
    }

    /// Appends `entry`, normalized. Returns the stored entry, or nil when it
    /// has a problem.
    @discardableResult
    func add(_ entry: SiteSearch) -> SiteSearch? {
        guard problems(for: entry).isEmpty, !entries.contains(where: { $0.id == entry.id }) else { return nil }
        var entry = entry.normalized
        entry.sortOrder = (entries.map(\.sortOrder).max() ?? -1) + 1
        entries.append(entry)
        database.saveSiteSearch(Self.record(from: entry))
        postChange()
        return entry
    }

    /// Replaces the entry with `entry.id`, keeping its place. False, and
    /// nothing changes, when there is no such entry or it has a problem.
    /// A discovered entry whose name, keyword or address changes becomes the
    /// user's: it loses the mark (TASK-288). An address on another site
    /// records the old site as removed, as `remove` would.
    @discardableResult
    func update(_ entry: SiteSearch) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), problems(for: entry).isEmpty
        else { return false }
        var entry = entry.normalized
        let old = entries[index]
        entry.sortOrder = old.sortOrder
        entry.isDiscovered = old.isDiscovered && entry.name == old.name && entry.keyword == old.keyword
            && entry.urlTemplate == old.urlTemplate
        entries[index] = entry
        // Moving the entry to another site removes the old site's search, so
        // discovery must not add that one back either.
        let leftHost = old.displayHost.flatMap { $0 == entry.displayHost ? nil : $0 }
        if let leftHost { removedHosts.insert(leftHost) }
        database.saveSiteSearch(Self.record(from: entry), recordingRemovedHost: leftHost)
        postChange()
        return true
    }

    /// Removes the entry, and remembers its host so discovery never adds the
    /// site back (TASK-288) — whether it was discovered, a starter entry or
    /// one the user typed.
    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: index)
        if let host = removed.displayHost {
            removedHosts.insert(host)
            database.deleteSiteSearch(id: id.uuidString, recordingRemovedHost: host)
        } else {
            database.deleteSiteSearch(id: id.uuidString)
        }
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Records

    private static func entry(from record: SiteSearchRecord) -> SiteSearch? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return SiteSearch(id: id, name: record.name, keyword: record.keyword, urlTemplate: record.urlTemplate,
                          sortOrder: record.sortOrder, isDiscovered: record.isDiscovered)
    }

    static func record(from entry: SiteSearch) -> SiteSearchRecord {
        SiteSearchRecord(id: entry.id.uuidString, name: entry.name, keyword: entry.keyword,
                         urlTemplate: entry.urlTemplate, sortOrder: entry.sortOrder,
                         isDiscovered: entry.isDiscovered)
    }
}
