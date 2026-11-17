import AppKit
import WebKit

/// TASK-405: what the GPU process holds and how Detour's web views are spread
/// over WebKit's process pools, for the closed-tab experiment
/// (`docs/harness/task405-gpu-experiment.py`) and for `/verify` runs.
extension AutomationTools {

    var gpuTools: [MCPTool] { [gpuProcessStats, trimBackForwardCache] }

    private var gpuProcessStats: MCPTool {
        MCPTool(
            name: "gpu_process_stats",
            title: "GPU process and process pool stats",
            description: "Reads WebKit's GPU process: gpu_pid (null when none is running), total IOSurface regions and "
                + "non_resident ones (purged buffers, vmmap's PURGE=E), as the recycler counts them. Also how the "
                + "live tabs' web views are spread over processes: live_web_views, tab_processes (distinct web content "
                + "pids) and their tab_process_footprint_mb, and process_pools, one entry per WKProcessPool WebKit reports (or, without that SPI, per pool "
                + "a live tab uses) with its tab_web_views count and, where WebKit answers, web_processes (excluding "
                + "cached and prewarmed ones), cached_processes, uses_web_process_cache and "
                + "prewarms_processes_automatically. detail true adds tabs (Private ones only with Private access): tab_id, host, web_process, pool (index into "
                + "process_pools) and asleep.",
            inputSchema: MCPSchema.input([
                ("detail", .boolean("Also list every live tab; false by default")),
            ]),
            outputSchema: MCPSchema.output([
                "gpu_pid": ["type": ["integer", "null"]],
                "total": ["type": ["integer", "null"]],
                "non_resident": ["type": ["integer", "null"]],
                "live_web_views": MCPSchema.integerType,
                "tab_processes": MCPSchema.integerType,
                "tab_process_footprint_mb": MCPSchema.integerType,
                "process_pools": MCPSchema.arrayOfObjects("One entry per WebKit process pool"),
                "tabs": MCPSchema.arrayOfObjects("detail only: one entry per live tab"),
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let detail = try arguments.bool("detail") ?? false
                var counts: IOSurfaceRegionCounts?
                let gpuPID = GPUProcessRecycler.gpuProcessIdentifier()
                if let gpuPID {
                    // ~50 ms at the cap: keep the region walk off the main thread.
                    counts = await Task.detached(priority: .utility) {
                        GPUProcessRecycler.ioSurfaceRegionCounts(pid: gpuPID)
                    }.value
                }

                // Read after the walk, so tabs closed or slept meanwhile drop out.
                let store = environment.store
                let tabs = store.allLiveTabs
                let pools = Self.processPools(of: tabs)
                let liveViews = tabs.compactMap(\.webView)
                let processes = Set(tabs.map(\.webProcessIdentifier).filter { $0 > 0 })
                var result: [String: JSONValue] = [
                    "gpu_pid": gpuPID.map { .int(Int($0)) } ?? .null,
                    "total": counts.map { .int($0.total) } ?? .null,
                    "non_resident": counts.map { .int($0.nonResident) } ?? .null,
                    "live_web_views": .int(liveViews.count),
                    "tab_processes": .int(processes.count),
                    "tab_process_footprint_mb": .int(processes.reduce(0) { $0 + Self.footprintMB(of: $1) }),
                    "process_pools": .array(pools.map { pool in
                        let ownViews = liveViews.filter { $0.configuration.processPool === pool }.count
                        return [
                            "tab_web_views": .int(ownViews),
                            "web_processes": Self.unsignedSPI(pool, "_webProcessCountIgnoringPrewarmedAndCached")
                                .map(JSONValue.int) ?? .null,
                            "cached_processes": Self.unsignedSPI(pool, "_processCacheSize").map(JSONValue.int) ?? .null,
                            "uses_web_process_cache": Self.configurationFlag(pool, "usesWebProcessCache"),
                            "prewarms_processes_automatically": Self.configurationFlag(pool, "prewarmsProcessesAutomatically"),
                        ]
                    }),
                ]
                if detail {
                    // Private tabs (ids and hosts) only while Private access is allowed.
                    let allowed = privateAllowed
                    result["tabs"] = .array(tabs.filter { allowed || !Self.isPrivate($0, in: store) }.map { tab in
                        let poolIndex = tab.webView.flatMap { view in
                            pools.firstIndex { $0 === view.configuration.processPool }
                        }
                        return [
                            "tab_id": .string(tab.id.uuidString),
                            "host": .nullable(tab.url?.host()),
                            "web_process": tab.webProcessIdentifier > 0 ? .int(Int(tab.webProcessIdentifier)) : .null,
                            "pool": poolIndex.map(JSONValue.int) ?? .null,
                            "asleep": .bool(tab.webView == nil),
                        ]
                    })
                }
                return .object(result)
            })
    }

    private var trimBackForwardCache: MCPTool {
        MCPTool(
            name: "trim_back_forward_cache",
            title: "Trim back/forward caches",
            description: "Clears WebKit's back/forward cache (the frozen pages kept for instant Back) of one tab "
                + "(context, a tab_id) or of every live tab no window hosts (no context; Private tabs only with Private "
                + "access), keeping their history. "
                + "Returns the trimmed tab_ids. For the TASK-405/408 measurement.",
            inputSchema: MCPSchema.input([
                ("context", .string("A tab_id; every hidden live tab when omitted")),
            ]),
            outputSchema: MCPSchema.output(["trimmed": ["type": "array", "items": MCPSchema.stringType]]),
            annotations: ["readOnlyHint": false, "destructiveHint": false],
            handler: { [self] arguments in
                let tabs: [BrowserTab]
                if let context = try arguments.string("context") {
                    tabs = [try resolveTab(context: context)]
                } else {
                    let store = environment.store
                    let allowed = privateAllowed
                    tabs = store.allLiveTabs.filter {
                        $0.webViewContainer?.superview == nil && (allowed || !Self.isPrivate($0, in: store))
                    }
                }
                let trimmed = tabs.filter { $0.clearBackForwardCache() }
                return ["trimmed": .array(trimmed.map { .string($0.id.uuidString) })]
            })
    }

    /// Every process pool WebKit reports (`+_allProcessPoolsForTesting`), which
    /// includes ones no tab uses (extension contexts); without that SPI, the
    /// distinct pools of the live tabs' web views.
    private static func processPools(of tabs: [BrowserTab]) -> [WKProcessPool] {
        var pools: [WKProcessPool] = []
        func add(_ pool: WKProcessPool) {
            if !pools.contains(where: { $0 === pool }) { pools.append(pool) }
        }
        let selector = NSSelectorFromString("_allProcessPoolsForTesting")
        let poolClass: AnyObject = WKProcessPool.self
        if poolClass.responds(to: selector),
           let all = poolClass.perform(selector)?.takeUnretainedValue() as? [WKProcessPool] {
            all.forEach(add)
        }
        tabs.compactMap(\.webView).forEach { add($0.configuration.processPool) }
        return pools
    }

    /// A tab of a Private space or on a non-persistent store (a Private Quick
    /// Detour or favorite), which automation reaches only with Private access.
    private static func isPrivate(_ tab: BrowserTab, in store: TabStore) -> Bool {
        if tab.spaceID.flatMap({ store.space(withID: $0) })?.isIncognito == true { return true }
        if tab.owningProfile?.isIncognito == true { return true }
        if store.profiles.contains(where: { $0.isIncognito && $0.favoriteTabs.contains { $0 === tab } }) { return true }
        return tab.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false
    }

    /// A process's physical footprint (what Activity Monitor calls Memory), in MB.
    private static func footprintMB(of pid: pid_t) -> Int {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? Int(info.ri_phys_footprint / 1_048_576) : 0
    }

    /// An `NSUInteger`-returning private getter, or nil when WebKit lacks it.
    private static func unsignedSPI(_ object: NSObject, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return Int(unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector))
    }

    /// A Boolean of the pool's `_WKProcessPoolConfiguration`, or null.
    private static func configurationFlag(_ pool: WKProcessPool, _ key: String) -> JSONValue {
        let configurationSelector = NSSelectorFromString("_configuration")
        guard pool.responds(to: configurationSelector),
              let configuration = pool.perform(configurationSelector)?.takeUnretainedValue() as? NSObject,
              configuration.responds(to: NSSelectorFromString(key)),
              let value = configuration.value(forKey: key) as? Bool else { return .null }
        return .bool(value)
    }
}
