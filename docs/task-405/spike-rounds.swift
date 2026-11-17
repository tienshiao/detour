// TASK-405 control: does a plain WKWebView app strand GPU-process IOSurfaces
// when its web views are closed? No Detour code involved.
//
// Each round creates one WKWebView per URL (each from a fresh
// WKWebViewConfiguration, as Detour's tabs are), shows each in turn `cycles`
// times (removeFromSuperview / addSubview, Detour's tab switch), then closes
// them all (remove + release), waits `settle` seconds and counts the GPU
// process's IOSurface regions. The GPU pid is asked of the first round's views
// and kept, so later samples work with no web view left.
//
//   swiftc -O spike-rounds.swift -o spike-rounds
//   ./spike-rounds <rounds> <cycles> <settle> [url,url,...]
// Prints one "ROUND n peak=… closed=…" line per round. Needs no sandbox
// privileges beyond running a GUI app; the region walk works for a same-user
// process.
import AppKit
import Darwin
import WebKit

let args = CommandLine.arguments
let rounds = args.count > 1 ? Int(args[1])! : 4
let cycles = args.count > 2 ? Int(args[2])! : 2
let settle = args.count > 3 ? Double(args[3])! : 20
let urls = (args.count > 4 ? args[4] : "https://www.youtube.com/,https://www.youtube.com/feed/trending,https://github.com/WebKit/WebKit,https://www.apple.com/,https://www.apple.com/macbook-pro/,https://developer.apple.com/documentation/webkit")
    .split(separator: ",").map { URL(string: String($0))! }

func regionCounts(_ pid: pid_t) -> (total: Int, nonResident: Int)? {
    let size = Int32(MemoryLayout<proc_regioninfo>.size)
    var address: UInt64 = 0, regions = 0, total = 0, nonResident = 0
    while true {
        var info = proc_regioninfo()
        guard proc_pidinfo(pid, PROC_PIDREGIONINFO, address, &info, size) == size else { break }
        regions += 1
        if info.pri_user_tag == 88 { total += 1; if info.pri_pages_resident == 0 { nonResident += 1 } }
        let next = info.pri_address + info.pri_size
        guard next > address else { break }
        address = next
    }
    return regions > 0 ? (total, nonResident) : nil
}

func gpuPID(_ views: [WKWebView]) -> pid_t? {
    let selector = NSSelectorFromString("_gpuProcessIdentifier")
    typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
    for view in views where view.responds(to: selector) {
        let pid = unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
        if pid > 0 { return pid }
    }
    return nil
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1200, height: 800),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "spike-rounds"
let container = NSView(frame: window.contentView!.bounds)
container.autoresizingMask = [.width, .height]
window.contentView!.addSubview(container)
window.makeKeyAndOrderFront(nil)

var gpu: pid_t?
var views: [WKWebView] = []
var leftBehind: [Int] = []
func after(_ s: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block) }
func sample() -> String {
    if gpu == nil { gpu = gpuPID(views) }
    guard let gpu, let c = regionCounts(gpu) else { return "total=? nonResident=?" }
    return "total=\(c.total) nonResident=\(c.nonResident)"
}
func show(_ view: WKWebView) {
    for v in container.subviews where v !== view { v.removeFromSuperview() }
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    if view.superview == nil { container.addSubview(view) }
}

func runRound(_ n: Int) {
    guard n <= rounds else { print("DONE left behind: \(leftBehind)"); exit(0) }
    views = urls.map { url in
        let view = WKWebView(frame: container.bounds, configuration: WKWebViewConfiguration())
        view.load(URLRequest(url: url))
        return view
    }
    var steps: [WKWebView] = []
    for _ in 0..<(1 + cycles) { steps += views }
    func step(_ i: Int) {
        guard i < steps.count else {
            let peak = sample()
            for v in views { v.removeFromSuperview() }
            views.removeAll()
            after(settle) {
                let counts = gpu.flatMap(regionCounts)
                let closed = counts.map { "total=\($0.total) nonResident=\($0.nonResident)" } ?? "total=? nonResident=?"
                if let counts { leftBehind.append(counts.total) }
                print("ROUND \(n) peak: \(peak) | closed +\(Int(settle))s: \(closed)")
                fflush(stdout)
                runRound(n + 1)
            }
            return
        }
        show(steps[i])
        // The first pass gives each page time to load; later passes are switches.
        after(i < views.count ? 8 : 2) { step(i + 1) }
    }
    step(0)
}
after(2) { runRound(1) }
app.run()
