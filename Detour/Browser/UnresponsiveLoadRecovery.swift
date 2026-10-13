import Foundation

/// When a request the web process never reads earns a fresh web process
/// (TASK-176).
///
/// `WKWebView.reload()`, `load(_:)` and `stopLoading()` only queue a message to
/// the web process. A process whose main thread is blocked never reads it: the
/// page stays as it was, `isLoading` stays true (the sidebar shows Stop), and
/// Stop is queued behind it. WebKit reports the process unresponsive three
/// seconds after the request, and does nothing more — recovering is the
/// client's job.
///
/// The rule: a load or a Stop that is still unanswered `patience` after WebKit
/// reported the process unresponsive terminates the process, and so does a load
/// requested while the process is already reported unresponsive; the caller
/// then issues the load in a new process (after an unanswered Stop: a reload of
/// the page the tab was showing, since a web view that cannot stop would
/// otherwise stay "loading" for good). A request the process answers, and a
/// page that is merely busy with nobody asking anything of it, terminate
/// nothing.
///
/// WebKit's own "responsive again" report is not proof of anything: it is also
/// sent whenever the view is hidden, with the process as blocked as before.
/// While a request is outstanding it is ignored — a process that really
/// recovered answers the request, and only that clears it.
struct UnresponsiveLoadRecovery: Equatable {
    enum Load: Equatable {
        case reload
        case url(URL)
    }

    enum Event: Equatable {
        /// The tab asked its web view for `Load`.
        case requested(Load)
        /// The web process dealt with what it was asked: it asked for a
        /// main-frame navigation's policy, a provisional load started, or the
        /// web view stopped loading (finished, failed, stopped, or the
        /// navigation was refused before it began).
        case answered
        /// The user pressed Stop while the web view was loading.
        case stopped
        case becameUnresponsive
        case becameResponsive
        /// The page is showing a script dialog: its process is waiting on the
        /// user, not hung, however long that takes.
        case waitingOnUser
        /// `patience` after the `waitForPatience` effect carrying this token.
        case patienceElapsed(token: Int)
        /// The web process is gone, or the web view was released.
        case reset
    }

    enum Effect: Equatable {
        case none
        /// Send `.patienceElapsed(token:)` after the patience interval.
        case waitForPatience(token: Int)
        /// Terminate the web process, then issue `Load` — without reporting it
        /// back as `.requested`: one termination per request, never a loop.
        case terminate(thenIssue: Load)
    }

    /// The load the web process has not answered yet.
    private(set) var pending: Load?
    /// A Stop the web process has not answered yet.
    private(set) var awaitingStop = false
    private(set) var isUnresponsive = false
    private var isWaiting = false
    private var token = 0

    private var hasUnansweredRequest: Bool { pending != nil || awaitingStop }

    mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .requested(let load):
            // Whatever an earlier wait was for, it was not for this request.
            cancelWait()
            awaitingStop = false
            guard isUnresponsive else {
                pending = load
                return .none
            }
            pending = nil
            isUnresponsive = false
            return .terminate(thenIssue: load)

        case .answered:
            cancelWait()
            pending = nil
            awaitingStop = false
            isUnresponsive = false
            return .none

        case .stopped:
            pending = nil
            awaitingStop = true
            // No new report comes for a process already reported: the wait
            // starts here, unless one is running for the load being stopped.
            return isUnresponsive ? startWait() : .none

        case .becameUnresponsive:
            isUnresponsive = true
            return hasUnansweredRequest ? startWait() : .none

        case .becameResponsive:
            // With a request outstanding the report proves nothing (see the
            // type's comment): a process that really recovered answers the
            // request, and that is what clears it.
            if !hasUnansweredRequest { isUnresponsive = false }
            return .none

        case .waitingOnUser:
            cancelWait()
            isUnresponsive = false
            return .none

        case .patienceElapsed(let elapsed):
            guard isWaiting, elapsed == token else { return .none }
            isWaiting = false
            guard isUnresponsive, hasUnansweredRequest else { return .none }
            let load = pending ?? .reload
            pending = nil
            awaitingStop = false
            isUnresponsive = false
            return .terminate(thenIssue: load)

        case .reset:
            cancelWait()
            pending = nil
            awaitingStop = false
            isUnresponsive = false
            return .none
        }
    }

    /// A wait already running keeps its deadline: WebKit repeats its report
    /// after a false "responsive", and that must not start the patience over.
    private mutating func startWait() -> Effect {
        guard !isWaiting else { return .none }
        isWaiting = true
        token += 1
        return .waitForPatience(token: token)
    }

    private mutating func cancelWait() {
        isWaiting = false
        token += 1
    }
}
