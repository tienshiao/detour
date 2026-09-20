import AppKit

/// The History page's native methods. There is no "open": entries are plain
/// links, so opening one is an ordinary navigation of the tab (click) or of a
/// new tab in its space (Cmd+click).
///
/// The destructive methods (TASK-87) keep the rule the query set: nothing in a
/// message says *whose* history it is about. `history.delete` names visit ids
/// and `history.clear` names a range; the profile's spaces come from the
/// sending tab, and the SQL deletes only rows that are both named and in that
/// scope — an id belonging to another profile deletes nothing.
///
/// The time filter (TASK-92) starts the same way: `history.query` takes a
/// symbolic `range` — `{preset: …}` or `{day: …}` — and `HistoryTimeRange`
/// turns it into half-open bounds here. A range that is neither absent nor one
/// of those shapes is "malformed", never widened to all of history.
///
/// The reply then says which window that was (`window: {from, until}`), and the
/// page echoes it back — on every later page of the same listing, and on a
/// URL-mode `history.delete` of one of its rows, which takes a `window` and no
/// `range` at all. One listing therefore pages and deletes against the window
/// it was rendered under: re-resolving "today" per request would move the
/// window under a listing that is open across midnight.
///
/// So a page *can* name instants here, which `history.clear` refuses. The
/// difference is what naming one can reach:
/// - the scope is still derived from the sending tab, so no window of any shape
///   reaches another profile's visits;
/// - a query window only narrows a read the page is allowed to make in full;
/// - a delete window only narrows a fan-out. `allVisitsOfURL` without one takes
///   *every* in-scope visit of the named URLs, so a window can only spare rows,
///   never reach further ones — and the named ids are deleted whatever it says.
/// `history.clear` is the opposite shape: nothing bounds it from below, so an
/// instant there would *widen* what is destroyed. Its cutoff stays native.
enum HistoryPageBridge {
    static let maxPageSize = 200
    /// Most visit ids one `history.delete` may name; a selection larger than
    /// this is sent in several messages.
    static let maxDeleteCount = 500

    enum ClearRange: String {
        case hour, today, all

        /// Visits at or after this time are cleared; nil clears everything.
        func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Double? {
            switch self {
            case .hour: return now.addingTimeInterval(-3600).timeIntervalSince1970
            case .today: return calendar.startOfDay(for: now).timeIntervalSince1970
            case .all: return nil
            }
        }

        var question: String {
            switch self {
            case .hour: return "Clear history from the last hour?"
            case .today: return "Clear today’s history?"
            case .all: return "Clear all history?"
            }
        }
    }

    /// Asks the user to confirm a clear, natively: a sheet on the window showing
    /// the tab, so no state of the page — and nothing that ever found its way
    /// into it — can confirm on the user's behalf or skip the question. Calls
    /// back with false when there is no window to ask in. A test seam, like
    /// `database`: production never assigns it.
    static var confirmClear: (BrowserTab, ClearRange, @escaping (Bool) -> Void) -> Void = presentClearConfirmation

    /// The history database the page reads, as a test seam: the bridge is
    /// reached through a real web view, so an integration test has no call site
    /// to hand a database to. Production never assigns it; a test that does
    /// must put `.shared` back in its tearDown.
    static var database: HistoryDatabase = .shared

    /// What a tab's History page may see: the visits of every space that
    /// currently uses the tab's profile. Derived from the sending tab — the
    /// page never names a profile or a space. Nil for incognito (nothing is
    /// recorded, and the page must not fall through to another profile).
    static func scope(for tab: BrowserTab, in store: TabStore = .shared) -> [String]? {
        guard let profile = tab.owningProfile, !profile.isIncognito, !profile.isDeleted else { return nil }
        return store.spaces.filter { $0.profileID == profile.id }.map { $0.id.uuidString }
    }

