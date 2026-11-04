import Foundation

/// The rows the command palette shows for a typed query, and how a pass that
/// lands late treats the user's keyboard selection.
///
/// The list area is a fixed `visibleRows` tall (TASK-184), so the rows fill it
/// rather than leaving empty space: matches first, search suggestions in the
/// room below `visibleRows`, then rows from the default (empty-field) list.
/// Kept apart from `CommandPaletteView` so the rules can be tested without a
/// window.
enum PaletteRows {
    static let visibleRows = 6

    /// - Parameters:
    ///   - matches: the latest local pass (top hit, verbatim row, hosts, open
    ///     tabs, history), in order.
    ///   - searchSuggestions: the network suggestions for the query, or those
    ///     carried over from the previous query while its fetch is pending.
    ///   - filler: the default list, used only to fill rows below
    ///     `visibleRows`; a filler row for a URL already listed is skipped.
    static func compose(matches: [SuggestionItem], searchSuggestions: [String],
                        filler: [SuggestionItem]) -> [SuggestionItem] {
        let maximum = SuggestionProvider.maxSuggestions
        var rows = Array(matches.prefix(maximum))

        let searchRoom = min(max(SuggestionProvider.maxSearchSuggestions, visibleRows - rows.count),
                             maximum - rows.count)
        rows += searchSuggestions.prefix(searchRoom).map { .searchSuggestion(text: $0) }

        var listedURLs = Set(rows.compactMap(url(of:)))
        for item in filler where rows.count < visibleRows {
            guard let url = url(of: item), !listedURLs.contains(url) else { continue }
            rows.append(item)
            listedURLs.insert(url)
        }
        return rows
    }

    /// The previous query's search suggestions still worth showing while the
    /// new query's fetch is pending: those the new text still prefixes, so
    /// the bottom rows do not blank out and refill on every keystroke.
    static func carriedSearchSuggestions(_ previous: [String], to query: String) -> [String] {
        let q = query.lowercased()
        return previous.filter {
            let s = $0.lowercased()
            return s.hasPrefix(q) && s != q
        }
    }

    enum LatePassOutcome: Equatable {
        /// Replace the rows; the selection goes back to the list's initial row.
        case apply
        /// Replace the rows and leave the selection where the user put it.
        case applyKeepingSelection
        /// Leave the list as it is: the replacement would change the row the
        /// user has selected (and whose text the field shows).
        case skip
    }

    /// What a pass that lands after the list was built for the same query (the
    /// background history pass, the network search suggestions) may do to it.
    /// While the selection is where the list put it, the pass replaces the
    /// rows as usual. Once the user has moved it with the arrow keys
    /// (`selectionMoved`, even back onto the row the list selected), rows are
    /// never changed under it.
    static func latePassOutcome(old: [SuggestionItem], new: [SuggestionItem],
                                selectedRow: Int?, selectionMoved: Bool) -> LatePassOutcome {
        guard selectionMoved else { return .apply }
        // Arrowed off the list: the field shows the typed text and no row is
        // selected, so any rows will do.
        guard let selected = selectedRow else { return .applyKeepingSelection }
        guard selected < old.count, selected < new.count,
              old[...selected] == new[...selected] else { return .skip }
        return .applyKeepingSelection
    }

    private static func url(of item: SuggestionItem) -> String? {
        switch item {
        case .historyResult(let url, _, _), .openTab(_, _, let url, _, _):
            return url
        case .searchInput, .searchSuggestion:
            return nil
        }
    }
}
