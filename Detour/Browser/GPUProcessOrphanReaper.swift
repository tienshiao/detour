import AppKit
import Darwin
import WebKit
import os.log

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "gpu-orphan")

/// Which of this app's GPU processes WebKit has abandoned (TASK-175).
///
/// Why this exists: when WebKit decides its GPU process is unresponsive it
/// "terminates" it and launches another. The hard kill does not work
/// (`Could not signal service com.apple.WebKit.GPU: 1: Operation not
/// permitted`); the process normally goes away because its XPC handler posts an
/// exit to its main run loop. A GPU process whose main thread is blocked never
/// runs that, so it stays alive with WebKit no longer tracking it. Web
/// processes that were handed a connection to it keep that connection — it
/// never closes — and the first synchronous call a page makes over it (audio
/// session setup, in the case that found this) parks the page's main thread
/// for good: a frozen tab that Reload cannot reach.
///
/// Killing the abandoned process closes those connections; the web processes
/// reconnect to the live GPU process and carry on where they were.
///
/// A process counts as abandoned when it is a `com.apple.WebKit.GPU` this app
/// is responsible for, it is not the process WebKit names as its GPU process —
/// WebKit names another, or none at all — and it is at least `minimumAge` old:
/// a GPU process that is still launching is not yet the one WebKit names (the
/// slow launch behind TASK-175 took 7.6 s).
///
/// "None at all" matters. WebKit launches the next GPU process only when a web
/// process asks for a connection, and a web process frozen on the abandoned one
/// never asks: with one tab open, the abandoned process is the only GPU process
/// there will ever be.
struct GPUProcessOrphanPolicy: Equatable {
    var minimumAge: TimeInterval = 60
    /// How long a process must have looked abandoned before it is killed. Age
    /// is read off the wall clock, and the clock cannot tell an abandoned
    /// process from one WebKit is about to adopt when the app did not run in
    /// between: the Mac slept, or the main thread stalled, right after the
    /// process was spawned. A second look gives WebKit the time to name it.
    var confirmationDelay: TimeInterval = 5
    /// One abandonment leaves one process behind. A reaper that keeps finding
    /// more is reading WebKit wrong, and WebKit answers a GPU process that
    /// dies repeatedly by terminating every web process: stop well short.
    var maximumKillsPerHour = 3
    /// The hour `maximumKillsPerHour` counts over.
    static let killWindow: TimeInterval = 3600

    /// A process that looked abandoned, and since when.
    struct Suspect: Equatable {
        var process: GPUProcessTable.Entry
        var since: Date
    }

    struct Verdict: Equatable {
        /// Looked abandoned for `confirmationDelay`: to be killed.
        var orphans: [GPUProcessTable.Entry]
        /// Every process that looks abandoned now, for the next look.
        var suspects: [Suspect]
        /// When to look again without waiting for the next periodic check: a
        /// suspect to confirm, or a disowned process coming of age.
        var recheckAt: Date?
    }

    /// - Parameters:
    ///   - current: what WebKit says its GPU process is. When nothing could be
    ///     asked, nothing is an orphan: not knowing is not "disowned".
    ///   - suspects: the suspects of the previous verdict.
    func verdict(processes: [GPUProcessTable.Entry], current: GPUProcessRecycler.WebKitGPUProcess,
                 suspects earlier: [Suspect], now: Date) -> Verdict {
        let currentPID: pid_t?
        switch current {
        case .unknown: return Verdict(orphans: [], suspects: [], recheckAt: nil)
        case .notRunning: currentPID = nil
        case .running(let pid): currentPID = pid
        }
        var verdict = Verdict(orphans: [], suspects: [], recheckAt: nil)
        func recheck(at due: Date) {
            verdict.recheckAt = verdict.recheckAt.map { min($0, due) } ?? due
        }
        for process in processes where process.pid != currentPID {
            guard now.timeIntervalSince(process.startedAt) >= minimumAge else {
                // A start time ahead of the clock would otherwise push the
                // recheck arbitrarily far out.
                recheck(at: min(process.startedAt.addingTimeInterval(minimumAge), now.addingTimeInterval(minimumAge)))
                continue
            }
            // A suspicion dated ahead of the clock (it was set back) starts over.
            let since = min(earlier.first { $0.process == process }?.since ?? now, now)
            verdict.suspects.append(Suspect(process: process, since: since))
            if now.timeIntervalSince(since) >= confirmationDelay {
                verdict.orphans.append(process)
            } else {
                recheck(at: since.addingTimeInterval(confirmationDelay))
            }
        }
        return verdict
    }

    /// How many more processes may be killed now, given when the earlier
    /// kills happened.
    func killAllowance(earlierKills: [Date], now: Date) -> Int {
        let recent = earlierKills.filter { now.timeIntervalSince($0) < Self.killWindow }.count
        return max(0, maximumKillsPerHour - recent)
    }

