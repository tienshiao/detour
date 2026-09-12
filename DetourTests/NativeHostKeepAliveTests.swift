import XCTest
@testable import Detour

/// Pure state-machine tests for `NativeHostKeepAliveState` (TASK-16): the rule
/// that decides when the background worker's keep-alive pings should be flowing.
/// The worker holds an idle port to Detour's `detourPolyfill` host from startup;
/// Detour arms it (`keepalive-start`) while at least one real native messaging
/// host is connected for that extension and disarms it (`keepalive-stop`) when
/// the last one goes away, so the worker never has to detect native ports itself
/// (WebKit re-materializes `runtime.connectNative` on every read — TASK-15).
final class NativeHostKeepAliveTests: XCTestCase {

    /// Apply a sequence of events and return the actions they produced.
    private func actions(_ events: [NativeHostKeepAliveState.Event],
                         from initial: NativeHostKeepAliveState = NativeHostKeepAliveState())
    -> (state: NativeHostKeepAliveState, actions: [NativeHostKeepAliveState.Action]) {
        var state = initial
        let produced = events.map { state.apply($0) }
        return (state, produced)
    }

    // MARK: - Arming

    func testFirstHostWithPortOpenArms() {
        var state = NativeHostKeepAliveState()
        XCTAssertEqual(state.apply(.portOpened), .none,
                       "a port on its own has nothing to keep alive")
        XCTAssertEqual(state.apply(.hostConnected), .sendStart)
        XCTAssertTrue(state.armed)
        XCTAssertEqual(state.connectedHosts, 1)
        XCTAssertTrue(state.portOpen)
    }

    func testSecondHostDoesNotRearm() {
        let (state, produced) = actions([.portOpened, .hostConnected, .hostConnected])
        XCTAssertEqual(produced, [.none, .sendStart, .none],
                       "the port is already pinging; a second host changes nothing")
        XCTAssertEqual(state.connectedHosts, 2)
        XCTAssertTrue(state.armed)
    }

    func testPortOpeningAfterHostsArms() {
        let (state, produced) = actions([.hostConnected, .hostConnected, .portOpened])
        XCTAssertEqual(produced, [.none, .none, .sendStart],
                       "hosts connected before the worker's port is open must arm it when it arrives")
        XCTAssertTrue(state.armed)
    }

    // MARK: - Disarming

    func testFirstOfTwoHostsDisconnectingKeepsArmed() {
        let (state, produced) = actions([.portOpened, .hostConnected, .hostConnected, .hostDisconnected])
        XCTAssertEqual(produced, [.none, .sendStart, .none, .none])
        XCTAssertEqual(state.connectedHosts, 1)
        XCTAssertTrue(state.armed, "another host is still connected")
    }

    func testLastHostDisconnectingDisarms() {
        let (state, produced) = actions([.portOpened, .hostConnected, .hostDisconnected])
        XCTAssertEqual(produced, [.none, .sendStart, .sendStop])
        XCTAssertEqual(state.connectedHosts, 0)
        XCTAssertFalse(state.armed)
        XCTAssertTrue(state.portOpen, "the worker keeps its idle port after the pings stop")
    }

    func testHostDisconnectedClampsAtZero() {
        var state = NativeHostKeepAliveState()
        XCTAssertEqual(state.apply(.hostDisconnected), .none)
        XCTAssertEqual(state.apply(.hostDisconnected), .none)
        XCTAssertEqual(state.connectedHosts, 0, "the count must never go negative")

        XCTAssertEqual(state.apply(.portOpened), .none)
        XCTAssertEqual(state.apply(.hostConnected), .sendStart,
                       "a clamped count must still arm on the next real host")
    }

    // MARK: - Port lifecycle

    func testPortClosingWhileArmedSendsNothingAndDisarms() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        XCTAssertEqual(state.apply(.hostConnected), .sendStart)

