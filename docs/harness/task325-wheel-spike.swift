import AppKit
import WebKit

// TASK-325 spike (2026-11-14, macOS 26.7): which synthetic two-finger scrolls does WebKit report
// to the private WKUIDelegate method _webView:didNotHandleWheelEvent:, for a page with no back item?
//
// Build: swiftc task325-wheel-spike.swift -module-cache-path $TMPDIR/mc -o spike
// Run with the sandbox OFF (the web process does not launch inside it).
//
// Result (see wiki/platform/back-swipe-and-unhandled-scrolls.md), back direction = deltaX > 0:
//   gestures on,  any rubber-band edges (even 0)  -> horizontal scrolls never reported (vertical ones are, with 0)
//   gestures off, left rubber-banding on (15)     -> not reported (the rubber band consumes them)
//   gestures off, left excluded (14) or 0         -> every back-direction event reported (began, changed, ended,
//                                                    phaseless); forward still rubber-bands at 14 (not reported)
//   gestures off, 14 or 0, overflow-x scroller at scrollLeft 600 under the pointer -> page scrolls it (600 -> 456),
//                                                    not reported; same scroller at scrollLeft 0 -> reported
//   gestures off, 0, wheel listener calling preventDefault -> listener gets 12 events, not reported
//   gestures off, right excluded (11) or left+right (10), dx < 0 -> forward events reported; with 10 back is too;
//                                                    scroller at scrollLeft 200 -> page scrolls it forward (200 -> 344), not reported
// Synthetic CGEvent scrolls sent with window.sendEvent; trackSwipeEvent itself is not exercised here.

// Spike: does WebKit report a back-direction overscroll on a page with NO back item
// as unhandled (_webView:didNotHandleWheelEvent:)? With default rubber-banding, and with
// left rubber-banding disabled via _setRubberBandingEnabled:.

final class UIDelegate: NSObject, WKUIDelegate {
    var unhandled: [String] = []
    @objc(_webView:didNotHandleWheelEvent:)
    func _webView(_ webView: WKWebView, didNotHandleWheelEvent event: NSEvent) {
        unhandled.append("phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) dx=\(event.scrollingDeltaX)")
    }
}
final class NavDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let f = onFinish; onFinish = nil; f?() }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
webView.allowsBackForwardNavigationGestures = true
window.contentView = webView
window.orderFrontRegardless()
let ui = UIDelegate(); let nav = NavDelegate()
webView.uiDelegate = ui; webView.navigationDelegate = nav

func setRubber(_ v: Int) {
    let sel = NSSelectorFromString("_setRubberBandingEnabled:")
    typealias F = @convention(c) (AnyObject, Selector, UInt) -> Void
    let f = unsafeBitCast(webView.method(for: sel), to: F.self)
    f(webView, sel, UInt(v))
}
func pinned() -> Int { (webView.value(forKey: "_pinnedState") as? NSNumber)?.intValue ?? -1 }
func rubber() -> Int { (webView.value(forKey: "_rubberBandingEnabled") as? NSNumber)?.intValue ?? -1 }

func scrollEvent(dx: Int32, dy: Int32, phase: Int64, momentum: Int64 = 0) -> NSEvent {
    let center = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
    let screenPt = window.convertPoint(toScreen: center)
    let screenH = NSScreen.screens[0].frame.height
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
    cg.location = CGPoint(x: screenPt.x, y: screenH - screenPt.y)
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
    return NSEvent(cgEvent: cg)!
}

func runGesture(dx: Int32, then: @escaping () -> Void) {
    // NSEventPhase raw: began=1, changed=4, ended=8 (CG scroll phase uses kCGScrollPhase: began=1 changed=2 ended=4)
    var events: [NSEvent] = [scrollEvent(dx: dx, dy: 0, phase: 1)]
    for _ in 0..<8 { events.append(scrollEvent(dx: dx, dy: 0, phase: 2)) }
    events.append(scrollEvent(dx: 0, dy: 0, phase: 4))
    var i = 0
    func step() {
        if i < events.count { window.sendEvent(events[i]); i += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: then) }
    }
    step()
}

func load(_ html: String, then: @escaping () -> Void) {
    nav.onFinish = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: then) }
    webView.loadHTMLString(html, baseURL: URL(string: "https://spike.example/")!)
}

func report(_ name: String, extra: String = "", done: @escaping () -> Void) {
    webView.evaluateJavaScript("JSON.stringify({sx: scrollX, inner: (document.getElementById('h')||{}).scrollLeft, wheel: window.wheelCount||0})") { r, _ in
        print("[\(name)] canGoBack=\(webView.canGoBack) pinned=\(pinned()) rubber=\(rubber()) unhandled=\(ui.unhandled.count) \(ui.unhandled.prefix(3)) page=\(r ?? "nil") \(extra)")
        ui.unhandled.removeAll()
        done()
    }
}

