import AppKit
import WebKit
// Build: swiftc task325-underlay-snapshot-spike.swift -module-cache-path $TMPDIR/mc -o snap; run with the
// sandbox OFF; SCALE2=1 forces device scale 2 (_setOverrideDeviceScaleFactor:) on a 1x display.
// Results 2026-11-14, macOS 26.7, 1500x950 pt page of 400 shadowed cards, machine load average ~250:
//   switcher 480 px            ~5 ms                (1x and 2x)
//   full size, on screen       15.6 ms, 5 MB at 1x;  64 ms, 22 MB at 2x   (async, web process paints)
//   cacheDisplay (sync, main)  5.5 ms at 1x;         26 ms at 2x
//   full size, 3 s after the web view left the window: 1x run A median 240 ms, max 1449 ms; run B median 19.5 ms;
//                                                      2x median 63 ms (background priority: unpredictable under load)
// TASK-325 underlay options: what a full-size takeSnapshot costs vs the 480 px switcher one,
// vs the synchronous cacheDisplay the window uses for ownership handoff, and whether a web view
// that has left the window can still be snapshotted.
setvbuf(stdout, nil, _IONBF, 0)
final class Nav: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { let f = onFinish; onFinish = nil; f?() }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let W: CGFloat = 1500, H: CGFloat = 950
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: W, height: H), styleMask: [.titled], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H)); window.contentView = container
let webView = WKWebView(frame: container.bounds); container.addSubview(webView)
window.orderFrontRegardless()
let nav = Nav(); webView.navigationDelegate = nav
// A busy-ish page: lots of text, gradients, shadows, rounded boxes, an SVG.
var cards = ""
for i in 0..<400 { cards += "<div class=c><h3>Card \(i)</h3><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam.</p><svg width=60 height=30><circle cx=15 cy=15 r=12 fill=hsl(\(i*7%360),70%,50%) /></svg></div>" }
let html = "<html><head><style>body{font:14px -apple-system;margin:0;background:linear-gradient(#fafafa,#e0e8f0)} .c{display:inline-block;width:260px;margin:10px;padding:12px;border-radius:12px;box-shadow:0 4px 14px rgba(0,0,0,.25);background:linear-gradient(135deg,#fff,#eef)}</style></head><body>\(cards)</body></html>"
if ProcessInfo.processInfo.environment["SCALE2"] != nil {
    let sel = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
    typealias F = @convention(c) (AnyObject, Selector, CGFloat) -> Void
    unsafeBitCast(webView.method(for: sel), to: F.self)(webView, sel, 2)
}
let scale: CGFloat = ProcessInfo.processInfo.environment["SCALE2"] != nil ? 2 : window.backingScaleFactor
print("backingScale=\(scale) content=\(Int(W))x\(Int(H)) pt")

func snap(_ label: String, widthPt: CGFloat?, runs: Int, then: @escaping () -> Void) {
    var times: [Double] = []; var px = ""
    func one(_ i: Int) {
        if i == runs { times.sort(); print("[\(label)] \(px) median \(String(format: "%.1f", times[times.count/2])) ms, min \(String(format: "%.1f", times[0])), max \(String(format: "%.1f", times.last!))"); then(); return }
        let cfg = WKSnapshotConfiguration(); if let w = widthPt { cfg.snapshotWidth = NSNumber(value: Double(w)) }
        let t0 = CACurrentMediaTime()
        webView.takeSnapshot(with: cfg) { img, err in
            let ms = (CACurrentMediaTime() - t0) * 1000
            if let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { px = "\(cg.width)x\(cg.height) px (\(cg.width*cg.height*4/1_000_000) MB)" } else { px = "nil err=\(String(describing: err))" }
            times.append(ms); one(i + 1)
        }
    }
    one(0)
}
func cacheDisplayTime() {
    var times: [Double] = []
    for _ in 0..<5 {
        let t0 = CACurrentMediaTime()
        let rep = webView.bitmapImageRepForCachingDisplay(in: webView.bounds)!
        webView.cacheDisplay(in: webView.bounds, to: rep)
        times.append((CACurrentMediaTime() - t0) * 1000)
    }
    times.sort(); print("[cacheDisplay sync, main thread] median \(String(format: "%.1f", times[2])) ms max \(String(format: "%.1f", times[4]))")
}
nav.onFinish = {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        snap("switcher 480px", widthPt: 480 / scale, runs: 7) {
            snap("full size", widthPt: nil, runs: 7) {
                cacheDisplayTime()
                webView.removeFromSuperview()   // the opener once the child is selected
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {   // WebKit drops a hidden page to background priority ~1 s after
                    snap("full size, detached 3 s", widthPt: nil, runs: 5) {
                        container.addSubview(webView)
                        let t0 = CACurrentMediaTime()
                        // How soon is a re-attached web view painted? Proxy: first snapshot after re-attach.
                        snap("full size, right after re-attach", widthPt: nil, runs: 1) { print(String(format: "re-attach to snapshot %.1f ms", (CACurrentMediaTime()-t0)*1000)); exit(0) }
                    }
                }
            }
        }
    }
}
webView.loadHTMLString(html, baseURL: URL(string: "https://spike.example/")!)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
