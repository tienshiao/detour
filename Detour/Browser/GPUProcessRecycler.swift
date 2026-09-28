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
/// `inactiveGrace`; at `hardLimit` — about to break, or already broken — also
/// while Detour is frontmost, once the user has not touched any input for
/// `userIdleGrace`. Never while any tab plays audio or captures camera/mic,
/// and never twice within `minimumInterval` (WebKit terminates every
/// WebContent process when its GPU process "crashes" repeatedly in a short
/// window).
struct GPUProcessRecyclePolicy: Equatable {
    var softLimit = 12_000
    var hardLimit = 15_000
    var inactiveGrace: TimeInterval = 5 * 60
    var userIdleGrace: TimeInterval = 60
    var minimumInterval: TimeInterval = 60 * 60

    struct Inputs {
        var surfaceCount: Int
        /// When Detour stopped being the active app, or nil while it is active.
        var inactiveSince: Date?
        /// Seconds since the last keyboard/mouse/trackpad event, session-wide.
        var userIdleSeconds: TimeInterval
        /// Any tab playing audio or capturing camera/microphone — a recycle
        /// would cut the media off (capture runs in the GPU process).
        var mediaInUse: Bool
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
        guard inputs.surfaceCount >= softLimit else { return .keep }
        guard !inputs.mediaInUse else { return .wait }
        if let last = inputs.lastRecycleAt, inputs.now.timeIntervalSince(last) < minimumInterval {
            return .wait
        }
        let inactiveFor = inputs.inactiveSince.map { inputs.now.timeIntervalSince($0) }
        if let inactiveFor, inactiveFor >= inactiveGrace { return .recycle }
        if inputs.surfaceCount >= hardLimit,
           inactiveFor != nil || inputs.userIdleSeconds >= userIdleGrace {
            return .recycle
        }
        return .wait
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
        if let v = int("DETOUR_GPU_RECYCLE_SOFT_LIMIT") { policy.softLimit = v }
        if let v = int("DETOUR_GPU_RECYCLE_HARD_LIMIT") { policy.hardLimit = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS") { policy.inactiveGrace = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS") { policy.userIdleGrace = v }
        if let v = seconds("DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS") { policy.minimumInterval = v }
        return policy
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
    private let sampleQueue = DispatchQueue(label: "com.detourbrowser.gpu-recycle", qos: .utility)

    private var timer: Timer?
    private var inactiveSince: Date?
    private var lastRecycleAt: Date?
    private var sampling = false

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

    private func check() {
        guard !sampling else { return }
        guard let pid = Self.gpuProcessIdentifier() else {
            log.debug("No GPU process identifier from any live web view")
            return
        }
        sampling = true
        // Walking ~30k regions takes ~50 ms at the limit; keep it off the main thread.
        sampleQueue.async { [weak self] in
            let count = Self.ioSurfaceCount(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sampling = false
                    guard let count else {
                        log.debug("GPU process \(pid) could not be inspected")
                        return
                    }
                    self.evaluate(pid: pid, surfaceCount: count)
                }
            }
        }
    }

    private func evaluate(pid: pid_t, surfaceCount: Int) {
        let inputs = GPUProcessRecyclePolicy.Inputs(
            surfaceCount: surfaceCount,
            inactiveSince: inactiveSince,
            userIdleSeconds: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: CGEventType(rawValue: ~0)!),
            mediaInUse: Self.liveTabs().contains(where: Self.isUsingMedia),
            lastRecycleAt: lastRecycleAt,
            now: Date())
        switch policy.decide(inputs) {
        case .keep:
            return
        case .wait:
            log.info("GPU process \(pid) holds \(surfaceCount) IOSurfaces; recycle gate closed (active=\(self.inactiveSince == nil), media=\(inputs.mediaInUse))")
        case .recycle:
            // The pid was sampled a moment ago and is about to receive SIGKILL:
            // confirm it is still *our* GPU process (the name alone would also
            // match another app's WebKit GPU process on a reused pid).
            guard Self.gpuProcessIdentifier() == pid,
                  Self.processName(pid) == "com.apple.WebKit.GPU" else { return }
            log.notice("Recycling GPU process \(pid) at \(surfaceCount) IOSurfaces")
            lastRecycleAt = inputs.now
            kill(pid, SIGKILL)
        }
    }

    /// Every tab that may own a web view: space tabs, pinned entries' and
    /// favourites' backing tabs, and their peeks.
    private static func liveTabs() -> [BrowserTab] {
        let store = TabStore.shared
        let owners = store.spaces.flatMap { $0.tabs + $0.pinnedTabs } + store.profiles.flatMap(\.favoriteTabs)
        return owners + owners.compactMap(\.peekTab)
    }

    private static func isUsingMedia(_ tab: BrowserTab) -> Bool {
        if tab.isPlayingAudio { return true }
        guard let webView = tab.webView else { return false }
        return webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
    }

    /// The GPU process is shared by every web view in the app; ask any live one.
    /// 0 (not launched yet) and a missing SPI both read as nil.
    private static func gpuProcessIdentifier() -> pid_t? {
        let selector = NSSelectorFromString("_gpuProcessIdentifier")
        guard let webView = liveTabs().lazy.compactMap(\.webView).first,
              webView.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        let pid = unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
        return pid > 0 ? pid : nil
    }

    /// Counts `pid`'s VM regions tagged VM_MEMORY_IOSURFACE — the same figure
    /// `vmmap --summary` reports. Works without privileges for a same-user
    /// process; nil when the process cannot be inspected.
    nonisolated static func ioSurfaceCount(pid: pid_t) -> Int? {
        let ioSurfaceTag: UInt32 = 88  // VM_MEMORY_IOSURFACE (mach/vm_statistics.h)
        let size = Int32(MemoryLayout<proc_regioninfo>.size)
        var address: UInt64 = 0
        var regions = 0
        var surfaces = 0
        while true {
            var info = proc_regioninfo()
            guard proc_pidinfo(pid, PROC_PIDREGIONINFO, address, &info, size) == size else { break }
            regions += 1
            if info.pri_user_tag == ioSurfaceTag { surfaces += 1 }
            let next = info.pri_address + info.pri_size
            guard next > address else { break }
            address = next
        }
        return regions > 0 ? surfaces : nil
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
