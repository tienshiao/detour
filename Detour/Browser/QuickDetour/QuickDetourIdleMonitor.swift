import AppKit

/// Closes Quick Detours left unused for the configured time into the archive,
/// as auto-closed (TASK-193.5). The decision is the pure
/// `QuickDetour.shouldAutoClose`; this only asks it about every open window,
/// on a periodic tick and when the Mac wakes, rather than on one long timer
/// per window: a timer does not fire while the Mac sleeps, and the wall clock
/// it would have been set against has moved on by then.
final class QuickDetourIdleMonitor {
    static let shared = QuickDetourIdleMonitor()

    /// The clock; a test sets a fixed one.
    var now: () -> Date = Date.init
    /// The settings it reads the interval from; a test swaps them.
    var settings: QuickDetourSettings = .shared

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// The Debug-only test override, in seconds, from
    /// `DETOUR_QUICK_DETOUR_IDLE_SECONDS`; nil in a Release build, so a
    /// runtime check need not wait hours.
    static let overrideSeconds: TimeInterval? = {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["DETOUR_QUICK_DETOUR_IDLE_SECONDS"],
              let seconds = TimeInterval(value), seconds > 0 else { return nil }
        return seconds
        #else
        return nil
        #endif
    }()

    /// The interval in force now; nil for Never.
    var interval: TimeInterval? {
        QuickDetour.idleInterval(for: settings.idleTimeout, overrideSeconds: Self.overrideSeconds)
    }

    /// Starts the periodic check and the wake check. Idempotent.
    func start() {
        guard timer == nil else { return }
        let interval = QuickDetour.idleCheckInterval(overrideSeconds: Self.overrideSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // On wake, at once: the Mac may have slept past the interval, and the
        // next tick could be a minute away.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Asks the rule about every open Quick Detour and closes those it says
    /// to, as auto-closed. Returns how many it closed.
    @discardableResult
    func check() -> Int {
        guard let interval else { return 0 }
        let date = now()
        let closing = QuickDetourWindowController.openControllers.filter {
            QuickDetour.shouldAutoClose($0.idleState, now: date, interval: interval)
        }
        for controller in closing { controller.autoClose() }
        return closing.count
    }
}
