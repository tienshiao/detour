import Foundation

/// The History page's native methods. Query-only: entries are plain links, so
/// opening one is an ordinary navigation of the tab (click) or of a new tab in
/// its space (Cmd+click), with no privileged "open" call to get wrong.
enum HistoryPageBridge {
    static let maxPageSize = 200

    /// What a tab's History page may see: the visits of every space that
    /// currently uses the tab's profile. Derived from the sending tab — the
    /// page never names a profile or a space. Nil for incognito (nothing is
    /// recorded, and the page must not fall through to another profile).
    static func scope(for tab: BrowserTab, in store: TabStore = .shared) -> [String]? {
        guard let profile = tab.owningProfile, !profile.isIncognito, !profile.isDeleted else { return nil }
        return store.spaces.filter { $0.profileID == profile.id }.map { $0.id.uuidString }
    }

    static func handle(method: String, params: [String: Any], from tab: BrowserTab,
                       database: HistoryDatabase = .shared,
                       reply: @escaping (Any?, String?) -> Void) {
        switch method {
        case "history.query":
            guard let spaceIDs = scope(for: tab) else {
                reply(["entries": [], "incognito": tab.owningProfile?.isIncognito == true], nil)
                return
            }
            let search = (params["search"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let limit = min(max((params["limit"] as? NSNumber)?.intValue ?? 100, 1), maxPageSize)
            let cursor = cursor(from: params["cursor"])
            DispatchQueue.global(qos: .userInitiated).async {
                // One extra row tells the page whether there is more to load.
                let rows = search.isEmpty
                    ? database.visits(spaceIDs: spaceIDs, before: cursor, limit: limit + 1)
                    : database.searchVisits(query: search, spaceIDs: spaceIDs, before: cursor, limit: limit + 1)
                let page = Array(rows.prefix(limit))
                var result: [String: Any] = ["entries": page.map(payload(for:)), "incognito": false]
                if rows.count > limit, let last = page.last {
                    result["nextCursor"] = ["time": last.visitTime, "id": last.visitID]
                }
                DispatchQueue.main.async { reply(result, nil) }
            }
        default:
            reply(nil, "unknown method")
        }
    }

    private static func cursor(from value: Any?) -> HistoryCursor? {
        guard let dict = value as? [String: Any],
              let time = (dict["time"] as? NSNumber)?.doubleValue,
              let id = (dict["id"] as? NSNumber)?.int64Value else { return nil }
        return HistoryCursor(visitTime: time, visitID: id)
    }

    private static func payload(for entry: HistoryVisitEntry) -> [String: Any] {
        ["id": entry.visitID, "url": entry.url, "title": entry.title, "time": entry.visitTime]
    }
}
