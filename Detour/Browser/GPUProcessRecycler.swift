import AppKit
import CoreGraphics
import Darwin
import WebKit
import os.log

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "gpu-recycle")

/// When to recycle WebKit's GPU process before it runs out of IOSurfaces
/// (TASK-105).
///
/// Why this exists: the kernel caps a process at 16,384 IOSurfaces, and after a
/// few days of uptime WebKit's GPU process gets there — its buffers for hidden
/// pages are purged by the kernel but never destroyed (TASK-104). From then on
/// every IOSurface allocation fails, WebGL contexts and accelerated canvases die
/// browser-wide, and YouTube's attestation fails so it serves an unplayable
/// player response. The TASK-104 show budget slows the growth but does not cap
/// it, and WebKit's own memory-pressure flush frees only ~15% of the stranded
/// surfaces (TASK-109). Only the GPU process exiting frees them all; WebKit
/// relaunches it and every page reconnects without its WebContent process being
/// touched.
///
/// A recycle interrupts media and loses WebGL contexts, so it waits until nobody
/// is looking: at `softLimit`, only once Detour has been in the background for
/// `inactiveGrace`; at `hardLimit` — close to breaking — also while Detour is
/// frontmost, once the user has not touched any input for `userIdleGrace`; at
/// `exhaustedLimit` — already broken, every allocation failing — on the next
/// check even while the user is busy, since WebGL is dead anyway and a user
/// retrying the broken page never goes idle (TASK-403: the 1,384 surfaces
/// between 15k and the cap went in one morning of active use, and the
/// recycler fired 100 s after the cap). Never while any tab plays audio or
/// captures camera/mic, and never twice within `minimumInterval` (WebKit
/// terminates every WebContent process when its GPU process "crashes"
/// repeatedly in a short window).
///
/// While the user is away — the screen locked or every display asleep —
/// nobody can see a recycle, so it fires from `awayLimit`, well below the
/// others (TASK-406). The busy-user tiers above then become a rare fallback
/// for long stretches of continuous use. The media and rate-limit guards
/// still apply.
///
/// A page losing a WebGL context, or failing to get one, is the breakage
/// itself (TASK-410). With the count at `breakageLimit` or more, such a report
/// recycles at once: inside `minimumInterval`, and while a tab plays audio,
/// since playback is failing too. Never during a call, and never for reports
/// that arrive within `postRecycleGrace` of a recycle, which itself makes every
/// WebGL page lose its context (WebKit gives up on its web processes after
/// repeated GPU process exits in a short window).
struct GPUProcessRecyclePolicy: Equatable {
    var awayLimit = 6_000
    var softLimit = 12_000
    var hardLimit = 14_000
    /// The kernel's per-process IOSurface cap. The region count this policy
    /// reads was 16,697 when the cap had been failing allocations for 100 s
    /// (TASK-403), and 16.7k in TASK-104. Regions can run a little above live
    /// surfaces, so this may fire shortly before the cap rather than after it.
    var exhaustedLimit = 16_384
    var inactiveGrace: TimeInterval = 5 * 60
    var userIdleGrace: TimeInterval = 60
    var minimumInterval: TimeInterval = 60 * 60
    /// At or above this count, a reported context loss is taken as the cap
    /// failing allocations. Below it, a report only logs (TASK-410).
    var breakageLimit = 15_000
    /// How old a context-loss report may be and still confirm breakage.
    var contextLossWindow: TimeInterval = 30
    /// Reports this soon after a recycle are the recycle's own doing.
    var postRecycleGrace: TimeInterval = 5 * 60

    struct Inputs {
        var surfaceCount: Int
        /// When Detour stopped being the active app, or nil while it is active.
        var inactiveSince: Date?
        /// Seconds since the last keyboard/mouse/trackpad event, session-wide.
        var userIdleSeconds: TimeInterval
        /// Any tab playing audio or capturing camera/microphone — a recycle
        /// would cut the media off (capture runs in the GPU process).
        var mediaInUse: Bool
        /// The screen is locked or every online display is asleep: nobody is
        /// looking at any page.
        var userAway = false
        /// A tab captures camera or microphone (a subset of `mediaInUse`):
        /// even confirmed breakage does not cut a call off (TASK-410).
        var capturingMedia = false
        /// When a page last reported a lost WebGL context or a failed one.
        var lastContextLossAt: Date? = nil
        var lastRecycleAt: Date?
        var now: Date
    }

