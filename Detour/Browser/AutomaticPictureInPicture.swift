import Foundation

/// When switching away from a tab puts its playing video into picture in
/// picture by itself (`BrowserWindowController.selectTab`). A page's own
/// request (`requestPictureInPicture()`, the video's PiP button) is not
/// governed by this: the per-site switch (TASK-188) turns off only the
/// automatic one.
enum AutomaticPictureInPicture {
    /// - Parameters:
    ///   - isMuted: the tab is muted. Page mute (TASK-192) keeps
    ///     `isPlayingAudio` true, where the old script mute turned it off; a
    ///     muted tab still stays out of PiP, as it did then.
    ///   - leavesClosingTab: the selection moves because the tab is closing
    ///     (TASK-79: closing never starts PiP).
    ///   - siteOverride: the `pictureInPicture` site setting for the tab's
    ///     host; nil (no row) means the default, on.
    static func shouldEnter(isPlayingAudio: Bool, isMuted: Bool, leavesClosingTab: Bool,
                            siteOverride: Bool?) -> Bool {
        isPlayingAudio && !isMuted && !leavesClosingTab && (siteOverride ?? true)
    }
}
