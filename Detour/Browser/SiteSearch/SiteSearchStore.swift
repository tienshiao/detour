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

    init(database: AppDatabase) {
        self.database = database
        entries = database.loadSiteSearches().compactMap(Self.entry(from:))
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
    @discardableResult
    func update(_ entry: SiteSearch) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }), problems(for: entry).isEmpty
        else { return false }
        var entry = entry.normalized
        entry.sortOrder = entries[index].sortOrder
        entries[index] = entry
        database.saveSiteSearch(Self.record(from: entry))
        postChange()
        return true
    }

    func remove(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        database.deleteSiteSearch(id: id.uuidString)
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Records

    private static func entry(from record: SiteSearchRecord) -> SiteSearch? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return SiteSearch(id: id, name: record.name, keyword: record.keyword, urlTemplate: record.urlTemplate,
                          sortOrder: record.sortOrder)
    }

    static func record(from entry: SiteSearch) -> SiteSearchRecord {
        SiteSearchRecord(id: entry.id.uuidString, name: entry.name, keyword: entry.keyword,
                         urlTemplate: entry.urlTemplate, sortOrder: entry.sortOrder)
    }
}
