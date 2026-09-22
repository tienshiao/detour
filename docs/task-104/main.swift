// TASK-104 control: plain WKWebViews cycled with removeFromSuperview/addSubview
// (Detour's hide/show pattern) so the GPU process's IOSurface count can be
// sampled without any Detour code involved.
import AppKit
import WebKit

let args = CommandLine.arguments
let urls = (args.count > 1 ? args[1] : "https://www.youtube.com/watch?v=dQw4w9WgXcQ,https://www.youtube.com/,https://github.com/WebKit/WebKit,https://www.apple.com/")
    .split(separator: ",").map { URL(string: String($0))! }
let switches = args.count > 2 ? Int(args[2])! : 150
let interval = args.count > 3 ? Double(args[3])! : 0.7
let settle = args.count > 4 ? Double(args[4])! : 45
let logPath = args.count > 5 ? args[5] : "/tmp/spike.log"
let hideMode = args.count > 6 ? args[6] : "remove"   // remove | hidden | none

let fmt = ISO8601DateFormatter()
fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func mark(_ s: String) {
    let line = "\(fmt.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
    print(s)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "spike"
let container = NSView(frame: window.contentView!.bounds)
container.autoresizingMask = [.width, .height]
window.contentView!.addSubview(container)
window.makeKeyAndOrderFront(nil)

let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
var views: [WKWebView] = []
for u in urls {
    let wv = WKWebView(frame: container.bounds, configuration: config)
    wv.autoresizingMask = [.width, .height]
    wv.load(URLRequest(url: u))
    views.append(wv)
}

var current = -1
func show(_ i: Int) {
    if hideMode == "occlude" {
        // one visible web view; a "switch" hides and re-shows the whole window
        if current < 0 { container.addSubview(views[0]); current = 0; return }
        window.orderOut(nil)
        after(interval / 2) { window.makeKeyAndOrderFront(nil) }
        return
    }
    if current >= 0 {
        switch hideMode {
        case "hidden": views[current].isHidden = true
        case "none": break
        default: views[current].removeFromSuperview()
        }
    }
    let v = views[i]
    v.frame = container.bounds
    if v.superview == nil { container.addSubview(v) }
    v.isHidden = false
    current = i
}
// hideMode none: all views stay in the hierarchy; the shown one is brought to front
if hideMode == "none" { for v in views { container.addSubview(v) } }
show(0)
mark("PHASE seed pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(hideMode) urls=\(urls.count) switches=\(switches)")

func after(_ s: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block) }
func loop(_ label: String, remaining: Int, index: Int, done: @escaping () -> Void) {
    guard remaining > 0 else { mark("PHASE \(label)-end"); done(); return }
    show(index % views.count)
    after(interval) { loop(label, remaining: remaining - 1, index: index + 1, done: done) }
}
after(20) {
    mark("PHASE idle")
    after(settle) {
        mark("PHASE switch1")
        loop("switch1", remaining: switches, index: 1) {
            mark("PHASE settle1")
            after(settle) {
                mark("PHASE switch2")
                loop("switch2", remaining: switches, index: 1) {
                    mark("PHASE settle2")
                    after(settle) {
                        mark("PHASE close")
                        show(0)
                        for v in views.dropFirst() { v.removeFromSuperview() }
                        views.removeLast(views.count - 1)
                        after(settle) { mark("PHASE done") }
                    }
                }
            }
        }
    }
}
app.run()
