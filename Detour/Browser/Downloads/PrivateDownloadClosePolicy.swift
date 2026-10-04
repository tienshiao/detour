import Foundation

/// What happens to a Private window's downloads that are still running when
/// the window goes away (TASK-156).
///
/// WebKit keeps a `WKDownload` transferring after the web view that started it
/// is gone, and a Private window's download list goes with the window, so a
/// download left alone would keep writing to disk where nothing shows it or can
/// stop it. The rule is Chrome's: it is cancelled and its partial file removed,
/// and the user is asked first wherever there is somebody to ask.
enum PrivateDownloadClosePolicy {

    /// What is going away.
    enum Closing: Equatable {
        /// The window with this download scope.
        case window(DownloadScope)
        /// Every window: the app is quitting.
        case allWindows
    }

    /// Whether `closing` cancels a download with `scope`.
    ///
    /// Only a Private download still in flight: one that has ended has nothing
    /// to cancel, and a normal download is listed by every normal window, so it
    /// outlives any one of them.
    static func cancels(downloadIn scope: DownloadScope, isInFlight: Bool, closing: Closing) -> Bool {
        guard isInFlight, case .incognito = scope else { return false }
        switch closing {
        case .window(let windowScope): return scope == windowScope
        case .allWindows: return true
        }
    }

    /// What closing a window does first.
    enum Decision: Equatable {
        /// Nothing would be cancelled: close.
        case close
        /// Ask; close and cancel only on a yes.
        case confirm(Prompt)
    }

    /// The question a Private window asks before it closes.
    struct Prompt: Equatable {
        let messageText: String
        let informativeText: String
        /// Closes the window and cancels the downloads.
        let closeButtonTitle: String
        /// Keeps the window open and the downloads running.
        let keepButtonTitle: String
    }

    /// - Parameter inFlightCount: how many downloads closing the window would
    ///   cancel (`cancels(downloadIn:isInFlight:closing:)`).
    static func decision(inFlightCount: Int) -> Decision {
        guard inFlightCount > 0 else { return .close }
        let informativeText = inFlightCount == 1
            ? "1 download is in progress. Closing this Private window cancels it."
            : "\(inFlightCount) downloads are in progress. Closing this Private window cancels them."
        return .confirm(Prompt(messageText: "Close this Private window?",
                               informativeText: informativeText,
                               closeButtonTitle: "Close Window",
                               keepButtonTitle: "Continue Downloading"))
    }

    /// The sentence the quit confirmation adds when quitting would cancel
    /// Private downloads; nil when it would cancel none.
    static func quitWarning(inFlightCount: Int) -> String? {
        guard inFlightCount > 0 else { return nil }
        return inFlightCount == 1
            ? "1 download in a Private window is in progress and will be cancelled."
            : "\(inFlightCount) downloads in Private windows are in progress and will be cancelled."
    }
}
