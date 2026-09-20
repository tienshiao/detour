import Foundation

/// How many `connectNative` attempts to a real native messaging host may be
/// logged, per (profile, extension, host), before the rest of the window is
/// summarised instead (TASK-90).
///
/// Every attempt and its outcome has to reach the *persisted* log: the incident
/// this exists for was diagnosed a day late because the interesting lines on
/// this path were `.info` (dropped from the log store) or absent altogether, and
/// the evidence for the hours before it had already been evicted. But an
/// extension stuck in a reconnect loop is exactly the case that needs logging
/// *and* exactly the case that would flood the store if every attempt wrote a
/// line — so the first `linesPerWindow` attempts of each window are logged in
/// full and the rest are counted, by outcome, and reported in one summary line.
///
/// Like `ConsoleBridgeLimiter`, the summary rides on the next attempt that is
/// logged rather than on a timer: a loop that stops leaves its final tally
/// unreported until the extension tries again, which is acceptable because the
/// lines that were logged already say what was happening.
///
/// Pure and clock-injected so `NativeConnectLogLimiterTests` can drive it
/// exactly; `Date` is only the default argument. Not thread-safe — it is owned
/// by `ExtensionManager` and touched only from the main thread, where WebKit's
/// delegate callbacks arrive.
struct NativeConnectLogLimiter {
    /// Attempts logged in full per key per `windowDuration`. Five is enough to
    /// see a normal connect, a retry and a couple of failures before Detour
    /// starts summarising.
    static let linesPerWindow = 5
    static let windowDuration: TimeInterval = 60

    /// What one attempt did — the breakdown a summary line carries, so a
    /// suppressed storm still says whether it was connecting or being refused.
    enum Outcome: Equatable {
        case connected
        case failed
        case refused
    }

    /// Attempts that were not logged in full, by outcome.
    struct Suppressed: Equatable {
        var connected = 0
        var failed = 0
        var refused = 0

        var total: Int { connected + failed + refused }

        mutating func record(_ outcome: Outcome) {
            switch outcome {
            case .connected: connected += 1
            case .failed: failed += 1
            case .refused: refused += 1
            }
        }
    }

    /// One (profile, extension, host) triple. Bounded by the extensions loaded
    /// across the profiles times the host names they name, so entries are not
    /// expired: an extension that stops connecting leaves one small window
    /// behind.
    struct Key: Hashable {
        let profileName: String
        let extensionID: String
        let hostName: String
    }

    enum Decision: Equatable {
        /// Log this attempt in full.
        case log
        /// Over the cap: say nothing, it is counted.
        case suppress
        /// Log this attempt in full, and first report what the window that just
        /// closed suppressed. `interval` is how long ago that window opened —
        /// the quiet gap before this attempt included — so it is the honest
        /// denominator for `suppressed`, and may be longer than
        /// `windowDuration`.
        case logReportingSuppressed(Suppressed, interval: TimeInterval)
    }

    private struct Window {
        var start: Date
        var logged: Int
        var suppressed: Suppressed
    }

    private var windows: [Key: Window] = [:]

    /// Whether this attempt should be logged in full, and what the caller still
    /// owes the log about the attempts that were not.
    mutating func admit(_ key: Key, outcome: Outcome, now: Date = Date()) -> Decision {
        guard var window = windows[key] else {
            windows[key] = Window(start: now, logged: 1, suppressed: Suppressed())
            return .log
        }

        let elapsed = now.timeIntervalSince(window.start)
        // A clock that jumped backwards rolls the window too: the alternative is
        // stalling the cap — and losing the summary — until real time catches up.
        if elapsed >= Self.windowDuration || elapsed < 0 {
            let suppressed = window.suppressed
            windows[key] = Window(start: now, logged: 1, suppressed: Suppressed())
            return suppressed.total > 0
                ? .logReportingSuppressed(suppressed, interval: max(0, elapsed))
                : .log
        }

        if window.logged < Self.linesPerWindow {
            window.logged += 1
            windows[key] = window
            return .log
        }

        window.suppressed.record(outcome)
        windows[key] = window
        return .suppress
    }
}
