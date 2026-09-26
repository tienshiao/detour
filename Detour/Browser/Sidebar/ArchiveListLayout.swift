import Foundation

/// One closed-tab record as the Archived Tabs page lists it (TASK-119): plain
/// closes and archived records alike, from every non-incognito space.
struct ArchiveEntry: Equatable {
    let id: Int64
    let spaceID: UUID
    let title: String
    let url: String?
    let faviconURL: URL?
    /// nil for rows written before closedAt existed (v16); they list last, undated.
    let closedAt: Date?
    /// False for a disabled extension's page: listed, but nothing could show it.
    let isRestorable: Bool
}

/// The relative-date group an entry is listed under, Arc-style.
enum ArchiveBucket: Hashable {
    case today
    case yesterday
    case daysAgo(Int)
    case weeksAgo(Int)
    case monthsAgo(Int)
    case yearsAgo(Int)
    case undated
}

/// The bucket for a close at `date`, counted in calendar days between the two
/// start-of-day dates (so "yesterday" means the previous calendar day, not 24
/// hours). A date after `now` (clock change) counts as today.
func archiveBucket(for date: Date, now: Date, calendar: Calendar) -> ArchiveBucket {
    let start = calendar.startOfDay(for: date)
    let end = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
    switch days {
    case ..<1: return .today
    case 1: return .yesterday
    case 2...6: return .daysAgo(days)
    case 7...29: return .weeksAgo(days / 7)
    default:
        let months = max(1, calendar.dateComponents([.month], from: start, to: end).month ?? 1)
        return months < 12 ? .monthsAgo(months) : .yearsAgo(months / 12)
    }
}

func archiveBucketTitle(_ bucket: ArchiveBucket) -> String {
    func plural(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago"
    }
    switch bucket {
    case .today: return "Today"
    case .yesterday: return "Yesterday"
    case .daysAgo(let n): return plural(n, "day")
    case .weeksAgo(let n): return plural(n, "week")
    case .monthsAgo(let n): return plural(n, "month")
    case .yearsAgo(let n): return plural(n, "year")
    case .undated: return "Undated"
    }
}

enum ArchiveRow: Equatable {
    case header(ArchiveBucket)
    case entry(ArchiveEntry)
}

/// The Archived Tabs table's rows: the entries of `spaceFilter` (every space
/// when nil) matching `query`, newest first under relative-date headers.
///
/// Dated entries sort by closedAt descending, ties by id descending (both
/// members of a split close share one stamp; the later row closed later).
/// Undated entries follow in one `.undated` group, newest id first. A header is
/// emitted only for a bucket with at least one surviving entry.
///
/// The query is split on whitespace and every term must occur — ignoring case
/// and diacritics — in the title or the URL without its scheme (so "https"
/// does not match every row).
func archiveRows(entries: [ArchiveEntry], query: String, spaceFilter: UUID?,
                 now: Date, calendar: Calendar) -> [ArchiveRow] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let matching = entries.filter { entry in
        if let spaceFilter, entry.spaceID != spaceFilter { return false }
        guard !terms.isEmpty else { return true }
        let url = entry.url.map(archiveSchemelessURL) ?? ""
        return terms.allSatisfy { term in
            entry.title.range(of: term, options: options) != nil
                || url.range(of: term, options: options) != nil
        }
    }
    let sorted = matching.sorted { a, b in
        switch (a.closedAt, b.closedAt) {
        case let (x?, y?):
            return x != y ? x > y : a.id > b.id
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.id > b.id
        }
    }
    var rows: [ArchiveRow] = []
    var currentBucket: ArchiveBucket?
    for entry in sorted {
        let bucket = entry.closedAt.map { archiveBucket(for: $0, now: now, calendar: calendar) } ?? .undated
        if bucket != currentBucket {
            rows.append(.header(bucket))
            currentBucket = bucket
        }
        rows.append(.entry(entry))
    }
    return rows
}

/// `url` without its `scheme://` prefix; a URL without one is returned as is.
func archiveSchemelessURL(_ url: String) -> String {
    guard let separator = url.range(of: "://") else { return url }
    let scheme = url[..<separator.lowerBound]
    guard let first = scheme.first, first.isLetter,
          scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return url }
    return String(url[separator.upperBound...])
}

/// The URL line of an archive row: no scheme, no leading `www.`, and no
/// trailing `/` when it is the whole path (`https://www.a.com/` → `a.com`).
func archiveDisplayURL(_ url: String?) -> String {
    guard let url else { return "" }
    var display = archiveSchemelessURL(url)
    if display.lowercased().hasPrefix("www.") {
        display.removeFirst(4)
    }
    if let slash = display.firstIndex(of: "/"), display[slash...] == "/" {
        display.removeLast()
    }
    return display
}
