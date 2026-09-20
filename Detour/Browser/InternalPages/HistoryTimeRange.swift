import Foundation

/// The period the History page is looking at (TASK-92).
///
/// A period is named symbolically — `today`, `yesterday`, a `YYYY-MM-DD` day —
/// and turned into instants here, the same rule as
/// `HistoryPageBridge.ClearRange`'s cutoff (TASK-87). The resolved window then
/// travels back to the page as a `HistoryTimeWindow` (below) so that one
/// listing pages and deletes against the window it was rendered under; see
/// `HistoryPageBridge` for why letting the page echo those instants is safe
/// while `history.clear` still refuses to be told one.
///
/// Every bound is day-aligned in the *local* calendar and half-open,
/// `[from, until)`, so one page of a listing and the next agree about where the
/// period ends however long the request takes. All of the day arithmetic goes
/// through `Calendar.date(byAdding: .day, …)` rather than a multiple of 86400:
/// on the two days a year that are 23 or 25 hours long, "yesterday" and "the
/// last 7 days" would otherwise start an hour off.
enum HistoryTimeRange: Equatable {
    case today
    case yesterday
    /// The last 7 days: today and the six days before it.
    case week
    /// The last 30 days: today and the 29 days before it.
    case month
    /// One calendar day. The components are validated at parse time; see
    /// `init?(day:)`.
    case day(year: Int, month: Int, day: Int)

    /// What a `range` param meant. "Absent" and "malformed" are deliberately not
    /// the same answer: a message that says nothing about a period asks for all
    /// of history, while one that says something unrecognizable is refused
    /// rather than quietly widened to everything.
    enum Parsed: Equatable {
        case allTime
        case range(HistoryTimeRange)
        case malformed
    }

    /// Reads the wire form: `{"preset": "today"|"yesterday"|"week"|"month"}` or
    /// `{"day": "YYYY-MM-DD"}`. `nil` (and JSON `null`) is all time; anything
    /// else — another type, an unknown preset, both keys at once, an extra key,
    /// a day that is not a real date — is malformed.
    ///
    /// A valid day *outside* the 90-day retention window is not malformed: it is
    /// simply a period nothing was recorded in, and answering it with an empty
    /// list is the honest reply.
    static func parse(_ value: Any?) -> Parsed {
        guard let value, !(value is NSNull) else { return .allTime }
        guard let fields = value as? [String: Any], fields.count == 1 else { return .malformed }
        if let preset = fields["preset"] {
            guard let name = preset as? String, let range = Self(preset: name) else { return .malformed }
            return .range(range)
        }
        if let day = fields["day"] {
            guard let text = day as? String, let range = Self(day: text) else { return .malformed }
            return .range(range)
        }
        return .malformed
    }

    private init?(preset: String) {
        switch preset {
        case "today": self = .today
        case "yesterday": self = .yesterday
        case "week": self = .week
        case "month": self = .month
        default: return nil
        }
    }

    /// `YYYY-MM-DD`, strictly: exactly three ASCII-digit groups of 4, 2 and 2,
    /// and a date the calendar agrees exists. `DateFormatter` is not used — it
    /// accepts `2026-2-3`, and with a lenient calendar rolls `2026-02-30` over
    /// into March rather than refusing it. The round trip below is what refuses
    /// it: a day that comes back as a different day was never that day.
    init?(day text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        // Validated against a fixed calendar, not the caller's: whether a date
        // exists is a property of the date, not of the reader's time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let round = calendar.dateComponents([.year, .month, .day], from: date)
        guard round.year == year, round.month == month, round.day == day else { return nil }
        self = .day(year: year, month: month, day: day)
    }

