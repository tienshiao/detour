import Foundation

/// How one native messaging host connection ends (TASK-232).
///
/// Two signals say a host has gone, and nothing orders them: the read loop
/// reaching the end of the host's stdout, and `Process.terminationHandler`
/// reporting the exit on a thread of its own. A host that writes its reply
/// and exits at once used to have the exit reported while the read loop was
/// still reading the reply, so the owner saw the disconnect first. The end of
/// stream is what follows the last message, so this reports the disconnect
/// once both signals are in, with the exit status joined to it, or once one
/// has waited `Timing` for the other:
///
/// | First | Then | Reported |
/// |---|---|---|
/// | End of stream | Exit within `exitStatusWait` | The exit status |
/// | End of stream | Nothing (stdout closed, process alive) | `nil`; teardown then ends the process |
/// | Exit | End of stream within `endOfStreamWait` | The exit status |
/// | Exit | Nothing (a child of the host holds stdout open) | The exit status |
/// | A failed write | End of stream within `endOfStreamWait` (or nothing) | The write failure |
/// | A framing error | | That reason, at once |
///
/// A failed write is joined like an exit: it means the host has gone (or
/// closed its stdin), and what it wrote before that may still be in the pipe.
/// A framing error comes from the read loop itself, which has stopped
/// reading, so everything it read was already handed on.
///
/// A reported end is final: everything after it is recorded and ignored.
nonisolated struct NativeHostEnding: Equatable, Sendable {

    enum Event: Equatable, Sendable {
        /// The read loop read the end of the host's stdout between frames.
        case endOfStream
        /// The read loop met a bad frame and stopped reading.
        case failed(String)
        /// A write to the host's stdin failed: the host is gone, but its
        /// stdout may still hold what it wrote first.
        case writeFailed(String)
        /// `Process.terminationHandler` ran.
        case processExited(status: Int32)
        /// The wait an earlier `.wait` asked for is over.
        case waitExpired
    }

    enum Action: Equatable, Sendable {
        case none
        /// Report the disconnect with this reason (`nil`: a clean exit).
        case report(String?)
        /// Deliver `.waitExpired` after this many seconds.
        case wait(TimeInterval)
    }

    struct Timing: Equatable, Sendable {
        /// After the end of stream, how long to wait for the exit status. The
        /// kernel closes a host's stdout as it exits, so the termination
        /// handler normally follows within milliseconds; this only runs out
        /// for a host that closed stdout and kept running.
        var exitStatusWait: TimeInterval
        /// After the exit, how long to wait for the end of stream. What the
        /// host wrote before exiting is already in the pipe, so the read loop
        /// normally reaches the end within milliseconds; this only runs out
        /// when a process the host started holds its stdout open. Long, so a
        /// read loop starved on a loaded machine still delivers the reply
        /// first.
        var endOfStreamWait: TimeInterval

        init(exitStatusWait: TimeInterval = 0.5, endOfStreamWait: TimeInterval = 5) {
            self.exitStatusWait = exitStatusWait
            self.endOfStreamWait = endOfStreamWait
        }
    }

    let timing: Timing
    private(set) var reachedEndOfStream = false
    private(set) var exitStatus: Int32?
    private(set) var writeFailure: String?
    private(set) var isReported = false

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The disconnect reason for an exit status, as the owner sees it.
    static func reason(forExitStatus status: Int32) -> String? {
        status == 0 ? nil : "Native host exited with status \(status)"
    }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .endOfStream:
            reachedEndOfStream = true
        case .processExited(let status):
            exitStatus = status
        case .writeFailed(let reason):
            if writeFailure == nil { writeFailure = reason }
        case .failed, .waitExpired:
            break
        }
        guard !isReported else { return .none }

        switch event {
        case .failed(let reason):
            return report(reason)
        case .writeFailed:
            guard reachedEndOfStream else { return .wait(timing.endOfStreamWait) }
            return report(writeFailure)
        case .endOfStream:
            if let writeFailure { return report(writeFailure) }
            guard let exitStatus else { return .wait(timing.exitStatusWait) }
            return report(Self.reason(forExitStatus: exitStatus))
        case .processExited(let status):
            guard reachedEndOfStream else { return .wait(timing.endOfStreamWait) }
            return report(Self.reason(forExitStatus: status))
        case .waitExpired:
            if let writeFailure { return report(writeFailure) }
            if let exitStatus { return report(Self.reason(forExitStatus: exitStatus)) }
            if reachedEndOfStream { return report(nil) }
            return .none
        }
    }

    private mutating func report(_ reason: String?) -> Action {
        isReported = true
        return .report(reason)
    }
}