let plain = "<html><body style='height:3000px'><h1>plain</h1></body></html>"
let scroller = "<html><body><div id=h style='width:800px;height:500px;overflow-x:scroll;white-space:nowrap'><div style='width:4000px;height:400px;background:linear-gradient(90deg,red,blue)'></div></div><script>onload=()=>{document.getElementById('h').scrollLeft=600}</script></body></html>"
let handler = "<html><body style='height:3000px'><script>window.wheelCount=0;addEventListener('wheel',e=>{wheelCount++;e.preventDefault()},{passive:false})</script></body></html>"

var steps: [(@escaping () -> Void) -> Void] = []
let tiny = "<html><body><h1>tiny</h1></body></html>"
func gesture(_ name: String, dx: Int32, dy: Int32 = 0, then next: @escaping () -> Void) {
    var events: [NSEvent] = [scrollEvent(dx: dx, dy: dy, phase: 1)]
    for _ in 0..<8 { events.append(scrollEvent(dx: dx, dy: dy, phase: 2)) }
    events.append(scrollEvent(dx: 0, dy: 0, phase: 4))
    // momentum-less legacy (no phase) events too
    for _ in 0..<3 { events.append(scrollEvent(dx: dx, dy: dy, phase: 0)) }
    var i = 0
    func step() { if i < events.count { window.sendEvent(events[i]); i += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { report(name, done: next) } } }
    step()
}
steps.append { next in load(tiny) { setRubber(0); gesture("tiny/rubber0/gestOn/back", dx: 12, then: next) } }
steps.append { next in gesture("tiny/rubber0/gestOn/down", dx: 0, dy: -12, then: next) }
steps.append { next in webView.allowsBackForwardNavigationGestures = false; setRubber(0); gesture("tiny/rubber0/gestOff/back", dx: 12, then: next) }
steps.append { next in setRubber(15); gesture("tiny/rubber15/gestOff/back", dx: 12, then: next) }
steps.append { next in setRubber(15); gesture("tiny/rubber15/gestOff/down", dx: 0, dy: -12, then: next) }
// Gesture off, rubber-banding 0: is a scroll the page DOES use left unreported?
steps.append { next in load(scroller) { webView.allowsBackForwardNavigationGestures = false; setRubber(0); gesture("scroller(600)/rubber0/gestOff/back", dx: 12, then: next) } }
steps.append { next in load(handler) { webView.allowsBackForwardNavigationGestures = false; setRubber(0); gesture("preventDefault/rubber0/gestOff/back", dx: 12, then: next) } }
// Inner scroller already at scrollLeft 0: the page cannot use a back-direction scroll.
steps.append { next in load(scroller.replacingOccurrences(of: "scrollLeft=600", with: "scrollLeft=0")) { webView.allowsBackForwardNavigationGestures = false; setRubber(0); gesture("scroller(0)/rubber0/gestOff/back", dx: 12, then: next) } }

// Left edge only excluded (top/bottom/right keep their bounce): is that enough?
steps.append { next in load(tiny) { webView.allowsBackForwardNavigationGestures = false; setRubber(14); gesture("tiny/rubber14/gestOff/back", dx: 12, then: next) } }
steps.append { next in gesture("tiny/rubber14/gestOff/forward", dx: -12, then: next) }
steps.append { next in load(scroller) { webView.allowsBackForwardNavigationGestures = false; setRubber(14); gesture("scroller(600)/rubber14/gestOff/back", dx: 12, then: next) } }

// Forward too (user decision 1): right edge excluded (11), and left + right both excluded (10).
steps.append { next in load(tiny) { webView.allowsBackForwardNavigationGestures = false; setRubber(11); gesture("tiny/rubber11/gestOff/forward", dx: -12, then: next) } }
steps.append { next in setRubber(10); gesture("tiny/rubber10/gestOff/forward", dx: -12, then: next) }
steps.append { next in gesture("tiny/rubber10/gestOff/back", dx: 12, then: next) }
steps.append { next in load(scroller.replacingOccurrences(of: "scrollLeft=600", with: "scrollLeft=200")) { webView.allowsBackForwardNavigationGestures = false; setRubber(10); gesture("scroller(200)/rubber10/gestOff/forward", dx: -12, then: next) } }

func runAll(_ i: Int) { if i < steps.count { steps[i]({ runAll(i + 1) }) } else { exit(0) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { runAll(0) }
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("timeout"); exit(1) }
app.run()
