import Foundation

/// When switching away from a tab puts its playing video into picture in
/// picture by itself (`BrowserWindowController.selectTab`). A page's own
/// request (`requestPictureInPicture()`, the video's PiP button) is not
/// governed by this: the per-site switch (TASK-188) turns off only the
/// automatic one.
enum AutomaticPictureInPicture {
    /// - Parameters:
    ///   - leavesClosingTab: the selection moves because the tab is closing
    ///     (TASK-79: closing never starts PiP).
    ///   - siteOverride: the `pictureInPicture` site setting for the tab's
    ///     host; nil (no row) means the default, on.
    static func shouldEnter(isPlayingAudio: Bool, leavesClosingTab: Bool, siteOverride: Bool?) -> Bool {
        isPlayingAudio && !leavesClosingTab && (siteOverride ?? true)
    }
}
