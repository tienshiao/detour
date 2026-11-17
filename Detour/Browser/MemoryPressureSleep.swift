import Dispatch
import Foundation
import os.log

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "memory-pressure")

/// When macOS memory pressure sleeps tabs (TASK-407). Pure: the caller
/// supplies every time, so tests drive it with a clock.
///
/// The user's rule (2026-11-17, "shorten, then sweep"):
/// - **Warning**: for `warningWindow` (2 min) after the last warning, hidden
///   normal tabs sleep once they have been out of sight for
///   `warningIdleThreshold` (5 min). It shortens the profile's threshold and
///   never lengthens it; a profile set to never sleep is honoured. The first
///   warning is common in everyday use, so pinned and favourite tabs are left
///   to their usual rules.
/// - **Critical**: every eligible hidden tab sleeps now, pinned entries' and
///   favourites' backing tabs included.
///
/// Pressure-driven sweeps run at most once per `rescanInterval` (30 s). A
/// burst of events defers the next sweep rather than dropping it, and the
/// warning window is rescanned on that interval while it lasts, since the
/// periodic 5-minute sweep would miss tabs that cross 5 min inside it.
struct MemoryPressureSleepPolicy: Equatable {
    enum Level: String, Equatable {
        case warning, critical

        /// The level a memory-pressure source reported, or nil for a return
        /// to normal (which changes nothing: the warning window runs out on
        /// its own clock).
        init?(_ event: DispatchSource.MemoryPressureEvent) {
            if event.contains(.critical) {
                self = .critical
            } else if event.contains(.warning) {
                self = .warning
            } else {
                return nil
            }
        }
    }

    var warningIdleThreshold: TimeInterval = 5 * 60
    var warningWindow: TimeInterval = 2 * 60
    var rescanInterval: TimeInterval = 30

    private(set) var lastWarningAt: Date?
    private(set) var criticalPending = false
    private(set) var lastSweepAt: Date?

    mutating func note(_ level: Level, at now: Date) {
        switch level {
        case .warning: lastWarningAt = now
        case .critical: criticalPending = true
        }
    }

    /// The idle threshold a recent warning imposes at `now`, or nil once its
    /// window has run out. Every sleep sweep applies it, the periodic one too.
    func idleThresholdCap(at now: Date) -> TimeInterval? {
        guard let lastWarningAt, now.timeIntervalSince(lastWarningAt) <= warningWindow else { return nil }
        return warningIdleThreshold
    }

    /// The pressure sweep due at `now`, if any, recorded as run. A pending
    /// critical outranks the warning window.
    mutating func takeDueSweep(at now: Date) -> Level? {
        if let lastSweepAt, now.timeIntervalSince(lastSweepAt) < rescanInterval { return nil }
        let level: Level
        if criticalPending {
            criticalPending = false
            level = .critical
        } else if idleThresholdCap(at: now) != nil {
            level = .warning
        } else {
            return nil
        }
        lastSweepAt = now
        return level
    }

    /// When `takeDueSweep` should next be asked, or nil when nothing more can
    /// come due without a new event.
    func nextCheck(after now: Date) -> Date? {
        let earliest = lastSweepAt.map { max(now, $0.addingTimeInterval(rescanInterval)) } ?? now
        if criticalPending { return earliest }
        guard idleThresholdCap(at: earliest) != nil else { return nil }
        return earliest
    }
}

/// Feeds macOS memory-pressure events into `MemoryPressureSleepPolicy` and
/// runs the sweeps it asks for through `TabStore.sleepStaleTabs` (TASK-407).
@MainActor
final class MemoryPressureSleeper {
    private(set) var policy = MemoryPressureSleepPolicy()
    private unowned let store: TabStore

