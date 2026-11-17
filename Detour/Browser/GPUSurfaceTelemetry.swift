import AppKit
import CryptoKit
import os.log

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "gpu-surfaces")

/// A GPU process's IOSurface VM regions (`VM_MEMORY_IOSURFACE`), as
/// `vmmap --summary` counts them. `nonResident` are regions with no page in
/// memory — in practice the purged volatile buffers `vmmap` marks `PURGE=E`
/// (TASK-104), which still count against the kernel's 16,384 cap.
struct IOSurfaceRegionCounts: Equatable, Sendable {
    var total: Int
    var nonResident: Int
}

/// One reading of the GPU process (TASK-404).
struct GPUSurfaceSample: Equatable {
    var gpuPID: pid_t
    var counts: IOSurfaceRegionCounts
    /// Distinct WebContent processes behind Detour's live tabs.
    var tabProcesses: Int
    var at: Date
}

/// Something a tab did that should move the GPU process's surface count.
struct GPUSurfaceEvent: Equatable {
    enum Kind: String {
        /// A window hosted the tab's web view (`BrowserTab.noteShown`).
        case show
        /// The tab got a fresh web view (`BrowserTab.wake`).
        case wake
        /// The tab released its web view to sleep.
        case sleep
        /// The tab was closed with its web view live (`BrowserTab.teardown`).
        case close
    }

    var kind: Kind
    var host: String
    /// 0 when the web view had no process yet (a wake) or the SPI is missing.
    var webProcess: pid_t
}

/// The pure half of the GPU surface telemetry: when a periodic sample is worth
/// a persisted line, and how lines read (TASK-404).
enum GPUSurfaceTelemetryRules {
    /// A periodic sample is logged once the total moved this far since the
    /// last logged sample…
    static let periodicMinDelta = 50
    /// …or this long after the last logged sample, so the curve has no gaps.
    static let periodicMaxSilence: TimeInterval = 10 * 60

    static func shouldLogPeriodic(_ sample: GPUSurfaceSample, lastLogged: GPUSurfaceSample?) -> Bool {
        guard let lastLogged, lastLogged.gpuPID == sample.gpuPID else { return true }
        if abs(sample.counts.total - lastLogged.counts.total) >= periodicMinDelta { return true }
        return sample.at.timeIntervalSince(lastLogged.at) >= periodicMaxSilence
    }

    /// `total=2291 (+57) nonResident=1564 (-307) tabProcesses=10 gpu=14558`.
    /// Without a previous sample of the same GPU process there is no delta.
    static func describe(_ sample: GPUSurfaceSample, since previous: GPUSurfaceSample?) -> String {
        let counts = sample.counts
        let tail = "tabProcesses=\(sample.tabProcesses) gpu=\(sample.gpuPID)"
        guard let previous, previous.gpuPID == sample.gpuPID else {
            let note = previous == nil ? "" : " (new GPU process)"
            return "total=\(counts.total) nonResident=\(counts.nonResident) \(tail)\(note)"
        }
        let seconds = Int(sample.at.timeIntervalSince(previous.at).rounded())
        return "total=\(counts.total) (\(signed(counts.total - previous.counts.total))) "
            + "nonResident=\(counts.nonResident) (\(signed(counts.nonResident - previous.counts.nonResident))) "
            + "\(tail) over \(seconds)s"
    }

    /// Identical events folded, in first-seen order:
    /// `show youtube.com[7011]×3, close jira.example.com[24775]`.
    static func describe(_ events: [GPUSurfaceEvent], limit: Int = 12) -> String {
        struct Group { var event: GPUSurfaceEvent; var count: Int }
        var groups: [Group] = []
        for event in events {
            if let index = groups.firstIndex(where: { $0.event == event }) {
                groups[index].count += 1
            } else {
                groups.append(Group(event: event, count: 1))
            }
        }
        var parts = groups.prefix(limit).map { group -> String in
            let process = group.event.webProcess > 0 ? "[\(group.event.webProcess)]" : ""
            let times = group.count > 1 ? "×\(group.count)" : ""
            return "\(group.event.kind.rawValue) \(group.event.host)\(process)\(times)"
        }
        if groups.count > limit { parts.append("+\(groups.count - limit) more") }
        return parts.joined(separator: ", ")
    }

    /// What an event line names a tab's site as. Host names are browsing
    /// history, and these lines are persisted in the unified log, which
    /// `log show` reads and a sysdiagnose carries off the machine — outside
    /// anything Clear History reaches. So by default a host is written as a
    /// token: HMAC-SHA256 under `salt`, which is random per launch and never
    /// stored, so equal hosts match within a run (enough to see one site keep
    /// growing the pool) but a token cannot be computed from a host, so not
    /// even a dictionary of popular sites reverses it. It is still linkable:
    /// whoever can tie one line to a known visit (by its time) knows that
    /// site's token for the rest of the launch. `logPublic` (the
    /// `GPUSurfaceLogPublic` default, for diagnosing one's own machine) writes
    /// the host itself. A private-browsing tab is never named either way.
    /// (`Logger`'s own `.private(mask: .hash)` cannot be used: privacy is fixed
    /// per interpolation, and a line folds a variable number of events into
    /// one string.)
    static func loggedHost(_ host: String?, isPrivateBrowsing: Bool, logPublic: Bool, salt: SymmetricKey) -> String {
        if isPrivateBrowsing { return "private" }
        guard let host, !host.isEmpty else { return "-" }
        if logPublic { return host }
        // One site, one token: `WWW.Example.com.` and `www.example.com` are the same host.
        var normalized = host.lowercased()
        if normalized.count > 1, normalized.hasSuffix(".") { normalized.removeLast() }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: salt)
        return "site-" + mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }
}