    static func handle(method: String, params: [String: Any], from tab: BrowserTab,
                       database: HistoryDatabase = HistoryPageBridge.database,
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
            // The period the page named, turned into instants here (TASK-92) —
            // unless the page echoed back the window its listing's first page
            // was resolved under, which is then the window this page of it is
            // read with. Either way the reply says which window that was, so
            // the whole listing agrees about where the period begins and ends
            // however long it stays open.
            guard let resolved = resolvedWindow(params) else { return reply(nil, "malformed") }
            DispatchQueue.global(qos: .userInitiated).async {
                // One extra row tells the page whether there is more to load.
                let rows = search.isEmpty
                    ? database.visits(spaceIDs: spaceIDs, from: resolved.from, until: resolved.until,
                                      before: cursor, limit: limit + 1)
                    : database.searchVisits(query: search, spaceIDs: spaceIDs, from: resolved.from,
                                            until: resolved.until, before: cursor, limit: limit + 1)
                let page = Array(rows.prefix(limit))
                var result: [String: Any] = ["entries": page.map(payload(for:)), "incognito": false]
                // Absent for all of history: there is no window to page inside.
                if let window = resolved.window { result["window"] = window.bridgeValue }
                if rows.count > limit, let last = page.last {
                    result["nextCursor"] = ["time": last.visitTime, "id": last.visitID]
                }
                DispatchQueue.main.async { reply(result, nil) }
            }
        case "history.delete":
            guard let spaceIDs = scope(for: tab) else { return reply(nil, "unavailable") }
            let ids = (params["ids"] as? [NSNumber] ?? []).map(\.int64Value)
            guard !ids.isEmpty, ids.count <= maxDeleteCount else { return reply(nil, "malformed") }
            let allVisitsOfURL = params["allVisitsOfURL"] as? Bool ?? false
            let sent: HistoryTimeWindow?
            switch windowParam(params["window"]) {
            case .malformed: return reply(nil, "malformed")
            case .absent: sent = nil
            case .window(let value): sent = value
            }
            // A row read under a period stands for the URL's visits inside it,
            // so the fan-out is narrowed to the window that row was rendered
            // under (TASK-92) — the page echoes the one its listing was read
            // with rather than naming a period this side would re-resolve to
            // some other pair of instants. A per-visit delete names one row and
            // needs no window; the page sends none, and one sent anyway is
            // ignored rather than allowed to silently spare the named visit.
            let window = allVisitsOfURL ? sent : nil
            // Taken before the write, not after it: a visit recorded while the
            // delete is in flight is newer than the request and its in-memory
            // state must survive `historyDidDelete` (TASK-87).
            let requestedAt = Date()
            database.deleteVisits(ids: ids, spaceIDs: spaceIDs, allVisitsOfURL: allVisitsOfURL,
                                  from: window?.from, until: window?.until) { result in
                DispatchQueue.main.async {
                    finish(result, spaceIDs: spaceIDs, requestedAt: requestedAt, clearedScope: false,
                           reply: reply)
                }
            }
        case "history.clear":
            guard scope(for: tab) != nil else { return reply(nil, "unavailable") }
            guard let range = (params["range"] as? String).flatMap(ClearRange.init(rawValue:)) else {
                return reply(nil, "malformed")
            }
            confirmClear(tab, range) { confirmed in
                guard confirmed else { return reply(["cleared": false, "deleted": 0], nil) }
                // The sheet blocks its own window only: spaces can be added or
                // deleted, and the tab can change profile, while the question is
                // up. The scope that is cleared is the one the tab has now, not
                // the one it had when the question was asked (TASK-87).
                guard let spaceIDs = scope(for: tab) else { return reply(nil, "unavailable") }
                // The cutoff is taken after the user answered: "the last hour"
                // means the hour before they said yes.
                let requestedAt = Date()
                database.deleteVisits(spaceIDs: spaceIDs, since: range.cutoff()) { result in
                    DispatchQueue.main.async {
                        finish(result, spaceIDs: spaceIDs, requestedAt: requestedAt, clearedScope: true,
                               reply: reply)
                    }
                }
            }
        default:
            reply(nil, "unknown method")
        }
    }

    /// Answers a finished delete. A write that failed is reported as one: the
    /// page keeps the rows it asked about, and the store keeps the cache entries
    /// that still describe rows in the database (TASK-87).
    private static func finish(_ result: Result<HistoryDeletionResult, Error>, spaceIDs: [String],
                               requestedAt: Date, clearedScope: Bool,
                               reply: (Any?, String?) -> Void) {
        switch result {
        case .success(let deletion):
            TabStore.shared.historyDidDelete(deletion, spaceIDs: spaceIDs, requestedAt: requestedAt,
                                             clearedScope: clearedScope)
            reply(["cleared": true, "deleted": deletion.deletedVisitCount], nil)
        case .failure:
            reply(nil, "failed")
        }
    }

    private static func presentClearConfirmation(for tab: BrowserTab, range: ClearRange,
                                                 completion: @escaping (Bool) -> Void) {
        // No window (the tab is not on screen), or one already asking something:
        // refuse rather than queue a destructive question the user cannot see.
        guard let window = tab.webView?.window, window.attachedSheet == nil else { return completion(false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = range.question
        let profile = tab.owningProfile?.name ?? ""
        alert.informativeText = "This removes the browsing history of the “\(profile)” profile from Detour. Other profiles are not affected. This can’t be undone."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// What a `window` param said. Absent is not malformed — the first page of
    /// a listing has no window to echo yet, and all of history never gets one.
    private enum WindowParam {
        case absent
        case window(HistoryTimeWindow)
        case malformed
    }

    private static func windowParam(_ value: Any?) -> WindowParam {
        guard let value, !(value is NSNull) else { return .absent }
        guard let window = HistoryTimeWindow(bridgeValue: value) else { return .malformed }
        return .window(window)
    }

    /// The window one `history.query` reads under, and the one its reply
    /// reports: the page's echoed `window` when it sent one, else the bounds of
    /// the symbolic `range`. Nil when either param is malformed — the `range` is
    /// validated even when a window overrides its bounds, because a message that
    /// says something unrecognizable is refused rather than half-read.
    ///
    /// `window` is nil only for all of history, which has no bounds to agree on.
    private static func resolvedWindow(_ params: [String: Any])
        -> (window: HistoryTimeWindow?, from: Double?, until: Double?)? {
        guard let bounds = HistoryTimeRange.parse(params["range"]).bounds() else { return nil }
        switch windowParam(params["window"]) {
        case .malformed:
            return nil
        case .window(let window):
            return (window, window.from, window.until)
        case .absent:
            guard let from = bounds.from else { return (nil, nil, nil) }
            return (HistoryTimeWindow(from: from, until: bounds.until), from, bounds.until)
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
