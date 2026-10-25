import Foundation

/// One run of audible playback in a tab, as the now-playing bar sees it
/// (TASK-192). A pause shorter than the grace period does not end it, so a
/// track change or a quick pause and resume neither flickers the bar nor
/// counts as playback starting anew.
struct MediaPlaybackSession: Equatable {
    /// When the run began: the bar shows the most recently started run, and a
    /// dismissal names the run it hid.
    var startedAt: Date
    /// When the tab last went quiet; nil while it is audible.
    var stoppedAt: Date?

    /// The session after the tab's audible state is observed at `now`.
    ///
    /// - Parameters:
    ///   - isPlaying: `BrowserTab.isPlayingAudio`.
    ///   - isHeld: the bar paused the tab (`BrowserTab.isPausedFromBar`): a
    ///     held run continues however long it was quiet.
    static func next(_ session: MediaPlaybackSession?, isPlaying: Bool, isHeld: Bool,
                     now: Date, grace: TimeInterval) -> MediaPlaybackSession? {
        guard isPlaying else {
            guard var session else { return nil }
            if session.stoppedAt == nil { session.stoppedAt = now }
            return session
        }
        if var session, session.isLive(isHeld: isHeld, now: now, grace: grace) {
            session.stoppedAt = nil
            return session
        }
        return MediaPlaybackSession(startedAt: now, stoppedAt: nil)
    }

    /// Whether the run still counts: audible, held by the bar, or quiet for
    /// less than `grace`.
    func isLive(isHeld: Bool, now: Date, grace: TimeInterval) -> Bool {
        guard let stoppedAt else { return true }
        return isHeld || now.timeIntervalSince(stoppedAt) < grace
    }
}

/// What the rule needs to know about one tab.
struct NowPlayingCandidate: Equatable {
    var tabID: UUID
    /// The tab's profile is the Private one.
    var isPrivate: Bool
    var session: MediaPlaybackSession?
    /// The bar paused the tab, so it stays on the bar while quiet.
    var isHeld: Bool = false
    /// The tab's video is in picture in picture, or was just asked to enter it.
    var isInPictureInPicture: Bool = false
    /// The `startedAt` of the run the user dismissed with the bar's ×.
    var dismissedSessionStart: Date?
}

/// Which tab, if any, a window's now-playing bar shows (TASK-192). Each window
/// decides for itself from every tab it could switch to — in any space.
enum NowPlayingRule {
    /// How long a tab that went quiet stays on the bar.
    static let grace: TimeInterval = 1.75

    /// - Parameters:
    ///   - visibleTabIDs: the tabs this window shows — the selected tab, and
    ///     both panes of a selected split.
    ///   - windowIsPrivate: a Private window shows only Private tabs, and a
    ///     normal window never shows them.
    /// - Returns: the most recently started live run among the tabs the user
    ///   has left, skipping a tab in picture in picture (its own window has the
    ///   controls) and a dismissed run.
    static func tabToShow(_ candidates: [NowPlayingCandidate], visibleTabIDs: Set<UUID>,
                          windowIsPrivate: Bool, now: Date, grace: TimeInterval = grace) -> UUID? {
        var best: (id: UUID, startedAt: Date)?
        for candidate in candidates {
            guard let session = candidate.session,
                  session.isLive(isHeld: candidate.isHeld, now: now, grace: grace),
                  candidate.isPrivate == windowIsPrivate,
                  !visibleTabIDs.contains(candidate.tabID),
                  !candidate.isInPictureInPicture,
                  candidate.dismissedSessionStart != session.startedAt else { continue }
            if let current = best, current.startedAt >= session.startedAt { continue }
            best = (candidate.tabID, session.startedAt)
        }
        return best?.id
    }

    /// When a quiet run that is still on the bar runs out of grace, so the
    /// window looks again then; nil when no run is waiting to expire.
    static func nextExpiry(_ candidates: [NowPlayingCandidate], now: Date,
                           grace: TimeInterval = grace) -> Date? {
        candidates.compactMap { candidate -> Date? in
            guard !candidate.isHeld, let stoppedAt = candidate.session?.stoppedAt else { return nil }
            let expiry = stoppedAt.addingTimeInterval(grace)
            return expiry > now ? expiry : nil
        }.min()
    }
}
