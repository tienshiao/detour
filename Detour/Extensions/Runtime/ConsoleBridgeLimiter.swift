import Foundation

/// Per-extension cap on how many console-bridge messages reach the log, as
/// defence in depth behind the polyfill's own limiter (TASK-17).
///
/// The JS limiter in `ExtensionAPIPolyfill.consoleJS` is the first line of
/// defence, but it lives in the extension's own context: a context that loaded
/// before an update, one whose `console` was replaced by the extension after the
/// polyfill wrapped it, or a page that posts `{type:"log"}` to the bridge
/// directly, is not limited by it at all. This is the limit the native side can
/// actually rely on, and the one that protects the unified log — a worker error
/// loop once produced ~950,000 lines in 55 seconds.
///
/// A token bucket, since TASK-90. The original fixed window only had a ceiling
/// *per second* (`burstCapacity`), which is a cap on a spike and no cap at all
/// on a steady stream: the incident that motivated the change ran at 20 errors a
/// second for hours — a fifth of the burst, so the limiter never engaged once —
/// and cost ~1,200 persisted log writes a minute, which evicted the rest of
/// Detour's log history and left the incident itself undiagnosable. The bucket
/// keeps the burst whole (a worker's start-up chatter is legitimate and passes
/// untouched) and adds the sustained rate the window never had, so that same
/// loop is cut to `sustainedRatePerSecond`.
///
/// Pure and clock-injected so `ConsoleBridgeLimiterTests` can drive it exactly;
/// `Date` is only the default argument. Not thread-safe — it is owned by
/// `ExtensionPolyfillHandler` and touched only from the message-handler thread.
struct ConsoleBridgeLimiter {
    /// Bucket capacity: the longest run of messages an extension can log at once
    /// after being quiet, and what a worker's start-up burst is measured against.
    /// 100 is far above any legitimate extension's steady-state chatter and far
    /// below the rate at which the unified log becomes the bottleneck.
    static let burstCapacity = 100

    /// Tokens added per second once the burst is spent, i.e. the rate a
    /// permanently noisy extension is held to. Low enough that an error loop
    /// costs a few hundred log writes a minute instead of tens of thousands,
    /// high enough that the loop is still visible in `log show`.
    static let sustainedRatePerSecond: Double = 5

    /// While messages are being dropped, how often the accumulated count is
    /// reported. The report costs a log write of its own, so it is deliberately
    /// much rarer than the drops it summarises.
    static let dropReportInterval: TimeInterval = 30

    /// How long an extension must drop *continuously* before Detour calls it a
    /// flood incident and says so once, loudly.
    static let floodDuration: TimeInterval = 60

    /// The gap without a single dropped message that ends a drop streak: the
    /// flood clock starts over, and an admitted message reports the tail of what
    /// was dropped. Short enough that a flood that stops is recognised promptly,
    /// long enough that the pauses inside one loop do not reset the clock.
    static let dropStreakGap: TimeInterval = 10

    /// How long an extension must go without dropping before its flood incident
    /// is considered over. A later flood is then a new incident and is reported
    /// again — a loop that comes back after an hour is news, a loop that
    /// stutters for a second is not.
    static let floodIncidentIdle: TimeInterval = 60

    /// Tokens accumulate by repeated addition of `elapsed * rate`, so a bucket
    /// that is exactly full in exact arithmetic can land a few ulps short. Drops
    /// are decided against this tolerance so that steady traffic at exactly the
    /// sustained rate is admitted rather than dropping one message in a few
    /// thousand for no reason a reader could explain.
    private static let tokenEpsilon = 1e-9

    enum Decision: Equatable {
        /// Forward the message.
        case allow
        /// Forward the message, and first report that `count` messages were
        /// dropped over the preceding `interval` — the span from the first
        /// unreported drop to now, so it *is* a fair rate denominator. Sent at
        /// most once per `dropReportInterval` while dropping continues, plus
        /// once when dropping stops, so the reported counts always add up to
        /// every message this limiter threw away.
        case allowReportingDropped(count: Int, interval: TimeInterval)
        /// Over the cap: do not forward, do not log.
        case drop
        /// Over the cap, and this extension has now been dropping continuously
        /// for `floodDuration`: drop the message and report the incident. Fires
        /// exactly once per incident (see `floodIncidentIdle`), so the caller may
        /// log it at error level. `droppedSoFar` counts the whole streak, which
        /// overlaps what `allowReportingDropped` has already reported — it is a
        /// description of the incident, not another instalment of the tally.
        case dropReportingFlood(droppedSoFar: Int, since: TimeInterval)
    }