    /// Environment override for the runtime harness, read once at launch. A
    /// negative or unparseable value is ignored rather than removing the guard
    /// by accident.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GPUProcessOrphanPolicy {
        var policy = GPUProcessOrphanPolicy()
        if let value = environment["DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS"].flatMap(TimeInterval.init),
           value.isFinite, value >= 0 {
            policy.minimumAge = value
        }
        return policy
    }
}

/// The `com.apple.WebKit.GPU` processes in the process table, and which app
/// each belongs to.
enum GPUProcessTable {
    static let processName = "com.apple.WebKit.GPU"

    /// A GPU process, identified by pid *and* start time: a pid alone can be
    /// reused between looking and killing.
    struct Entry: Equatable {
        var pid: pid_t
        var startedAt: Date
    }

    /// Every GPU process `owner` is responsible for. WebKit's helpers are
    /// launchd's children, not the app's, and every WebKit app on the machine
    /// has a GPU process of the same name: responsibility is what tells them
    /// apart (it is also what Activity Monitor groups by).
    static func ownGPUProcesses(owner: pid_t = getpid()) -> [Entry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { entry(pid: $0, owner: owner) }
    }

    /// `pid` as an entry, when it is a GPU process `owner` is responsible for.
    static func entry(pid: pid_t, owner: pid_t = getpid()) -> Entry? {
        guard pid > 0, name(of: pid) == processName,
              responsiblePID(for: pid) == owner,
              let startedAt = startTime(of: pid) else { return nil }
        return Entry(pid: pid, startedAt: startedAt)
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` is exported by libSystem
    /// but declared in no public header. Looked up at runtime so that, were it
    /// ever to go away, the reaper finds no processes instead of the app
    /// failing to launch.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// The process the system holds responsible for `pid`: for an app's XPC
    /// helpers, the app. Nil when the lookup is unavailable or fails.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let responsible = responsibleFunction(pid)
        return responsible > 0 ? responsible : nil
    }
}

/// Finds GPU processes WebKit has abandoned and kills them under
/// `GPUProcessOrphanPolicy` (TASK-175).
@MainActor
final class GPUProcessOrphanReaper {
    static let shared = GPUProcessOrphanReaper()

    private let policy = GPUProcessOrphanPolicy.fromEnvironment()
    private let checkInterval: TimeInterval = {
        let raw = ProcessInfo.processInfo.environment["DETOUR_GPU_ORPHAN_CHECK_SECONDS"]
        // Often enough that a frozen tab is not frozen for long; one pass over
        // the process table costs a few milliseconds off the main thread.
        return raw.flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 30
    }()
    private let scanQueue = DispatchQueue(label: "com.detourbrowser.gpu-orphan", qos: .utility)

    private var timer: Timer?
    private var recheck: DispatchWorkItem?
    private var scanning = false
    private var kills: [Date] = []
    private var suspects: [GPUProcessOrphanPolicy.Suspect] = []

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer.tolerance = checkInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Looks for abandoned GPU processes now. Called on a timer, and whenever a
    /// web process is reported unresponsive — the symptom an abandoned GPU
    /// process produces.
    func sweep() {
        guard !scanning else { return }
        scanning = true
        // A pass over the whole process table; keep it off the main thread.
        scanQueue.async { [weak self] in
            let processes = GPUProcessTable.ownGPUProcesses()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    self.evaluate(processes)
                }
            }
        }
    }

    private func evaluate(_ processes: [GPUProcessTable.Entry]) {
        // Read after the scan, so a GPU process WebKit adopted while the scan
        // ran is the current one here.
        let current = GPUProcessRecycler.webKitGPUProcess()
        let verdict = policy.verdict(processes: processes, current: current, suspects: suspects, now: Date())
        suspects = verdict.suspects
        for orphan in verdict.orphans {
            // About to receive SIGKILL: confirm the pid still names the same
            // process (same start time), still a GPU process of ours.
            guard GPUProcessTable.entry(pid: orphan.pid) == orphan else { continue }
            let now = Date()
            kills.removeAll { now.timeIntervalSince($0) >= GPUProcessOrphanPolicy.killWindow }
            guard policy.killAllowance(earlierKills: kills, now: now) > 0 else {
                log.error("Not killing GPU process \(orphan.pid): \(self.kills.count) abandoned GPU processes were killed in the last hour already")
                break
            }
            let age = Int(now.timeIntervalSince(orphan.startedAt))
            let currentPID: pid_t = if case .running(let pid) = current { pid } else { 0 }
            log.notice("Killing abandoned GPU process \(orphan.pid), launched \(age) s ago; WebKit's GPU process is \(currentPID)")
            if kill(orphan.pid, SIGKILL) == 0 {
                kills.append(now)
            } else {
                let code = errno
                log.error("Could not kill abandoned GPU process \(orphan.pid): errno \(code)")
            }
        }
        scheduleRecheck(at: verdict.recheckAt)
    }

    private func scheduleRecheck(at date: Date?) {
        recheck?.cancel()
        recheck = nil
        guard let date else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.sweep() }
        }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow) + 1, execute: work)
    }
}