    /// The half-open window `[from, until)` in seconds since 1970. A `nil`
    /// `until` is "up to now and beyond" — a period that is still running, so
    /// a visit recorded while the page is open belongs to it.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (from: Double, until: Double?) {
        let calendar = gregorian(like: calendar)
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (startOfToday.timeIntervalSince1970, nil)
        case .yesterday:
            return (startOfDay(calendar, daysBefore: 1, from: startOfToday).timeIntervalSince1970,
                    startOfToday.timeIntervalSince1970)
        case .week:
            return (startOfDay(calendar, daysBefore: 6, from: startOfToday).timeIntervalSince1970, nil)
        case .month:
            return (startOfDay(calendar, daysBefore: 29, from: startOfToday).timeIntervalSince1970, nil)
        case .day(let year, let month, let day):
            // Anchored at noon rather than at midnight: on a day whose midnight
            // does not exist (a DST jump at 00:00, as Brazil used to have),
            // `date(from:)` would answer some other instant. Noon always exists,
            // and `startOfDay` walks back to the day's real first instant.
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = 12
            guard let noon = calendar.date(from: components),
                  let nextNoon = calendar.date(byAdding: .day, value: 1, to: noon) else {
                // Unreachable for a parsed day; an empty window rather than a
                // crash or an accidental "all time".
                return (0, 0)
            }
            let start = calendar.startOfDay(for: noon)
            return (start.timeIntervalSince1970, calendar.startOfDay(for: nextNoon).timeIntervalSince1970)
        }
    }

    /// `calendar`'s time zone, read with the Gregorian calendar.
    ///
    /// A day the page names is a *Gregorian* day — the date field speaks
    /// `YYYY-MM-DD` and nothing else — while `Calendar.current` is whatever the
    /// user set macOS to. Resolving 2026-09-18 in the Buddhist calendar gives a
    /// day 543 years out, and in the Japanese one a year 2026 of the current era
    /// that does not exist at all; the day the list then shows is not the day
    /// the control says. The presets are day arithmetic (`startOfDay`, ±n days),
    /// which lands on the same instants in any calendar whose days start at
    /// midnight, but they go through this one too: one rule per method is easier
    /// to keep true than two. Only the calendar system is replaced — the time
    /// zone is the user's, and it is what decides where a local day begins.
    private func gregorian(like calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    private func startOfDay(_ calendar: Calendar, daysBefore days: Int, from start: Date) -> Date {
        guard let shifted = calendar.date(byAdding: .day, value: -days, to: start) else { return start }
        // `byAdding` keeps the wall-clock time where it can, which on a day that
        // gained an hour lands at 23:00 the day before; take the day's start
        // again rather than trusting the arithmetic.
        return calendar.startOfDay(for: shifted)
    }
}

extension HistoryTimeRange.Parsed {
    /// The bounds to query with: `(nil, nil)` for all time. Malformed has no
    /// bounds — a caller must refuse it before asking.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (from: Double?, until: Double?)? {
        switch self {
        case .allTime: return (nil, nil)
        case .range(let range):
            let window = range.bounds(now: now, calendar: calendar)
            return (window.from, window.until)
        case .malformed: return nil
        }
    }
}

/// One listing's resolved period (TASK-92): the half-open window
/// `[from, until)` in seconds since 1970 that a page of entries was read under,
/// as it travels on the wire in both directions.
///
/// `history.query` answers with the window it resolved, and the page sends that
/// same window back on every later page of the listing — and on a URL-mode
/// `history.delete` of one of its rows. A symbolic period would not do: "today"
/// re-resolved at the next request is a different pair of instants once the
/// clock has passed midnight, and the listing would page, and delete, against a
/// window it was never rendered under.
///
/// So this is the one place where the page names instants rather than a period.
/// What that can do is bounded by the two things it cannot touch: the scope,
/// which is always derived from the sending tab, and the direction — a window
/// only ever *narrows*, a read or a fan-out. `HistoryPageBridge`'s doc comment
/// has the argument in full.
struct HistoryTimeWindow: Equatable {
    let from: Double
    /// `nil` is "up to now and beyond": a period that is still running.
    let until: Double?

    init(from: Double, until: Double?) {
        self.from = from
        self.until = until
    }

    /// Reads the wire form `{"from": <number>, "until": <number>|null}`.
    ///
    /// Exactly those two keys, both present, `from` finite, `until` finite or
    /// null, and — when there is an upper bound — `from < until`. Everything
    /// else is refused: a window is not a thing to guess at, and a caller that
    /// cannot say what it means gets "malformed" rather than some wider period
    /// it did not ask for. An empty or inverted window would ask the database
    /// for rows it can never return, which no honest caller wants.
    init?(bridgeValue: Any?) {
        guard let fields = bridgeValue as? [String: Any], fields.count == 2,
              let from = Self.finite(fields["from"]), let rawUntil = fields["until"] else { return nil }
        if rawUntil is NSNull {
            self.init(from: from, until: nil)
            return
        }
        guard let until = Self.finite(rawUntil), from < until else { return nil }
        self.init(from: from, until: until)
    }

    var bridgeValue: [String: Any] {
        ["from": from, "until": until ?? NSNull()]
    }

    /// A finite JavaScript number, and not a boolean: `true` bridges to an
    /// `NSNumber` too, and a window bounded by `true` is nonsense.
    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
