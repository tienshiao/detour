import Foundation
import os.log

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "back-forward-cache")

/// Trims the back/forward cache of tabs hidden for a while (TASK-408).
///
/// WebKit keeps a tab's recent back/forward entries as complete frozen pages,
/// and after a cross-site navigation it keeps the old site's web process
/// alive to hold one. Those suspended processes keep their GPU-process
/// IOSurfaces: six tabs navigated three times each held 14 web processes and
/// 2,367 IOSurface regions, and clearing their caches brought that to 7 and
/// 1,521 within 30 s (TASK-405). Trimming keeps the back/forward list, so Back
/// and Forward still work; a trimmed entry loads again instead of resuming
/// frozen. The delay is the user's choice (2026-11-17): 15 minutes hidden, so
/// "click a link, go back" on a tab in use stays instant.
extension TabStore {

    static let backForwardTrimDelay = backForwardTrimDelaySetting()
    static let defaultBackForwardTrimDelay: TimeInterval = 15 * 60

    /// `DETOUR_BACK_FORWARD_TRIM_SECONDS` overrides the delay for harness runs;
    /// a negative or unparseable value is ignored.
    static func backForwardTrimDelaySetting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["DETOUR_BACK_FORWARD_TRIM_SECONDS"],
              let value = TimeInterval(raw), value.isFinite, value >= 0 else { return defaultBackForwardTrimDelay }
        return value
    }

    /// Whether `tab`'s back/forward cache is due a trim at `now`: it has a web
    /// view that no window hosts, it has been deselected for at least `delay`,
    /// this hidden stretch has not been trimmed yet, and it is not playing
    /// sound or capturing (a page on a call is left alone entirely, as by the
    /// sleep rules). A profile set to never sleep tabs is trimmed too: this
    /// keeps the page live and only drops the frozen back pages.
    static func isDueBackForwardTrim(_ tab: BrowserTab, now: Date, delay: TimeInterval) -> Bool {
        guard tab.webView != nil,
              tab.webViewContainer?.superview == nil,
              let since = tab.lastDeselectedAt,
              now.timeIntervalSince(since) >= delay,
              tab.backForwardCacheTrimmedForDeselection != since,
              !tab.isAudible, !tab.isCapturingMedia else { return false }
        return true
    }

    /// Trims every due tab's back/forward cache — space tabs and pinned
    /// entries' and favourites' backing tabs alike — and returns the tabs it
    /// trimmed. Peeks and Quick Detour pages are walked too but never stamp
    /// `lastDeselectedAt`, so they are not reached. Driven by `archiveTimer`; `now` and
    /// `delay` are injectable for tests.
    @discardableResult
    func trimStaleBackForwardCaches(now: Date = Date(),
                                    delay: TimeInterval = TabStore.backForwardTrimDelay) -> [BrowserTab] {
        var seen = Set<ObjectIdentifier>()
        var trimmed: [BrowserTab] = []
        for tab in allLiveTabs where seen.insert(ObjectIdentifier(tab)).inserted {
            guard Self.isDueBackForwardTrim(tab, now: now, delay: delay) else { continue }
            // Marked even when WebKit lacks the call, so a missing selector
            // costs one check per stretch, not one per timer tick.
            tab.backForwardCacheTrimmedForDeselection = tab.lastDeselectedAt
            if tab.clearBackForwardCache() { trimmed.append(tab) }
        }
        if !trimmed.isEmpty {
            log.notice("Trimmed the back/forward caches of \(trimmed.count) tabs hidden for \(Int(delay)) s or more")
        }
        return trimmed
    }
}
