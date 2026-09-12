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
/// A fixed window rather than a token bucket, because the aim here is a hard
/// ceiling on log writes per extension per second, not smooth pacing: the first
/// `messagesPerWindow` messages of each window are forwarded and the rest are
/// counted. The count is reported once, on the first message of the next window
/// — so a flood that stops dead leaves its final tally unreported until the
/// extension logs again (the JS side's summary covers that case, and an
/// extension that never logs again has nothing left to hide).
///
/// Pure and clock-injected so `ConsoleBridgeLimiterTests` can drive it exactly;
/// `Date` is only the default argument. Not thread-safe — it is owned by
/// `ExtensionPolyfillHandler` and touched only from the message-handler thread.
struct ConsoleBridgeLimiter {
    /// Messages forwarded per extension per `windowDuration`. 100/s is far above
    /// any legitimate extension's steady-state chatter and far below the rate at
    /// which the unified log becomes the bottleneck.
    static let messagesPerWindow = 100
    static let windowDuration: TimeInterval = 1.0

    enum Decision: Equatable {
        /// Forward the message.
        case allow
        /// Forward the message, and first report that `count` messages were
        /// dropped in the previous window. Drops only ever accumulate within one
        /// `windowDuration` of a window's start; `interval` is how long ago that
        /// window opened — the quiet gap before this message included — not the
        /// span the flood ran, so it must not be presented as a rate denominator.
        case allowReportingDropped(count: Int, interval: TimeInterval)
        /// Over the cap: do not forward, do not log.
        case drop
    }

    private struct Window {
        var start: Date
        var forwarded: Int
        var dropped: Int
    }

    /// One entry per extension that has used the console bridge. Bounded by the
    /// number of extensions loaded in the owning profile.
    private var windows: [String: Window] = [:]

    /// Whether this message should be forwarded, and what the caller still owes
    /// the log about the messages that were not.
    mutating func admit(_ extensionID: String, now: Date = Date()) -> Decision {
        guard var window = windows[extensionID] else {
            windows[extensionID] = Window(start: now, forwarded: 1, dropped: 0)
            return .allow
        }

        let elapsed = now.timeIntervalSince(window.start)
        // A clock that jumped backwards rolls the window too: the alternative is
        // stalling the cap until real time catches up.
        if elapsed >= Self.windowDuration || elapsed < 0 {
            let dropped = window.dropped
            windows[extensionID] = Window(start: now, forwarded: 1, dropped: 0)
            return dropped > 0
                ? .allowReportingDropped(count: dropped, interval: max(0, elapsed))
                : .allow
        }

        if window.forwarded < Self.messagesPerWindow {
            window.forwarded += 1
            windows[extensionID] = window
            return .allow
        }

        window.dropped += 1
        windows[extensionID] = window
        return .drop
    }

    /// Forget an extension's window — for unload, so an id that never comes back
    /// does not keep an entry. Any unreported drop count goes with it.
    mutating func forget(_ extensionID: String) {
        windows.removeValue(forKey: extensionID)
    }
}
