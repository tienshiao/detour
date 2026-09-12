import Foundation

/// Per (controller, extension): whether the background worker's keep-alive pings
/// should be flowing (TASK-16).
///
/// Chrome keeps a service worker alive while it holds a native messaging port.
/// WebKit unloads a non-persistent background 30 s after load/wake, or 2 minutes
/// after the last message the *background* posted on any of its open ports, so a
/// worker that posts periodically on a port stays alive. The worker cannot detect
/// its own native ports — WebKit re-materializes `runtime.connectNative` on every
/// read, so it cannot be wrapped, and shadowing the `chrome`/`browser` globals
/// breaks page→worker messaging (TASK-15) — but Detour knows natively exactly when
/// a real native host is connected.
///
/// So the worker holds one idle port to Detour's own `detourPolyfill` host from
/// startup (`ExtensionAPIPolyfill.nativePortKeepAliveJS`) and Detour drives it:
/// this state machine decides when to send `keepalive-start` / `keepalive-stop` on
/// that port. It is deliberately pure so the ordering rules (hosts before the port,
/// a reconnecting port, a worker restart, a context unload) are unit-testable
/// without a controller — see `NativeHostKeepAliveTests`.
struct NativeHostKeepAliveState: Equatable {
    /// Real native messaging hosts currently connected for this extension. One-shot
    /// `sendNativeMessage` hosts never count: they exit as soon as they reply.
    private(set) var connectedHosts = 0
    /// Whether the worker's keep-alive port is currently open in Detour.
    private(set) var portOpen = false
    /// Whether the worker has been told to ping (i.e. a `keepalive-start` is
    /// standing). Stored rather than derived from `connectedHosts > 0 && portOpen`
    /// because it deliberately diverges from that after `controlSendFailed`: the
    /// send never reached the worker, so the worker is *not* pinging even though
    /// the port and the hosts say it should be, and the next `reconcile` has to see
    /// that gap to re-send the control message.
    private(set) var armed = false

    enum Event {
        case hostConnected
        case hostDisconnected
        case portOpened
        case portClosed
        case contextUnloaded
        /// The control message could not be delivered on the port, so whatever it
        /// was meant to change never happened in the worker.
        case controlSendFailed
        /// Change nothing; just re-evaluate what the worker should be doing versus
        /// what it was last told. Used to retry a failed control send.
        case reconcile
    }

    enum Action: Equatable {
        case none
        case sendStart
        case sendStop
    }

    /// Applies the event and returns what to send on the keep-alive port.
    mutating func apply(_ event: Event) -> Action {
        switch event {
        case .hostConnected:
            connectedHosts += 1
        case .hostDisconnected:
            // Clamped: the host's process exit and the port's disconnect race, and
            // a stray second release must not make the count negative (and with it
            // a later real host fail to arm).
            connectedHosts = max(0, connectedHosts - 1)
        case .portOpened:
            portOpen = true
        case .portClosed:
            // Nothing to send: the port is gone. The worker's own reconnect starts
            // disarmed, so `portOpened` re-arms it if hosts are still connected.
            portOpen = false
            armed = false
            return .none
        case .contextUnloaded:
            // The whole context (and its worker) is gone; nothing can be sent to it.
            self = NativeHostKeepAliveState()
            return .none
        case .controlSendFailed:
            // The worker never got the start/stop, so it is not doing what `armed`
            // claimed. Record that and send nothing now: an immediate resend would
            // most likely fail the same way. The caller schedules a `reconcile`,
            // which is where the retry is decided.
            armed = false
            return .none
        case .reconcile:
            // Nothing changed; fall through to the desired-vs-armed comparison.
            break
        }

        let desired = connectedHosts > 0 && portOpen
        if desired && !armed {
            armed = true
            return .sendStart
        }
        if !desired && armed {
            armed = false
            return .sendStop
        }
        return .none
    }

    /// Nothing is being tracked, so the manager can drop the entry.
    var isIdle: Bool { connectedHosts == 0 && !portOpen && !armed }
}
