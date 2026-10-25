import Foundation
import WebKit

/// The per-tab half of the now-playing bar (TASK-192): the tab's playback
/// run, what its page reports through `MediaSessionBridge`, whether its video
/// is in picture in picture, and the bar's controls. Windows hear about every
/// change through `nowPlayingDidChangeNotification` and decide for themselves
/// what to show (`NowPlayingRule`).
extension BrowserTab {
    /// Posted with the tab as the object whenever anything the bar shows or
    /// decides by changes.
    static let nowPlayingDidChangeNotification = Notification.Name("BrowserTabNowPlayingDidChange")

    /// How long a requested picture in picture may take to be reported before
    /// the tab counts as not in PiP after all (WebKit reports it in the same
    /// turn as the request when it works).
    static var pictureInPictureEntryTimeout: TimeInterval = 2

    /// What `NowPlayingRule` needs to know about this tab.
    func nowPlayingCandidate(isPrivate: Bool) -> NowPlayingCandidate {
        NowPlayingCandidate(tabID: id, isPrivate: isPrivate, session: playbackSession,
                            isHeld: isPausedFromBar, isInPictureInPicture: isInPictureInPicture,
                            dismissedSessionStart: nowPlayingDismissedSessionStart)
    }

    var isInPictureInPicture: Bool { isAwaitingPictureInPicture || !pictureInPictureFrames.isEmpty }

    func postNowPlayingChange() {
        NotificationCenter.default.post(name: Self.nowPlayingDidChangeNotification, object: self)
    }

    /// `isPlayingAudio` changed.
    func updatePlaybackSession() {
        playbackSession = MediaPlaybackSession.next(playbackSession, isPlaying: isPlayingAudio, isHeld: isPausedFromBar,
                                                    now: Date(), grace: NowPlayingRule.grace)
        if isPlayingAudio { isPausedFromBar = false }
        postNowPlayingChange()
    }

    /// The web view is going away (sleep, close, retarget): the tab leaves the
    /// bar now, not after a grace.
    func resetNowPlayingState() {
        playbackSession = nil
        mediaSession = nil
        pictureInPictureFrames.removeAll()
        isAwaitingPictureInPicture = false
        pictureInPictureEntryWorkItem?.cancel()
        pictureInPictureEntryWorkItem = nil
        isPausedFromBar = false
        isMediaSuspendedFromBar = false
        postNowPlayingChange()
    }

    // MARK: Reports from the page

    func mediaBridgeDidReport(_ message: MediaBridgeMessage) {
        switch message {
        case .document:
            forgetDocumentMediaState()
        case .session(let report):
            mediaSession = report == MediaSessionReport() ? nil : report
        case .pictureInPicture(let frame, let active):
            if active {
                pictureInPictureFrames.insert(frame)
                endAwaitingPictureInPicture()
            } else {
                pictureInPictureFrames.remove(frame)
            }
        }
        postNowPlayingChange()
    }

    /// The main frame committed a new document (a full navigation; a
    /// same-document one does not commit). The old page's Media Session and
    /// picture in picture went with it. The new page's script posts
    /// 'document' too, but a document no user script runs in (a PDF, a
    /// plugin) never does, and would keep the old title and an enabled Next.
    /// WebKit delivers the commit before any message from the new document's
    /// scripts, which run from its document start; a page restored from the
    /// back-forward cache re-reports on `pageshow`, after the commit too. The
    /// playback run is left alone: it follows `_isPlayingAudio`.
    func nowPlayingDocumentDidCommit() {
        guard mediaSession != nil || !pictureInPictureFrames.isEmpty else { return }
        forgetDocumentMediaState()
        postNowPlayingChange()
    }

    private func forgetDocumentMediaState() {
        mediaSession = nil
        pictureInPictureFrames.removeAll()
    }

    // MARK: Picture in picture