    /// The time events and checks are stamped with; tests inject their clock.
    var clock: () -> Date = { Date() }
    /// Runs `fire` after `delay` seconds on the main actor. Production uses a
    /// main-run-loop timer; tests capture the closure and fire it themselves.
    var schedule: (_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> Void = { delay, fire in
        _ = Timer.scheduledMainTimer(withTimeInterval: delay, repeats: false) { _ in fire() }
    }
    /// How many tabs one main-loop turn of a pressure sweep sleeps. A sleep
    /// costs about 4.5 ms of main thread (40 tabs with loaded pages took
    /// 181 ms in one go in the test host, which has no sidebar observing
    /// them), so a critical sweep over every hidden tab would stall the app
    /// visibly; four per turn keeps each turn near 20 ms.
    var tabsPerTurn = 4
    /// Runs `turn` on a later turn of the main loop, so input and drawing get
    /// in between batches. Tests run it at once or queue it.
    var nextTurn: (_ turn: @escaping @MainActor @Sendable () -> Void) -> Void = { turn in
        DispatchQueue.main.async {
            // Not a crossing: the main queue runs this on the main thread.
            MainActor.assumeIsolated(turn)
        }
    }

    struct SweepResult: Equatable {
        var level: MemoryPressureSleepPolicy.Level
        var slept: Int
    }
    /// The last pressure sweep to finish, as logged.
    private(set) var lastSweepResult: SweepResult?

    /// Tells a superseded scheduled check from the current one: only the
    /// latest `schedule` call may run a check.
    private var scheduleGeneration = 0
    private var source: (any DispatchSourceMemoryPressure)?

    init(store: TabStore) {
        self.store = store
    }

    /// Starts listening for memory pressure. Not called in the unit-test host,
    /// whose tests deliver events through `receive(_:)`.
    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            // Not a crossing: a source targeting the main queue runs its
            // handler on the main thread.
            MainActor.assumeIsolated {
                guard let self, let event = self.source?.data, let level = MemoryPressureSleepPolicy.Level(event)
                else { return }
                self.receive(level)
            }
        }
        self.source = source
        source.activate()
    }

    /// A memory-pressure event. Sweeps at once unless a pressure sweep ran
    /// within the rescan interval, in which case the check is deferred to the
    /// end of it.
    func receive(_ level: MemoryPressureSleepPolicy.Level) {
        log.info("Memory pressure \(level.rawValue, privacy: .public)")
        let now = clock()
        policy.note(level, at: now)
        runDueSweep(at: now)
    }

    /// Runs the sweep due at `now`, if any, then arms the next check.
    ///
    /// A scheduled check runs as of the time it was armed for, not the time
    /// its timer actually fired. Timers fire late (and later still under App
    /// Nap), and judged at the real time the last rescan of the warning
    /// window would land just past its end and never run, cutting the
    /// window short by one rescan.
    private func runDueSweep(at now: Date) {
        if let level = policy.takeDueSweep(at: now) {
            continueSweep(StaggeredSweep(level: level, now: now))
        }
        scheduleGeneration += 1
        guard let next = policy.nextCheck(after: now) else { return }
        let generation = scheduleGeneration
        schedule(max(0, next.timeIntervalSince(now))) { [weak self] in
            guard let self, self.scheduleGeneration == generation else { return }
            self.runDueSweep(at: next)
        }
    }

    /// One pressure sweep spread over main-loop turns.
    private final class StaggeredSweep {
        let level: MemoryPressureSleepPolicy.Level
        let now: Date
        var attempted = Set<ObjectIdentifier>()
        var slept = 0

        init(level: MemoryPressureSleepPolicy.Level, now: Date) {
            self.level = level
            self.now = now
        }
    }

    /// Sleeps the next `tabsPerTurn` candidates. The candidates are asked for
    /// again on every turn, so a tab the user selected, or that started
    /// playing, since the sweep began is spared; a tab already tried is not
    /// tried twice (a sleep that does nothing must not loop).
    private func continueSweep(_ sweep: StaggeredSweep) {
        let remaining = store.staleTabCandidates(now: sweep.now, pressure: sweep.level)
            .filter { !sweep.attempted.contains(ObjectIdentifier($0)) }
        let batch = Array(remaining.prefix(max(1, tabsPerTurn)))
        for tab in batch { sweep.attempted.insert(ObjectIdentifier(tab)) }
        sweep.slept += store.sleepTabs(batch)
        guard remaining.count > batch.count else {
            log.notice("Memory pressure \(sweep.level.rawValue, privacy: .public): slept \(sweep.slept) tabs")
            lastSweepResult = SweepResult(level: sweep.level, slept: sweep.slept)
            return
        }
        nextTurn { [weak self] in self?.continueSweep(sweep) }
    }
}