        XCTAssertEqual(state.apply(.portClosed), .none,
                       "there is no port left to send the stop on")
        XCTAssertFalse(state.armed)
        XCTAssertFalse(state.portOpen)
        XCTAssertEqual(state.connectedHosts, 1, "the host is still connected")
    }

    func testPortReopeningWithHostsStillConnectedRearms() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        _ = state.apply(.hostConnected)
        _ = state.apply(.portClosed)

        XCTAssertEqual(state.apply(.portOpened), .sendStart,
                       "a reconnected worker port starts disarmed and must be re-armed by Detour")
        XCTAssertTrue(state.armed)
    }

    func testPortClosingWhileDisarmedSendsNothing() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        XCTAssertEqual(state.apply(.portClosed), .none)
        XCTAssertFalse(state.armed)
    }

    // MARK: - Context unload

    func testContextUnloadedResetsEverything() {
        for events in [[NativeHostKeepAliveState.Event.portOpened, .hostConnected],
                       [.hostConnected, .hostConnected],
                       [.portOpened],
                       []] {
            var state = NativeHostKeepAliveState()
            for event in events { _ = state.apply(event) }

            XCTAssertEqual(state.apply(.contextUnloaded), .none,
                           "the context is gone; nothing can be sent to it")
            XCTAssertEqual(state, NativeHostKeepAliveState(),
                           "unloading must reset the whole state, from \(events)")
            XCTAssertTrue(state.isIdle)
        }
    }

    func testStateAfterUnloadCanArmAgain() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        _ = state.apply(.hostConnected)
        _ = state.apply(.contextUnloaded)

        XCTAssertEqual(state.apply(.portOpened), .none)
        XCTAssertEqual(state.apply(.hostConnected), .sendStart)
    }

    // MARK: - A failed control send

    /// The `keepalive-start` never reached the worker, so the worker is not
    /// pinging: `armed` must stop claiming it is, and nothing is re-sent from the
    /// failure itself (the caller schedules a reconcile instead).
    func testControlSendFailedWhileArmedClearsArmed() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        XCTAssertEqual(state.apply(.hostConnected), .sendStart)

        XCTAssertEqual(state.apply(.controlSendFailed), .none,
                       "an immediate resend would just fail the same way")
        XCTAssertFalse(state.armed, "the worker never got the start")
        XCTAssertEqual(state.connectedHosts, 1, "the host and the port are untouched")
        XCTAssertTrue(state.portOpen)
    }

    /// This is why `armed` is stored rather than derived: after a failed send it
    /// deliberately diverges from `connectedHosts > 0 && portOpen`, and the
    /// reconcile is what closes the gap.
    func testReconcileAfterAFailedStartRetriesIt() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        _ = state.apply(.hostConnected)
        _ = state.apply(.controlSendFailed)

        XCTAssertEqual(state.apply(.reconcile), .sendStart,
                       "the host is still connected on the same port, so the start must be re-sent")
        XCTAssertTrue(state.armed)
    }

    func testReconcileAfterAFailedStopRetriesIt() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        _ = state.apply(.hostConnected)
        XCTAssertEqual(state.apply(.hostDisconnected), .sendStop)
        _ = state.apply(.controlSendFailed)
        XCTAssertFalse(state.armed)

        // The worker is still pinging as far as anyone knows, but nothing tracks
        // that: with no hosts and nothing armed there is nothing to re-send.
        XCTAssertEqual(state.apply(.reconcile), .none)
    }

    /// The host went away while the retry was pending: the start is no longer
    /// wanted, so the reconcile must not send it after all.
    func testReconcileAfterTheHostWentAwayRetriesNothing() {
        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        _ = state.apply(.hostConnected)
        _ = state.apply(.controlSendFailed)
        XCTAssertEqual(state.apply(.hostDisconnected), .none,
                       "nothing is armed, so the last host leaving has nothing to stop")

        XCTAssertEqual(state.apply(.reconcile), .none)
        XCTAssertFalse(state.armed)
    }

    func testReconcileOnAnIdleStateDoesNothing() {
        var state = NativeHostKeepAliveState()
        XCTAssertEqual(state.apply(.reconcile), .none)
        XCTAssertEqual(state, NativeHostKeepAliveState(), "reconcile changes no fields")
        XCTAssertTrue(state.isIdle)

        // Nor on a settled, already-armed state.
        _ = state.apply(.portOpened)
        XCTAssertEqual(state.apply(.hostConnected), .sendStart)
        XCTAssertEqual(state.apply(.reconcile), .none,
                       "the worker is already doing what it should be")
        XCTAssertTrue(state.armed)
    }

    // MARK: - isIdle

    func testIsIdleOnlyWhenNothingIsTracked() {
        XCTAssertTrue(NativeHostKeepAliveState().isIdle)

        var state = NativeHostKeepAliveState()
        _ = state.apply(.portOpened)
        XCTAssertFalse(state.isIdle, "an open port is still tracked")

        _ = state.apply(.hostConnected)
        XCTAssertFalse(state.isIdle)

        _ = state.apply(.portClosed)
        XCTAssertFalse(state.isIdle, "a connected host is still tracked")

        _ = state.apply(.hostDisconnected)
        XCTAssertTrue(state.isIdle, "no hosts, no port, not armed — the entry can be dropped")
    }
}