    /// `enterPictureInPicture()` is about to ask the page: until the page
    /// answers, the tab counts as entering PiP, so the bar does not flash up
    /// for a tab whose video is on its way into a PiP window.
    func pictureInPictureEntryWillStart() {
        isAwaitingPictureInPicture = true
        pictureInPictureEntryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.endAwaitingPictureInPicture(notify: true) }
        pictureInPictureEntryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pictureInPictureEntryTimeout, execute: item)
        postNowPlayingChange()
    }

    /// The entry script ran; `requested` is false when it found no playing
    /// video that supports PiP (an audio-only page, say).
    func pictureInPictureEntryDidFinish(requested: Bool) {
        guard !requested else { return }
        endAwaitingPictureInPicture(notify: true)
    }

    private func endAwaitingPictureInPicture(notify: Bool = false) {
        guard isAwaitingPictureInPicture else { return }
        isAwaitingPictureInPicture = false
        pictureInPictureEntryWorkItem?.cancel()
        pictureInPictureEntryWorkItem = nil
        if notify { postNowPlayingChange() }
    }

    // MARK: Controls

    /// The page has its own Play and Pause handlers, so the bar asks it
    /// rather than pausing its media from outside.
    private var pageHandlesPlayPause: Bool {
        guard let actions = mediaSession?.actions else { return false }
        return actions.contains(.play) && actions.contains(.pause)
    }

    func canPerformMediaSessionAction(_ action: MediaSessionAction) -> Bool {
        webView != nil && mediaSession?.actions.contains(action) == true
    }

    /// Previous or Next: the page's own handler. The bar disables the button
    /// when the page has none.
    func performMediaSessionAction(_ action: MediaSessionAction) {
        guard let webView, canPerformMediaSessionAction(action) else { return }
        MediaSessionBridge.invoke(action, in: webView)
    }

    /// The bar's play/pause button: pauses an audible tab, resumes a quiet one.
    func togglePlayPauseFromBar() {
        guard let webView else { return }
        if isPlayingAudio {
            isPausedFromBar = true
            if pageHandlesPlayPause {
                MediaSessionBridge.invoke(.pause, in: webView)
            } else if !isMediaSuspendedFromBar {
                // Every media element in every frame, and Web Audio: WebKit
                // interrupts them and resumes the same ones on the way back.
                isMediaSuspendedFromBar = true
                webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            }
            postNowPlayingChange()
            return
        }
        if isMediaSuspendedFromBar {
            isMediaSuspendedFromBar = false
            webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        } else if mediaSession?.actions.contains(.play) == true {
            MediaSessionBridge.invoke(.play, in: webView)
        } else {
            // Quiet without the bar's doing (the page paused within the
            // grace): play what script can reach.
            webView.evaluateJavaScript("""
                (function search(doc) {
                    for (const media of doc.querySelectorAll('video, audio')) {
                        if (media.paused && !media.ended && media.currentTime > 0) { media.play(); return true; }
                    }
                    for (const iframe of doc.querySelectorAll('iframe')) {
                        try { if (search(iframe.contentDocument)) return true; } catch (e) {}
                    }
                    return false;
                })(document)
                """)
        }
        postNowPlayingChange()
    }

    /// The tab is on screen in a window again. A page the bar suspended cannot
    /// start media itself until the suspension is lifted, and lifting it alone
    /// would resume playback the user paused: pausing first leaves every
    /// element paused but playable.
    func nowPlayingTabWasSelected() {
        let changed = isPausedFromBar || isMediaSuspendedFromBar
        liftMediaSuspensionFromBar()
        isPausedFromBar = false
        if changed { postNowPlayingChange() }
    }

    /// The tab is on screen in some window while the bar's suspension holds
    /// its media — another window's bar paused a tab this one shows, where no
    /// selection will lift it. Its media stays paused but playable, and the
    /// pause still holds the tab on that other window's bar.
    func liftMediaSuspensionFromBar() {
        guard isMediaSuspendedFromBar else { return }
        isMediaSuspendedFromBar = false
        guard let webView else { return }
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
    }

    /// The bar's ×: hides the current run until the tab starts playing anew.
    func dismissFromNowPlaying() {
        guard let start = playbackSession?.startedAt else { return }
        nowPlayingDismissedSessionStart = start
        postNowPlayingChange()
    }
}