/// Persists the GPU process's IOSurface curve and ties its moves to what tabs
/// did (TASK-404), so a recurrence of TASK-104/403 can be attributed from
/// `log show` alone: category `gpu-surfaces`, all at notice.
///
/// - The recycler's periodic sample goes through `recordPeriodic`, logged
///   under `GPUSurfaceTelemetryRules.shouldLogPeriodic`.
/// - Tab events are queued by `note`; `settleDelay` after the first one a
///   sample is taken and logged with every event queued meanwhile, against the
///   previous sample of any kind. Freeing is not instant, so a close's effect
///   can also land in the next line.
///
/// Every region walk runs on one serial queue, so there is never more than one
/// in flight (each takes ~50 ms at the cap).
@MainActor
final class GPUSurfaceTelemetry {
    static let shared = GPUSurfaceTelemetry()

    private let settleDelay: Duration = .seconds(3)
    /// A runaway caller cannot grow the queue without bound; the overflow is
    /// counted and reported with the next line.
    private let maxPendingEvents = 200

    private nonisolated static let sampleQueue = DispatchQueue(
        label: "com.detourbrowser.gpu-surfaces", qos: .utility)

    private var pending: [GPUSurfaceEvent] = []
    private var droppedEvents = 0
    private var flushScheduled = false
    private var lastSample: GPUSurfaceSample?
    private var lastLogged: GPUSurfaceSample?

    func note(_ kind: GPUSurfaceEvent.Kind, tab: BrowserTab) {
        guard pending.count < maxPendingEvents else {
            droppedEvents += 1
            return
        }
        pending.append(GPUSurfaceEvent(
            kind: kind,
            host: Self.loggedHost(of: tab),
            webProcess: tab.webProcessIdentifier))
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [settleDelay] in
            try? await Task.sleep(for: settleDelay)
            self.flushEvents()
        }
    }

    /// Reads `pid` off the main thread and hands back a sample; nil when the
    /// process could not be inspected.
    func takeSample(pid: pid_t, completion: @escaping @MainActor (GPUSurfaceSample?) -> Void) {
        let tabProcesses = Self.tabProcessCount()
        Self.sampleQueue.async {
            let counts = GPUProcessRecycler.ioSurfaceRegionCounts(pid: pid)
            DispatchQueue.main.async {
                // Not a crossing: the main queue runs this on the main thread.
                MainActor.assumeIsolated {
                    completion(counts.map {
                        GPUSurfaceSample(gpuPID: pid, counts: $0, tabProcesses: tabProcesses, at: Date())
                    })
                }
            }
        }
    }

    func recordPeriodic(_ sample: GPUSurfaceSample) {
        defer { lastSample = sample }
        guard GPUSurfaceTelemetryRules.shouldLogPeriodic(sample, lastLogged: lastLogged) else { return }
        log.notice("sample \(GPUSurfaceTelemetryRules.describe(sample, since: self.lastLogged), privacy: .public)")
        lastLogged = sample
    }

    private func flushEvents() {
        flushScheduled = false
        let events = pending
        let dropped = droppedEvents
        pending = []
        droppedEvents = 0
        guard !events.isEmpty else { return }
        let described = GPUSurfaceTelemetryRules.describe(events)
            + (dropped > 0 ? " (+\(dropped) dropped)" : "")
        guard let pid = GPUProcessRecycler.gpuProcessIdentifier() else {
            log.notice("after \(described, privacy: .public): no GPU process")
            return
        }
        takeSample(pid: pid) { [weak self] sample in
            guard let self else { return }
            guard let sample else {
                log.notice("after \(described, privacy: .public): GPU process \(pid) could not be inspected")
                return
            }
            log.notice("after \(described, privacy: .public): \(GPUSurfaceTelemetryRules.describe(sample, since: self.lastSample), privacy: .public)")
            self.lastSample = sample
            self.lastLogged = sample
        }
    }

    /// `defaults write com.detourbrowser.mac GPUSurfaceLogPublic -bool YES`
    /// logs real host names instead of per-launch tokens (TASK-404); undo with
    /// `defaults delete com.detourbrowser.mac GPUSurfaceLogPublic`.
    static let logPublicDefaultsKey = "GPUSurfaceLogPublic"

    /// Per launch, in memory only — see `GPUSurfaceTelemetryRules.loggedHost`.
    private static let hostSalt = SymmetricKey(size: .bits256)

    /// Whether this launch has already said, in the log itself, that host
    /// names are being written in the clear.
    private static var announcedPublicHosts = false

    private static func loggedHost(of tab: BrowserTab) -> String {
        let inIncognitoSpace = tab.spaceID.flatMap { TabStore.shared.space(withID: $0) }?.isIncognito ?? false
        let ephemeralStore = tab.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
        let logPublic = UserDefaults.standard.bool(forKey: logPublicDefaultsKey)
        if logPublic, !announcedPublicHosts {
            announcedPublicHosts = true
            log.notice("Logging tab host names PUBLICLY (\(logPublicDefaultsKey, privacy: .public) is set); these lines are browsing history")
        }
        return GPUSurfaceTelemetryRules.loggedHost(
            tab.url?.host(),
            isPrivateBrowsing: inIncognitoSpace || ephemeralStore,
            logPublic: logPublic,
            salt: hostSalt)
    }

    private static func tabProcessCount() -> Int {
        Set(TabStore.shared.allLiveTabs.map(\.webProcessIdentifier).filter { $0 > 0 }).count
    }
}