    enum Decision: Equatable {
        case keep
        /// Over a limit but the gate is closed; checked again on the next tick.
        case wait
        case recycle
    }

    func decide(_ inputs: Inputs) -> Decision {
        if confirmsBreakage(inputs) { return .recycle }
        let overAwayLimit = inputs.userAway && inputs.surfaceCount >= awayLimit
        guard overAwayLimit || inputs.surfaceCount >= softLimit else { return .keep }
        guard !inputs.mediaInUse else { return .wait }
        if let last = inputs.lastRecycleAt, inputs.now.timeIntervalSince(last) < minimumInterval {
            return .wait
        }
        if overAwayLimit { return .recycle }
        let inactiveFor = inputs.inactiveSince.map { inputs.now.timeIntervalSince($0) }
        if let inactiveFor, inactiveFor >= inactiveGrace { return .recycle }
        if inputs.surfaceCount >= hardLimit,
           inactiveFor != nil || inputs.userIdleSeconds >= userIdleGrace {
            return .recycle
        }
        if inputs.surfaceCount >= exhaustedLimit { return .recycle }
        return .wait
    }

    /// A recent context-loss report with the count near the cap and no call in
    /// progress: the GPU process is failing allocations now (TASK-410).
    func confirmsBreakage(_ inputs: Inputs) -> Bool {
        guard let loss = inputs.lastContextLossAt,
              inputs.surfaceCount >= breakageLimit,
              !inputs.capturingMedia else { return false }
        let age = inputs.now.timeIntervalSince(loss)
        guard age >= 0, age <= contextLossWindow else { return false }
        return !isRecyclesOwn(reportAt: loss, lastRecycleAt: inputs.lastRecycleAt)
    }

    /// A report from before the last recycle, or within `postRecycleGrace`
    /// after it: the recycle's own doing, never evidence of breakage.
    func isRecyclesOwn(reportAt report: Date, lastRecycleAt: Date?) -> Bool {
        guard let lastRecycleAt else { return false }
        return report.timeIntervalSince(lastRecycleAt) < postRecycleGrace
    }

