import XCTest
@testable import Detour

/// TASK-192: which tab a window's now-playing bar shows. Media playing in a
/// tab the user has left, in any space, the most recently started; never a
/// tab whose video is in picture in picture; Private and normal windows never
/// see each other's media; a quiet tab stays for a short grace; a dismissed
/// run stays hidden until the tab starts playing anew.
final class NowPlayingRuleTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let grace = NowPlayingRule.grace
    private let a = UUID(), b = UUID(), c = UUID()

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func playing(_ id: UUID, since start: TimeInterval = 0, isPrivate: Bool = false,
                         pip: Bool = false) -> NowPlayingCandidate {
        NowPlayingCandidate(tabID: id, isPrivate: isPrivate,
                            session: MediaPlaybackSession(startedAt: at(start), stoppedAt: nil),
                            isInPictureInPicture: pip)
    }

    private func show(_ candidates: [NowPlayingCandidate], visible: Set<UUID> = [],
                      privateWindow: Bool = false, now: TimeInterval = 10) -> UUID? {
        NowPlayingRule.tabToShow(candidates, visibleTabIDs: visible, windowIsPrivate: privateWindow, now: at(now))
    }

    // MARK: - Sessions

    func testATabThatStartsPlayingStartsASession() {
        let session = MediaPlaybackSession.next(nil, isPlaying: true, isHeld: false, now: at(5), grace: grace)
        XCTAssertEqual(session, MediaPlaybackSession(startedAt: at(5), stoppedAt: nil))
    }

    func testATabThatWasNeverPlayingHasNoSession() {
        XCTAssertNil(MediaPlaybackSession.next(nil, isPlaying: false, isHeld: false, now: at(5), grace: grace))
    }

    func testGoingQuietRecordsWhenAndKeepsTheStart() {
        let playing = MediaPlaybackSession(startedAt: at(0), stoppedAt: nil)
        let quiet = MediaPlaybackSession.next(playing, isPlaying: false, isHeld: false, now: at(8), grace: grace)
        XCTAssertEqual(quiet, MediaPlaybackSession(startedAt: at(0), stoppedAt: at(8)))
        XCTAssertEqual(MediaPlaybackSession.next(quiet, isPlaying: false, isHeld: false, now: at(9), grace: grace), quiet,
                       "a second quiet observation does not move the stop time")
    }

    func testResumingWithinTheGraceContinuesTheSameSession() {
        let quiet = MediaPlaybackSession(startedAt: at(0), stoppedAt: at(8))
        let resumed = MediaPlaybackSession.next(quiet, isPlaying: true, isHeld: false, now: at(8 + grace / 2), grace: grace)
        XCTAssertEqual(resumed, MediaPlaybackSession(startedAt: at(0), stoppedAt: nil),
                       "a pause and resume (or a track change) is the same run: no flicker, dismissal holds")
    }

    func testPlayingAgainAfterTheGraceStartsANewSession() {
        let quiet = MediaPlaybackSession(startedAt: at(0), stoppedAt: at(8))
        let again = MediaPlaybackSession.next(quiet, isPlaying: true, isHeld: false, now: at(20), grace: grace)
        XCTAssertEqual(again, MediaPlaybackSession(startedAt: at(20), stoppedAt: nil))
    }

    func testResumingARunTheBarPausedContinuesItHoweverLongItWasQuiet() {
        let paused = MediaPlaybackSession(startedAt: at(0), stoppedAt: at(8))
        let resumed = MediaPlaybackSession.next(paused, isPlaying: true, isHeld: true, now: at(300), grace: grace)
        XCTAssertEqual(resumed, MediaPlaybackSession(startedAt: at(0), stoppedAt: nil))
    }

    func testLiveness() {
        let playing = MediaPlaybackSession(startedAt: at(0), stoppedAt: nil)
        let quiet = MediaPlaybackSession(startedAt: at(0), stoppedAt: at(8))
        XCTAssertTrue(playing.isLive(isHeld: false, now: at(100), grace: grace))
        XCTAssertTrue(quiet.isLive(isHeld: false, now: at(8 + grace - 0.01), grace: grace))
        XCTAssertFalse(quiet.isLive(isHeld: false, now: at(8 + grace), grace: grace))
        XCTAssertTrue(quiet.isLive(isHeld: true, now: at(500), grace: grace))
    }

    // MARK: - AC #1: a tab you have left

    func testAPlayingTabTheUserHasLeftIsShown() {
        XCTAssertEqual(show([playing(a)]), a)
    }

    func testTheSelectedTabIsNotShown() {
        XCTAssertNil(show([playing(a)], visible: [a]))
    }

    func testAVisibleSplitPaneIsNotShown() {
        XCTAssertNil(show([playing(a)], visible: [a, b]), "both panes of a selected split are on screen")
        XCTAssertNil(show([playing(b)], visible: [a, b]))
    }

    func testATabInAnotherSpaceIsShown() {
        // The window passes every tab it could switch to; what it shows is
        // only its own selection, so another space's tab is never visible.
        XCTAssertEqual(show([playing(a), playing(b, since: 1)], visible: [c]), b)
    }

    func testTheMostRecentlyStartedTabIsShown() {
        XCTAssertEqual(show([playing(a, since: 5), playing(b, since: 2), playing(c, since: 3)]), a)
        XCTAssertEqual(show([playing(a, since: 5), playing(b, since: 2)], visible: [a]), b,
                       "selecting the newest falls back to the next one")
    }

    func testATabThatNeverPlayedIsNotShown() {
        XCTAssertNil(show([NowPlayingCandidate(tabID: a, isPrivate: false, session: nil)]))
    }

    func testAClosedTabIsNotShown() {
        // A closed tab is no longer a candidate: the window gathers from the
        // store, and teardown clears the tab's session.
        XCTAssertEqual(show([playing(a), playing(b, since: 1)]), b)
        XCTAssertEqual(show([playing(a)]), a, "b closed")
        XCTAssertNil(show([]))
    }

    func testAQuietTabStaysForTheGraceThenGoes() {
        var tab = playing(a)
        tab.session?.stoppedAt = at(8)
        XCTAssertEqual(show([tab], now: 8 + grace - 0.1), a, "a pause or track change must not flicker")
        XCTAssertNil(show([tab], now: 8 + grace))
    }

    func testATabTheBarPausedStaysShown() {
        var tab = playing(a)
        tab.session?.stoppedAt = at(8)
        tab.isHeld = true
        XCTAssertEqual(show([tab], now: 600), a, "the bar's own pause keeps it, so the user can resume")
    }

    // MARK: - AC #6: picture in picture

    func testATabInPictureInPictureIsNotShown() {
        XCTAssertNil(show([playing(a, pip: true)]), "its PiP window has the controls")
        XCTAssertEqual(show([playing(a, since: 1, pip: true), playing(b)]), b)
    }

    func testATabWhosePiPWindowClosedWhileItKeepsPlayingIsShown() {
        var tab = playing(a, pip: true)
        XCTAssertNil(show([tab]))
        tab.isInPictureInPicture = false
        XCTAssertEqual(show([tab]), a)
    }

    func testATabThatDidNotEnterPiPIsShown() {
        // Audio only, no PiP-capable video, or the site's automatic PiP off:
        // all reach the rule as a playing tab that is not in PiP.
        XCTAssertEqual(show([playing(a, pip: false)]), a)
    }

    // MARK: - Private and normal windows

    func testANormalWindowNeverShowsPrivateMedia() {
        XCTAssertNil(show([playing(a, isPrivate: true)]))
        XCTAssertEqual(show([playing(a, since: 5, isPrivate: true), playing(b)]), b)
    }

    func testAPrivateWindowNeverShowsNormalMedia() {
        XCTAssertNil(show([playing(a)], privateWindow: true))
        XCTAssertEqual(show([playing(a, since: 5), playing(b, isPrivate: true)], privateWindow: true), b)
    }

    // MARK: - Dismissal

    func testADismissedRunIsHidden() {
        var tab = playing(a, since: 2)
        tab.dismissedSessionStart = at(2)
        XCTAssertNil(show([tab]))
    }

    func testDismissingTheShownTabRevealsTheNextOne() {
        var newest = playing(a, since: 5)
        newest.dismissedSessionStart = at(5)
        XCTAssertEqual(show([newest, playing(b, since: 1)]), b)
    }

    func testADismissedTabShowsAgainWhenItStartsPlayingAnew() {
        // Dismissed at 2; stopped at 8, played again at 20: a new run.
        let quiet = MediaPlaybackSession(startedAt: at(2), stoppedAt: at(8))
        let again = MediaPlaybackSession.next(quiet, isPlaying: true, isHeld: false, now: at(20), grace: grace)
        let tab = NowPlayingCandidate(tabID: a, isPrivate: false, session: again, dismissedSessionStart: at(2))
        XCTAssertEqual(show([tab], now: 21), a)
    }

    func testADismissedTabStaysHiddenThroughAShortPause() {
        let quiet = MediaPlaybackSession(startedAt: at(2), stoppedAt: at(8))
        let resumed = MediaPlaybackSession.next(quiet, isPlaying: true, isHeld: false, now: at(9), grace: grace)
        let tab = NowPlayingCandidate(tabID: a, isPrivate: false, session: resumed, dismissedSessionStart: at(2))
        XCTAssertNil(show([tab], now: 9), "a track change is the same run")
    }

    // MARK: - Re-evaluation

    func testNextExpiryIsTheEarliestQuietRunStillInItsGrace() {
        var x = playing(a); x.session?.stoppedAt = at(8)
        var y = playing(b); y.session?.stoppedAt = at(9)
        XCTAssertEqual(NowPlayingRule.nextExpiry([x, y, playing(c)], now: at(9)), at(8 + grace))
    }

    func testNoExpiryForPlayingHeldOrExpiredRuns() {
        var held = playing(a); held.session?.stoppedAt = at(8); held.isHeld = true
        var expired = playing(b); expired.session?.stoppedAt = at(1)
        XCTAssertNil(NowPlayingRule.nextExpiry([held, expired, playing(c)], now: at(9)))
    }
}