    private struct Bucket {
        /// Tokens left; one is spent per forwarded message.
        var tokens: Double
        /// When `tokens` was last brought up to date.
        var lastRefill: Date

        /// Dropped messages not yet reported, and when that tally started.
        var unreportedDrops = 0
        var unreportedSince: Date?
        /// When the last `allowReportingDropped` went out, if any.
        var lastReportAt: Date?

        /// The current run of dropping: when it started, how much it has dropped,
        /// and when it last dropped anything. Nil between streaks.
        var streakStart: Date?
        var streakDropped = 0
        var lastDropAt: Date?
        /// Whether the current incident has already been reported.
        var floodReported = false

        /// Treat a clock that jumped backwards as zero elapsed time rather than
        /// as a refill, a longer streak or a longer report interval: every stamp
        /// that is now in the future is re-anchored to the present.
        mutating func reanchorStamps(after now: Date) {
            if lastRefill > now { lastRefill = now }
            if let stamp = unreportedSince, stamp > now { unreportedSince = now }
            if let stamp = lastReportAt, stamp > now { lastReportAt = now }
            if let stamp = streakStart, stamp > now { streakStart = now }
            if let stamp = lastDropAt, stamp > now { lastDropAt = now }
        }
    }

    /// One entry per extension that has used the console bridge. Bounded by the
    /// number of extensions loaded in the owning profile.
    private var buckets: [String: Bucket] = [:]

    /// Whether this message should be forwarded, and what the caller still owes
    /// the log about the messages that were not.
    mutating func admit(_ extensionID: String, now: Date = Date()) -> Decision {
        // An extension the limiter has not seen starts with a full bucket: the
        // burst is what a worker's start-up is allowed to spend.
        var bucket = buckets[extensionID]
            ?? Bucket(tokens: Double(Self.burstCapacity), lastRefill: now)
        defer { buckets[extensionID] = bucket }

        bucket.reanchorStamps(after: now)

        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        bucket.tokens = min(Double(Self.burstCapacity),
                            bucket.tokens + elapsed * Self.sustainedRatePerSecond)
        bucket.lastRefill = now

        // Age the streak and the incident before deciding anything: a quiet gap
        // restarts the flood clock, and a longer quiet ends the incident so the
        // next flood is reported as a new one.
        if let lastDrop = bucket.lastDropAt {
            let quiet = now.timeIntervalSince(lastDrop)
            if quiet >= Self.dropStreakGap {
                bucket.streakStart = nil
                bucket.streakDropped = 0
            }
            if quiet >= Self.floodIncidentIdle {
                bucket.floodReported = false
            }
        }

        guard bucket.tokens >= 1 - Self.tokenEpsilon else {
            bucket.unreportedDrops += 1
            if bucket.unreportedSince == nil { bucket.unreportedSince = now }
            if bucket.streakStart == nil {
                bucket.streakStart = now
                bucket.streakDropped = 0
            }
            bucket.streakDropped += 1
            bucket.lastDropAt = now

            if !bucket.floodReported,
               let streakStart = bucket.streakStart,
               now.timeIntervalSince(streakStart) >= Self.floodDuration {
                bucket.floodReported = true
                return .dropReportingFlood(droppedSoFar: bucket.streakDropped,
                                           since: now.timeIntervalSince(streakStart))
            }
            return .drop
        }

        bucket.tokens -= 1
        guard bucket.unreportedDrops > 0 else { return .allow }

        // Report either because the drops have stopped — this message is the
        // first one admitted after the streak ended, and nothing else will ever
        // account for its tail — or because the last report is old enough.
        let droppingStopped = bucket.lastDropAt
            .map { now.timeIntervalSince($0) >= Self.dropStreakGap } ?? true
        let sinceLastReport = now.timeIntervalSince(
            bucket.lastReportAt ?? bucket.unreportedSince ?? now)
        guard droppingStopped || sinceLastReport >= Self.dropReportInterval else { return .allow }

        let count = bucket.unreportedDrops
        let interval = now.timeIntervalSince(bucket.unreportedSince ?? now)
        bucket.unreportedDrops = 0
        bucket.unreportedSince = nil
        bucket.lastReportAt = now
        return .allowReportingDropped(count: count, interval: interval)
    }

    /// Forget an extension's bucket — for unload, so an id that never comes back
    /// does not keep an entry. Any unreported drop count, and any incident in
    /// progress, goes with it: a context that reloads starts from a full bucket
    /// and can be reported on again.
    mutating func forget(_ extensionID: String) {
        buckets.removeValue(forKey: extensionID)
    }
}