    /// Environment overrides for the runtime harness, read once at launch. A
    /// non-positive or unparseable value is ignored rather than disabling a
    /// guard by accident.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GPUProcessRecyclePolicy {
        var policy = GPUProcessRecyclePolicy()
        func int(_ key: String) -> Int? {
            environment[key].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        }
        func seconds(_ key: String) -> TimeInterval? {
            environment[key].flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        if let v = int("DETOUR_GPU_RECYCLE_AWAY_LIMIT") { policy.awayLimit = v }
        if let v = int("DETOUR_GPU_RECYCLE_SOFT_LIMIT") { policy.softLimit = v }
        if let v = int("DETOUR_GPU_RECYCLE_HARD_LIMIT") { policy.hardLimit = v }
        if let v = int("DETOUR_GPU_RECYCLE_EXHAUSTED_LIMIT") { policy.exhaustedLimit = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS") { policy.inactiveGrace = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS") { policy.userIdleGrace = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS") { policy.minimumInterval = v }
        if let v = int("DETOUR_GPU_RECYCLE_BREAKAGE_LIMIT") { policy.breakageLimit = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_POST_RECYCLE_GRACE_SECONDS") { policy.postRecycleGrace = v }
        return policy
    }
}

/// When a context-loss report starts a count of its own (TASK-410): at once,
/// at most once per `gap`; a report inside the gap schedules one check for
/// when it ends, and later ones ride on that.
struct ContextLossCheckThrottle: Equatable {
    var gap: TimeInterval = 5
    private(set) var lastCheckAt: Date?
    private(set) var scheduled = false

    enum Action: Equatable {
        case checkNow
        case checkAfter(TimeInterval)
        /// A check is already scheduled; it will see this report.
        case none
    }

    mutating func report(at now: Date) -> Action {
        guard !scheduled else { return .none }
        if let last = lastCheckAt, now.timeIntervalSince(last) < gap {
            scheduled = true
            return .checkAfter(gap - now.timeIntervalSince(last))
        }
        lastCheckAt = now
        return .checkNow
    }

    mutating func scheduledCheckFired(at now: Date) {
        scheduled = false
        lastCheckAt = now
    }
}

/// Counts the GPU process's IOSurfaces and recycles it under
/// `GPUProcessRecyclePolicy` (TASK-105).
@MainActor
final class GPUProcessRecycler {
    static let shared = GPUProcessRecycler()

    private let policy = GPUProcessRecyclePolicy.fromEnvironment()
    private let checkInterval: TimeInterval = {
        let raw = ProcessInfo.processInfo.environment["DETOUR_GPU_RECYCLE_CHECK_SECONDS"]
        return raw.flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 120
    }()

    private var timer: Timer?
    private var inactiveSince: Date?
    private var lastRecycleAt: Date?
    private var sampling = false
    /// When a closed gate was last logged at notice; nil once the gate is not
    /// closed. Keeps a long wait to one persisted line per `waitLogInterval`.
    private var lastWaitLogAt: Date?
    private let waitLogInterval: TimeInterval = 10 * 60

    /// Context-loss reports not yet logged: each is logged once the count it
    /// prompted is known (TASK-410). Capped; the rest are only counted.
    private var pendingLosses: [String] = []
    private var droppedLosses = 0
    private let pendingLossCap = 20
    private var lastContextLossAt: Date?
    private var reportChecks = ContextLossCheckThrottle()

    func start() {
        guard timer == nil else { return }
        inactiveSince = NSApp.isActive ? nil : Date()
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactiveSince = Date() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactiveSince = nil }
        }
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = checkInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A page lost a WebGL context or failed to get one
    /// (`WebGLContextLossBridge`): count now rather than at the next tick.
    func contextLossReported(_ kind: WebGLContextLossKind, tab: BrowserTab, isMainFrame: Bool) {
        let now = Date()
        lastContextLossAt = now
        if pendingLosses.count < pendingLossCap {
            pendingLosses.append("\(kind.rawValue) in \(GPUSurfaceTelemetry.loggedHost(of: tab)) (\(isMainFrame ? "main frame" : "subframe"))")
        } else {
            droppedLosses += 1
        }
        // A recycle makes every WebGL page lose its context, and the policy
        // refuses those reports anyway: nothing to count.
        if policy.isRecyclesOwn(reportAt: now, lastRecycleAt: lastRecycleAt) {
            logPendingLosses { "within \(Int(policy.postRecycleGrace)) s of a recycle; not counted" }
            return
        }
        switch reportChecks.report(at: now) {
        case .none:
            return
        case .checkNow:
            check()
        case .checkAfter(let delay):
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.reportChecks.scheduledCheckFired(at: Date())
                self.check()
            }
        }
    }

    private func check() {
        // A sample already in flight evaluates with the latest report.
        guard !sampling else { return }
        guard let pid = Self.gpuProcessIdentifier() else {
            log.debug("No GPU process identifier from any live web view")
            logPendingLosses { "no GPU process" }
            return
        }
        sampling = true
        // Walking ~30k regions takes ~50 ms at the limit; the telemetry runs it
        // off the main thread, on the one queue every walk shares (TASK-404).
        GPUSurfaceTelemetry.shared.takeSample(pid: pid) { [weak self] sample in
            guard let self else { return }
            self.sampling = false
            guard let sample else {
                log.debug("GPU process \(pid) could not be inspected")
                self.logPendingLosses { "GPU process \(pid) could not be inspected" }
                return
            }
            GPUSurfaceTelemetry.shared.recordPeriodic(sample)
            self.evaluate(pid: pid, surfaceCount: sample.counts.total)
        }
    }

    private func evaluate(pid: pid_t, surfaceCount: Int) {
        let tabs = Self.liveTabs()
        let inputs = GPUProcessRecyclePolicy.Inputs(
            surfaceCount: surfaceCount,
            inactiveSince: inactiveSince,
            userIdleSeconds: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: CGEventType(rawValue: ~0)!),
            mediaInUse: tabs.contains(where: Self.isUsingMedia),
            userAway: Self.userIsAway(),
            capturingMedia: tabs.contains(where: \.isCapturingMedia),
            lastContextLossAt: lastContextLossAt,
            lastRecycleAt: lastRecycleAt,
            now: Date())
        let decision = policy.decide(inputs)
        // Confirmed breakage always decides `.recycle`.
        let breakage = policy.confirmsBreakage(inputs)
        // The pid was sampled a moment ago and is about to receive SIGKILL:
        // confirm it is still *our* GPU process (the name alone would also
        // match another app's WebKit GPU process on a reused pid).
        let pidStillOurs = decision == .recycle && Self.gpuProcessIdentifier() == pid
            && GPUProcessTable.name(of: pid) == GPUProcessTable.processName
        logPendingLosses {
            let outcome = switch decision {
            case .keep: "keep"
            case .wait: "wait"
            case .recycle where !pidStillOurs: "recycle skipped (GPU process changed)"
            case .recycle: breakage ? "recycle (breakage confirmed)" : "recycle"
            }
            return "GPU process \(pid) holds \(surfaceCount) IOSurfaces; \(outcome)"
        }
        if decision != .wait { lastWaitLogAt = nil }
        switch decision {
        case .keep:
            return
        case .wait:
            // Notice, not info: info lines are not persisted, and without these
            // a late recycle cannot be explained after the fact (TASK-403).
            if let last = lastWaitLogAt, inputs.now.timeIntervalSince(last) < waitLogInterval {
                log.info("GPU process \(pid) holds \(surfaceCount) IOSurfaces; recycle gate closed")
            } else {
                lastWaitLogAt = inputs.now
                let inactiveFor = inputs.inactiveSince.map { inputs.now.timeIntervalSince($0) } ?? -1
                let sinceRecycle = inputs.lastRecycleAt.map { inputs.now.timeIntervalSince($0) } ?? -1
                log.notice("GPU process \(pid) holds \(surfaceCount) IOSurfaces; recycle gate closed (inactiveFor=\(inactiveFor, format: .fixed(precision: 0))s, userIdle=\(inputs.userIdleSeconds, format: .fixed(precision: 0))s, media=\(inputs.mediaInUse), away=\(inputs.userAway), sinceLastRecycle=\(sinceRecycle, format: .fixed(precision: 0))s)")
            }
        case .recycle:
            guard pidStillOurs else { return }
            log.notice("Recycling GPU process \(pid) at \(surfaceCount) IOSurfaces (away=\(inputs.userAway), contextLoss=\(breakage))")
            lastRecycleAt = inputs.now
            kill(pid, SIGKILL)
        }
    }

    /// One notice per context-loss report since the last check, each with what
    /// the check found (TASK-410). Hosts are tokens unless the user turned
    /// on `GPUSurfaceLogPublic` (see `GPUSurfaceTelemetry.loggedHost(of:)`).
    private func logPendingLosses(_ outcome: () -> String) {
        guard !pendingLosses.isEmpty || droppedLosses > 0 else { return }
        let result = outcome()
        for loss in pendingLosses {
            log.notice("WebGL context \(loss, privacy: .public): \(result, privacy: .public)")
        }
        if droppedLosses > 0 {
            log.notice("WebGL context: \(self.droppedLosses) more reports not logged: \(result, privacy: .public)")
        }
        pendingLosses.removeAll()
        droppedLosses = 0
    }

    /// Whether nobody can be looking at the screen: the session's screen is
    /// locked, the session is not on the console (fast user switching moved
    /// another user in front), or every online display is asleep (TASK-406). Read at each
    /// check rather than tracked through notifications, so a missed
    /// lock/unlock or display-sleep notification cannot leave it stale. Both
    /// calls ask the window server and need no privileges. No online display
    /// at all reads as "not away": that is not a state this can judge.
    static func userIsAway() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true { return true }
            if (session[kCGSessionOnConsoleKey] as? NSNumber)?.boolValue == false { return true }
        }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success, count > 0 else { return false }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// Every tab that may own a web view: space tabs, pinned entries' and
    /// favourites' backing tabs, their peeks, and Quick Detour pages.
    private static func liveTabs() -> [BrowserTab] {
        TabStore.shared.allLiveTabs
    }

    private static func isUsingMedia(_ tab: BrowserTab) -> Bool {
        // `isAudible`, as before page mute (TASK-192): the old script mute made
        // a muted tab inaudible, so muted playback never held the recycler
        // back. A muted tab left looping would otherwise keep the GPU process
        // alive until its IOSurfaces run out (TASK-104), which is worse than
        // freezing a video nobody is listening to while the user is idle.
        tab.isAudible || tab.isCapturingMedia
    }

    /// What WebKit says its GPU process is. The process is one per app, shared
    /// by every web view.
    enum WebKitGPUProcess: Equatable {
        /// Nothing could be asked: no web view named a process, and the
        /// app-wide SPI is missing.
        case unknown
        /// WebKit tracks no launched GPU process: none was needed yet, one is
        /// launching, or WebKit dropped the last one and no page has asked for
        /// another since. (Not called `none`: on an optional of this type that
        /// name would silently mean "could not ask".)
        case notRunning
        case running(pid_t)
    }

    static func webKitGPUProcess() -> WebKitGPUProcess {
        webKitGPUProcess(askedOf: liveTabs().lazy.compactMap(\.webView))
    }

    /// A web view that names a process is believed first: it answers for its
    /// own process pool, every pool forgets the GPU process the moment it
    /// exits, so a pid named here is the live one. But a pool whose pages have
    /// not needed the GPU process since its last relaunch answers 0, and "every
    /// tab answers 0" does not mean there is none — so only the app-wide answer
    /// (`+[WKProcessPool _gpuProcessInfo]`) can say `.notRunning` (TASK-175).
    static func webKitGPUProcess<WebViews: Sequence>(askedOf webViews: WebViews) -> WebKitGPUProcess
    where WebViews.Element == WKWebView {
        if let pid = gpuProcessIdentifier(of: webViews) { return .running(pid) }
        let infoSelector = NSSelectorFromString("_gpuProcessInfo")
        let poolClass: AnyObject = WKProcessPool.self
        guard poolClass.responds(to: infoSelector) else { return .unknown }
        guard let info = poolClass.perform(infoSelector)?.takeUnretainedValue() as? NSObject,
              info.responds(to: NSSelectorFromString("pid")),
              let pid = (info.value(forKey: "pid") as? NSNumber)?.int32Value, pid > 0 else { return .notRunning }
        return .running(pid)
    }

    /// The pid of WebKit's GPU process, when it has one running.
    static func gpuProcessIdentifier() -> pid_t? {
        if case .running(let pid) = webKitGPUProcess() { return pid }
        return nil
    }

    /// The first GPU process any of `webViews` names; 0 (see
    /// `webKitGPUProcess(askedOf:)`) and a missing SPI are skipped.
    static func gpuProcessIdentifier<WebViews: Sequence>(of webViews: WebViews) -> pid_t?
    where WebViews.Element == WKWebView {
        let selector = NSSelectorFromString("_gpuProcessIdentifier")
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        for webView in webViews where webView.responds(to: selector) {
            let pid = unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
            if pid > 0 { return pid }
        }
        return nil
    }

    /// Counts `pid`'s VM regions tagged VM_MEMORY_IOSURFACE — the same figure
    /// `vmmap --summary` reports. Works without privileges for a same-user
    /// process; nil when the process cannot be inspected.
    nonisolated static func ioSurfaceCount(pid: pid_t) -> Int? {
        ioSurfaceRegionCounts(pid: pid)?.total
    }

    /// The IOSurface regions of `pid`, and how many of them have no resident
    /// page (purged volatile buffers, `PURGE=E` in `vmmap`) (TASK-404).
    nonisolated static func ioSurfaceRegionCounts(pid: pid_t) -> IOSurfaceRegionCounts? {
        let ioSurfaceTag: UInt32 = 88  // VM_MEMORY_IOSURFACE (mach/vm_statistics.h)
        let size = Int32(MemoryLayout<proc_regioninfo>.size)
        var address: UInt64 = 0
        var regions = 0
        var counts = IOSurfaceRegionCounts(total: 0, nonResident: 0)
        while true {
            var info = proc_regioninfo()
            guard proc_pidinfo(pid, PROC_PIDREGIONINFO, address, &info, size) == size else { break }
            regions += 1
            if info.pri_user_tag == ioSurfaceTag {
                counts.total += 1
                if info.pri_pages_resident == 0 { counts.nonResident += 1 }
            }
            let next = info.pri_address + info.pri_size
            guard next > address else { break }
            address = next
        }
        return regions > 0 ? counts : nil
    }
}
